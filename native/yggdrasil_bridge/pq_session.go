package main

import (
	"bytes"
	"container/list"
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
	"sort"
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
// sender starts a new session. A frame sent just as the receiver restarted
// never gets that far (the receiver's new mesh core drops it while it sets
// up a session with the sender's core), so a node's key record says when
// it holds no session of the peer's ("fresh"): the peer then drops its own
// and sends again what went lately under it.
//
// Device keys are pinned per address on first sight (pins): a record with
// another key for a pinned address is refused, so a broken node key cannot
// swap in a key of its own either. A pin is firm only once the device
// proved it holds the key: a session with it opened here, or the app
// vouched for it (a hello signed by the device's hybrid key came over a
// session with that key). A pin no session followed is loose: loose pins
// have a share of the table of their own and expire unseen. The app keeps
// the pins and their kind across restarts (YggPqPinsJson /
// YggPqSetPinsJson). What someone else says about an address (a friend's
// friend list, a friend's device record) is only a hint (importHints),
// which the device's own record confirms or overrules.
//
// Who is known (the app's friends and this person's own devices) the app
// says explicitly (setKnown): only they use the known peers' KEM budget,
// and only their peer entries and pins are never pushed out by others.
// Nothing a stranger does (being answered, being written to) makes it
// known.
//
// Wire (signals: the signal text before fragmentation; media: the payload
// of a relay packet):
//
//	"ZPQ1" 'K' flags(1: want, challenge, fresh) record [chid(16) ct(1120)]
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
	pqMagic         = "ZPQ1"
	pqKindKeys      = 'K'
	pqKindData      = 'D'
	pqKindMedia     = 'M'
	pqKindAck       = 'A'
	pqKindUnknown   = 'N'
	pqFlagWant      = 0x01
	pqFlagChallenge = 0x02
	// The sender holds no session of the receiver's. Peers up to 1.14 never
	// set it and ignore it.
	pqFlagFresh        = 0x04
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
	pqKeyRequestInterval = time.Second
	// While frames wait for a peer's record, it is asked again this many
	// times, without waiting for the app's next send: every
	// pqKeyRequestInterval for the first pqKeyReasksSteady, then twice as
	// long each time (within pqPendingTTL): 1, 2, 3, 4, 5, 7, 11 and 19 s
	// after the first ask. A friend's node that just restarted is often
	// out of reach for its first seconds; asking every second through them
	// gets the frames there as soon as it is, not at the next doubling.
	pqKeyReasks            = 8
	pqKeyReasksSteady      = 5
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
	// Peer entries of addresses that are not known (setKnown); the one used
	// longest ago makes room. Known peers' entries are never pushed out.
	pqMaxPeers = 4096
	// Addresses the app names as known at most.
	pqMaxKnown = 4096
	// A challenge given to a peer is kept this long (a session opened with
	// it must reach this node within that time) ...
	pqChallengeKeep  = 6 * time.Hour
	pqChallengesKept = 4
	// Sessions one challenge starts at most (a sender starts one an hour,
	// and anew after a restart); then the sender is given another.
	pqSessionsPerChallenge = 32
	// ... and the peer starts sessions with it only while it is younger
	// than this, asking for a new one once it is older than
	// pqChallengeRefresh (so a rotation never waits for one).
	pqChallengeUseLimit     = 4 * time.Hour
	pqChallengeRefresh      = 2 * time.Hour
	pqChallengeRefreshRetry = time.Minute
	// Challenges given to one peer in a minute at most (answers to its key
	// requests, and to frames of sessions this node does not know): every
	// one is a KEM operation, from whichever budget the peer belongs to.
	pqChallengesPerMinute = pqNewSessionsPerMinute
	// KEM operations other nodes can make this node do (opening sessions
	// and challenges, giving challenges), all known peers together (see
	// knownLocked) ...
	pqForeignKEMPerSecond = 200
	pqForeignKEMBurst     = 400
	// A phone does a fifth of that: each operation keeps it awake, so a
	// stranger asking for sessions over and over would drain its battery.
	// Friends opening sessions after a network change fit the burst.
	pqPhoneForeignKEMPerSecond = 40
	pqPhoneForeignKEMBurst     = 200
	// ... and all other peers together: addresses cost nothing to make, so
	// strangers asking over and over spend this budget, never the known
	// peers'. A challenge given from it pays for the first session opened
	// with it as well, so a first contact that got one gets its session.
	pqStrangerKEMPerSecond      = 20
	pqStrangerKEMBurst          = 40
	pqPhoneStrangerKEMPerSecond = 4
	pqPhoneStrangerKEMBurst     = 20
	// Answers to frames of sessions from addresses this node has no peer
	// for (it restarted: "ask for my record"), all of them together; no
	// peer is made for such a frame.
	pqUnknownRepliesPerSecond = 20
	pqUnknownRepliesBurst     = 40
	// Addresses whose device key is pinned. New pins from records come at
	// most pqNewPinsPerMinute (strangers' addresses cost nothing to make)
	// and are loose: at most pqMaxLoosePins of them, the one seen longest
	// ago making room, and each goes once unseen for pqLoosePinTTL. A pin
	// whose device had a session here (firm) or that the app vouched for
	// is never pushed out by a record; a session pushes out a loose pin or
	// the firm one seen longest ago, a vouch a loose pin or the vouched one
	// seen longest ago, and a pin of a known address goes only when it is
	// loose and expired. A session pins its device even with no new pins
	// left.
	pqMaxPins          = 16384
	pqMaxLoosePins     = pqMaxPins / 4
	pqNewPinsPerMinute = 120
	pqLoosePinTTL      = 14 * 24 * time.Hour
	// Pins kept by an app before the kinds of pins were kept (1.16.4 and
	// earlier saved every pin as firm, made-up keys a friend's device
	// record named among them) come back loose, as if seen this long
	// before they would expire: a device that is around in that time
	// confirms its pin (a record or a session with the same key), while a
	// pin nobody holds the key of stops keeping the real device out.
	pqLegacyPinGrace = 3 * 24 * time.Hour
	// Expired loose pins dropped at most per new pin (the rest go with
	// later ones, or when the app reads the pins).
	pqExpiredPerPin = 16
	// Device keys someone else names for an address (hints): a friend's
	// friend list or device record. At most this many; a new one makes
	// room by dropping the hint given longest ago.
	pqMaxHints = 8192
	// Vouched keys that found the pins full of firm and vouched pins are
	// kept as vouched hints, at most this many: a record that contradicts
	// one is refused and reported (takeConflicts).
	pqMaxVouchedHints = 1024
	// Contradictions waiting for the app to read them.
	pqMaxConflicts = 64
)

