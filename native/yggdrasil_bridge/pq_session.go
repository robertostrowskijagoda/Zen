package main

import (
	"bytes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hpke"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
)

// The session layer: every signal between two Zen nodes, and every packet
// of call media (bridge_relay.go), is sealed with keys from the hybrid KEM
// (pq_kem.go), on top of Yggdrasil's own (classical) encryption. There is
// no plaintext mode: a node takes only sealed frames and the few control
// messages that set the keys up.
//
// Sessions go one way. A node that sends to a peer for the first time asks
// for its key record ('K', with its own record, "want" set) and holds what
// it sends until the record comes back. The answer carries the peer's
// record and a challenge: a secret the peer encapsulated to this node's
// device key. A session then mixes two KEM secrets: a fresh one
// encapsulated to the peer's device key (only the peer can read the
// session), and the peer's challenge (only the holder of this node's
// device key can have opened it, so only this node can make a session the
// peer takes as coming from this address). Who holds the Ed25519 node key
// alone — someone who broke it with a quantum computer — can neither read
// a session nor start one in the node's name.
//
// The ciphertext (and the challenge id) go along in the header of the
// session's frames until the peer acknowledges the session ('A'); after
// that a frame carries only the session id and a counter. KEM operations
// happen only here — at a session's start, when it is rotated and when a
// challenge is given — never per frame. A receiver that gets a frame of a
// session or challenge it does not know (it restarted, it is the other
// process of the same device) answers 'N' with a fresh challenge, and the
// sender starts a new session.
//
// Device keys are pinned per address on first sight (pins): a record with
// another key for a pinned address is refused, so a broken node key cannot
// swap in a key of its own either. The app keeps the pins across restarts
// (YggPqPinsJson / YggPqSetPinsJson).
//
// Wire (signals: the signal text before fragmentation; media: the payload
// of a relay packet):
//
//	"ZPQ1" 'K' flags(1: want, challenge) record [chid(16) ct(1120)]
//	"ZPQ1" 'D' flags(1: opening) sid(16) counter(8) [chid(16) ct(1120)]
//	       AEAD(signal text)
//	"ZPQ1" 'M' flags(1: opening) sid(16) counter(8) [chid(16) ct(1120)]
//	       AEAD(relay frame)
//	"ZPQ1" 'A' sid(16)                     the session is known here
//	"ZPQ1" 'N' flags(1: want, challenge) sid(16) [chid(16) ct(1120)]
//	                                       the session is not known here
//
// The keys of a session are HKDF-SHA256(kemSecret | challengeSecret,
// info "zen.pq.keys.v2" | sender | recipient | sid | chid), 64 bytes: one
// ChaCha20-Poly1305 key for signals, one for media, each with its own
// counter (nonce 0^4 | counter) and replay window. The associated data is
// the frame header plus the sender's and the recipient's address, so a
// session belongs to one ordered pair and cannot be moved to another.
const (
	pqMagic            = "ZPQ1"
	pqKindKeys         = 'K'
	pqKindData         = 'D'
	pqKindMedia        = 'M'
	pqKindAck          = 'A'
	pqKindUnknown      = 'N'
	pqFlagWant         = 0x01
	pqFlagChallenge    = 0x02
	pqFlagCiphertext   = 0x01
	pqSessionIDSize    = 16
	pqChallengeIDSize  = 16
	pqDataHeaderSize   = len(pqMagic) + 1 + 1 + pqSessionIDSize + 8
	pqOpeningSize      = pqChallengeIDSize + pqCiphertextSize
	pqMaxFrameOverhead = pqDataHeaderSize + pqOpeningSize + chacha20poly1305.Overhead
	// Bytes a media packet grows by once its session is acknowledged.
	pqMediaOverhead       = pqDataHeaderSize + chacha20poly1305.Overhead
	pqSessionInfo         = "zen.pq.session.v2"
	pqChallengeInfo       = "zen.pq.challenge.v1"
	pqKeysInfo            = "zen.pq.keys.v2"
	pqSessionLifetime     = time.Hour
	pqSessionMaxFrames    = 1 << 24
	pqReceiveSessionsKept = 4
	pqReceiveSessionIdle  = 2*pqSessionLifetime + 10*time.Minute
	// A receive session opens nothing once this old: a sender starts a new
	// one every pqSessionLifetime, so only a session someone keeps alive
	// on purpose ever gets here.
	pqReceiveSessionMaxAge = 2 * pqSessionLifetime
	pqNewSessionsPerMinute = 16
	pqReplayWindow         = 1024
	// Media of several calls with one peer shares a session; a wider
	// window keeps reordered packets of a busy video call.
	pqMediaReplayWindow  = 4096
	pqKeyRequestInterval = 2 * time.Second
	// While frames wait for a peer's record, it is asked again this many
	// times (after pqKeyRequestInterval, then twice and four times that),
	// without waiting for the app's next send.
	pqKeyReasks            = 3
	pqKeyReplyInterval     = time.Second
	pqUnknownReplyInterval = time.Second
	pqAckInterval          = 250 * time.Millisecond
	pqPendingTTL           = 20 * time.Second
	pqPendingPerPeer       = 64
	pqPendingBytesPerPeer  = 4 * 1024 * 1024
	pqPendingBytesTotal    = 16 * 1024 * 1024
	// Signal frames sent lately are kept this long (within these limits):
	// when the peer answers that it does not know their session (it
	// restarted, or the other process of the device took its address
	// over), they go again under a new one instead of being lost. A
	// peer answers at once, so a short while is enough, and it keeps a
	// frame the peer did open before it restarted from coming twice.
	pqResendWindow       = 10 * time.Second
	pqResendPerPeer      = 16
	pqResendBytesPerPeer = 256 * 1024
	pqResendBytesTotal   = 4 * 1024 * 1024
	pqMaxPeers           = 4096
	// A challenge given to a peer is kept this long (a session opened with
	// it must reach this node within that time) ...
	pqChallengeKeep  = 6 * time.Hour
	pqChallengesKept = 4
	// ... and the peer starts sessions with it only while it is younger
	// than this, asking for a new one once it is older than
	// pqChallengeRefresh (so a rotation never waits for one).
	pqChallengeUseLimit     = 4 * time.Hour
	pqChallengeRefresh      = 2 * time.Hour
	pqChallengeRefreshRetry = time.Minute
	// KEM operations other nodes can make this node do (opening sessions
	// and challenges, giving challenges), all peers together.
	pqForeignKEMPerSecond = 200
	pqForeignKEMBurst     = 400
	// Addresses whose device key is pinned. New pins come at most
	// pqNewPinsPerMinute (strangers' addresses cost nothing to make); when
	// the pins are full, the one seen longest ago makes room, so filling
	// them takes hours and evicts nobody this node talks to meanwhile.
	pqMaxPins          = 16384
	pqNewPinsPerMinute = 120
)

