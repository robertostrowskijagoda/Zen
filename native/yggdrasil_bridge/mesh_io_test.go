package main

import (
	"bytes"
	"crypto/ed25519"
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	iwt "github.com/Arceliar/ironwood/types"
	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// fakeMeshCore is a core for meshIO: it records what the writer does, and
// a test says which keys have a session and a path.
type fakeMeshCore struct {
	key ed25519.PublicKey
	mu  sync.Mutex
	// Closed to let writes through; nil: they go at once.
	gate     chan struct{}
	writes   []fakeMeshWrite
	lookups  []ed25519.PublicKey
	sessions map[string]bool
	paths    map[string]bool
	notify   func(ed25519.PublicKey)
}

type fakeMeshWrite struct {
	key  ed25519.PublicKey
	data []byte
}

func newFakeMeshCore(t *testing.T) *fakeMeshCore {
	t.Helper()
	public, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return &fakeMeshCore{key: public, sessions: map[string]bool{}, paths: map[string]bool{}}
}

func (c *fakeMeshCore) WriteTo(p []byte, addr net.Addr) (int, error) {
	c.mu.Lock()
	gate := c.gate
	c.mu.Unlock()
	if gate != nil {
		<-gate
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.writes = append(c.writes, fakeMeshWrite{key: bytes.Clone(addr.(iwt.Addr)), data: bytes.Clone(p)})
	return len(p), nil
}

func (c *fakeMeshCore) SendLookup(key ed25519.PublicKey) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lookups = append(c.lookups, bytes.Clone(key))
}

func (c *fakeMeshCore) SetPathNotify(notify func(ed25519.PublicKey)) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.notify = notify
}

func (c *fakeMeshCore) GetSessions() []core.SessionInfo {
	c.mu.Lock()
	defer c.mu.Unlock()
	var sessions []core.SessionInfo
	for key := range c.sessions {
		sessions = append(sessions, core.SessionInfo{Key: ed25519.PublicKey(key)})
	}
	return sessions
}

func (c *fakeMeshCore) GetPaths() []core.PathEntryInfo {
	c.mu.Lock()
	defer c.mu.Unlock()
	var paths []core.PathEntryInfo
	for key := range c.paths {
		paths = append(paths, core.PathEntryInfo{Key: ed25519.PublicKey(key)})
	}
	return paths
}

func (c *fakeMeshCore) PublicKey() ed25519.PublicKey { return c.key }

func (c *fakeMeshCore) MTU() uint64 { return 65535 }

// open gives key a session and a path, as the core has once it set the
// way up.
func (c *fakeMeshCore) open(key ed25519.PublicKey) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.sessions[string(key)] = true
	c.paths[string(key)] = true
}

// found is the core's path notification for key.
func (c *fakeMeshCore) found(key ed25519.PublicKey) {
	c.mu.Lock()
	notify := c.notify
	c.mu.Unlock()
	notify(key)
}

func (c *fakeMeshCore) written() []fakeMeshWrite {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]fakeMeshWrite(nil), c.writes...)
}

func (c *fakeMeshCore) lookedUp() []ed25519.PublicKey {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]ed25519.PublicKey(nil), c.lookups...)
}

func newTestMeshIO(t *testing.T, c *fakeMeshCore) *meshIO {
	t.Helper()
	m := newMeshIO(c, nil)
	m.start()
	t.Cleanup(m.stop)
	return m
}

// meshPeer is another node's key and address.
func meshPeer(t *testing.T) (ed25519.PublicKey, net.IP) {
	t.Helper()
	public, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return public, net.IP(address.AddrForKey(public)[:])
}

func meshPacketTo(t *testing.T, m *meshIO, to net.IP, payload string) []byte {
	t.Helper()
	packet, err := buildYggPacket(net.IP(m.local[:]), to, yggSignalPort, []byte(payload))
	if err != nil {
		t.Fatal(err)
	}
	return packet
}

func waitMeshIO(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal(what)
		}
		time.Sleep(2 * time.Millisecond)
	}
}

// payloadOf is what a packet a test built carries.
func payloadOf(t *testing.T, packet []byte) string {
	t.Helper()
	_, _, payload, ok := parseYggPacket(packet)
	if !ok {
		t.Fatal("not a packet of the test")
	}
	return string(payload)
}

