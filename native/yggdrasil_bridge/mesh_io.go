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
//
// Hails. A friend that still holds a session with this node's previous
// process (it restarted) reaches the new core with a packet no session here
// opens: the core drops it and sets up a new session with the friend, and
// nothing reaches the packet loop. The core's path notification for a node
// this node never wrote to tells it happened; when nothing of that node
// comes through within meshHailAfter, the session layer asks it for its
// keys (pqEndpoint.hail), saying that it holds no session of its, and the
// friend sends again what it sent lately.
//
// Echoes. For a few seconds after a node came back (it restarted) ironwood
// loses packets to it without anyone noticing: the two cores' sessions go
// out of step when both start one within the same second (ironwood counts
// them in seconds and takes only the first; it heals on a later packet,
// which is lost too), and the restarted node's place in the tree changes a
// second or two after it came on, so packets along the old path die on the
// way (ironwood looks the node up again only on the next packet). Nothing
// above notices either: the session layers of both just set up their
// sessions anew. So for meshSettleFor after the node said it holds no
// session of this node's (pqEndpoint.settle), each signal packet written
// to it goes twice more, meshEchoAfter apart; the receiver drops the copies
// (sealed frames have counters).
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
	// After its own lookup found a path, the writer gives a session the
	// core may start by itself a round and a half of the lookup's time
	// (within these bounds) before its opening packet starts one.
	meshOpenWait    = 20 * time.Millisecond
	meshOpenWaitMax = time.Second
	// Keys of node addresses remembered: in two generations of up to
	// meshKeysPerGeneration each, so a stranger sending from many keys
	// only ever pushes out the ones heard from longest ago.
	meshKeysPerGeneration = 2048
	// Destinations the writer keeps state for at once; one idle this long
	// is forgotten.
	meshMaxWays  = 4096
	meshWayIdle  = 2 * time.Minute
	meshWaySweep = 30 * time.Second
	// A node the core found a path to unasked (see hails below) is hailed
	// when nothing of it came through this long after, at most once in
	// meshHailEvery; path notifications kept for the writer at most.
	meshHailAfter = time.Second
	meshHailTries = 6
	meshHailEvery = 10 * time.Minute
	meshMaxFound  = 256
	// Signal packets written lately are kept this long (at most so many
	// per destination and bytes in all), to go again when the path they
	// went along turns out to have broken (meshWriter.again).
	meshRecentFor    = 2 * time.Second
	meshRecentPerWay = 8
	meshRecentBytes  = 1 << 20
	// How long a way settles (see echoes above), how long after a write its
	// copies go and how many; packets and bytes kept for them at most, per
	// destination and in all; nodes marked as coming back, kept at most.
	meshSettleFor   = 4 * time.Second
	meshEchoAfter   = 1200 * time.Millisecond
	meshEchoes      = 2
	meshEchoPerWay  = 64
	meshEchoBytes   = 1 << 20
	meshMaxSettling = 1024
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

// meshPacket is a packet queued for a destination. echo marks a fragment
// of a sealed signal frame, which may go again (see echoes at the top of
// this file): the receiver drops a copy of it unopened.
type meshPacket struct {
	to    address.Address
	data  []byte
	media bool
	echo  bool
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
	// Asks a contact that reached this node unasked for its keys (the
	// session layer, pqEndpoint.hail); may be nil. Set before start.
	hail func(ip net.IP)

	mu sync.Mutex
	// What the node knows of node addresses, newer and older generation.
	keys, oldKeys map[address.Address]*meshKnown
	// Addresses the core found paths to since the writer last looked.
	found []address.Address
	// Nodes that came back since the writer last looked (see echoes at the
	// top of this file), and until when their ways settle.
	settling map[address.Address]time.Time
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
		keys:    make(map[address.Address]*meshKnown),
		oldKeys: make(map[address.Address]*meshKnown),
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
	return m.enqueue(packet, media, false)
}

// sendSealed is send for a fragment of a sealed signal frame (the session
// layer's 'D' frames), which goes again while its way settles (see echoes
// at the top of this file). Never a control frame of the session layer: a
// copy of a key request would have the peer set up its session once more.
func (m *meshIO) sendSealed(packet []byte) error {
	return m.enqueue(packet, false, true)
}