// pqPin is the device key fingerprint pinned for an address.
type pqPin struct {
	fingerprint [sha256.Size]byte
	seen        time.Time
}

// maxSignalWireBytes is the longest signal text on the wire: the largest
// signal, sealed.
const maxSignalWireBytes = maxSignalPayloadBytes + pqMaxFrameOverhead

// errPQNotReady: no session can be made with the peer yet (its key record
// or challenge is on its way).
var errPQNotReady = errors.New("pq: no session with the peer yet")

// isPQWire reports whether a signal text belongs to the session layer.
func isPQWire(wire string) bool {
	return len(wire) > len(pqMagic) && wire[:len(pqMagic)] == pqMagic
}

type pqSessionID [pqSessionIDSize]byte

type pqChallengeID [pqChallengeIDSize]byte

// pqChallenge is a challenge this node gave a peer (issued) or the newest
// one a peer gave this node.
type pqChallenge struct {
	id     pqChallengeID
	secret []byte
	at     time.Time
}

type pqSendSession struct {
	id         pqSessionID
	challenge  pqChallengeID
	ciphertext []byte
	signal     cipher.AEAD
	media      cipher.AEAD
	next       uint64
	mediaNext  uint64
	created    time.Time
	// The peer said it knows the session: frames go without ciphertext.
	acked bool
}

type pqReceiveSession struct {
	id pqSessionID
	// The fingerprint of the peer's device key the session was made with
	// (its challenge was sealed to that key): what its frames are labelled
	// with, whatever key the address has by now.
	fingerprint [sha256.Size]byte
	signal      cipher.AEAD
	media       cipher.AEAD
	created     time.Time
	lastUsed    time.Time
	lastAck     time.Time
	window      pqReplay
	mediaWindow *pqMediaReplay
}

type pqPendingFrame struct {
	wire  []byte
	until time.Time
}

// pqSentFrame is a signal frame sent lately under session (see
// pqResendWindow).
type pqSentFrame struct {
	wire    []byte
	session pqSessionID
	at      time.Time
}

type pqPeer struct {
	ip net.IP
	// The peer's device key, from its verified record (nil: not known yet),
	// and its fingerprint.
	publicKey   []byte
	fingerprint [sha256.Size]byte
	send        *pqSendSession
	receive     []*pqReceiveSession
	// Challenges this node gave the peer, oldest first, and the newest the
	// peer gave this node.
	issued       []pqChallenge
	challenge    *pqChallenge
	pending      []pqPendingFrame
	pendingBytes int
	// Asks again for the record armed while frames wait, and how many
	// were made for the frames waiting now (see reask).
	reaskArmed bool
	reasks     int
	// Signal frames sent lately, oldest first, to send again under a new
	// session should the peer not know theirs.
	sent        []pqSentFrame
	sentBytes   int
	keysAskedAt time.Time
	keysSentAt  time.Time
	unknownAt   time.Time
	// New KEM openings in the current minute (a stranger cannot make this
	// node decapsulate without end).
	sessionsMinute time.Time
	sessionsCount  int
	lastUsed       time.Time
}

// pqBucket is a token bucket.
type pqBucket struct {
	tokens float64
	at     time.Time
}