// R5-F4: whoever sends never waits for the core, also when the core does
// not take a single packet: the queue refuses once its budget is spent.
func TestMeshSendNeverWaitsForTheCore(t *testing.T) {
	c := newFakeMeshCore(t)
	c.gate = make(chan struct{})
	m := newTestMeshIO(t, c)
	key, to := meshPeer(t)
	m.learn(*address.AddrForKey(key), key, false)
	c.open(key)
	packet := meshPacketTo(t, m, to, string(bytes.Repeat([]byte{'x'}, 60000)))
	refused := false
	done := make(chan struct{})
	go func() {
		defer close(done)
		for range 2 * m.budget / len(packet) {
			if err := m.send(packet, false); errors.Is(err, errMeshQueueFull) {
				refused = true
				return
			}
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("send waited for the core")
	}
	if !refused {
		t.Fatal("the queue took more than its budget")
	}
	close(c.gate)
}

// R5-F5: a destination whose key is unknown is looked up; once the key is
// found, one packet goes alone to open the way, and the rest only once the
// core has a session and a path, in order.
func TestMeshOpensTheWayWithOnePacketAndThenSendsTheRest(t *testing.T) {
	c := newFakeMeshCore(t)
	m := newTestMeshIO(t, c)
	key, to := meshPeer(t)
	for _, payload := range []string{"first", "second", "third"} {
		if err := m.send(meshPacketTo(t, m, to, payload), false); err != nil {
			t.Fatal(err)
		}
	}
	waitMeshIO(t, "no lookup", func() bool { return len(c.lookedUp()) > 0 })
	if partial := c.lookedUp()[0]; !bytes.Equal(partial, address.AddrForKey(key).GetKey()) {
		t.Fatal("the lookup is for the address's key")
	}
	if len(c.written()) != 0 {
		t.Fatal("nothing goes before the key is known")
	}
	c.found(key)
	waitMeshIO(t, "no opening packet", func() bool { return len(c.written()) > 0 })
	time.Sleep(50 * time.Millisecond)
	writes := c.written()
	if len(writes) != 1 || !bytes.Equal(writes[0].key, key) || payloadOf(t, writes[0].data) != "first" {
		t.Fatalf("only the first packet opens the way, got %d writes", len(writes))
	}
	c.open(key)
	waitMeshIO(t, "the held packets never went", func() bool { return len(c.written()) == 4 })
	var got []string
	for _, write := range c.written()[1:] {
		got = append(got, payloadOf(t, write.data))
	}
	if got[0] != "first" || got[1] != "second" || got[2] != "third" {
		t.Fatalf("held packets went as %q", got)
	}
	// The way is open: the next packet goes at once.
	if err := m.send(meshPacketTo(t, m, to, "fourth"), false); err != nil {
		t.Fatal(err)
	}
	waitMeshIO(t, "a packet on an open way waited", func() bool { return len(c.written()) == 5 })
}

// A packet from another node notes its key: the answer needs no lookup.
func TestMeshAcceptNotesTheSendersKey(t *testing.T) {
	c := newFakeMeshCore(t)
	m := newTestMeshIO(t, c)
	key, from := meshPeer(t)
	incoming, err := buildYggPacket(from, net.IP(m.local[:]), yggSignalPort, []byte("hi"))
	if err != nil {
		t.Fatal(err)
	}
	if !m.accept(incoming, iwt.Addr(key)) {
		t.Fatal("a packet from the key's own address to this node is taken")
	}
	c.open(key)
	if err := m.send(meshPacketTo(t, m, from, "answer"), false); err != nil {
		t.Fatal(err)
	}
	waitMeshIO(t, "the answer never went", func() bool { return len(c.written()) > 0 })
	if len(c.lookedUp()) != 0 {
		t.Fatal("the answer needed a lookup")
	}
}

// What a node takes: addressed to it, from the sender key's own address
// (not another address, not one of the sender's /64), IPv6.
func TestMeshAcceptRefusesForeignPackets(t *testing.T) {
	c := newFakeMeshCore(t)
	m := newTestMeshIO(t, c)
	key, from := meshPeer(t)
	_, other := meshPeer(t)
	local := net.IP(m.local[:])
	subnet := address.SubnetForKey(key)
	fromSubnet := net.IP(append(append([]byte(nil), subnet[:]...), 0, 0, 0, 0, 0, 0, 0, 1))
	cases := map[string][]byte{}
	for name, ends := range map[string][2]net.IP{
		"another sender's address": {other, local},
		"the sender's /64":         {fromSubnet, local},
		"another destination":      {from, other},
	} {
		packet, err := buildYggPacket(ends[0], ends[1], yggSignalPort, []byte("x"))
		if err != nil {
			t.Fatal(err)
		}
		cases[name] = packet
	}
	cases["not IPv6"] = append([]byte{0x45}, make([]byte, 60)...)
	cases["too short"] = []byte{0x60, 0}
	for name, packet := range cases {
		if m.accept(packet, iwt.Addr(key)) {
			t.Errorf("%s was taken", name)
		}
	}
	good, _ := buildYggPacket(from, local, yggSignalPort, []byte("x"))
	if m.accept(good, iwt.Addr(key[:16])) {
		t.Error("a short key was taken")
	}
}

// What a node sends: from its own address, to a node address, within the
// mesh MTU.
func TestMeshSendRefusesPacketsItMayNotSend(t *testing.T) {
	c := newFakeMeshCore(t)
	m := newTestMeshIO(t, c)
	key, to := meshPeer(t)
	_, other := meshPeer(t)
	subnet := address.SubnetForKey(key)
	toSubnet := net.IP(append(append([]byte(nil), subnet[:]...), 0, 0, 0, 0, 0, 0, 0, 1))
	notMine, _ := buildYggPacket(other, to, yggSignalPort, []byte("x"))
	toNet, _ := buildYggPacket(net.IP(m.local[:]), toSubnet, yggSignalPort, []byte("x"))
	huge := make([]byte, m.MTU()+1)
	huge[0] = 0x60
	copy(huge[8:24], m.local[:])
	copy(huge[24:40], to.To16())
	for name, packet := range map[string][]byte{
		"from another address": notMine,
		"to a /64":             toNet,
		"over the MTU":         huge,
		"not IPv6":             {0x45, 0},
	} {
		if err := m.send(packet, false); err == nil {
			t.Errorf("%s was queued", name)
		}
	}
	m.stop()
	if err := m.send(meshPacketTo(t, m, to, "late"), false); !errors.Is(err, errMeshStopped) {
		t.Fatalf("a stopped writer took a packet: %v", err)
	}
}

// Call media held for a way that does not open goes after a second (a
// late frame of a call is worse than a lost one), and its budget with it.
func TestMeshDropsHeldMediaSoon(t *testing.T) {
	c := newFakeMeshCore(t)
	m := newTestMeshIO(t, c)
	key, to := meshPeer(t)
	m.learn(*address.AddrForKey(key), key, false)
	if err := m.send(meshPacketTo(t, m, to, "media"), true); err != nil {
		t.Fatal(err)
	}
	waitMeshIO(t, "no opening packet", func() bool { return len(c.written()) == 1 })
	time.Sleep(meshHoldMediaFor + meshRetryFirst/2)
	c.open(key)
	m.signal()
	time.Sleep(100 * time.Millisecond)
	if writes := c.written(); len(writes) != 1 {
		t.Fatalf("media held past its time went: %d writes", len(writes))
	}
	m.mu.Lock()
	held := m.heldBytes + m.queueBytes
	m.mu.Unlock()
	if held != 0 {
		t.Fatalf("%d bytes still count against the budget", held)
	}
}

// While a way does not open, the opening packet goes again every second at
// first (a node just come on the mesh is found only after a router round
// or two), then less often.
func TestMeshRetriesAWayThatDoesNotOpen(t *testing.T) {
	if got := []time.Duration{retryDelay(0), retryDelay(meshRetrySteady - 1)}; got[0] != meshRetryFirst || got[1] != meshRetryFirst {
		t.Fatalf("first retries after %v", got)
	}
	if retryDelay(meshRetrySteady) <= meshRetryFirst || retryDelay(100) != meshRetryMax {
		t.Fatalf("later retries after %v, at most %v", retryDelay(meshRetrySteady), retryDelay(100))
	}
	c := newFakeMeshCore(t)
	m := newTestMeshIO(t, c)
	key, to := meshPeer(t)
	m.learn(*address.AddrForKey(key), key, false)
	if err := m.send(meshPacketTo(t, m, to, "knock"), false); err != nil {
		t.Fatal(err)
	}
	waitMeshIO(t, "no opening packet", func() bool { return len(c.written()) == 1 })
	waitMeshIO(t, "the opening packet never went again", func() bool { return len(c.written()) == 2 })
}

// R5-F5: a node the core found a path to although this node never wrote to
// it (a friend that still holds a session with this node's previous
// process) is hailed once nothing of it came through within meshHailAfter,
// and again while nothing comes; not one that sent something meanwhile, nor
// one this node writes to.
func TestMeshHailsANodeThatReachedItUnasked(t *testing.T) {
	c := newFakeMeshCore(t)
	m := newMeshIO(c, nil)
	var mu sync.Mutex
	var hailed []string
	m.hail = func(ip net.IP) {
		mu.Lock()
		defer mu.Unlock()
		hailed = append(hailed, ip.String())
	}
	m.start()
	t.Cleanup(m.stop)
	silent, silentIP := meshPeer(t)
	talking, talkingIP := meshPeer(t)
	written, writtenIP := meshPeer(t)
	if err := m.send(meshPacketTo(t, m, writtenIP, "to it"), false); err != nil {
		t.Fatal(err)
	}
	waitMeshIO(t, "no lookup", func() bool { return len(c.lookedUp()) > 0 })
	c.found(silent)
	c.found(talking)
	c.found(written)
	incoming, _ := buildYggPacket(talkingIP, net.IP(m.local[:]), yggSignalPort, []byte("hi"))
	m.accept(incoming, iwt.Addr(talking))
	got := func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), hailed...)
	}
	waitMeshIO(t, "the silent node was never hailed", func() bool { return len(got()) > 0 })
	time.Sleep(300 * time.Millisecond)
	if hails := got(); len(hails) != 1 || hails[0] != silentIP.String() {
		t.Fatalf("hailed %v, want only %s", hails, silentIP)
	}
	// Nothing came: hailed again (the first may not have opened there).
	deadline := time.Now().Add(2*meshHailAfter + time.Second)
	for len(got()) < 2 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if hails := got(); len(hails) != 2 || hails[1] != silentIP.String() {
		t.Fatalf("hailed %v, want %s twice", hails, silentIP)
	}
}

