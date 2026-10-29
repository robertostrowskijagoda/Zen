package main

import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	iwt "github.com/Arceliar/ironwood/types"
	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// A node's own IPv6 packets on the mesh, in place of Yggdrasil's ipv6rwc.
//
// Reading. ironwood hands what reaches a node to its reader through a
// channel of one, behind actors that wait for each other (phony's
// backpressure): the session manager waits for the session of the peer that
// sent, the session for the reader actor, the reader for the next read. A
// packet loop that waits for any of them — a write (Core.WriteTo waits for
// the session manager), a look at the sessions, a lock held by someone who
// does — waits for itself as soon as the peer keeps sending: the node is
// deaf and mute for good, and the app's next look at its sessions never
// returns (R5-F4). ipv6rwc wrote from inside its read too (the packet it
// held for an address whose key a packet just brought, an ICMP answer to an
// oversized packet). So whatever reads here only checks a packet and notes
// its sender's key (accept); everything the node sends goes to a queue and
// is written by a goroutine of its own, and a full queue refuses instead of
// waiting (the session layer and the app send again).
//
// Writing. While a destination's key, its session or the path to it is
// still being set up, every layer below keeps just one packet for it: ipv6rwc
// for the address's key, ironwood's session layer for the session, its
// pathfinder for the path, each dropping the one before for the newest. A
// first contact (or the first one after a peer restarted, or after a minute
// of quiet, when ironwood forgets sessions and paths) so lost all but the
// last packet of a burst, such as the fragments of a key request, and the
// session layer had to ask again seconds later (R5-F5). The writer sends one
// packet alone to open the way and keeps the rest until the core has a
// session and a path for the key; then they all go, in order. A destination
// whose key is not known yet is looked up first (the path notification
// brings the key).
const (
	// Bytes of packets waiting for the writer and held for ways that are
	// still opening, all destinations together; a phone keeps less, under
	// its Go memory limit (memory_tuning.go).
	meshQueueBytes      = 32 << 20
	meshPhoneQueueBytes = 8 << 20
	// Packets and bytes held for one destination while the way to it opens.
	meshHeldPerWay      = 1024
	meshHeldBytesPerWay = 4 << 20
	// How long a packet is held for a way that does not open (the session
	// layer holds its frames as long, pqPendingTTL); call media only
	// briefly: a late frame of a call is worse than a lost one.
	meshHoldFor      = 20 * time.Second
	meshHoldMediaFor = time.Second
	// A way found open is taken as open this long, then looked at again
	// (ironwood forgets a session or a path after a minute of quiet).
	meshOpenFor = 10 * time.Second
	// While a way does not open, the key is looked up again and the opening
	// packet sent again every meshRetryFirst for the first meshRetrySteady
	// times, then twice as long each time up to meshRetryMax. ironwood sends
	// one lookup a second at most, and a node that just came on the mesh is
	// found only once its bloom filter reached the others (a router round a
	// second, per hop).
	meshRetryFirst  = time.Second
	meshRetrySteady = 5
	meshRetryMax    = 8 * time.Second
	// How soon the writer looks whether a way opened after its opening
	// packet went out, then twice as long each time up to meshCheckMax.
	meshCheckFirst = 5 * time.Millisecond
	meshCheckMax   = 200 * time.Millisecond
	// Keys of node addresses remembered: in two generations of up to
	// meshKeysPerGeneration each, so a stranger sending from many keys
	// only ever pushes out the ones heard from longest ago.
	meshKeysPerGeneration = 2048
	// Destinations the writer keeps state for at once; one idle this long
	// is forgotten.
	meshMaxWays  = 4096
	meshWayIdle  = 2 * time.Minute
	meshWaySweep = 30 * time.Second
)

var (
	errMeshStopped   = errors.New("the node's mesh writer stopped")
	errMeshQueueFull = errors.New("the node's mesh send queue is full")
)

