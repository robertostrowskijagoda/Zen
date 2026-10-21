package main

import (
	"bytes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hpke"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"net"
	"sync"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
)

// The session layer: every signal between two Zen nodes is sealed with a
// key from the hybrid KEM (pq_kem.go), on top of Yggdrasil's own (classical)
// encryption. There is no plaintext mode: a node takes only sealed signals
// and the few control messages that set the keys up.
//
// Sessions go one way. A node that sends to a peer for the first time asks
// for its key record ('K', with its own record, "want" set) and holds what
// it sends until the record comes back (pqPending*). It then encapsulates
// once to the peer's device key: the 1120-byte ciphertext goes along in the
// header of its frames until the peer acknowledges the session ('A'); after
// that a frame carries only the session id and a counter. KEM operations
// happen only here — at a session's start and when it is rotated — never
// per message. A receiver that gets a frame of a session it does not know
// (it restarted, it is the other process of the same device) answers 'N',
// and the sender puts the ciphertext back in the header.
//
// Wire (the signal text, before fragmentation; never JSON, never "ZSTD:"):
//
//	"ZPQ1" 'K' flags(1, bit 0: answer with your record) record
//	"ZPQ1" 'D' flags(1, bit 0: ciphertext follows) sid(16) counter(8)
//	       [ciphertext(1120)] AEAD(signal text)
//	"ZPQ1" 'A' sid(16)    the session is known here
//	"ZPQ1" 'N' sid(16)    the session is not known here
//
// The AEAD is ChaCha20-Poly1305 under the session key, nonce 0^4 | counter,
// associated data the frame header plus the sender's and the recipient's
// address. The session key is the hybrid secret for the info "zen.pq.
// session.v1" | sender | recipient | sid, so a session belongs to one
// ordered pair and cannot be moved to another. A counter is used once: the
// receiver keeps a window of the last pqReplayWindow counters and refuses
// repeats and anything older. Control messages carry no content; they
// come from the authenticated mesh source like every signal.
const (
	pqMagic                = "ZPQ1"
	pqKindKeys             = 'K'
	pqKindData             = 'D'
	pqKindAck              = 'A'
	pqKindUnknown          = 'N'
	pqFlagWant             = 0x01
	pqFlagCiphertext       = 0x01
	pqSessionIDSize        = 16
	pqDataHeaderSize       = len(pqMagic) + 1 + 1 + pqSessionIDSize + 8
	pqMaxFrameOverhead     = pqDataHeaderSize + pqCiphertextSize + chacha20poly1305.Overhead
	pqSessionInfo          = "zen.pq.session.v1"
	pqSessionLifetime      = time.Hour
	pqSessionMaxFrames     = 1 << 24
	pqReceiveSessionsKept  = 4
	pqReceiveSessionIdle   = 2*pqSessionLifetime + 10*time.Minute
	pqNewSessionsPerMinute = 16
	pqReplayWindow         = 1024
	pqKeyRequestInterval   = 2 * time.Second
	pqKeyReplyInterval     = time.Second
	pqUnknownReplyInterval = time.Second
	pqAckInterval          = 250 * time.Millisecond
	pqPendingTTL           = 20 * time.Second
	pqPendingPerPeer       = 64
	pqPendingBytesPerPeer  = 4 * 1024 * 1024
	pqPendingBytesTotal    = 16 * 1024 * 1024
	pqMaxPeers             = 4096
)

// maxSignalWireBytes is the longest signal text on the wire: the largest
// signal, sealed.
const maxSignalWireBytes = maxSignalPayloadBytes + pqMaxFrameOverhead

// isPQWire reports whether a signal text belongs to the session layer.
func isPQWire(wire string) bool {
	return len(wire) > len(pqMagic) && wire[:len(pqMagic)] == pqMagic
}

type pqSessionID [pqSessionIDSize]byte