// pqPin is the device key fingerprint pinned for an address (or, in
// hints, named for it).
type pqPin struct {
	fingerprint [sha256.Size]byte
	seen        time.Time
	// The device proved it holds the key: a session with it opened here.
	firm bool
	// The app vouched for it: a hello signed by the device's hybrid key
	// came over a session with that key (or the pin was restored so).
	vouched bool
	// The eviction list it is on (nil: none, its address is known) and its
	// element there.
	list *list.List
	elem *list.Element
}

// loose tells whether nothing but a record backs the pin.
func (pin *pqPin) loose() bool {
	return !pin.firm && !pin.vouched
}

// expired tells whether a loose pin went unseen too long.
func (pin *pqPin) expired(now time.Time) bool {
	return pin.loose() && now.Sub(pin.seen) > pqLoosePinTTL
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

// isPQDataWire reports whether a signal text is a sealed signal frame
// ('D'): a copy of one is dropped unopened (its counter was seen), so the
// mesh writer may send it again (mesh_io.go, echoes).
func isPQDataWire(wire []byte) bool {
	return isPQWire(string(wire[:min(len(wire), len(pqMagic)+1)])) && wire[len(pqMagic)] == pqKindData
}

type pqSessionID [pqSessionIDSize]byte

type pqChallengeID [pqChallengeIDSize]byte

// pqChallenge is a challenge this node gave a peer (issued) or the newest
// one a peer gave this node.
type pqChallenge struct {
	id     pqChallengeID
	secret []byte
	at     time.Time
	// Given from the strangers' budget, which paid for the first session
	// opened with it too (issued challenges only).
	prepaid bool
	// The sessions opened with it (issued challenges only): kept as long
	// as the challenge, so an opening frame recorded earlier starts nothing
	// again once its session is gone.
	opened []pqSessionID
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
	// Challenges given to the peer in the current minute.
	challengesMinute time.Time
	challengesCount  int
	lastUsed         time.Time
	// Its element in the strangers' peers (nil while it is known).
	elem *list.Element
}

// pqBucket is a token bucket.
type pqBucket struct {
	tokens float64
	at     time.Time
}

func (b *pqBucket) allow(now time.Time, rate, burst float64) bool {
	return b.take(now, rate, burst, 1)
}

// take takes n tokens at once, or none.
func (b *pqBucket) take(now time.Time, rate, burst, n float64) bool {
	if b.at.IsZero() {
		b.tokens = burst
	} else if elapsed := now.Sub(b.at).Seconds(); elapsed > 0 {
		b.tokens = min(burst, b.tokens+elapsed*rate)
	}
	b.at = now
	if b.tokens < n {
		return false
	}
	b.tokens -= n
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
	// Addresses of the peers that are not known, used last first: the
	// last makes room.
	strangerPeers list.List
	// The addresses the app named as known (setKnown): its friends and
	// this person's own devices.
	known map[string]struct{}
	// Device key fingerprints by address (see pins above), and the
	// eviction lists of the pins of addresses that are not known, seen
	// last first.
	pins        map[string]*pqPin
	loosePins   list.List
	firmPins    list.List
	vouchedPins list.List
	// Device key fingerprints others named for addresses not pinned (see
	// importHints): never a pin until the device's own record agrees; and
	// vouched keys that found no room among the pins. Given last first.
	hints        map[string]*pqPin
	wordHints    list.List
	vouchedHints list.List
	// Records refused because they contradict a vouched key, for the app
	// (takeConflicts): address -> the vouched fingerprint (hex).
	conflicts map[string]string
	newPins   pqBucket
	// New pins of devices a session opened with, whose records found no
	// new pins left (firmPinLocked).
	sessionPins  pqBucket
	pendingBytes int
	sentBytes    int
	foreignKEM   pqBucket
	strangerKEM  pqBucket
	// Answers to frames from addresses with no peer (open).
	unknownReplies pqBucket
	// The node runs on a phone (smaller KEM budgets).
	phone bool
	// Sends a signal text (already sealed, or a control message) to a peer.
	write func(destination net.IP, wire []byte) error
	// Tells the mesh writer a peer holds no session of this node's (it
	// restarted): the way to it settles (meshIO.settle). May be nil; set
	// before the endpoint is used.
	settle func(ip net.IP)
	now    func() time.Time
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
		hints:       make(map[string]*pqPin),
		phone:       isPhoneOS(),
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
		peer = &pqPeer{ip: bytes.Clone(ip.To16())}
		if !e.isKnownLocked(key) {
			if e.strangerPeers.Len() >= pqMaxPeers {
				e.evictStrangerLocked()
			}
			peer.elem = e.strangerPeers.PushFront(key)
		}
		e.peers[key] = peer
	} else if peer.elem != nil {
		e.strangerPeers.MoveToFront(peer.elem)
	}
	peer.lastUsed = now
	return peer
}