// meshCore is what meshIO needs of a node's Yggdrasil core (*core.Core;
// tests use fakes).
type meshCore interface {
	WriteTo(p []byte, addr net.Addr) (int, error)
	SendLookup(key ed25519.PublicKey)
	SetPathNotify(notify func(key ed25519.PublicKey))
	GetSessions() []core.SessionInfo
	GetPaths() []core.PathEntryInfo
	PublicKey() ed25519.PublicKey
	MTU() uint64
}

// meshPacket is a packet queued for a destination.
type meshPacket struct {
	to    address.Address
	data  []byte
	media bool
	at    time.Time
}

// meshIO is a node's packets on the mesh (see the top of this file). Its
// methods are safe for concurrent use; send and accept never wait for the
// mesh.
type meshIO struct {
	core  meshCore
	local address.Address
	mtu   int
	// The queue's byte budget (meshQueueBytes on this device).
	budget int
	// Counts a packet once it is written (the traffic meter); may be nil.
	sent func(size int, media bool)

	mu sync.Mutex
	// Keys by node address, newer and older generation.
	keys, oldKeys map[address.Address]ed25519.PublicKey
	// Packets for the writer, oldest first, and what the writer holds
	// for ways that are opening, together within budget.
	queue      []meshPacket
	queueBytes int
	heldBytes  int
	stopped    bool

	// New keys and paths found, so the writer looks at waiting ways at once.
	events atomic.Uint64
	// Holds a token while the writer has something to look at.
	wake     chan struct{}
	quit     chan struct{}
	done     chan struct{}
	stopOnce sync.Once
	// Packets refused or dropped (queue full, held too long), for the log.
	dropped atomic.Uint64
}

func newMeshIO(c meshCore, sent func(size int, media bool)) *meshIO {
	local := address.AddrForKey(c.PublicKey())
	return &meshIO{
		core:    c,
		local:   *local,
		mtu:     int(c.MTU()),
		budget:  phoneOr(meshPhoneQueueBytes, meshQueueBytes),
		sent:    sent,
		keys:    make(map[address.Address]ed25519.PublicKey),
		oldKeys: make(map[address.Address]ed25519.PublicKey),
		wake:    make(chan struct{}, 1),
		quit:    make(chan struct{}),
		done:    make(chan struct{}),
	}
}

// start takes the core's path notifications and starts the writer.
func (m *meshIO) start() {
	// Called inside the core's actor: it only notes the key.
	m.core.SetPathNotify(m.pathFound)
	go m.run()
}

// stop ends the writer; what waits is dropped. It does not wait for a
// write in progress (one the core never answers would hold it for good).
func (m *meshIO) stop() {
	m.stopOnce.Do(func() {
		m.mu.Lock()
		m.stopped = true
		m.queue = nil
		m.queueBytes = 0
		m.mu.Unlock()
		close(m.quit)
	})
}

// MTU is the largest packet the mesh takes.
func (m *meshIO) MTU() int {
	return m.mtu
}

// send queues packet, an IPv6 packet from this node's address to another
// node's address, for the writer and returns at once. The caller must not
// change packet afterwards. media marks call media (held only briefly).
func (m *meshIO) send(packet []byte, media bool) error {
	to, err := m.check(packet)
	if err != nil {
		return err
	}
	m.mu.Lock()
	if m.stopped {
		m.mu.Unlock()
		return errMeshStopped
	}
	if m.queueBytes+m.heldBytes+len(packet) > m.budget {
		m.mu.Unlock()
		m.dropped.Add(1)
		return errMeshQueueFull
	}
	m.queue = append(m.queue, meshPacket{to: to, data: packet, media: media, at: time.Now()})
	m.queueBytes += len(packet)
	m.mu.Unlock()
	m.signal()
	return nil
}