type pqSendSession struct {
	id         pqSessionID
	ciphertext []byte
	aead       cipher.AEAD
	next       uint64
	created    time.Time
	// The peer said it knows the session: frames go without ciphertext.
	acked bool
}

type pqReceiveSession struct {
	id       pqSessionID
	aead     cipher.AEAD
	created  time.Time
	lastUsed time.Time
	lastAck  time.Time
	window   pqReplay
}

type pqPendingFrame struct {
	wire  []byte
	until time.Time
}

type pqPeer struct {
	ip net.IP
	// The peer's device key, from its verified record (nil: not known yet).
	publicKey    []byte
	send         *pqSendSession
	receive      []*pqReceiveSession
	pending      []pqPendingFrame
	pendingBytes int
	keysAskedAt  time.Time
	keysSentAt   time.Time
	unknownAt    time.Time
	// New receive sessions in the current minute (a stranger cannot make
	// this node decapsulate without end).
	sessionsMinute time.Time
	sessionsCount  int
	lastUsed       time.Time
}

// pqEndpoint is the session layer of one node.
type pqEndpoint struct {
	mu           sync.Mutex
	local        net.IP
	key          hpke.PrivateKey
	record       []byte
	peers        map[string]*pqPeer
	pendingBytes int
	// Sends a signal text (already sealed, or a control message) to a peer.
	write func(destination net.IP, wire []byte) error
	now   func() time.Time
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
	key, err := pqPrivateKey(seed)
	if err != nil {
		return nil, err
	}
	record, err := pqBuildRecord(nodeKey, key.PublicKey().Bytes())
	if err != nil {
		return nil, err
	}
	return &pqEndpoint{
		local:  bytes.Clone(local16),
		key:    key,
		record: record,
		peers:  make(map[string]*pqPeer),
		write:  write,
		now:    time.Now,
	}, nil
}

func pqSessionInfoFor(sender, recipient net.IP, id pqSessionID) []byte {
	info := make([]byte, 0, len(pqSessionInfo)+16+16+pqSessionIDSize)
	info = append(info, pqSessionInfo...)
	info = append(info, sender.To16()...)
	info = append(info, recipient.To16()...)
	return append(info, id[:]...)
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
// on the next contact).
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
		delete(e.peers, oldestKey)
	}
}

func (e *pqEndpoint) keysFrame(want bool) []byte {
	frame := make([]byte, 0, len(pqMagic)+2+len(e.record))
	frame = append(frame, pqMagic...)
	flags := byte(0)
	if want {
		flags = pqFlagWant
	}
	frame = append(frame, pqKindKeys, flags)
	return append(frame, e.record...)
}

func pqControlFrame(kind byte, id pqSessionID) []byte {
	frame := make([]byte, 0, len(pqMagic)+1+pqSessionIDSize)
	frame = append(frame, pqMagic...)
	frame = append(frame, kind)
	return append(frame, id[:]...)
}