// evictStrangerLocked forgets the peer that is not known used longest ago
// (its record comes again on the next contact; its pin stays). A known
// peer's entry never goes: strangers' records, however many, cannot take
// a quiet friend's sessions and challenges away.
func (e *pqEndpoint) evictStrangerLocked() {
	back := e.strangerPeers.Back()
	if back == nil {
		return
	}
	key := back.Value.(string)
	e.strangerPeers.Remove(back)
	if peer := e.peers[key]; peer != nil && peer.elem == back {
		e.pendingBytes -= peer.pendingBytes
		e.sentBytes -= peer.sentBytes
		delete(e.peers, key)
	}
}

func (e *pqEndpoint) isKnownLocked(address string) bool {
	_, ok := e.known[address]
	return ok
}

// knownLocked tells whether peer's KEM work comes from the known peers'
// budget: only when the app named its address as known (a friend, or a
// device of this person). Being answered, written to or vouched for does
// not make a stranger known: the app answers anyone who asks (rly_ack),
// and a stranger's signed hello is as cheap as its address.
func (e *pqEndpoint) knownLocked(peer *pqPeer) bool {
	return e.isKnownLocked(peer.ip.String())
}

// setKnown replaces the addresses the app knows (its friends and this
// person's own devices), at most pqMaxKnown; malformed ones are skipped.
// Their peer entries and pins leave the eviction lists, and the entries
// and pins of addresses no longer known go back to them. Returns how many
// are known now.
func (e *pqEndpoint) setKnown(addresses []string) int {
	next := make(map[string]struct{}, min(len(addresses), pqMaxKnown))
	for _, address := range addresses {
		if len(next) >= pqMaxKnown {
			break
		}
		ip := net.ParseIP(address)
		if ip == nil || ip.To4() != nil || !isYggNodeAddress(ip) {
			continue
		}
		next[ip.String()] = struct{}{}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	before := e.known
	e.known = next
	for address := range before {
		if _, still := next[address]; !still {
			e.placeAddressLocked(address)
		}
	}
	for address := range next {
		if _, was := before[address]; !was {
			e.placeAddressLocked(address)
		}
	}
	for e.strangerPeers.Len() > pqMaxPeers {
		e.evictStrangerLocked()
	}
	return len(next)
}

// knownAddressesLocked is what setKnown took last (for the app to keep).
func (e *pqEndpoint) knownAddressesLocked() []string {
	addresses := make([]string, 0, len(e.known))
	for address := range e.known {
		addresses = append(addresses, address)
	}
	sort.Strings(addresses)
	return addresses
}

// placeAddressLocked puts address's peer entry and pin on the eviction
// lists, or takes them off, as its being known now says.
func (e *pqEndpoint) placeAddressLocked(address string) {
	if peer := e.peers[address]; peer != nil {
		known := e.isKnownLocked(address)
		if known && peer.elem != nil {
			e.strangerPeers.Remove(peer.elem)
			peer.elem = nil
		} else if !known && peer.elem == nil {
			peer.elem = e.strangerPeers.PushFront(address)
		}
	}
	if pin := e.pins[address]; pin != nil {
		e.placePinLocked(address, pin)
	}
}

// allowForeignKEMLocked takes n KEM operations peer makes this node do from
// the budget it belongs to.
func (e *pqEndpoint) allowForeignKEMLocked(peer *pqPeer, n float64, now time.Time) bool {
	switch known := e.knownLocked(peer); {
	case known && e.phone:
		return e.foreignKEM.take(now, pqPhoneForeignKEMPerSecond, pqPhoneForeignKEMBurst, n)
	case known:
		return e.foreignKEM.take(now, pqForeignKEMPerSecond, pqForeignKEMBurst, n)
	case e.phone:
		return e.strangerKEM.take(now, pqPhoneStrangerKEMPerSecond, pqPhoneStrangerKEMBurst, n)
	default:
		return e.strangerKEM.take(now, pqStrangerKEMPerSecond, pqStrangerKEMBurst, n)
	}
}

// openingFrame appends the opening part (challenge id, ciphertext).
func appendOpening(frame []byte, id pqChallengeID, ciphertext []byte) []byte {
	frame = append(frame, id[:]...)
	return append(frame, ciphertext...)
}

// keysFrame is this node's record (a 'K' frame): asking for the peer's
// (want), with a challenge for it, and saying this node holds no session
// of the peer's (fresh, pqFlagFresh).
func (e *pqEndpoint) keysFrame(want bool, challenge *pqChallengeID, ciphertext []byte, fresh bool) []byte {
	frame := make([]byte, 0, len(pqMagic)+2+len(e.record)+pqOpeningSize)
	frame = append(frame, pqMagic...)
	flags := byte(0)
	if want {
		flags |= pqFlagWant
	}
	if challenge != nil {
		flags |= pqFlagChallenge
	}
	if fresh {
		flags |= pqFlagFresh
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
// without the peer's key, past the peer's challenges of the minute, or over
// the KEM budget of the peers it belongs to.
func (e *pqEndpoint) issueChallengeLocked(peer *pqPeer, now time.Time) (pqChallengeID, []byte, bool) {
	var id pqChallengeID
	if peer.publicKey == nil || !peer.allowNewChallenge(now) {
		return id, nil, false
	}
	// A stranger's challenge pays for its first session as well.
	prepaid := !e.knownLocked(peer)
	cost := 1.0
	if prepaid {
		cost = 2
	}
	if !e.allowForeignKEMLocked(peer, cost, now) {
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
	peer.issued = append(kept, pqChallenge{id: id, secret: secret, at: now, prepaid: prepaid})
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
	if len(opening) != pqOpeningSize || !peer.allowNewSession(now) || !e.allowForeignKEMLocked(peer, 1, now) {
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
		var request []byte
		if e.askLocked(peer, now, pqKeyRequestInterval) {
			request = e.requestFrameLocked(peer)
		}
		e.armReaskLocked(peer)
		e.mu.Unlock()
		if request != nil {
			return e.write(destination16, request)
		}
		return nil
	}
	job := e.frameLocked(peer, session, pqKindData, wire)
	e.keepSentLocked(peer, session.id, bytes.Clone(wire), now)
	var request []byte
	if e.refreshLocked(peer, now) {
		request = e.requestFrameLocked(peer)
	}
	e.mu.Unlock()
	if request != nil {
		_ = e.write(destination16, request)
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
		var request []byte
		if e.askLocked(peer, now, pqKeyRequestInterval) {
			request = e.requestFrameLocked(peer)
		}
		e.mu.Unlock()
		if request != nil {
			_ = e.write(destination16, request)
		}
		return nil, errPQNotReady
	}
	job := e.frameLocked(peer, session, pqKindMedia, frame)
	var request []byte
	if e.refreshLocked(peer, now) {
		request = e.requestFrameLocked(peer)
	}
	e.mu.Unlock()
	if request != nil {
		_ = e.write(destination16, request)
	}
	return job.seal(e.local), nil
}

// armReaskLocked asks peer again for its record (and a challenge) a while
// from now, while frames wait for it. Only the app's next send asked again
// before, and a friend request waited for the relay engine's backoff (10 s,
// 30 s, minutes). The mesh writer opens the way before it sends more than
// one packet (mesh_io.go), but a request can still be lost: in the second
// or two a node needs to be found after it came on the mesh, or while two
// cores set up their sessions anew after one of them restarted (ironwood
// heals a session that went out of step only on the next packet, a second
// later).
func (e *pqEndpoint) armReaskLocked(peer *pqPeer) {
	if peer.reaskArmed || peer.reasks >= pqKeyReasks || len(peer.pending) == 0 {
		return
	}
	peer.reaskArmed = true
	ip := bytes.Clone(peer.ip)
	e.after(pqReaskDelay(peer.reasks), func() { e.reask(ip) })
}

// pqReaskDelay is the wait before asking again after reasks times.
func pqReaskDelay(reasks int) time.Duration {
	if reasks < pqKeyReasksSteady {
		return pqKeyRequestInterval
	}
	return pqKeyRequestInterval << (reasks - pqKeyReasksSteady + 1)
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
	var request []byte
	if e.askLocked(peer, now, pqKeyRequestInterval) {
		request = e.requestFrameLocked(peer)
	}
	e.armReaskLocked(peer)
	e.mu.Unlock()
	if request != nil {
		_ = e.write(ip, request)
	}
}

// hail asks a known contact at ip for its record when this node knows
// nothing of it: the mesh writer calls it when the contact reached this
// node unasked and nothing of it came through (mesh_io.go), as a frame of a
// session this node no longer holds does after a restart. The request says
// this node holds no session of the contact's (pqFlagFresh), so the contact
// sends again what it sent lately. Only pinned addresses are asked.
func (e *pqEndpoint) hail(ip net.IP) {
	ip16 := ip.To16()
	if ip16 == nil || ip.To4() != nil {
		return
	}
	e.mu.Lock()
	if e.pinLocked(ip16.String(), e.now()) == nil {
		e.mu.Unlock()
		return
	}
	if known := e.peers[ip16.String()]; known != nil && known.publicKey != nil {
		e.mu.Unlock()
		return
	}
	now := e.now()
	peer := e.peerLocked(ip16, now)
	var request []byte
	if e.askLocked(peer, now, pqKeyRequestInterval) {
		request = e.requestFrameLocked(peer)
	}
	e.mu.Unlock()
	if request != nil {
		_ = e.write(ip16, request)
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
// is pinned to another key, or a vouched key found no room among the pins
// and the record names another one (refused and kept for the app to
// report). A key seen for the first time is pinned loose. A hint someone
// else gave for the address goes either way: the record of the device
// itself decides, and a hint it confirms is pinned at once.
func (e *pqEndpoint) acceptRecordLocked(source net.IP, publicKey []byte, now time.Time) (*pqPeer, bool) {
	fingerprint := sha256.Sum256(publicKey)
	address := source.String()
	if pinned := e.pinLocked(address, now); pinned != nil {
		if pinned.fingerprint != fingerprint {
			if !pinned.loose() {
				// Only a holder of the address's node key signs such a
				// record: worth a line in the log, not only in debug.
				fmt.Printf("[ZEN-GO] pq: %s signed another device key than the one it proved; refused\n", source)
			}
			return nil, false
		}
		e.removeHintLocked(address)
		pinned.seen = now
		e.placePinLocked(address, pinned)
	} else {
		hint := e.hints[address]
		confirmed := hint != nil && hint.fingerprint == fingerprint
		switch {
		case hint != nil && hint.vouched && !confirmed:
			// The device proved another key elsewhere (a hello over a
			// session with it): whoever signed this one holds only the
			// address's node key.
			fmt.Printf("[ZEN-GO] pq: %s signed another device key than the one vouched for; refused\n", source)
			e.noteConflictLocked(address, hint.fingerprint)
			return nil, false
		case confirmed && hint.vouched:
			if e.roomForVouchLocked() {
				e.removeHintLocked(address)
				e.setPinLocked(address, &pqPin{fingerprint: fingerprint, seen: now, firm: true, vouched: true})
			}
		default:
			if hint != nil && !confirmed {
				debugf("[ZEN-GO] pq: %s signed another device key than it was named with\n", source)
			}
			e.removeHintLocked(address)
			if (confirmed || e.newPins.allow(now, float64(pqNewPinsPerMinute)/60, pqNewPinsPerMinute)) &&
				e.roomForLoosePinLocked(now) {
				e.setPinLocked(address, &pqPin{fingerprint: fingerprint, seen: now})
			}
		}
	}
	peer := e.peerLocked(source, now)
	if !bytes.Equal(peer.publicKey, publicKey) {
		e.resetPeerKeyLocked(peer)
		peer.publicKey = publicKey
		peer.fingerprint = fingerprint
	}
	return peer, true
}

// firmPinLocked marks peer's pin firm once a session with the device that
// holds its key opened (this node took one, or the peer took this node's):
// pinned now if the record was not (no new pins were left), unless the
// pins are full of firm ones.
func (e *pqEndpoint) firmPinLocked(peer *pqPeer, now time.Time) {
	if peer.publicKey == nil {
		return
	}
	address := peer.ip.String()
	if pinned := e.pinLocked(address, now); pinned != nil {
		if pinned.fingerprint == peer.fingerprint {
			pinned.firm = true
			pinned.seen = now
			e.placePinLocked(address, pinned)
		}
		return
	}
	// A vouched key a session now proves too may push out a vouched pin as
	// well as a firm one.
	hint := e.hints[address]
	vouched := hint != nil && hint.vouched && hint.fingerprint == peer.fingerprint
	// A stranger can open sessions too, at the price of KEM work: these
	// pins come no faster than the ones from records.
	if e.sessionPins.allow(now, float64(pqNewPinsPerMinute)/60, pqNewPinsPerMinute) &&
		(e.roomForFirmPinLocked() || (vouched && e.evictLastLocked(&e.vouchedPins))) {
		e.removeHintLocked(address)
		e.setPinLocked(address, &pqPin{fingerprint: peer.fingerprint, seen: now, firm: true, vouched: vouched})
	}
}

// pinLocked is address's pin, or nil: none, or a loose one that expired
// (dropped now).
func (e *pqEndpoint) pinLocked(address string, now time.Time) *pqPin {
	pin := e.pins[address]
	if pin != nil && pin.expired(now) {
		e.removePinLocked(address)
		return nil
	}
	return pin
}

// pinListLocked is the eviction list pin belongs on: none for a known
// address, else by its kind.
func (e *pqEndpoint) pinListLocked(address string, pin *pqPin) *list.List {
	switch {
	case e.isKnownLocked(address):
		return nil
	case pin.vouched:
		return &e.vouchedPins
	case pin.firm:
		return &e.firmPins
	default:
		return &e.loosePins
	}
}

// placePinLocked puts address's pin first on the eviction list its kind
// and address call for (seen last), or takes it off.
func (e *pqEndpoint) placePinLocked(address string, pin *pqPin) {
	want := e.pinListLocked(address, pin)
	if pin.list == want {
		if want != nil {
			want.MoveToFront(pin.elem)
		}
		return
	}
	if pin.list != nil {
		pin.list.Remove(pin.elem)
	}
	pin.list, pin.elem = want, nil
	if want != nil {
		pin.elem = want.PushFront(address)
	}
}

// setPinLocked pins address to pin, replacing any pin it had.
func (e *pqEndpoint) setPinLocked(address string, pin *pqPin) {
	e.removePinLocked(address)
	e.pins[address] = pin
	e.placePinLocked(address, pin)
}

func (e *pqEndpoint) removePinLocked(address string) {
	pin := e.pins[address]
	if pin == nil {
		return
	}
	if pin.list != nil {
		pin.list.Remove(pin.elem)
	}
	delete(e.pins, address)
}

// evictLastLocked drops the pin last on l (seen longest ago). Reports
// whether there was one.
func (e *pqEndpoint) evictLastLocked(l *list.List) bool {
	back := l.Back()
	if back == nil {
		return false
	}
	address := back.Value.(string)
	if pin := e.pins[address]; pin != nil && pin.elem == back {
		e.removePinLocked(address)
	} else {
		l.Remove(back)
	}
	return true
}

// roomForLoosePinLocked makes room for one more loose pin (a record's): a
// few expired loose pins go, and when the loose pins have their share or
// the pins are full, the loose one seen longest ago. A record never pushes
// out a firm or vouched pin, nor a pin of a known address. Reports whether
// there is room. Never more than a few steps: no table is scanned.
func (e *pqEndpoint) roomForLoosePinLocked(now time.Time) bool {
	for range pqExpiredPerPin {
		back := e.loosePins.Back()
		if back == nil {
			break
		}
		if pin := e.pins[back.Value.(string)]; pin != nil && pin.elem == back && !pin.expired(now) {
			break
		}
		e.evictLastLocked(&e.loosePins)
	}
	if e.loosePins.Len() >= pqMaxLoosePins || len(e.pins) >= pqMaxPins {
		return e.evictLastLocked(&e.loosePins)
	}
	return true
}

// roomForFirmPinLocked makes room for a pin a session proved: a loose pin
// goes, else the firm one seen longest ago (never a vouched one, nor one
// of a known address).
func (e *pqEndpoint) roomForFirmPinLocked() bool {
	return len(e.pins) < pqMaxPins || e.evictLastLocked(&e.loosePins) || e.evictLastLocked(&e.firmPins)
}

// roomForVouchLocked makes room for a pin the app vouched for: a loose pin
// goes, else the vouched one seen longest ago (never a pin a session with
// this node proved, nor one of a known address).
func (e *pqEndpoint) roomForVouchLocked() bool {
	return len(e.pins) < pqMaxPins || e.evictLastLocked(&e.loosePins) || e.evictLastLocked(&e.vouchedPins)
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
	restarted := flags&pqFlagFresh != 0 && peer.send != nil
	if restarted {
		// The peer holds no session of this node's (it restarted, or the
		// other process of the device took its address over): this node's
		// goes, and what went lately under it goes again under the next
		// one, as after 'N'. Frames sent while the peer restarted reached
		// nobody: its new core dropped them while it set up a session with
		// this node's core, so nobody could say the session was unknown.
		// The challenge in hand went with the peer's old state too.
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
	var request []byte
	if reply == nil && len(peer.pending) > 0 && peer.usableChallenge(now) == nil &&
		e.askLocked(peer, now, pqKeyRequestInterval) {
		request = e.requestFrameLocked(peer)
	}
	e.mu.Unlock()
	if restarted && e.settle != nil {
		// What goes to the peer the next seconds may still die below (its
		// core and this node's set up their session anew; mesh_io.go).
		e.settle(source)
	}
	if reply != nil {
		_ = e.write(source, reply)
	}
	if request != nil {
		_ = e.write(source, request)
	}
	e.writeJobs(source, jobs)
}

// replyKeysLocked is this node's record with a fresh challenge for peer,
// asking for one back when this node has none from peer.
func (e *pqEndpoint) replyKeysLocked(peer *pqPeer, now time.Time) []byte {
	want := peer.usableChallenge(now) == nil
	if id, ciphertext, ok := e.issueChallengeLocked(peer, now); ok {
		return e.keysFrame(want, &id, ciphertext, len(peer.receive) == 0)
	}
	return e.keysFrame(want, nil, nil, len(peer.receive) == 0)
}

// requestFrameLocked is a key request to peer: this node's record with the
// want flag, and the fresh flag while this node holds no session of the
// peer's.
func (e *pqEndpoint) requestFrameLocked(peer *pqPeer) []byte {
	return e.keysFrame(true, nil, nil, len(peer.receive) == 0)
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
	if !peer.send.acked {
		e.firmPinLocked(peer, e.now())
	}
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
	var request []byte
	if reply == nil && peer.usableChallenge(now) == nil && e.askLocked(peer, now, pqKeyRequestInterval) {
		request = e.requestFrameLocked(peer)
	}
	e.mu.Unlock()
	if e.settle != nil {
		// As after a key request saying so (receiveKeys).
		e.settle(source)
	}
	if reply != nil {
		_ = e.write(source, reply)
	}
	if request != nil {
		_ = e.write(source, request)
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
	if e.peers[source.String()] == nil && e.pins[source.String()] == nil && !e.isKnownLocked(source.String()) {
		// Nothing is known of the address: no session of its can open, and
		// no peer is made for it (that would push out a quiet friend's).
		// It is asked for its record, as after a restart.
		var reply []byte
		if e.unknownReplies.allow(now, pqUnknownRepliesPerSecond, pqUnknownRepliesBurst) {
			reply = pqUnknownFrame(id, true, nil, nil)
		}
		e.mu.Unlock()
		if reply != nil {
			_ = e.write(source, reply)
		}
		return nil, none, false
	}
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
	for _, opened := range challenge.opened {
		if opened == id {
			// Its session was here and is gone (too old, or newer ones
			// took its place): a copy of its first frame, or a replay.
			return nil, nil, false
		}
	}
	if len(challenge.opened) >= pqSessionsPerChallenge {
		// It started its share: the sender gets a new one.
		return nil, e.unknownReplyLocked(peer, id, now), false
	}
	if !peer.allowNewSession(now) {
		return nil, nil, false
	}
	if challenge.prepaid {
		challenge.prepaid = false
	} else if !e.allowForeignKEMLocked(peer, 1, now) {
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
	challenge.opened = append(challenge.opened, id)
	peer.addReceiveSession(session, now)
	e.firmPinLocked(peer, now)
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

// allowNewChallenge counts a challenge given to the peer: at most
// pqChallengesPerMinute a minute, however often it asks.
func (peer *pqPeer) allowNewChallenge(now time.Time) bool {
	if now.Sub(peer.challengesMinute) >= time.Minute {
		peer.challengesMinute = now
		peer.challengesCount = 0
	}
	if peer.challengesCount >= pqChallengesPerMinute {
		return false
	}
	peer.challengesCount++
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

// pqPinsState is what the app keeps of the pins across restarts
// (YggPqPinsJson): address -> fingerprint (hex), the addresses whose pin is
// firm or vouched, when each was seen last (Unix seconds, to the hour), and
// the addresses the app named as known.
type pqPinsState struct {
	Pins    map[string]string `json:"pins"`
	Firm    []string          `json:"firm"`
	Vouched []string          `json:"vouched"`
	Seen    map[string]int64  `json:"seen"`
	Known   []string          `json:"known"`
}

// pinsState is every pin with its kind, expired loose pins dropped (the
// app reads it once a minute; no remote peer makes this scan).
func (e *pqEndpoint) pinsState() pqPinsState {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	state := pqPinsState{
		Pins:    make(map[string]string, len(e.pins)),
		Firm:    []string{},
		Vouched: []string{},
		Seen:    make(map[string]int64, len(e.pins)),
		Known:   e.knownAddressesLocked(),
	}
	for address, pin := range e.pins {
		if pin.expired(now) {
			e.removePinLocked(address)
			continue
		}
		state.Pins[address] = hex.EncodeToString(pin.fingerprint[:])
		state.Seen[address] = pin.seen.Truncate(time.Hour).Unix()
		if pin.vouched {
			state.Vouched = append(state.Vouched, address)
		} else if pin.firm {
			state.Firm = append(state.Firm, address)
		}
	}
	sort.Strings(state.Firm)
	sort.Strings(state.Vouched)
	return state
}

// pinsSnapshot is every pin: address -> device key fingerprint (hex).
func (e *pqEndpoint) pinsSnapshot() map[string]string {
	return e.pinsState().Pins
}

// pqPinEntry reads one entry the app hands over: a mesh node address and a
// device key fingerprint (hex).
func pqPinEntry(address, value string) (string, [sha256.Size]byte, bool) {
	var fingerprint [sha256.Size]byte
	ip := net.ParseIP(address)
	decoded, err := hex.DecodeString(value)
	if ip == nil || ip.To4() != nil || !isYggNodeAddress(ip) || err != nil || len(decoded) != sha256.Size {
		return "", fingerprint, false
	}
	copy(fingerprint[:], decoded)
	return ip.String(), fingerprint, true
}

// pqAddressSet reads the addresses of a list the app hands over.
func pqAddressSet(addresses []string) map[string]bool {
	set := make(map[string]bool, len(addresses))
	for _, address := range addresses {
		if ip := net.ParseIP(address); ip != nil && ip.To4() == nil {
			set[ip.String()] = true
		}
	}
	return set
}

// restorePins takes back the pins the app kept from an earlier run
// (pinsState), each of its kind: a pin is firm or vouched only when it was
// so, never because it was kept. Pins kept by an app that did not keep
// their kind (no time seen) come back loose, to expire after
// pqLegacyPinGrace unless the device confirms them; a loose pin kept past
// its time is dropped. Kept pins win over a key this run merely saw.
// Malformed entries are skipped; the count taken is returned.
func (e *pqEndpoint) restorePins(kept pqPinsState) int {
	firm := pqAddressSet(kept.Firm)
	vouched := pqAddressSet(kept.Vouched)
	seen := make(map[string]int64, len(kept.Seen))
	for address, at := range kept.Seen {
		if ip := net.ParseIP(address); ip != nil && ip.To4() == nil {
			seen[ip.String()] = at
		}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	type entry struct {
		address     string
		fingerprint [sha256.Size]byte
		pin         *pqPin
	}
	entries := make([]entry, 0, len(kept.Pins))
	for address, value := range kept.Pins {
		key, fingerprint, valid := pqPinEntry(address, value)
		if !valid {
			continue
		}
		pin := &pqPin{fingerprint: fingerprint, vouched: vouched[key]}
		pin.firm = firm[key] || pin.vouched
		if at, ok := seen[key]; ok {
			pin.seen = time.Unix(at, 0)
			if pin.seen.After(now) {
				pin.seen = now
			}
		} else if pin.firm {
			pin.seen = now
		} else {
			pin.seen = now.Add(pqLegacyPinGrace - pqLoosePinTTL)
		}
		if pin.expired(now) {
			continue
		}
		entries = append(entries, entry{address: key, fingerprint: fingerprint, pin: pin})
	}
	// Seen longest ago first, so the eviction lists end in that order.
	sort.Slice(entries, func(i, j int) bool { return entries[i].pin.seen.Before(entries[j].pin.seen) })
	taken := 0
	for _, kept := range entries {
		if existing := e.pins[kept.address]; existing != nil && existing.fingerprint == kept.fingerprint {
			existing.firm = existing.firm || kept.pin.firm
			existing.vouched = existing.vouched || kept.pin.vouched
			if kept.pin.seen.After(existing.seen) {
				existing.seen = kept.pin.seen
			}
			e.placePinLocked(kept.address, existing)
			taken++
			continue
		} else if existing == nil && len(e.pins) >= pqMaxPins {
			continue
		}
		e.removeHintLocked(kept.address)
		e.setPinLocked(kept.address, kept.pin)
		if peer := e.peers[kept.address]; peer != nil && peer.publicKey != nil && peer.fingerprint != kept.fingerprint {
			e.resetPeerKeyLocked(peer)
		}
		taken++
	}
	return taken
}

// importPins adds pins the app vouches for: a device key a hello signed by
// the device's hybrid key named, over a session made with that key.
// With keep (the usual vouch), a pin already there that names another key
// stays, and the address is returned among the conflicts (address -> the
// pinned fingerprint): two sources disagree about who is at that address,
// and the app warns. A vouch pushes out a loose pin, or the vouched one
// seen longest ago, never a pin a session proved; with no room it is kept
// as a vouched hint, which refuses a record naming another key. Without
// keep (a hello the device signed contradicts the session it came over:
// someone else holds the address's node key), the key replaces the pin and
// whatever was made with the old one. Malformed entries are skipped; the
// count taken is returned.
func (e *pqEndpoint) importPins(pins map[string]string, keep bool) (int, map[string]string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	taken := 0
	conflicts := map[string]string{}
	for address, value := range pins {
		key, fingerprint, valid := pqPinEntry(address, value)
		if !valid {
			continue
		}
		existing := e.pinLocked(key, now)
		if keep {
			if existing != nil && existing.fingerprint != fingerprint {
				conflicts[key] = hex.EncodeToString(existing.fingerprint[:])
				continue
			}
			if hint := e.hints[key]; existing == nil && hint != nil && hint.vouched && hint.fingerprint != fingerprint {
				conflicts[key] = hex.EncodeToString(hint.fingerprint[:])
				continue
			}
			if existing != nil {
				existing.firm, existing.vouched, existing.seen = true, true, now
				e.placePinLocked(key, existing)
				e.removeHintLocked(key)
				taken++
				continue
			}
			if !e.roomForVouchLocked() {
				e.addHintLocked(key, fingerprint, now, true)
				taken++
				continue
			}
		} else if existing == nil && !e.roomForVouchLocked() && !e.roomForFirmPinLocked() {
			continue
		}
		e.removeHintLocked(key)
		e.setPinLocked(key, &pqPin{fingerprint: fingerprint, seen: now, firm: true, vouched: true})
		if peer := e.peers[key]; peer != nil && peer.publicKey != nil && peer.fingerprint != fingerprint {
			e.resetPeerKeyLocked(peer)
		}
		taken++
	}
	return taken, conflicts
}

// importHints keeps device keys someone else names for addresses (a
// friend's friend list or device record): hearsay, so a hint never moves a
// pin, never ends a session, never keeps the device itself out, and becomes
// a pin only when the record of the device at that address names the same
// key (acceptRecordLocked). A hint for a pinned address that names another
// key is returned among the conflicts (for the log: a friend's word is no
// reason to warn about the device that proved its key). Each hint costs a
// few steps, never a scan. Malformed entries are skipped; the count kept is
// returned.
func (e *pqEndpoint) importHints(hints map[string]string) (int, map[string]string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := e.now()
	taken := 0
	conflicts := map[string]string{}
	for address, value := range hints {
		key, fingerprint, valid := pqPinEntry(address, value)
		if !valid {
			continue
		}
		if pinned := e.pinLocked(key, now); pinned != nil {
			if pinned.fingerprint != fingerprint {
				conflicts[key] = hex.EncodeToString(pinned.fingerprint[:])
			}
			continue
		}
		if e.addHintLocked(key, fingerprint, now, false) {
			taken++
		}
	}
	return taken, conflicts
}

// dropHints forgets hints nobody gives any more (the friend who named them
// was removed), each only while it still names that key. A vouched hint
// stays. Returns how many went.
func (e *pqEndpoint) dropHints(hints map[string]string) int {
	e.mu.Lock()
	defer e.mu.Unlock()
	dropped := 0
	for address, value := range hints {
		key, fingerprint, valid := pqPinEntry(address, value)
		if !valid {
			continue
		}
		if hint := e.hints[key]; hint != nil && !hint.vouched && hint.fingerprint == fingerprint {
			e.removeHintLocked(key)
			dropped++
		}
	}
	return dropped
}

// addHintLocked keeps a hint for address, dropping the one given longest
// ago when the hints of its kind are full. A word never replaces a vouched
// hint. Reports whether it was kept.
func (e *pqEndpoint) addHintLocked(address string, fingerprint [sha256.Size]byte, now time.Time, vouched bool) bool {
	if e.hints == nil {
		e.hints = make(map[string]*pqPin)
	}
	if old := e.hints[address]; old != nil {
		if old.vouched && !vouched {
			return false
		}
		e.removeHintLocked(address)
	}
	hints, limit := &e.wordHints, pqMaxHints
	if vouched {
		hints, limit = &e.vouchedHints, pqMaxVouchedHints
	}
	for hints.Len() >= limit {
		back := hints.Back()
		if hint := e.hints[back.Value.(string)]; hint != nil && hint.elem == back {
			e.removeHintLocked(back.Value.(string))
		} else {
			hints.Remove(back)
		}
	}
	hint := &pqPin{fingerprint: fingerprint, seen: now, vouched: vouched, list: hints}
	hint.elem = hints.PushFront(address)
	e.hints[address] = hint
	return true
}

func (e *pqEndpoint) removeHintLocked(address string) {
	hint := e.hints[address]
	if hint == nil {
		return
	}
	if hint.list != nil {
		hint.list.Remove(hint.elem)
	}
	delete(e.hints, address)
}

// noteConflictLocked keeps, for the app, that a record from address named
// another key than the vouched one (a bounded few until it reads them).
func (e *pqEndpoint) noteConflictLocked(address string, vouched [sha256.Size]byte) {
	if e.conflicts == nil {
		e.conflicts = make(map[string]string)
	}
	if _, ok := e.conflicts[address]; ok || len(e.conflicts) < pqMaxConflicts {
		e.conflicts[address] = hex.EncodeToString(vouched[:])
	}
}

// takeConflicts hands the app the records refused since it asked last
// because they contradict a vouched key: address -> the vouched
// fingerprint.
func (e *pqEndpoint) takeConflicts() map[string]string {
	e.mu.Lock()
	defer e.mu.Unlock()
	conflicts := e.conflicts
	e.conflicts = nil
	if conflicts == nil {
		conflicts = map[string]string{}
	}
	return conflicts
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