// check is the destination of a packet this node may send.
func (m *meshIO) check(packet []byte) (address.Address, error) {
	var to address.Address
	if len(packet) < 40 || packet[0]>>4 != 6 {
		return to, errors.New("not an IPv6 packet")
	}
	if len(packet) > m.mtu {
		return to, fmt.Errorf("a packet of %d bytes is over the mesh MTU of %d", len(packet), m.mtu)
	}
	if !bytes.Equal(packet[8:24], m.local[:]) {
		return to, errors.New("the packet is not from this node's address")
	}
	copy(to[:], packet[24:40])
	if !to.IsValid() {
		return to, fmt.Errorf("%s is not a mesh node address", net.IP(to[:]))
	}
	return to, nil
}

// accept checks a packet the node read from the mesh, from the key ironwood
// authenticated as its sender, as ipv6rwc did: addressed to this node and
// sent from the sender key's own address. The key is noted, so an answer
// needs no lookup. The packet loop calls it for every packet: it never
// waits for the mesh.
func (m *meshIO) accept(packet []byte, from net.Addr) bool {
	key, ok := from.(iwt.Addr)
	if !ok || len(key) != ed25519.PublicKeySize || len(packet) < 40 || packet[0]>>4 != 6 {
		return false
	}
	if !bytes.Equal(packet[24:40], m.local[:]) {
		return false
	}
	source := address.AddrForKey(ed25519.PublicKey(key))
	if source == nil || !bytes.Equal(packet[8:24], source[:]) {
		return false
	}
	m.learn(*source, ed25519.PublicKey(key), false)
	return true
}

// pathFound is the core's path notification: a lookup found key and the
// path to it. It runs inside the core's actor and only notes the key.
func (m *meshIO) pathFound(key ed25519.PublicKey) {
	if source := address.AddrForKey(key); source != nil {
		debugf("[ZEN-GO] mesh: path to %s found\n", net.IP(source[:]))
		m.learn(*source, key, true)
	}
}

// learn notes key for addr; the writer is woken for a new key or a path.
func (m *meshIO) learn(addr address.Address, key ed25519.PublicKey, path bool) {
	m.mu.Lock()
	fresh := !bytes.Equal(m.keyLocked(addr), key)
	if fresh {
		m.storeKeyLocked(addr, bytes.Clone(key))
	}
	m.mu.Unlock()
	if fresh || path {
		m.events.Add(1)
		m.signal()
	}
}

// keyLocked is the key of addr (nil: unknown); one of the older generation
// moves to the newer. m.mu is held.
func (m *meshIO) keyLocked(addr address.Address) ed25519.PublicKey {
	if key, ok := m.keys[addr]; ok {
		return key
	}
	if key, ok := m.oldKeys[addr]; ok {
		m.storeKeyLocked(addr, key)
		return key
	}
	return nil
}

func (m *meshIO) storeKeyLocked(addr address.Address, key ed25519.PublicKey) {
	if _, ok := m.keys[addr]; !ok && len(m.keys) >= meshKeysPerGeneration {
		m.oldKeys = m.keys
		m.keys = make(map[address.Address]ed25519.PublicKey, meshKeysPerGeneration)
	}
	m.keys[addr] = key
	delete(m.oldKeys, addr)
}

// keyOf is the key of addr, nil when the node never heard of it.
func (m *meshIO) keyOf(addr address.Address) ed25519.PublicKey {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.keyLocked(addr)
}

func (m *meshIO) signal() {
	select {
	case m.wake <- struct{}{}:
	default:
	}
}

// take hands the queue to the writer: its packets now count as held.
func (m *meshIO) take() []meshPacket {
	m.mu.Lock()
	defer m.mu.Unlock()
	packets := m.queue
	m.queue = nil
	m.heldBytes += m.queueBytes
	m.queueBytes = 0
	return packets
}

// release gives back the budget of packets the writer wrote or dropped.
func (m *meshIO) release(size int) {
	m.mu.Lock()
	m.heldBytes -= size
	m.mu.Unlock()
}