func (b *pqBucket) allow(now time.Time, rate, burst float64) bool {
	if b.at.IsZero() {
		b.tokens = burst
	} else if elapsed := now.Sub(b.at).Seconds(); elapsed > 0 {
		b.tokens = min(burst, b.tokens+elapsed*rate)
	}
	b.at = now
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// pqEndpoint is the session layer of one node.
type pqEndpoint struct {
	mu          sync.Mutex
	local       net.IP
	key         hpke.PrivateKey
	record      []byte
	fingerprint [sha256.Size]byte
	peers       map[string]*pqPeer
	// Device key fingerprints by address (see pins above).
	pins         map[string]*pqPin
	newPins      pqBucket
	pendingBytes int
	sentBytes    int
	foreignKEM   pqBucket
	// Sends a signal text (already sealed, or a control message) to a peer.
	write func(destination net.IP, wire []byte) error
	now   func() time.Time
	// Runs f after d (time.AfterFunc; tests run it by hand).
	after func(d time.Duration, f func())
}

func newPQEndpoint(nodeKey ed25519.PrivateKey, local net.IP, write func(net.IP, []byte) error) (*pqEndpoint, error) {
	local16 := local.To16()
	if local16 == nil || local.To4() != nil {
		return nil, errors.New("pq: the node has no mesh address")
	}
	seed, err := pqDeviceSeed(nodeKey)
	if err != nil {
		return nil, err
	}
	defer wipeBytes(seed)
	key, err := pqPrivateKey(seed)
	if err != nil {
		return nil, err
	}
	publicKey := key.PublicKey().Bytes()
	record, err := pqBuildRecord(nodeKey, publicKey)
	if err != nil {
		return nil, err
	}
	return &pqEndpoint{
		local:       bytes.Clone(local16),
		key:         key,
		record:      record,
		fingerprint: sha256.Sum256(publicKey),
		peers:       make(map[string]*pqPeer),
		pins:        make(map[string]*pqPin),
		write:       write,
		now:         time.Now,
		after:       func(d time.Duration, f func()) { time.AfterFunc(d, f) },
	}, nil
}

func pqSessionInfoFor(sender, recipient net.IP, id pqSessionID) []byte {
	info := make([]byte, 0, len(pqSessionInfo)+16+16+pqSessionIDSize)
	info = append(info, pqSessionInfo...)
	info = append(info, sender.To16()...)
	info = append(info, recipient.To16()...)
	return append(info, id[:]...)
}

func pqChallengeInfoFor(issuer, holder net.IP, id pqChallengeID) []byte {
	info := make([]byte, 0, len(pqChallengeInfo)+16+16+pqChallengeIDSize)
	info = append(info, pqChallengeInfo...)
	info = append(info, issuer.To16()...)
	info = append(info, holder.To16()...)
	return append(info, id[:]...)
}

// pqSessionKeys are the signal and media AEADs of a session.
func pqSessionKeys(kemSecret, challengeSecret []byte, sender, recipient net.IP, id pqSessionID, challenge pqChallengeID) (cipher.AEAD, cipher.AEAD, error) {
	ikm := make([]byte, 0, len(kemSecret)+len(challengeSecret))
	ikm = append(ikm, kemSecret...)
	ikm = append(ikm, challengeSecret...)
	info := make([]byte, 0, len(pqKeysInfo)+32+pqSessionIDSize+pqChallengeIDSize)
	info = append(info, pqKeysInfo...)
	info = append(info, sender.To16()...)
	info = append(info, recipient.To16()...)
	info = append(info, id[:]...)
	info = append(info, challenge[:]...)
	keys, err := hkdf.Key(sha256.New, ikm, nil, string(info), 2*chacha20poly1305.KeySize)
	if err != nil {
		return nil, nil, err
	}
	signal, err := chacha20poly1305.New(keys[:chacha20poly1305.KeySize])
	if err != nil {
		return nil, nil, err
	}
	media, err := chacha20poly1305.New(keys[chacha20poly1305.KeySize:])
	if err != nil {
		return nil, nil, err
	}
	return signal, media, nil
}

func pqNonce(counter uint64) []byte {
	nonce := make([]byte, chacha20poly1305.NonceSize)
	binary.BigEndian.PutUint64(nonce[4:], counter)
	return nonce
}

func pqAssociatedData(header []byte, sender, recipient net.IP) []byte {
	aad := make([]byte, 0, len(header)+32)
	aad = append(aad, header...)
	aad = append(aad, sender.To16()...)
	return append(aad, recipient.To16()...)
}

func (e *pqEndpoint) peerLocked(ip net.IP, now time.Time) *pqPeer {
	key := ip.String()
	peer := e.peers[key]
	if peer == nil {
		if len(e.peers) >= pqMaxPeers {
			e.evictPeerLocked()
		}
		peer = &pqPeer{ip: bytes.Clone(ip.To16())}
		e.peers[key] = peer
	}
	peer.lastUsed = now
	return peer
}

// evictPeerLocked forgets the peer used longest ago (its record comes again
// on the next contact; its pin stays).
func (e *pqEndpoint) evictPeerLocked() {
	var oldestKey string
	var oldest *pqPeer
	for key, peer := range e.peers {
		if oldest == nil || peer.lastUsed.Before(oldest.lastUsed) {
			oldestKey, oldest = key, peer
		}
	}
	if oldest != nil {
		e.pendingBytes -= oldest.pendingBytes
		e.sentBytes -= oldest.sentBytes
		delete(e.peers, oldestKey)
	}
}

func (e *pqEndpoint) allowForeignKEMLocked(now time.Time) bool {
	return e.foreignKEM.allow(now, pqForeignKEMPerSecond, pqForeignKEMBurst)
}

// openingFrame appends the opening part (challenge id, ciphertext).
func appendOpening(frame []byte, id pqChallengeID, ciphertext []byte) []byte {
	frame = append(frame, id[:]...)
	return append(frame, ciphertext...)
}

func (e *pqEndpoint) keysFrame(want bool, challenge *pqChallengeID, ciphertext []byte) []byte {
	frame := make([]byte, 0, len(pqMagic)+2+len(e.record)+pqOpeningSize)
	frame = append(frame, pqMagic...)
	flags := byte(0)
	if want {
		flags |= pqFlagWant
	}
	if challenge != nil {
		flags |= pqFlagChallenge
	}
	frame = append(frame, pqKindKeys, flags)
	frame = append(frame, e.record...)
	if challenge != nil {
		frame = appendOpening(frame, *challenge, ciphertext)
	}
	return frame
}

func pqControlFrame(kind byte, id pqSessionID) []byte {
	frame := make([]byte, 0, len(pqMagic)+1+pqSessionIDSize)
	frame = append(frame, pqMagic...)
	frame = append(frame, kind)
	return append(frame, id[:]...)
}

func pqUnknownFrame(id pqSessionID, want bool, challenge *pqChallengeID, ciphertext []byte) []byte {
	frame := make([]byte, 0, len(pqMagic)+2+pqSessionIDSize+pqOpeningSize)
	frame = append(frame, pqMagic...)
	flags := byte(0)
	if want {
		flags |= pqFlagWant
	}
	if challenge != nil {
		flags |= pqFlagChallenge
	}
	frame = append(frame, pqKindUnknown, flags)
	frame = append(frame, id[:]...)
	if challenge != nil {
		frame = appendOpening(frame, *challenge, ciphertext)
	}
	return frame
}

// issueChallengeLocked gives peer a new challenge: its id and the
// ciphertext only the holder of the peer's device key opens. ok is false
// without the peer's key or over the KEM budget.
func (e *pqEndpoint) issueChallengeLocked(peer *pqPeer, now time.Time) (pqChallengeID, []byte, bool) {
	var id pqChallengeID
	if peer.publicKey == nil || !e.allowForeignKEMLocked(now) {
		return id, nil, false
	}
	if _, err := rand.Read(id[:]); err != nil {
		return id, nil, false
	}
	ciphertext, secret, err := pqEncapsulate(peer.publicKey, pqChallengeInfoFor(e.local, peer.ip, id))
	if err != nil {
		return id, nil, false
	}
	kept := make([]pqChallenge, 0, pqChallengesKept)
	for _, issued := range peer.issued {
		if now.Sub(issued.at) < pqChallengeKeep {
			kept = append(kept, issued)
		}
	}
	if len(kept) >= pqChallengesKept {
		kept = kept[len(kept)-pqChallengesKept+1:]
	}
	peer.issued = append(kept, pqChallenge{id: id, secret: secret, at: now})
	return id, ciphertext, true
}

func (peer *pqPeer) issuedChallenge(id pqChallengeID, now time.Time) *pqChallenge {
	for index := range peer.issued {
		issued := &peer.issued[index]
		if issued.id == id && now.Sub(issued.at) < pqChallengeKeep {
			return issued
		}
	}
	return nil
}

// takeChallengeLocked opens a challenge source gave this node and keeps it
// as the newest.
func (e *pqEndpoint) takeChallengeLocked(peer *pqPeer, opening []byte, now time.Time) {
	if len(opening) != pqOpeningSize || !peer.allowNewSession(now) || !e.allowForeignKEMLocked(now) {
		return
	}
	var id pqChallengeID
	copy(id[:], opening[:pqChallengeIDSize])
	secret, err := pqDecapsulate(e.key, opening[pqChallengeIDSize:], pqChallengeInfoFor(peer.ip, e.local, id))
	if err != nil {
		return
	}
	peer.challenge = &pqChallenge{id: id, secret: secret, at: now}
}

func (peer *pqPeer) usableChallenge(now time.Time) *pqChallenge {
	if peer.challenge == nil || now.Sub(peer.challenge.at) >= pqChallengeUseLimit {
		return nil
	}
	return peer.challenge
}

// askLocked tells whether to ask peer for its record and a challenge now.
func (e *pqEndpoint) askLocked(peer *pqPeer, now time.Time, interval time.Duration) bool {
	if now.Sub(peer.keysAskedAt) < interval {
		return false
	}
	peer.keysAskedAt = now
	return true
}

// refreshLocked tells whether to ask for a new challenge before the one in
// hand gets too old for new sessions.
func (e *pqEndpoint) refreshLocked(peer *pqPeer, now time.Time) bool {
	if peer.challenge == nil || now.Sub(peer.challenge.at) < pqChallengeRefresh {
		return false
	}
	return e.askLocked(peer, now, pqChallengeRefreshRetry)
}

// sendSessionLocked is the session to seal with: the current one while it
// lasts, else a new one, or nil when there is no key or challenge yet.
func (e *pqEndpoint) sendSessionLocked(peer *pqPeer, now time.Time) (*pqSendSession, error) {
	session := peer.send
	if session != nil && now.Sub(session.created) < pqSessionLifetime &&
		session.next < pqSessionMaxFrames && session.mediaNext < pqSessionMaxFrames {
		return session, nil
	}
	challenge := peer.usableChallenge(now)
	if peer.publicKey == nil || challenge == nil {
		return nil, nil
	}
	var id pqSessionID
	if _, err := rand.Read(id[:]); err != nil {
		return nil, err
	}
	ciphertext, secret, err := pqEncapsulate(peer.publicKey, pqSessionInfoFor(e.local, peer.ip, id))
	if err != nil {
		return nil, err
	}
	signal, media, err := pqSessionKeys(secret, challenge.secret, e.local, peer.ip, id, challenge.id)
	if err != nil {
		return nil, err
	}
	session = &pqSendSession{
		id:         id,
		challenge:  challenge.id,
		ciphertext: ciphertext,
		signal:     signal,
		media:      media,
		created:    now,
	}
	peer.send = session
	return session, nil
}

// pqSealJob is a frame to seal once the endpoint's lock is released (the
// AEADs are safe for concurrent use; a large signal must not hold up call
// media).
type pqSealJob struct {
	header  []byte
	aead    cipher.AEAD
	counter uint64
	plain   []byte
	to      net.IP
}

func (job pqSealJob) seal(from net.IP) []byte {
	out := make([]byte, len(job.header), len(job.header)+len(job.plain)+chacha20poly1305.Overhead)
	copy(out, job.header)
	return job.aead.Seal(out, pqNonce(job.counter), job.plain, pqAssociatedData(job.header, from, job.to))
}

// frameLocked takes the next counter of session for kind and builds the
// frame's header.
func (e *pqEndpoint) frameLocked(peer *pqPeer, session *pqSendSession, kind byte, plain []byte) pqSealJob {
	aead, counter := session.signal, session.next
	if kind == pqKindMedia {
		aead, counter = session.media, session.mediaNext
		session.mediaNext++
	} else {
		session.next++
	}
	size := pqDataHeaderSize
	if !session.acked {
		size += pqOpeningSize
	}
	header := make([]byte, 0, size)
	header = append(header, pqMagic...)
	flags := byte(0)
	if !session.acked {
		flags = pqFlagCiphertext
	}
	header = append(header, kind, flags)
	header = append(header, session.id[:]...)
	header = binary.BigEndian.AppendUint64(header, counter)
	if !session.acked {
		header = appendOpening(header, session.challenge, session.ciphertext)
	}
	return pqSealJob{header: header, aead: aead, counter: counter, plain: plain, to: peer.ip}
}

// sealLocked seals one signal text for peer (tests and benchmarks).
func (e *pqEndpoint) sealLocked(peer *pqPeer, wire []byte, now time.Time) ([]byte, error) {
	session, err := e.sendSessionLocked(peer, now)
	if err != nil {
		return nil, err
	}
	if session == nil {
		return nil, errPQNotReady
	}
	return e.frameLocked(peer, session, pqKindData, wire).seal(e.local), nil
}

// send seals wire (a signal text) for destination and sends it, or holds
// it until destination's key record and challenge are known.
func (e *pqEndpoint) send(destination net.IP, wire []byte) error {
	destination16 := destination.To16()
	if destination16 == nil || destination.To4() != nil {
		return fmt.Errorf("pq: invalid destination %s", destination)
	}
	e.mu.Lock()
	now := e.now()
	peer := e.peerLocked(destination16, now)
	session, err := e.sendSessionLocked(peer, now)
	if err != nil {
		e.mu.Unlock()
		return err
	}
	if session == nil {
		e.dropExpiredLocked(peer, now)
		if len(peer.pending) == 0 {
			peer.reasks = 0
		}
		e.holdLocked(peer, wire, now)
		ask := e.askLocked(peer, now, pqKeyRequestInterval)
		e.armReaskLocked(peer)
		e.mu.Unlock()
		if ask {
			return e.write(destination16, e.keysFrame(true, nil, nil))
		}
		return nil
	}
	job := e.frameLocked(peer, session, pqKindData, wire)
	e.keepSentLocked(peer, session.id, bytes.Clone(wire), now)
	refresh := e.refreshLocked(peer, now)
	e.mu.Unlock()
	if refresh {
		_ = e.write(destination16, e.keysFrame(true, nil, nil))
	}
	return e.write(destination16, job.seal(e.local))
}

// keepSentLocked keeps wire, just sent to peer under session, for
// pqResendWindow within the limits; older frames go first.
func (e *pqEndpoint) keepSentLocked(peer *pqPeer, session pqSessionID, wire []byte, now time.Time) {
	e.dropOldSentLocked(peer, now)
	if len(wire) > pqResendBytesPerPeer {
		return
	}
	for len(peer.sent) > 0 &&
		(len(peer.sent) >= pqResendPerPeer ||
			peer.sentBytes+len(wire) > pqResendBytesPerPeer ||
			e.sentBytes+len(wire) > pqResendBytesTotal) {
		e.dropFirstSentLocked(peer)
	}
	if e.sentBytes+len(wire) > pqResendBytesTotal {
		return
	}
	peer.sent = append(peer.sent, pqSentFrame{wire: wire, session: session, at: now})
	peer.sentBytes += len(wire)
	e.sentBytes += len(wire)
}

func (e *pqEndpoint) dropFirstSentLocked(peer *pqPeer) {
	size := len(peer.sent[0].wire)
	peer.sent = peer.sent[1:]
	peer.sentBytes -= size
	e.sentBytes -= size
}

func (e *pqEndpoint) dropOldSentLocked(peer *pqPeer, now time.Time) {
	for len(peer.sent) > 0 && now.Sub(peer.sent[0].at) > pqResendWindow {
		e.dropFirstSentLocked(peer)
	}
}

// resendLocked puts the frames sent lately under session (which the peer
// does not know) back in front of what peer holds, to go under the next
// session; they are not kept for it any more.
func (e *pqEndpoint) resendLocked(peer *pqPeer, session pqSessionID, now time.Time) {
	e.dropOldSentLocked(peer, now)
	var again []pqPendingFrame
	kept := peer.sent[:0:0]
	for _, sent := range peer.sent {
		if sent.session == session {
			again = append(again, pqPendingFrame{wire: sent.wire, until: now.Add(pqPendingTTL)})
		} else {
			kept = append(kept, sent)
		}
	}
	if len(again) == 0 {
		return
	}
	peer.sent = kept
	e.sentBytes -= peer.sentBytes
	peer.sentBytes = 0
	for _, sent := range kept {
		peer.sentBytes += len(sent.wire)
	}
	e.sentBytes += peer.sentBytes
	for _, frame := range again {
		peer.pendingBytes += len(frame.wire)
		e.pendingBytes += len(frame.wire)
	}
	peer.pending = append(again, peer.pending...)
	for len(peer.pending) > 0 &&
		(len(peer.pending) > pqPendingPerPeer ||
			peer.pendingBytes > pqPendingBytesPerPeer ||
			e.pendingBytes > pqPendingBytesTotal) {
		e.dropFirstPendingLocked(peer)
	}
}

// sealMedia seals a relay frame (call media) for destination. Media is
// never held (a late packet is worse than a lost one) and never sent in
// clear: without a session yet it asks for the keys and returns
// errPQNotReady.
func (e *pqEndpoint) sealMedia(destination net.IP, frame []byte) ([]byte, error) {
	destination16 := destination.To16()
	if destination16 == nil || destination.To4() != nil {
		return nil, fmt.Errorf("pq: invalid destination %s", destination)
	}
	e.mu.Lock()
	now := e.now()
	peer := e.peerLocked(destination16, now)
	session, err := e.sendSessionLocked(peer, now)
	if err != nil {
		e.mu.Unlock()
		return nil, err
	}
	if session == nil {
		ask := e.askLocked(peer, now, pqKeyRequestInterval)
		e.mu.Unlock()
		if ask {
			_ = e.write(destination16, e.keysFrame(true, nil, nil))
		}
		return nil, errPQNotReady
	}
	job := e.frameLocked(peer, session, pqKindMedia, frame)
	refresh := e.refreshLocked(peer, now)
	e.mu.Unlock()
	if refresh {
		_ = e.write(destination16, e.keysFrame(true, nil, nil))
	}
	return job.seal(e.local), nil
}

// armReaskLocked asks peer again for its record (and a challenge) a while
// from now, while frames wait for it. A first contact loses its first
// tries: the mesh keeps only the last packet for an address whose key or
// path it is still looking up, a key request is two packets and the
// answer three, and the answer looks up its own way back. Only the app's
// next send asked again before, and a friend request waited for the relay
// engine's backoff (10 s, 30 s, minutes) although the way was found within
// a second or two.
func (e *pqEndpoint) armReaskLocked(peer *pqPeer) {
	if peer.reaskArmed || peer.reasks >= pqKeyReasks || len(peer.pending) == 0 {
		return
	}
	peer.reaskArmed = true
	ip := bytes.Clone(peer.ip)
	e.after(pqKeyRequestInterval<<peer.reasks, func() { e.reask(ip) })
}

// reask is armReaskLocked's timer: asks again while frames still wait for
// ip's record or challenge.
func (e *pqEndpoint) reask(ip net.IP) {
	e.mu.Lock()
	peer := e.peers[ip.String()]
	if peer == nil {
		e.mu.Unlock()
		return
	}
	peer.reaskArmed = false
	now := e.now()
	e.dropExpiredLocked(peer, now)
	if len(peer.pending) == 0 || (peer.publicKey != nil && peer.usableChallenge(now) != nil) {
		peer.reasks = 0
		e.mu.Unlock()
		return
	}
	peer.reasks++
	ask := e.askLocked(peer, now, pqKeyRequestInterval)
	e.armReaskLocked(peer)
	e.mu.Unlock()
	if ask {
		_ = e.write(ip, e.keysFrame(true, nil, nil))
	}
}

// holdLocked keeps wire for peer until its key record arrives, within
// the limits; older frames go first.
func (e *pqEndpoint) holdLocked(peer *pqPeer, wire []byte, now time.Time) {
	e.dropExpiredLocked(peer, now)
	if len(wire) > pqPendingBytesPerPeer {
		return
	}
	for len(peer.pending) > 0 &&
		(len(peer.pending) >= pqPendingPerPeer ||
			peer.pendingBytes+len(wire) > pqPendingBytesPerPeer ||
			e.pendingBytes+len(wire) > pqPendingBytesTotal) {
		e.dropFirstPendingLocked(peer)
	}
	if e.pendingBytes+len(wire) > pqPendingBytesTotal {
		return
	}
	peer.pending = append(peer.pending, pqPendingFrame{wire: bytes.Clone(wire), until: now.Add(pqPendingTTL)})
	peer.pendingBytes += len(wire)
	e.pendingBytes += len(wire)
}

func (e *pqEndpoint) dropFirstPendingLocked(peer *pqPeer) {
	size := len(peer.pending[0].wire)
	peer.pending = peer.pending[1:]
	peer.pendingBytes -= size
	e.pendingBytes -= size
}

func (e *pqEndpoint) dropExpiredLocked(peer *pqPeer, now time.Time) {
	for len(peer.pending) > 0 && now.After(peer.pending[0].until) {
		e.dropFirstPendingLocked(peer)
	}
}

// flushLocked seals what peer holds once a session can be made.
func (e *pqEndpoint) flushLocked(peer *pqPeer, now time.Time) []pqSealJob {
	e.dropExpiredLocked(peer, now)
	if len(peer.pending) == 0 {
		return nil
	}
	session, err := e.sendSessionLocked(peer, now)
	if err != nil || session == nil {
		return nil
	}
	jobs := make([]pqSealJob, 0, len(peer.pending))
	for _, pending := range peer.pending {
		jobs = append(jobs, e.frameLocked(peer, session, pqKindData, pending.wire))
		e.keepSentLocked(peer, session.id, pending.wire, now)
	}
	e.pendingBytes -= peer.pendingBytes
	peer.pending = nil
	peer.pendingBytes = 0
	peer.reasks = 0
	return jobs
}

func (e *pqEndpoint) writeJobs(to net.IP, jobs []pqSealJob) {
	for _, job := range jobs {
		if err := e.write(to, job.seal(e.local)); err != nil {
			debugf("[ZEN-GO] pq: held frame to %s not sent: %v\n", to, err)
		}
	}
}

// receive takes one signal text from source: the plaintext it carries, or
// false for a control message, something that does not open, or anything
// not sealed (refused).
func (e *pqEndpoint) receive(source net.IP, wire []byte) ([]byte, bool) {
	plain, _, ok := e.receiveKeyed(source, wire)
	return plain, ok
}

// receiveKeyed is receive, with the fingerprint (hex) of the device key
// the session that carried the text was made with.
func (e *pqEndpoint) receiveKeyed(source net.IP, wire []byte) ([]byte, string, bool) {
	source16 := source.To16()
	if source16 == nil || len(wire) < len(pqMagic)+1 || string(wire[:len(pqMagic)]) != pqMagic {
		return nil, "", false
	}
	body := wire[len(pqMagic)+1:]
	switch wire[len(pqMagic)] {
	case pqKindKeys:
		e.receiveKeys(source16, body)
	case pqKindAck:
		e.receiveAck(source16, body)
	case pqKindUnknown:
		e.receiveUnknown(source16, body)
	case pqKindData:
		plain, fingerprint, ok := e.open(source16, wire, pqKindData)
		if !ok {
			return nil, "", false
		}
		return plain, hex.EncodeToString(fingerprint[:]), true
	}
	return nil, "", false
}

// receiveMedia opens a media frame (a relay packet) from source.
func (e *pqEndpoint) receiveMedia(source net.IP, wire []byte) ([]byte, bool) {
	source16 := source.To16()
	if source16 == nil || len(wire) < len(pqMagic)+1 || string(wire[:len(pqMagic)]) != pqMagic ||
		wire[len(pqMagic)] != pqKindMedia {
		return nil, false
	}
	plain, _, ok := e.open(source16, wire, pqKindMedia)
	return plain, ok
}

// acceptRecordLocked takes a verified record of source unless its address
// is pinned to another key; a key seen for the first time is pinned.
func (e *pqEndpoint) acceptRecordLocked(source net.IP, publicKey []byte, now time.Time) (*pqPeer, bool) {
	fingerprint := sha256.Sum256(publicKey)
	address := source.String()
	if pinned, ok := e.pins[address]; ok {
		if pinned.fingerprint != fingerprint {
			return nil, false
		}
		pinned.seen = now
	} else if e.newPins.allow(now, float64(pqNewPinsPerMinute)/60, pqNewPinsPerMinute) {
		e.makeRoomForPinLocked()
		e.pins[address] = &pqPin{fingerprint: fingerprint, seen: now}
	}
	peer := e.peerLocked(source, now)
	if !bytes.Equal(peer.publicKey, publicKey) {
		e.resetPeerKeyLocked(peer)
		peer.publicKey = publicKey
		peer.fingerprint = fingerprint
	}
	return peer, true
}

// makeRoomForPinLocked drops the pin seen longest ago when the pins are
// full.
func (e *pqEndpoint) makeRoomForPinLocked() {
	if len(e.pins) < pqMaxPins {
		return
	}
	var oldestKey string
	var oldest *pqPin
	for key, pin := range e.pins {
		if oldest == nil || pin.seen.Before(oldest.seen) {
			oldestKey, oldest = key, pin
		}
	}
	delete(e.pins, oldestKey)
}

// resetPeerKeyLocked forgets everything made with peer's device key: the
// sessions both ways too, so nothing opened with the old key (a session an
// impostor started before the real key was pinned) is taken any more.
func (e *pqEndpoint) resetPeerKeyLocked(peer *pqPeer) {
	peer.publicKey = nil
	peer.fingerprint = [sha256.Size]byte{}
	peer.send = nil
	peer.receive = nil
	peer.issued = nil
	peer.challenge = nil
}

func (e *pqEndpoint) receiveKeys(source net.IP, body []byte) {
	if len(body) != 1+pqRecordSize && len(body) != 1+pqRecordSize+pqOpeningSize {
		return
	}
	flags := body[0]
	hasChallenge := flags&pqFlagChallenge != 0
	if hasChallenge != (len(body) == 1+pqRecordSize+pqOpeningSize) {
		return
	}
	publicKey, err := pqVerifyRecord(body[1:1+pqRecordSize], source)
	if err != nil {
		debugf("[ZEN-GO] pq: key record from %s refused: %v\n", source, err)
		return
	}
	e.mu.Lock()
	now := e.now()
	peer, ok := e.acceptRecordLocked(source, publicKey, now)
	if !ok {
		e.mu.Unlock()
		debugf("[ZEN-GO] pq: key record from %s is not the pinned one\n", source)
		return
	}
	if flags&pqFlagWant != 0 && e.peerLostStateLocked(peer, now) {
		// The session the peer no longer knows goes, and what went lately
		// under it goes again under the next one, as after 'N': frames sent
		// while the peer restarted reached nobody (its new core dropped
		// them while it set up a session with this node's core), so nobody
		// could say the session was unknown. The challenge in hand went
		// with the peer's old state too.
		id := peer.send.id
		peer.send = nil
		e.resendLocked(peer, id, now)
		peer.challenge = nil
	}
	if hasChallenge {
		e.takeChallengeLocked(peer, body[1+pqRecordSize:], now)
	}
	var reply []byte
	if flags&pqFlagWant != 0 && now.Sub(peer.keysSentAt) >= pqKeyReplyInterval {
		peer.keysSentAt = now
		reply = e.replyKeysLocked(peer, now)
	}
	jobs := e.flushLocked(peer, now)
	ask := reply == nil && len(peer.pending) > 0 && peer.usableChallenge(now) == nil &&
		e.askLocked(peer, now, pqKeyRequestInterval)
	e.mu.Unlock()
	if reply != nil {
		_ = e.write(source, reply)
	}
	if ask {
		_ = e.write(source, e.keysFrame(true, nil, nil))
	}
	e.writeJobs(source, jobs)
}

// peerLostStateLocked tells whether peer, which asks for this node's record
// and a challenge, lost what it had of this node (it restarted, or the other
// process of the device took its address over): it acknowledged this node's
// session and was given a challenge too lately to ask for a new one
// (pqChallengeRefresh).
func (e *pqEndpoint) peerLostStateLocked(peer *pqPeer, now time.Time) bool {
	if peer.send == nil || !peer.send.acked || len(peer.issued) == 0 {
		return false
	}
	return now.Sub(peer.issued[len(peer.issued)-1].at) < pqChallengeRefresh/2
}

// replyKeysLocked is this node's record with a fresh challenge for peer,
// asking for one back when this node has none from peer.
func (e *pqEndpoint) replyKeysLocked(peer *pqPeer, now time.Time) []byte {
	want := peer.usableChallenge(now) == nil
	if id, ciphertext, ok := e.issueChallengeLocked(peer, now); ok {
		return e.keysFrame(want, &id, ciphertext)
	}
	return e.keysFrame(want, nil, nil)
}

func (e *pqEndpoint) receiveAck(source net.IP, body []byte) {
	if len(body) != pqSessionIDSize {
		return
	}
	var id pqSessionID
	copy(id[:], body)
	e.mu.Lock()
	defer e.mu.Unlock()
	peer := e.peers[source.String()]
	if peer == nil || peer.send == nil || peer.send.id != id {
		return
	}
	// Known: frames go without the opening.
	peer.send.acked = true
}

// receiveUnknown: the peer does not know a session of this node (it
// restarted, or it lost the challenge the session was opened with). The
// session is dropped; the next frame starts a new one, with the challenge
// that came along, or after asking for one.
func (e *pqEndpoint) receiveUnknown(source net.IP, body []byte) {
	if len(body) != 1+pqSessionIDSize && len(body) != 1+pqSessionIDSize+pqOpeningSize {
		return
	}
	flags := body[0]
	hasChallenge := flags&pqFlagChallenge != 0
	if hasChallenge != (len(body) == 1+pqSessionIDSize+pqOpeningSize) {
		return
	}
	var id pqSessionID
	copy(id[:], body[1:1+pqSessionIDSize])
	e.mu.Lock()
	now := e.now()
	peer := e.peers[source.String()]
	if peer == nil || peer.send == nil || peer.send.id != id {
		e.mu.Unlock()
		return
	}
	peer.send = nil
	// What went lately under it did not open there: it goes again under
	// the next session (a pong to a friend whose app just started again).
	e.resendLocked(peer, id, now)
	if hasChallenge && peer.publicKey != nil {
		e.takeChallengeLocked(peer, body[1+pqSessionIDSize:], now)
	} else {
		// The peer's state is gone: the challenge in hand may be too.
		peer.challenge = nil
	}
	var reply []byte
	if flags&pqFlagWant != 0 && now.Sub(peer.keysSentAt) >= pqKeyReplyInterval {
		peer.keysSentAt = now
		reply = e.replyKeysLocked(peer, now)
	}
	jobs := e.flushLocked(peer, now)
	ask := reply == nil && peer.usableChallenge(now) == nil && e.askLocked(peer, now, pqKeyRequestInterval)
	e.mu.Unlock()
	if reply != nil {
		_ = e.write(source, reply)
	}
	if ask {
		_ = e.write(source, e.keysFrame(true, nil, nil))
	}
	e.writeJobs(source, jobs)
}

// unknownReplyLocked answers a frame of a session (or challenge) this node
// does not know: with a fresh challenge when it has the sender's key,
// else asking for its record. Nil within pqUnknownReplyInterval.
func (e *pqEndpoint) unknownReplyLocked(peer *pqPeer, id pqSessionID, now time.Time) []byte {
	if now.Sub(peer.unknownAt) < pqUnknownReplyInterval {
		return nil
	}
	peer.unknownAt = now
	if challenge, ciphertext, ok := e.issueChallengeLocked(peer, now); ok {
		return pqUnknownFrame(id, false, &challenge, ciphertext)
	}
	return pqUnknownFrame(id, peer.publicKey == nil, nil, nil)
}

// open opens a data or media frame: its plaintext and the fingerprint of
// the device key its session was made with.
func (e *pqEndpoint) open(source net.IP, wire []byte, kind byte) ([]byte, [sha256.Size]byte, bool) {
	var none [sha256.Size]byte
	if len(wire) < pqDataHeaderSize+chacha20poly1305.Overhead {
		return nil, none, false
	}
	offset := len(pqMagic) + 1
	flags := wire[offset]
	offset++
	var id pqSessionID
	copy(id[:], wire[offset:offset+pqSessionIDSize])
	offset += pqSessionIDSize
	counter := binary.BigEndian.Uint64(wire[offset : offset+8])
	offset += 8
	var opening []byte
	if flags&pqFlagCiphertext != 0 {
		if len(wire) < offset+pqOpeningSize+chacha20poly1305.Overhead {
			return nil, none, false
		}
		opening = wire[offset : offset+pqOpeningSize]
		offset += pqOpeningSize
	}
	header, sealed := wire[:offset], wire[offset:]
	aad := pqAssociatedData(header, source, e.local)

	e.mu.Lock()
	now := e.now()
	peer := e.peerLocked(source, now)
	session := peer.receiveSession(id)
	if session == nil {
		// A new session: opened, checked and kept under the lock (rare).
		plain, reply, ok := e.openNewLocked(peer, id, opening, kind, counter, sealed, aad, now)
		fingerprint := peer.fingerprint
		e.mu.Unlock()
		if reply != nil {
			_ = e.write(source, reply)
		}
		return plain, fingerprint, ok
	}
	// Too old: kept (so its opening cannot start it again) but refused.
	if now.Sub(session.created) >= pqReceiveSessionMaxAge || !session.windowFor(kind).fresh(counter) {
		e.mu.Unlock()
		return nil, none, false
	}
	aead := session.aeadFor(kind)
	e.mu.Unlock()

	// A known session: the AEAD runs without the lock, so a large signal
	// never holds up call media.
	plain, err := aead.Open(nil, pqNonce(counter), sealed, aad)
	if err != nil {
		return nil, none, false
	}
	e.mu.Lock()
	window := session.windowFor(kind)
	if !window.fresh(counter) {
		e.mu.Unlock()
		return nil, none, false
	}
	window.mark(counter)
	session.lastUsed = now
	ack := opening != nil && now.Sub(session.lastAck) >= pqAckInterval
	if ack {
		session.lastAck = now
	}
	e.mu.Unlock()
	if ack {
		_ = e.write(source, pqControlFrame(pqKindAck, id))
	}
	return plain, session.fingerprint, true
}

// openNewLocked opens the first frame of a session this node does not know
// yet. reply is a control frame to send back ('A' or 'N').
func (e *pqEndpoint) openNewLocked(peer *pqPeer, id pqSessionID, opening []byte, kind byte, counter uint64, sealed, aad []byte, now time.Time) ([]byte, []byte, bool) {
	if opening == nil {
		return nil, e.unknownReplyLocked(peer, id, now), false
	}
	var challengeID pqChallengeID
	copy(challengeID[:], opening[:pqChallengeIDSize])
	challenge := peer.issuedChallenge(challengeID, now)
	if challenge == nil {
		// Not a challenge this node gave (it restarted, or it is not
		// the sender it claims): nobody gets a session without one.
		return nil, e.unknownReplyLocked(peer, id, now), false
	}
	if !peer.allowNewSession(now) || !e.allowForeignKEMLocked(now) {
		return nil, nil, false
	}
	secret, err := pqDecapsulate(e.key, opening[pqChallengeIDSize:], pqSessionInfoFor(peer.ip, e.local, id))
	if err != nil {
		return nil, nil, false
	}
	signal, media, err := pqSessionKeys(secret, challenge.secret, peer.ip, e.local, id, challengeID)
	if err != nil {
		return nil, nil, false
	}
	session := &pqReceiveSession{id: id, fingerprint: peer.fingerprint, signal: signal, media: media, created: now}
	plain, err := session.aeadFor(kind).Open(nil, pqNonce(counter), sealed, aad)
	if err != nil {
		return nil, nil, false
	}
	session.windowFor(kind).mark(counter)
	session.lastUsed = now
	session.lastAck = now
	peer.addReceiveSession(session, now)
	return plain, pqControlFrame(pqKindAck, id), true
}

func (session *pqReceiveSession) aeadFor(kind byte) cipher.AEAD {
	if kind == pqKindMedia {
		return session.media
	}
	return session.signal
}

// pqWindow is a replay window.
type pqWindow interface {
	fresh(counter uint64) bool
	mark(counter uint64)
}

func (session *pqReceiveSession) windowFor(kind byte) pqWindow {
	if kind == pqKindMedia {
		if session.mediaWindow == nil {
			session.mediaWindow = new(pqMediaReplay)
		}
		return session.mediaWindow
	}
	return &session.window
}

func (peer *pqPeer) receiveSession(id pqSessionID) *pqReceiveSession {
	for _, session := range peer.receive {
		if session.id == id {
			return session
		}
	}
	return nil
}

func (peer *pqPeer) allowNewSession(now time.Time) bool {
	if now.Sub(peer.sessionsMinute) >= time.Minute {
		peer.sessionsMinute = now
		peer.sessionsCount = 0
	}
	if peer.sessionsCount >= pqNewSessionsPerMinute {
		return false
	}
	peer.sessionsCount++
	return true
}

// addReceiveSession keeps session and the newest others (a sender rotates
// its session; frames of the old one may still be on their way).
func (peer *pqPeer) addReceiveSession(session *pqReceiveSession, now time.Time) {
	kept := make([]*pqReceiveSession, 0, pqReceiveSessionsKept)
	for _, other := range peer.receive {
		if now.Sub(other.lastUsed) < pqReceiveSessionIdle {
			kept = append(kept, other)
		}
	}
	for len(kept) >= pqReceiveSessionsKept {
		oldest := 0
		for index, other := range kept {
			if other.created.Before(kept[oldest].created) {
				oldest = index
			}
		}
		kept = append(kept[:oldest], kept[oldest+1:]...)
	}
	peer.receive = append(kept, session)
}

// ownFingerprint is the fingerprint of this node's device key (hex).
// peerState tells what this endpoint has of the peer at ip (diagnostics):
// its key, the challenge it gave, challenges issued to it, the session and
// frames held for it.
func (e *pqEndpoint) peerState(ip net.IP) string {
	e.mu.Lock()
	defer e.mu.Unlock()
	peer := e.peers[ip.To16().String()]
	if peer == nil {
		return "unknown peer"
	}
	now := e.now()
	session := "none"
	if peer.send != nil {
		session = fmt.Sprintf("sent %d acked %v", peer.send.next, peer.send.acked)
	}
	return fmt.Sprintf("key %v, its challenge %v, issued %d, receive sessions %d, send session %s, held %d",
		peer.publicKey != nil, peer.usableChallenge(now) != nil, len(peer.issued),
		len(peer.receive), session, len(peer.pending))
}

func (e *pqEndpoint) ownFingerprint() string {
	return hex.EncodeToString(e.fingerprint[:])
}

// peerFingerprint is the fingerprint (hex) of the device key source's
// sessions are made with, "" when it is not known.
func (e *pqEndpoint) peerFingerprint(source net.IP) string {
	e.mu.Lock()
	defer e.mu.Unlock()
	peer := e.peers[source.String()]
	if peer == nil || peer.publicKey == nil {
		return ""
	}
	return hex.EncodeToString(peer.fingerprint[:])
}

// pinsSnapshot is every pin: address -> device key fingerprint (hex).
func (e *pqEndpoint) pinsSnapshot() map[string]string {
	e.mu.Lock()
	defer e.mu.Unlock()
	pins := make(map[string]string, len(e.pins))
	for address, pin := range e.pins {
		pins[address] = hex.EncodeToString(pin.fingerprint[:])
	}
	return pins
}

// importPins adds pins: kept from an earlier run, or vouched for by the
// app (a friend's device key from a hybrid-signed record or hello). They
// win over a key this run merely saw. With keep, a pin already there that
// names another key stays, and the address is returned among the
// conflicts (address -> the pinned fingerprint): two sources disagree
// about who is at that address, and the app warns. Malformed entries are
// skipped; the count taken is returned.
func (e *pqEndpoint) importPins(pins map[string]string, keep bool) (int, map[string]string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	taken := 0
	conflicts := map[string]string{}
	for address, value := range pins {
		ip := net.ParseIP(address)
		decoded, err := hex.DecodeString(value)
		if ip == nil || ip.To4() != nil || !isYggNodeAddress(ip) || err != nil || len(decoded) != sha256.Size {
			continue
		}
		var fingerprint [sha256.Size]byte
		copy(fingerprint[:], decoded)
		key := ip.String()
		existing, ok := e.pins[key]
		if ok && keep && existing.fingerprint != fingerprint {
			conflicts[key] = hex.EncodeToString(existing.fingerprint[:])
			continue
		}
		if !ok {
			e.makeRoomForPinLocked()
		}
		e.pins[key] = &pqPin{fingerprint: fingerprint, seen: e.now()}
		if peer := e.peers[key]; peer != nil && peer.publicKey != nil && peer.fingerprint != fingerprint {
			e.resetPeerKeyLocked(peer)
		}
		taken++
	}
	return taken, conflicts
}

// pqReplay remembers which of the last pqReplayWindow counters came.
type pqReplay struct {
	highest uint64
	any     bool
	seen    [pqReplayWindow / 64]uint64
}

func (r *pqReplay) fresh(counter uint64) bool {
	return replayFresh(r.highest, r.any, r.seen[:], counter)
}

func (r *pqReplay) mark(counter uint64) {
	replayMark(&r.highest, &r.any, r.seen[:], counter)
}

// pqMediaReplay is the wider window of media frames.
type pqMediaReplay struct {
	highest uint64
	any     bool
	seen    [pqMediaReplayWindow / 64]uint64
}

func (r *pqMediaReplay) fresh(counter uint64) bool {
	return replayFresh(r.highest, r.any, r.seen[:], counter)
}

func (r *pqMediaReplay) mark(counter uint64) {
	replayMark(&r.highest, &r.any, r.seen[:], counter)
}

func replayFresh(highest uint64, any bool, seen []uint64, counter uint64) bool {
	if !any || counter > highest {
		return true
	}
	if highest-counter >= uint64(len(seen))*64 {
		return false
	}
	return seen[(counter/64)%uint64(len(seen))]&(1<<(counter%64)) == 0
}

func replayMark(highest *uint64, any *bool, seen []uint64, counter uint64) {
	size := uint64(len(seen)) * 64
	if !*any || counter > *highest {
		start := *highest + 1
		if !*any || counter-*highest >= size {
			clear(seen)
		} else {
			// Clear the bits of the counters skipped over: they now name
			// counters a full window ahead of the ones they held.
			for value := start; value < counter; value++ {
				seen[(value/64)%uint64(len(seen))] &^= 1 << (value % 64)
			}
		}
		*highest = counter
		*any = true
	}
	seen[(counter/64)%uint64(len(seen))] |= 1 << (counter % 64)
}