func (m *meshIO) enqueue(packet []byte, media, echo bool) error {
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
	m.queue = append(m.queue, meshPacket{to: to, data: packet, media: media, echo: echo, at: time.Now()})
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

// meshKnown is what the node knows of a node address: its key, and when a
// packet from it last came through (zero: none did).
type meshKnown struct {
	key   ed25519.PublicKey
	heard time.Time
}

// learn notes key for addr, from a packet that came through, or from a
// path the core found; the writer is woken for a new key or a path.
func (m *meshIO) learn(addr address.Address, key ed25519.PublicKey, path bool) {
	m.mu.Lock()
	known := m.knownLocked(addr)
	fresh := known == nil || !bytes.Equal(known.key, key)
	if fresh {
		known = &meshKnown{key: bytes.Clone(key)}
		m.storeKnownLocked(addr, known)
	}
	if path {
		if len(m.found) < meshMaxFound {
			m.found = append(m.found, addr)
		}
	} else {
		known.heard = time.Now()
	}
	m.mu.Unlock()
	if fresh || path {
		m.events.Add(1)
		m.signal()
	}
}

// knownLocked is what the node knows of addr (nil: nothing); an entry of
// the older generation moves to the newer. m.mu is held.
func (m *meshIO) knownLocked(addr address.Address) *meshKnown {
	if known, ok := m.keys[addr]; ok {
		return known
	}
	if known, ok := m.oldKeys[addr]; ok {
		m.storeKnownLocked(addr, known)
		return known
	}
	return nil
}

func (m *meshIO) storeKnownLocked(addr address.Address, known *meshKnown) {
	if _, ok := m.keys[addr]; !ok && len(m.keys) >= meshKeysPerGeneration {
		m.oldKeys = m.keys
		m.keys = make(map[address.Address]*meshKnown, meshKeysPerGeneration)
	}
	m.keys[addr] = known
	delete(m.oldKeys, addr)
}

// keyOf is the key of addr, nil when the node never heard of it.
func (m *meshIO) keyOf(addr address.Address) ed25519.PublicKey {
	m.mu.Lock()
	defer m.mu.Unlock()
	if known := m.knownLocked(addr); known != nil {
		return known.key
	}
	return nil
}

// heardSince reports whether a packet from addr came through since since.
func (m *meshIO) heardSince(addr address.Address, since time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	known := m.knownLocked(addr)
	return known != nil && !known.heard.Before(since)
}

func (m *meshIO) signal() {
	select {
	case m.wake <- struct{}{}:
	default:
	}
}

// settle marks the node at ip as coming back: the session layer heard from
// it that it holds no session of this node's (it restarted). For
// meshSettleFor what is written to it goes again (see echoes at the top of
// this file). It never waits for the mesh.
func (m *meshIO) settle(ip net.IP) {
	ip16 := ip.To16()
	if ip16 == nil || ip.To4() != nil {
		return
	}
	var addr address.Address
	copy(addr[:], ip16)
	if !addr.IsValid() {
		return
	}
	m.mu.Lock()
	if m.settling == nil {
		m.settling = make(map[address.Address]time.Time)
	}
	if _, ok := m.settling[addr]; ok || len(m.settling) < meshMaxSettling {
		m.settling[addr] = time.Now().Add(meshSettleFor)
	}
	m.mu.Unlock()
	m.signal()
}

// take hands the queue to the writer (its packets now count as held), the
// addresses the core found paths to meanwhile and the nodes that came back.
func (m *meshIO) take() ([]meshPacket, []address.Address, map[address.Address]time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	packets, found, settling := m.queue, m.found, m.settling
	m.queue, m.found, m.settling = nil, nil, nil
	m.heldBytes += m.queueBytes
	m.queueBytes = 0
	return packets, found, settling
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
	// When the writer last did something that has the core look the node
	// up (a lookup, an opening packet), and the signal packets written to
	// it lately, oldest first (see again).
	sought time.Time
	recent []meshSent
	// When the writer's own lookup found the path, and how long it took
	// (a round trip to the node).
	found time.Time
	rtt   time.Duration
	// Until when the way settles, and the packets written meanwhile that go
	// again (see echoes at the top of this file), oldest first.
	settle time.Time
	echo   []meshEcho
}

// meshSent is a packet written lately.
type meshSent struct {
	data []byte
	at   time.Time
}

// meshEcho is a packet written while its way settled: when it goes again,
// and how many more times.
type meshEcho struct {
	data []byte
	due  time.Time
	left int
}

// meshWriter is the writer goroutine's own state.
type meshWriter struct {
	m    *meshIO
	ways map[address.Address]*meshWay
	// The ways with packets held.
	waiting map[address.Address]*meshWay
	// Nodes the core found a path to unasked (to be hailed), and when each
	// was last hailed.
	hails  map[address.Address]*meshHail
	hailed map[address.Address]time.Time
	// Bytes of the packets written lately that the ways keep (see again).
	recentBytes int
	events      uint64
	swept       time.Time
	// The ways with packets to go again, and their bytes (see echoes at the
	// top of this file).
	echoing   map[address.Address]*meshWay
	echoBytes int
}

// run is the writer: it writes what is queued, holds what goes to a way
// that is still opening and keeps looking at those ways.
func (m *meshIO) run() {
	defer close(m.done)
	w := &meshWriter{
		m:       m,
		ways:    make(map[address.Address]*meshWay),
		waiting: make(map[address.Address]*meshWay),
		hails:   make(map[address.Address]*meshHail),
		hailed:  make(map[address.Address]time.Time),
		swept:   time.Now(),
		echoing: make(map[address.Address]*meshWay),
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
		packets, found, settling := m.take()
		for addr, until := range settling {
			w.way(addr, now).settle = until
		}
		for _, packet := range packets {
			w.route(packet, now)
		}
		w.unasked(found, now)
		next := w.progress(time.Now())
		if hail := w.hail(time.Now()); hail > 0 && (next == 0 || hail < next) {
			next = hail
		}
		if echo := w.echoes(time.Now()); echo > 0 && (next == 0 || echo < next) {
			next = echo
		}
		if next > 0 {
			timer.Reset(next)
		} else {
			timer.Stop()
		}
	}
}

// unasked takes the paths the core found that the writer did not look for:
// to a node this node never wrote to (see hails at the top of this file),
// or a new path to one it writes to. The core then looked the node up by
// itself: its path broke (the node restarted elsewhere in the tree), and
// what went lately may have died on the old one; it goes again (again).
func (w *meshWriter) unasked(found []address.Address, now time.Time) {
	for _, addr := range found {
		if way := w.ways[addr]; way != nil {
			if len(way.held) > 0 && !way.asked.IsZero() && way.found.IsZero() {
				// The writer's own lookup: how long it took is a round trip.
				way.found = now
				way.rtt = now.Sub(way.asked)
			} else if len(way.held) == 0 && now.Sub(way.sought) >= meshRecentFor {
				w.again(addr, way, now)
			}
			continue
		}
		if w.m.hail == nil {
			continue
		}
		if last, ok := w.hailed[addr]; ok && now.Sub(last) < meshHailEvery {
			continue
		}
		if _, ok := w.hails[addr]; !ok {
			w.hails[addr] = &meshHail{found: now, due: now.Add(meshHailAfter)}
		}
	}
}

// meshHail is a node to be hailed: when the core found the path to it, when
// the next hail is due and how many went.
type meshHail struct {
	found time.Time
	due   time.Time
	tries int
}

// keep notes a signal packet just written to way (media goes once: a late
// frame of a call is worse than a lost one).
func (w *meshWriter) keep(way *meshWay, packet meshPacket, now time.Time) {
	w.forget(way, now)
	if packet.media {
		return
	}
	if len(way.recent) >= meshRecentPerWay || w.recentBytes+len(packet.data) > meshRecentBytes {
		if len(way.recent) == 0 {
			return
		}
		w.recentBytes -= len(way.recent[0].data)
		way.recent = way.recent[1:]
	}
	way.recent = append(way.recent, meshSent{data: packet.data, at: now})
	w.recentBytes += len(packet.data)
}

// forget lets go of what went to way longer than meshRecentFor ago.
func (w *meshWriter) forget(way *meshWay, now time.Time) {
	for len(way.recent) > 0 && now.Sub(way.recent[0].at) >= meshRecentFor {
		w.recentBytes -= len(way.recent[0].data)
		way.recent = way.recent[1:]
	}
}

// again writes once more what went to way lately.
func (w *meshWriter) again(addr address.Address, way *meshWay, now time.Time) {
	w.forget(way, now)
	if len(way.recent) == 0 {
		return
	}
	debugf("[ZEN-GO] mesh: the path to %s changed, %d packet(s) go again\n", net.IP(addr[:]), len(way.recent))
	recent := way.recent
	way.recent = nil
	for _, sent := range recent {
		w.recentBytes -= len(sent.data)
		w.write(way.key, meshPacket{to: addr, data: sent.data})
	}
}

// hail hails the nodes found unasked whose time came and of which nothing
// came through since, and tells when the next is due (0: none). A node is
// hailed again every meshHailAfter (meshHailTries in all): the first hails
// often do not open there, as the two cores' sessions are still out of step
// (ironwood heals that only on later packets, seconds later).
func (w *meshWriter) hail(now time.Time) time.Duration {
	next := time.Duration(0)
	for addr, hail := range w.hails {
		if now.Before(hail.due) {
			if wait := hail.due.Sub(now); next == 0 || wait < next {
				next = wait
			}
			continue
		}
		if w.m.heardSince(addr, hail.found) || (hail.tries == 0 && len(w.hailed) >= meshMaxWays) {
			delete(w.hails, addr)
			continue
		}
		if hail.tries == 0 {
			w.hailed[addr] = now
		}
		hail.tries++
		debugf("[ZEN-GO] mesh: hailing %s, which reached this node unasked (try %d)\n", net.IP(addr[:]), hail.tries)
		w.m.hail(net.IP(append([]byte(nil), addr[:]...)))
		if hail.tries >= meshHailTries {
			delete(w.hails, addr)
			continue
		}
		hail.due = now.Add(meshHailAfter)
		if wait := hail.due.Sub(now); next == 0 || wait < next {
			next = wait
		}
	}
	return next
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
		w.keep(way, packet, now)
		w.remember(packet.to, way, packet, now)
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
				way.sought = now
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
		if way.opened.IsZero() && !way.found.IsZero() {
			// The writer's lookup just found the path. It also let go a
			// packet the core held for the node meanwhile, maybe a session
			// init of its own (a friend's frame of a session this node no
			// longer holds); the session it starts comes after a round
			// trip. An opening packet now would start a second one, and the
			// node takes only the first of two acknowledgements made within
			// the same second (ironwood counts them in seconds): the
			// sessions would not match, and neither side could open the
			// other's packets until one started yet another in a later
			// second.
			if wait := way.found.Add(min(max(meshOpenWait, way.rtt*3/2), meshOpenWaitMax)); now.Before(wait) {
				way.checkAt = wait
				soonest(wait)
				continue
			}
		}
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
			way.sought = now
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
	way.found = time.Time{}
	way.retries = 0
	way.checks = 0
	for _, packet := range held {
		w.write(way.key, packet)
		w.keep(way, packet, now)
		w.remember(packet.to, way, packet, now)
		w.m.release(len(packet.data))
	}
}

// remember keeps a signal packet just written to the way to addr to go
// again, while the way settles (see echoes at the top of this file).
func (w *meshWriter) remember(addr address.Address, way *meshWay, packet meshPacket, now time.Time) {
	if !packet.echo || !now.Before(way.settle) {
		return
	}
	if len(way.echo) >= meshEchoPerWay || w.echoBytes+len(packet.data) > meshEchoBytes {
		return
	}
	way.echo = append(way.echo, meshEcho{data: packet.data, due: now.Add(meshEchoAfter), left: meshEchoes})
	w.echoBytes += len(packet.data)
	w.echoing[addr] = way
}

// echoes writes again what is due of the packets the settling ways keep,
// and tells when the next is due (0: none). A way that is opening again
// waits: the core keeps one packet for it meanwhile, which must be the
// opening one.
func (w *meshWriter) echoes(now time.Time) time.Duration {
	next := time.Duration(0)
	soonest := func(delay time.Duration) {
		delay = max(delay, time.Millisecond)
		if next == 0 || delay < next {
			next = delay
		}
	}
	for addr, way := range w.echoing {
		if len(way.held) > 0 {
			soonest(meshCheckMax)
			continue
		}
		kept := way.echo[:0]
		for _, echo := range way.echo {
			if now.Before(echo.due) {
				kept = append(kept, echo)
				soonest(echo.due.Sub(now))
				continue
			}
			w.write(way.key, meshPacket{to: addr, data: echo.data})
			if echo.left--; echo.left > 0 {
				echo.due = now.Add(meshEchoAfter)
				kept = append(kept, echo)
				soonest(meshEchoAfter)
				continue
			}
			w.echoBytes -= len(echo.data)
		}
		clear(way.echo[len(kept):])
		way.echo = kept
		if len(way.echo) == 0 {
			way.echo = nil
			delete(w.echoing, addr)
		}
	}
	return next
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
		w.forget(way, now)
		if len(way.held) > 0 || len(way.echo) > 0 {
			continue
		}
		if full || now.Sub(way.used) >= meshWayIdle {
			for _, sent := range way.recent {
				w.recentBytes -= len(sent.data)
			}
			delete(w.ways, addr)
		}
	}
	for addr, last := range w.hailed {
		if now.Sub(last) >= meshHailEvery {
			delete(w.hailed, addr)
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