// meshWay is the writer's state of one destination.
type meshWay struct {
	key       ed25519.PublicKey
	held      []meshPacket
	heldBytes int
	// When the way was last found open (zero: not since it last closed).
	open time.Time
	// When the opening packet last went out and the key was last looked
	// up (zero: not yet), and how many times either was done again.
	opened  time.Time
	asked   time.Time
	retries int
	// Looks at the core since the opening packet went out, and when the
	// next is due (zero: at once).
	checks  int
	checkAt time.Time
	used    time.Time
}

// meshWriter is the writer goroutine's own state.
type meshWriter struct {
	m    *meshIO
	ways map[address.Address]*meshWay
	// The ways with packets held.
	waiting map[address.Address]*meshWay
	events  uint64
	swept   time.Time
}

// run is the writer: it writes what is queued, holds what goes to a way
// that is still opening and keeps looking at those ways.
func (m *meshIO) run() {
	defer close(m.done)
	w := &meshWriter{
		m:       m,
		ways:    make(map[address.Address]*meshWay),
		waiting: make(map[address.Address]*meshWay),
		swept:   time.Now(),
	}
	timer := time.NewTimer(time.Hour)
	timer.Stop()
	for {
		select {
		case <-m.quit:
			timer.Stop()
			return
		case <-m.wake:
		case <-timer.C:
		}
		now := time.Now()
		for _, packet := range m.take() {
			w.route(packet, now)
		}
		if next := w.progress(time.Now()); next > 0 {
			timer.Reset(next)
		} else {
			timer.Stop()
		}
	}
}

// way is the state of addr, made if needed.
func (w *meshWriter) way(addr address.Address, now time.Time) *meshWay {
	way := w.ways[addr]
	if way == nil {
		if len(w.ways) >= meshMaxWays {
			w.sweep(now, true)
		}
		way = &meshWay{}
		w.ways[addr] = way
	}
	way.used = now
	return way
}

// route writes packet, or holds it while its way is not known to be open.
func (w *meshWriter) route(packet meshPacket, now time.Time) {
	way := w.way(packet.to, now)
	if way.key == nil {
		way.key = w.m.keyOf(packet.to)
	}
	if way.key != nil && len(way.held) == 0 && !way.open.IsZero() && now.Sub(way.open) < meshOpenFor {
		w.write(way.key, packet)
		w.m.release(len(packet.data))
		return
	}
	if len(way.held) >= meshHeldPerWay || way.heldBytes+len(packet.data) > meshHeldBytesPerWay {
		w.drop(packet)
		return
	}
	if len(way.held) == 0 {
		way.checkAt = time.Time{}
	}
	way.held = append(way.held, packet)
	way.heldBytes += len(packet.data)
	w.waiting[packet.to] = way
}

// write hands one packet to the core. It may wait for the core's session
// actors: that is why only the writer ever writes.
func (w *meshWriter) write(key ed25519.PublicKey, packet meshPacket) {
	if _, err := w.m.core.WriteTo(packet.data, iwt.Addr(key)); err == nil && w.m.sent != nil {
		w.m.sent(len(packet.data), packet.media)
	}
}

func (w *meshWriter) drop(packet meshPacket) {
	w.m.release(len(packet.data))
	w.m.dropped.Add(1)
}