// R5-F4: everything that reaches the writer at once — sends from many
// goroutines, packets read from many senders, path notifications, ways
// opening, a stop in the middle — never blocks a caller, and once every
// way opened nothing is left counting against the budget.
func TestMeshIOUnderLoad(t *testing.T) {
	c := newFakeMeshCore(t)
	m := newTestMeshIO(t, c)
	type peer struct {
		key ed25519.PublicKey
		ip  net.IP
	}
	peers := make([]peer, 40)
	for index := range peers {
		peers[index].key, peers[index].ip = meshPeer(t)
	}
	packets := make([][]byte, len(peers))
	for index, to := range peers {
		size := 40 + (index%5)*2000
		packets[index] = meshPacketTo(t, m, to.ip, string(bytes.Repeat([]byte{'z'}, size)))
	}
	var wait sync.WaitGroup
	for sender := range 8 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for index := range 400 {
				_ = m.send(packets[(sender*7+index)%len(peers)], index%3 == 0)
			}
		}()
	}
	for reader := range 4 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for index := range 400 {
				from := peers[(reader*11+index)%len(peers)]
				packet, _ := buildYggPacket(from.ip, net.IP(m.local[:]), yggSignalPort, []byte("in"))
				m.accept(packet, iwt.Addr(from.key))
			}
		}()
	}
	wait.Add(1)
	go func() {
		defer wait.Done()
		for index, to := range peers {
			c.found(to.key)
			if index%2 == 0 {
				c.open(to.key)
			}
		}
	}()
	wait.Wait()
	for _, to := range peers {
		c.open(to.key)
	}
	m.signal()
	waitMeshIO(t, "held packets never went once every way opened", func() bool {
		m.mu.Lock()
		defer m.mu.Unlock()
		return m.queueBytes == 0 && m.heldBytes == 0
	})
	// A stop while senders still send: they hear it at once.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for index := range 1000 {
			_ = m.send(packets[index%len(peers)], false)
		}
	}()
	m.stop()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("a send waited for a stopped writer")
	}
}