// send seals wire (a signal text) for destination and sends it, or holds
// it until destination's key record is known.
func (e *pqEndpoint) send(destination net.IP, wire []byte) error {
	destination16 := destination.To16()
	if destination16 == nil || destination.To4() != nil {
		return fmt.Errorf("pq: invalid destination %s", destination)
	}
	e.mu.Lock()
	now := e.now()
	peer := e.peerLocked(destination16, now)
	if peer.publicKey == nil {
		e.holdLocked(peer, wire, now)
		ask := now.Sub(peer.keysAskedAt) >= pqKeyRequestInterval
		if ask {
			peer.keysAskedAt = now
		}
		e.mu.Unlock()
		if ask {
			return e.write(destination16, e.keysFrame(true))
		}
		return nil
	}
	frame, err := e.sealLocked(peer, wire, now)
	e.mu.Unlock()
	if err != nil {
		return err
	}
	return e.write(destination16, frame)
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

func (e *pqEndpoint) newSendSessionLocked(peer *pqPeer, now time.Time) (*pqSendSession, error) {
	var id pqSessionID
	if _, err := rand.Read(id[:]); err != nil {
		return nil, err
	}
	ciphertext, secret, err := pqEncapsulate(peer.publicKey, pqSessionInfoFor(e.local, peer.ip, id))
	if err != nil {
		return nil, err
	}
	aead, err := chacha20poly1305.New(secret)
	if err != nil {
		return nil, err
	}
	return &pqSendSession{id: id, ciphertext: ciphertext, aead: aead, created: now}, nil
}

func (e *pqEndpoint) sealLocked(peer *pqPeer, wire []byte, now time.Time) ([]byte, error) {
	session := peer.send
	if session == nil || now.Sub(session.created) >= pqSessionLifetime || session.next >= pqSessionMaxFrames {
		fresh, err := e.newSendSessionLocked(peer, now)
		if err != nil {
			return nil, err
		}
		session = fresh
		peer.send = fresh
	}
	counter := session.next
	session.next++
	size := pqDataHeaderSize + len(wire) + chacha20poly1305.Overhead
	if !session.acked {
		size += pqCiphertextSize
	}
	frame := make([]byte, 0, size)
	frame = append(frame, pqMagic...)
	flags := byte(0)
	if !session.acked {
		flags = pqFlagCiphertext
	}
	frame = append(frame, pqKindData, flags)
	frame = append(frame, session.id[:]...)
	frame = binary.BigEndian.AppendUint64(frame, counter)
	if !session.acked {
		frame = append(frame, session.ciphertext...)
	}
	aad := pqAssociatedData(frame, e.local, peer.ip)
	return session.aead.Seal(frame, pqNonce(counter), wire, aad), nil
}

// receive takes one signal text from source: the plaintext it carries, or
// false for a control message, something that does not open, or anything
// not sealed (refused).
func (e *pqEndpoint) receive(source net.IP, wire []byte) ([]byte, bool) {
	source16 := source.To16()
	if source16 == nil || len(wire) < len(pqMagic)+1 || string(wire[:len(pqMagic)]) != pqMagic {
		return nil, false
	}
	body := wire[len(pqMagic)+1:]
	switch wire[len(pqMagic)] {
	case pqKindKeys:
		e.receiveKeys(source16, body)
	case pqKindAck, pqKindUnknown:
		e.receiveControl(source16, wire[len(pqMagic)], body)
	case pqKindData:
		return e.open(source16, wire)
	}
	return nil, false
}

func (e *pqEndpoint) receiveKeys(source net.IP, body []byte) {
	if len(body) != 1+pqRecordSize {
		return
	}
	publicKey, err := pqVerifyRecord(body[1:], source)
	if err != nil {
		debugf("[ZEN-GO] pq: key record from %s refused: %v\n", source, err)
		return
	}
	e.mu.Lock()
	now := e.now()
	peer := e.peerLocked(source, now)
	if !bytes.Equal(peer.publicKey, publicKey) {
		peer.publicKey = publicKey
		peer.send = nil
	}
	reply := body[0]&pqFlagWant != 0 && now.Sub(peer.keysSentAt) >= pqKeyReplyInterval
	if reply {
		peer.keysSentAt = now
	}
	e.dropExpiredLocked(peer, now)
	frames := make([][]byte, 0, len(peer.pending))
	for _, pending := range peer.pending {
		frame, err := e.sealLocked(peer, pending.wire, now)
		if err == nil {
			frames = append(frames, frame)
		}
	}
	e.pendingBytes -= peer.pendingBytes
	peer.pending = nil
	peer.pendingBytes = 0
	e.mu.Unlock()
	if reply {
		_ = e.write(source, e.keysFrame(false))
	}
	for _, frame := range frames {
		if err := e.write(source, frame); err != nil {
			debugf("[ZEN-GO] pq: held frame to %s not sent: %v\n", source, err)
		}
	}
}

func (e *pqEndpoint) receiveControl(source net.IP, kind byte, body []byte) {
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
	// Known: frames go without the ciphertext. Not known (the peer lost
	// it): the ciphertext goes along again.
	peer.send.acked = kind == pqKindAck
}

func (e *pqEndpoint) open(source net.IP, wire []byte) ([]byte, bool) {
	if len(wire) < pqDataHeaderSize+chacha20poly1305.Overhead {
		return nil, false
	}
	offset := len(pqMagic) + 1
	flags := wire[offset]
	offset++
	var id pqSessionID
	copy(id[:], wire[offset:offset+pqSessionIDSize])
	offset += pqSessionIDSize
	counter := binary.BigEndian.Uint64(wire[offset : offset+8])
	offset += 8
	var ciphertext []byte
	if flags&pqFlagCiphertext != 0 {
		if len(wire) < offset+pqCiphertextSize+chacha20poly1305.Overhead {
			return nil, false
		}
		ciphertext = wire[offset : offset+pqCiphertextSize]
		offset += pqCiphertextSize
	}
	header, sealed := wire[:offset], wire[offset:]

	e.mu.Lock()
	now := e.now()
	peer := e.peerLocked(source, now)
	session := peer.receiveSession(id)
	fresh := false
	if session == nil {
		if ciphertext == nil {
			reply := now.Sub(peer.unknownAt) >= pqUnknownReplyInterval
			if reply {
				peer.unknownAt = now
			}
			e.mu.Unlock()
			if reply {
				_ = e.write(source, pqControlFrame(pqKindUnknown, id))
			}
			return nil, false
		}
		if !peer.allowNewSession(now) {
			e.mu.Unlock()
			return nil, false
		}
		secret, err := pqDecapsulate(e.key, ciphertext, pqSessionInfoFor(source, e.local, id))
		if err != nil {
			e.mu.Unlock()
			return nil, false
		}
		aead, err := chacha20poly1305.New(secret)
		if err != nil {
			e.mu.Unlock()
			return nil, false
		}
		session = &pqReceiveSession{id: id, aead: aead, created: now}
		fresh = true
	}
	if !session.window.fresh(counter) {
		e.mu.Unlock()
		return nil, false
	}
	plain, err := session.aead.Open(nil, pqNonce(counter), sealed, pqAssociatedData(header, source, e.local))
	if err != nil {
		e.mu.Unlock()
		return nil, false
	}
	session.window.mark(counter)
	session.lastUsed = now
	if fresh {
		peer.addReceiveSession(session, now)
	}
	ack := ciphertext != nil && now.Sub(session.lastAck) >= pqAckInterval
	if ack {
		session.lastAck = now
	}
	e.mu.Unlock()
	if ack {
		_ = e.write(source, pqControlFrame(pqKindAck, id))
	}
	return plain, true
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

// pqReplay remembers which of the last pqReplayWindow counters came.
type pqReplay struct {
	highest uint64
	any     bool
	seen    [pqReplayWindow / 64]uint64
}

func (r *pqReplay) fresh(counter uint64) bool {
	if !r.any || counter > r.highest {
		return true
	}
	behind := r.highest - counter
	if behind >= pqReplayWindow {
		return false
	}
	return r.seen[(counter/64)%uint64(len(r.seen))]&(1<<(counter%64)) == 0
}

func (r *pqReplay) mark(counter uint64) {
	if !r.any || counter > r.highest {
		start := r.highest + 1
		if !r.any || counter-r.highest >= pqReplayWindow {
			r.seen = [pqReplayWindow / 64]uint64{}
		} else {
			// Clear the bits of the counters skipped over: they now name
			// counters a full window ahead of the ones they held.
			for value := start; value < counter; value++ {
				r.seen[(value/64)%uint64(len(r.seen))] &^= 1 << (value % 64)
			}
		}
		r.highest = counter
		r.any = true
	}
	r.seen[(counter/64)%uint64(len(r.seen))] |= 1 << (counter % 64)
}