// progress drops what was held too long, writes what waited for ways that
// opened, opens or looks up the others, and tells when to look again (0:
// nothing waits).
func (w *meshWriter) progress(now time.Time) time.Duration {
	if now.Sub(w.swept) >= meshWaySweep {
		w.sweep(now, false)
	}
	// A key or a path came: every opening way is looked at now.
	events := w.m.events.Load()
	found := events != w.events
	w.events = events
	next := time.Duration(0)
	soonest := func(at time.Time) {
		delay := max(at.Sub(now), time.Millisecond)
		if next == 0 || delay < next {
			next = delay
		}
	}
	var opening []address.Address
	for addr, way := range w.waiting {
		w.expire(way, now)
		if len(way.held) == 0 {
			delete(w.waiting, addr)
			continue
		}
		if way.key == nil {
			way.key = w.m.keyOf(addr)
		}
		if way.key == nil {
			// The path notification brings the key and wakes the writer.
			if way.asked.IsZero() || !now.Before(way.asked.Add(retryDelay(way.retries))) {
				if !way.asked.IsZero() {
					way.retries++
				}
				way.asked = now
				debugf("[ZEN-GO] mesh: looking up %s (retry %d, %d held)\n", net.IP(addr[:]), way.retries, len(way.held))
				w.m.core.SendLookup(addr.GetKey())
			}
			soonest(way.asked.Add(retryDelay(way.retries)))
			continue
		}
		if found || !now.Before(way.checkAt) {
			opening = append(opening, addr)
		} else {
			soonest(way.checkAt)
		}
	}
	if len(opening) == 0 {
		return next
	}
	sessions, paths := w.openWays()
	for _, addr := range opening {
		way := w.ways[addr]
		name := string(way.key)
		if sessions[name] && paths[name] {
			debugf("[ZEN-GO] mesh: the way to %s is open, %d held packet(s) go\n", net.IP(addr[:]), len(way.held))
			w.flush(way, now)
			continue
		}
		way.open = time.Time{}
		if way.opened.IsZero() || !now.Before(way.opened.Add(retryDelay(way.retries))) {
			if way.opened.IsZero() {
				way.retries = 0
			} else {
				way.retries++
			}
			debugf("[ZEN-GO] mesh: opening the way to %s (retry %d, session %v, path %v, %d held)\n",
				net.IP(addr[:]), way.retries, sessions[name], paths[name], len(way.held))
			// Alone, so the one packet the core keeps while it sets the
			// way up is this one. It stays held and goes again with the
			// rest: the receiver drops the copy (fragments are joined by
			// index, sealed frames have counters).
			w.write(way.key, way.held[0])
			way.opened = now
			way.checks = 0
		}
		way.checkAt = now.Add(min(meshCheckFirst<<min(way.checks, 8), meshCheckMax))
		way.checks++
		soonest(way.checkAt)
		soonest(way.opened.Add(retryDelay(way.retries)))
	}
	return next
}

// openWays are the keys the core has a session with and a path to.
func (w *meshWriter) openWays() (map[string]bool, map[string]bool) {
	sessions := make(map[string]bool)
	for _, session := range w.m.core.GetSessions() {
		sessions[string(session.Key)] = true
	}
	paths := make(map[string]bool)
	for _, path := range w.m.core.GetPaths() {
		paths[string(path.Key)] = true
	}
	return sessions, paths
}

// flush writes everything held for an open way, in order.
func (w *meshWriter) flush(way *meshWay, now time.Time) {
	held := way.held
	way.held = nil
	way.heldBytes = 0
	way.open = now
	way.opened = time.Time{}
	way.asked = time.Time{}
	way.retries = 0
	way.checks = 0
	for _, packet := range held {
		w.write(way.key, packet)
		w.m.release(len(packet.data))
	}
}

// expire drops packets held too long for way.
func (w *meshWriter) expire(way *meshWay, now time.Time) {
	kept := way.held[:0]
	for _, packet := range way.held {
		limit := meshHoldFor
		if packet.media {
			limit = meshHoldMediaFor
		}
		if now.Sub(packet.at) > limit {
			way.heldBytes -= len(packet.data)
			w.drop(packet)
			continue
		}
		kept = append(kept, packet)
	}
	clear(way.held[len(kept):])
	way.held = kept
}

// sweep forgets ways idle for meshWayIdle (every idle one when full).
func (w *meshWriter) sweep(now time.Time, full bool) {
	w.swept = now
	for addr, way := range w.ways {
		if len(way.held) > 0 {
			continue
		}
		if full || now.Sub(way.used) >= meshWayIdle {
			delete(w.ways, addr)
		}
	}
}

// retryDelay is the wait before the retry after retries ones.
func retryDelay(retries int) time.Duration {
	if retries < meshRetrySteady {
		return meshRetryFirst
	}
	return min(meshRetryFirst<<min(retries-meshRetrySteady+1, 8), meshRetryMax)
}
