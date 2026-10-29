package main

import (
	"bytes"
	"crypto/ed25519"
	"fmt"
	"io"
	"net"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// loopbackMesh is a hub on loopback and Zen nodes peered with it, each a
// real Yggdrasil core under the bridge's own node, as on the real mesh.
type loopbackMesh struct {
	t      *testing.T
	hubURI string
	// A plain node beside the others, which looks them up (waitFindable).
	prober *core.Core
	logger *log.Logger
}

func newLoopbackMesh(t *testing.T) *loopbackMesh {
	t.Helper()
	logger := log.New(io.Discard, "", 0)
	// The mesh's root is the hub (the lowest key), as in newTestMesh.
	var hubKey ed25519.PrivateKey
	for hubKey == nil || hubKey.Public().(ed25519.PublicKey)[0] != 0 ||
		hubKey.Public().(ed25519.PublicKey)[1] > 0x0f {
		_, hubKey, _ = ed25519.GenerateKey(nil)
	}
	hubConfig := &config.NodeConfig{PrivateKey: config.KeyBytes(hubKey)}
	if err := hubConfig.GenerateSelfSignedCertificate(); err != nil {
		t.Fatal(err)
	}
	hub, err := core.New(hubConfig.Certificate, logger)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(hub.Stop)
	listenURL, _ := url.Parse("tcp://127.0.0.1:0")
	listener, err := hub.Listen(listenURL, "")
	if err != nil {
		t.Fatal(err)
	}
	hubURI := fmt.Sprintf("tcp://127.0.0.1:%d", listener.Addr().(*net.TCPAddr).Port)
	prober, err := core.New(config.GenerateConfig().Certificate, logger, core.Peer{URI: hubURI})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(prober.Stop)
	return &loopbackMesh{t: t, hubURI: hubURI, prober: prober, logger: logger}
}

// waitFindable waits until the other nodes can find each of nodes, as two
// devices that have been on the mesh a while can: a node that just came on
// the mesh answers lookups only once its bloom filter and its place in the
// tree reached the others (ironwood's router rounds, a second each). A
// third node looks them up, which leaves their own sessions and paths
// cold.
func (m *loopbackMesh) waitFindable(nodes ...*bridgeNode) {
	m.t.Helper()
	for _, node := range nodes {
		key := node.core.PublicKey()
		waitMesh(m.t, "the node never became findable", func() bool {
			m.prober.SendLookup(key)
			time.Sleep(100 * time.Millisecond)
			for _, path := range m.prober.GetPaths() {
				if bytes.Equal(path.Key, key) {
					return true
				}
			}
			return false
		})
	}
}

// waitFinding waits until node can find the others itself: its lookups go
// nowhere until the bloom filter of its peer (the hub) reached it. It looks
// the third node up, which leaves its sessions and paths with the others
// cold.
func (m *loopbackMesh) waitFinding(node *bridgeNode) {
	m.t.Helper()
	key := m.prober.PublicKey()
	waitMesh(m.t, "the node never found the others", func() bool {
		node.core.SendLookup(key)
		time.Sleep(100 * time.Millisecond)
		for _, path := range node.core.GetPaths() {
			if bytes.Equal(path.Key, key) {
				return true
			}
		}
		return false
	})
}

// node is a new node on the mesh with a fresh key.
func (m *loopbackMesh) node() *bridgeNode {
	return m.nodeWithKey(nil)
}

// nodeWithKey is a node with key (a fresh one when nil): the same key
// again is the same device after a restart. Its packet loop does not run
// yet (startPacketLoop).
func (m *loopbackMesh) nodeWithKey(key ed25519.PrivateKey) *bridgeNode {
	m.t.Helper()
	cfg := config.GenerateConfig()
	if key != nil {
		cfg.PrivateKey = config.KeyBytes(key)
		if err := cfg.GenerateSelfSignedCertificate(); err != nil {
			m.t.Fatal(err)
		}
	}
	cfg.Peers = []string{m.hubURI}
	yggCore, err := core.New(cfg.Certificate, m.logger, core.Peer{URI: m.hubURI})
	if err != nil {
		m.t.Fatal(err)
	}
	node := &bridgeNode{
		core:           yggCore,
		config:         cfg,
		logger:         m.logger,
		signalPartials: make(map[string]*signalReassembly),
		relays:         make(map[string]*relayState),
		peerProbe:      newPeerProbeState(),
	}
	node.startMesh()
	m.t.Cleanup(func() { stopTestNode(node) })
	return node
}

// stopTestNode stops a node of a loopbackMesh (again: nothing).
func stopTestNode(node *bridgeNode) {
	node.mesh.stop()
	node.core.Stop()
}

func meshIP(node *bridgeNode) net.IP {
	return net.ParseIP(node.core.Address().String())
}

// answersWithin reports whether call returns within limit (a call that
// does not is left behind).
func answersWithin(limit time.Duration, call func()) bool {
	done := make(chan struct{})
	go func() {
		call()
		close(done)
	}()
	select {
	case <-done:
		return true
	case <-time.After(limit):
		return false
	}
}

// floodRaw sends count small unsealed signals from from to to: the
// receiver's packet loop refuses them, but its mesh core carries each one
// up to the loop first.
func floodRaw(from, to *bridgeNode, count int) {
	destination := meshIP(to)
	for index := range count {
		_ = from.writeSignalWire(destination, []byte(fmt.Sprintf("flood %d", index)))
	}
}

// R5-F4: ironwood hands what reaches a node to its reader through a channel
// of one, behind actors that wait for each other (phony's backpressure):
// the session manager waits for the peer's session, the session for the
// reader, the reader for the packet loop to take the packet in hand. The
// packet loop answered key requests and new sessions from inside the loop,
// with a write that waits for that same session manager: when the peer kept
// sending meanwhile, the loop waited for the manager, the manager for the
// loop, and the node was deaf and mute for good; the app's next look at its
// sessions (YggGetNodeInfo, on the UI thread) never returned either. Here
// the loop is held at the moment it answers while the peer keeps sending,
// as at a start when every friend writes at once.
func TestPacketLoopNeverWaitsForTheMesh(t *testing.T) {
	mesh := newLoopbackMesh(t)
	a, b := mesh.node(), mesh.node()
	endpoint, err := a.pqEndpointOf()
	if err != nil {
		t.Fatal(err)
	}
	gate := make(chan struct{})
	held := make(chan struct{})
	write := endpoint.write
	first := true
	// Set before A's packet loop starts: only that loop calls it.
	endpoint.write = func(destination net.IP, wire []byte) error {
		if first {
			first = false
			close(held)
			<-gate
		}
		return write(destination, wire)
	}
	startPacketLoop(a)
	startPacketLoop(b)
	warmPaths(t, a.core, b.core)
	warmSessions(t, a, b)

	// B has no session with A: it asks for A's key record, and A's packet
	// loop answers from within the loop, where it is held.
	if err := sendSignal(b, meshIP(a).String(), `{"type":"message","text":"hej"}`); err != nil {
		t.Fatal(err)
	}
	select {
	case <-held:
	case <-time.After(15 * time.Second):
		t.Fatal("A never answered B's key request")
	}
	floodRaw(b, a, 64)
	time.Sleep(500 * time.Millisecond)
	close(gate)

	if !answersWithin(5*time.Second, func() { a.core.GetSessions() }) {
		t.Fatal("A's mesh core stopped answering: its packet loop waited for the mesh while answering")
	}
	deadline := time.Now().Add(20 * time.Second)
	for {
		message, ok := a.signalInbox.wait(time.Until(deadline))
		if !ok {
			t.Fatal("B's message never reached A")
		}
		if message.Payload == `{"type":"message","text":"hej"}` {
			break
		}
	}
}

// stallCore leaves node's mesh core stalled as behind a packet loop that
// stopped (the one R5-F4 left waiting in a write): its reader takes one
// packet and no more (ironwood starts reading with the first read), and
// from sends it enough for its session actors to wait for each other.
func stallCore(t *testing.T, node, from *bridgeNode) {
	t.Helper()
	go func() {
		buffer := make([]byte, 64*1024)
		_, _, _ = node.core.ReadFrom(buffer)
	}()
	startPacketLoop(from)
	warmPaths(t, node.core, from.core)
	// The sender's writer sends once the way is open: a moment later.
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		floodRaw(from, node, 32)
		if !answersWithin(500*time.Millisecond, func() { node.core.GetSessions() }) {
			return
		}
	}
	t.Fatal("the mesh core did not stall")
}

// R5-F4: what the app asks of a node on its UI thread answers also while
// the node's mesh core does not: the screen never freezes on a core that
// stopped answering (the "logo that never goes away"), and the node stops.
func TestNodeInfoAnswersWhileTheMeshCoreIsStalled(t *testing.T) {
	mesh := newLoopbackMesh(t)
	a, b := mesh.node(), mesh.node()
	stallCore(t, a, b)
	if !answersWithin(2*time.Second, func() { normalizeNodeState(1, a) }) {
		t.Fatal("the node info waited for the stalled mesh core")
	}
	hub, _ := url.Parse(mesh.hubURI)
	for name, call := range map[string]func(){
		"the node info again": func() { normalizeNodeState(1, a) },
		"the peers":           func() { buildPeerJSON(a.view().peers) },
		"the sessions":        func() { _ = a.view().sessions },
		"the paths":           func() { a.viewPaths() },
		"the tree":            func() { a.viewTree() },
		"the public peers":    func() { a.publicPeerStates() },
		"the door":            func() { a.doorState() },
		"a peer call":         func() { _ = a.coreAction(func() error { return a.core.CallPeer(hub, "") }) },
		"a message":           func() { _ = sendSignal(a, meshIP(b).String(), `{"type":"ping"}`) },
	} {
		// Each within the view's wait (the stalled question is not waited
		// for again) or a change's, never for good.
		if !answersWithin(nodeActionWait+time.Second, call) {
			t.Fatalf("%s waited for the stalled mesh core", name)
		}
	}
	if !answersWithin(nodeStopWait+2*time.Second, func() { _ = a.shutdown(1) }) {
		t.Fatal("the node did not stop")
	}
}

// R5-F5: the first message between two devices on the mesh that never
// talked arrives at once: the key lookup, ironwood's session and path and
// the session layer's key request and answer are set up without losing a
// packet (each layer below keeps only one per destination meanwhile, and the
// key frames went in several fragments).
func TestFirstContactArrivesQuickly(t *testing.T) {
	mesh := newLoopbackMesh(t)
	a, b := mesh.node(), mesh.node()
	startPacketLoop(a)
	startPacketLoop(b)
	// Both on the mesh a while, as a friend whose code someone scans.
	mesh.waitFindable(a, b)
	took := deliverWithin(t, a, b, `{"type":"friend_request","text":"cześć"}`, 20*time.Second)
	t.Logf("first contact: %v", took)
	if took > firstContactBound {
		t.Fatalf("the first message took %v (at most %v)", took, firstContactBound)
	}
	took = deliverWithin(t, b, a, `{"type":"friend_accept"}`, 20*time.Second)
	t.Logf("the answer: %v", took)
	if took > firstContactBound {
		t.Fatalf("the answer took %v (at most %v)", took, firstContactBound)
	}
}

// talkingPair is two devices on the mesh that already exchanged messages
// both ways (sessions and paths of every layer set up).
func talkingPair(t *testing.T) (*loopbackMesh, *bridgeNode, *bridgeNode) {
	t.Helper()
	mesh := newLoopbackMesh(t)
	a, b := mesh.node(), mesh.node()
	startPacketLoop(a)
	startPacketLoop(b)
	mesh.waitFindable(a, b)
	deliverWithin(t, a, b, `{"type":"message","text":"przed"}`, 30*time.Second)
	deliverWithin(t, b, a, `{"type":"message","text":"odpowiedź"}`, 30*time.Second)
	return mesh, a, b
}

// restartTestNode stops node and starts it again with its key, as after an
// update or a phone's restart: the app hands the new node the pins it kept
// (YggPqSetPinsJson); returns the new node once it reached the mesh (as the
// app's start waits for), its packet loop running.
func restartTestNode(t *testing.T, mesh *loopbackMesh, node *bridgeNode) *bridgeNode {
	t.Helper()
	key := ed25519.PrivateKey(node.config.PrivateKey)
	var pins map[string]string
	if endpoint, err := node.pqEndpointOf(); err == nil {
		pins = endpoint.pinsSnapshot()
	}
	stopTestNode(node)
	again := mesh.nodeWithKey(key)
	if endpoint, err := again.pqEndpointOf(); err == nil {
		endpoint.importPins(pins, false)
	}
	startPacketLoop(again)
	waitMesh(t, "the restarted node never reached the hub", func() bool { return again.hasUpPeer() })
	return again
}

// R5-F5: a device that restarted reaches its friend at once (its hello
// after the start), although the friend still holds sessions and paths of
// the old process; the friend's answer arrives too.
func TestMessagesFlowQuicklyAfterARestart(t *testing.T) {
	mesh, a, b := talkingPair(t)
	b = restartTestNode(t, mesh, b)
	took := deliverWithin(t, b, a, `{"type":"hello","text":"po starcie"}`, 30*time.Second)
	t.Logf("restarted device to friend: %v", took)
	if took > firstContactBound {
		t.Fatalf("after the restart the restarted device's message took %v (at most %v)", took, firstContactBound)
	}
	took = deliverWithin(t, a, b, `{"type":"message","text":"po restarcie"}`, 30*time.Second)
	t.Logf("friend to restarted device: %v", took)
	if took > firstContactBound {
		t.Fatalf("after the restart the friend's message took %v (at most %v)", took, firstContactBound)
	}
}

// R5-F5: a friend who writes to a device just as it restarted gets through
// within seconds. Its sessions with the old process are stale on every
// layer: the device's new core drops the packet, and only the device's
// greeting after its start (the app greets its friends) tells the friend's
// session layer to send it again.
func TestFriendReachesARestartedDeviceQuickly(t *testing.T) {
	mesh, a, b := talkingPair(t)
	b = restartTestNode(t, mesh, b)
	started := time.Now()
	payload := `{"type":"message","text":"jesteś?"}`
	if err := sendSignal(a, meshIP(b).String(), payload); err != nil {
		t.Fatal(err)
	}
	deliverWithin(t, b, a, `{"type":"hello"}`, 30*time.Second)
	for {
		message, ok := b.signalInbox.wait(time.Until(started.Add(30 * time.Second)))
		if !ok {
			t.Fatalf("the friend's message never reached the restarted device")
		}
		if message.Payload == payload {
			break
		}
	}
	took := time.Since(started)
	t.Logf("friend to restarted device: %v", took)
	if took > afterRestartBound {
		t.Fatalf("the friend's message to the restarted device took %v (at most %v)", took, afterRestartBound)
	}
}

// R5-F5: a friend who writes to a device that restarted and says nothing
// gets through within seconds: the device's new core drops the frame (the
// friend's session is one of the old process), the device hails the friend
// it never wrote to, and the friend sends again.
func TestFriendReachesASilentlyRestartedDevice(t *testing.T) {
	mesh, a, b := talkingPair(t)
	b = restartTestNode(t, mesh, b)
	// Back on the mesh a while, as when a friend writes some time later:
	// found by the others, and finding them (the hub's bloom filter reached
	// it on the hub's next router round).
	mesh.waitFindable(b)
	mesh.waitFinding(b)
	took := deliverWithin(t, a, b, `{"type":"message","text":"halo?"}`, 30*time.Second)
	t.Logf("friend to silently restarted device: %v", took)
	if took > afterRestartBound {
		t.Fatalf("the friend's message to the silently restarted device took %v (at most %v)", took, afterRestartBound)
	}
}

// afterRestartBound is the longest a friend's first message to a device
// that restarted may take on a loopback mesh: the device must first become
// findable again (ironwood's router rounds).
const afterRestartBound = 5 * time.Second

// R5-F5: a friend's message to a device that restarted a moment before is
// not lost, although the two talked again already: ironwood can drop it
// then without anyone noticing (the two cores' sessions out of step, the
// device's place in the tree changing), and the mesh writer sends it again
// (mesh_io.go, echoes). The steps of the real-device crash test: a burst of
// messages, the device restarts and greets, the friend answers and writes
// again a second later.
func TestAMessageSoonAfterARestartIsNotLost(t *testing.T) {
	mesh, a, b := talkingPair(t)
	drain := func(node *bridgeNode) func() {
		stop := make(chan struct{})
		done := make(chan struct{})
		go func() {
			defer close(done)
			for {
				select {
				case <-stop:
					return
				default:
				}
				node.signalInbox.wait(20 * time.Millisecond)
			}
		}()
		return func() {
			close(stop)
			<-done
		}
	}
	stopA := drain(a)
	defer stopA()
	stopB := drain(b)
	for i := range 40 {
		_ = sendSignal(a, meshIP(b).String(), fmt.Sprintf(`{"type":"message","text":"%d"}`, i))
		_ = sendSignal(b, meshIP(a).String(), fmt.Sprintf(`{"type":"message_ack","n":%d}`, i))
		time.Sleep(60 * time.Millisecond)
	}
	stopB()
	b = restartTestNode(t, mesh, b)
	time.Sleep(time.Second)
	for _, kind := range []string{"hello", "ping", "poll"} {
		_ = sendSignal(b, meshIP(a).String(), fmt.Sprintf(`{"type":"%s"}`, kind))
	}
	time.Sleep(10 * time.Millisecond)
	for _, kind := range []string{"pong", "heads", "here"} {
		_ = sendSignal(a, meshIP(b).String(), fmt.Sprintf(`{"type":"%s"}`, kind))
	}
	time.Sleep(time.Second)
	took := deliverWithin(t, a, b, `{"type":"message","text":"po awarii"}`, 15*time.Second)
	t.Logf("the friend's message a moment after the restart: %v", took)
	if took > afterRestartBound {
		t.Fatalf("the friend's message a moment after the restart took %v (at most %v)", took, afterRestartBound)
	}
}

// R5-F4: four devices sending to each other at once (short signals, ones
// of several fragments, call media), the app asking about them all the
// while, and one of them restarting every few seconds: no node stops
// answering, no question of the app waits, and every pair still talks
// afterwards.
func TestNodesUnderLoadKeepAnswering(t *testing.T) {
	if testing.Short() {
		t.Skip("a storm of half a minute")
	}
	mesh := newLoopbackMesh(t)
	const count = 4
	slots := make([]atomic.Pointer[bridgeNode], count)
	for index := range slots {
		node := mesh.node()
		startPacketLoop(node)
		slots[index].Store(node)
	}
	mesh.waitFindable(slots[0].Load(), slots[1].Load(), slots[2].Load(), slots[3].Load())

	stop := make(chan struct{})
	var wait sync.WaitGroup
	var slowest atomic.Int64
	var sent, received atomic.Int64
	big := strings.Repeat("zen ", 6000)
	for from := range count {
		for to := range count {
			if from == to {
				continue
			}
			wait.Add(1)
			go func() {
				defer wait.Done()
				for index := 0; ; index++ {
					select {
					case <-stop:
						return
					case <-time.After(time.Duration(5+index%15) * time.Millisecond):
					}
					node, target := slots[from].Load(), meshIP(slots[to].Load())
					payload := fmt.Sprintf(`{"type":"ping","n":%d}`, index)
					if index%4 == 0 {
						payload = fmt.Sprintf(`{"type":"message","n":%d,"text":"%s"}`, index, big)
					}
					if sendSignal(node, target.String(), payload) == nil {
						sent.Add(1)
					}
					if index%3 == 0 {
						if packet, err := buildRelayPacket(node, target, "storm", []byte("media")); err == nil {
							_ = node.writeMesh(packet, true)
						}
					}
				}
			}()
		}
		wait.Add(1)
		go func() {
			defer wait.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				if _, ok := slots[from].Load().signalInbox.wait(50 * time.Millisecond); ok {
					received.Add(1)
				}
			}
		}()
	}
	for asker := range 2 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for index := 0; ; index++ {
				select {
				case <-stop:
					return
				case <-time.After(20 * time.Millisecond):
				}
				node := slots[(asker+index)%count].Load()
				started := time.Now()
				normalizeNodeState(1, node)
				node.publicPeerStates()
				_ = node.view().sessions
				if took := int64(time.Since(started)); took > slowest.Load() {
					slowest.Store(took)
				}
			}
		}()
	}
	deadline := time.Now().Add(20 * time.Second)
	for index := 0; time.Now().Before(deadline); index++ {
		time.Sleep(3 * time.Second)
		slot := &slots[index%count]
		restarted := restartTestNode(t, mesh, slot.Load())
		slot.Store(restarted)
		// The app greets its friends once it started.
		for other := range slots {
			if node := slots[other].Load(); node != restarted {
				_ = sendSignal(restarted, meshIP(node).String(), `{"type":"hello"}`)
			}
		}
	}
	close(stop)
	wait.Wait()
	t.Logf("%d signals sent, %d received; slowest look of the app %v", sent.Load(), received.Load(), time.Duration(slowest.Load()))
	if slowest := time.Duration(slowest.Load()); slowest > 2*nodeViewWait+time.Second {
		t.Fatalf("a look of the app took %v", slowest)
	}
	for index := range slots {
		node := slots[index].Load()
		if !answersWithin(2*time.Second, func() { node.core.GetSessions() }) {
			t.Fatalf("node %d stopped answering", index)
		}
	}
	for from := range count {
		for to := range count {
			if from == to {
				continue
			}
			sender, receiver := slots[from].Load(), slots[to].Load()
			payload := fmt.Sprintf(`{"type":"message","text":"after the storm %d to %d"}`, from, to)
			if err := sendSignal(sender, meshIP(receiver).String(), payload); err != nil {
				t.Fatal(err)
			}
			if !arrives(receiver, sender, payload, 15*time.Second) {
				t.Fatalf("after the storm %d to %d never arrived; %d has of %d: %s; %d has of %d: %s",
					from, to, from, to, sessionState(sender, receiver), to, from, sessionState(receiver, sender))
			}
		}
	}
}

// arrives waits up to limit for payload from from in to's inbox.
func arrives(to, from *bridgeNode, payload string, limit time.Duration) bool {
	deadline := time.Now().Add(limit)
	for {
		message, ok := to.signalInbox.wait(time.Until(deadline))
		if !ok {
			return false
		}
		if message.Payload == payload && bytes.Equal(net.ParseIP(message.From), meshIP(from)) {
			return true
		}
	}
}

// sessionState is what node's session layer holds of peer, whether it
// pinned the peer and whether its mesh reader knows the peer's key
// (diagnostics).
func sessionState(node, peer *bridgeNode) string {
	endpoint, err := node.pqEndpointOf()
	if err != nil {
		return err.Error()
	}
	_, pinned := endpoint.pinsSnapshot()[meshIP(peer).String()]
	known := node.mesh.keyOf(*address.AddrForKey(peer.core.PublicKey())) != nil
	return fmt.Sprintf("%s (pinned %v, key known to the mesh reader %v)", endpoint.peerState(meshIP(peer)), pinned, known)
}

// firstContactBound is the longest a first contact (or the first message
// after a restart) may take on a loopback mesh.
const firstContactBound = 3 * time.Second

// deliverWithin sends payload from from to to once and waits for it at
// to; it returns how long that took, failing after limit.
func deliverWithin(t *testing.T, from, to *bridgeNode, payload string, limit time.Duration) time.Duration {
	t.Helper()
	started := time.Now()
	if err := sendSignal(from, meshIP(to).String(), payload); err != nil {
		t.Fatalf("send: %v", err)
	}
	for {
		message, ok := to.signalInbox.wait(time.Until(started.Add(limit)))
		if !ok {
			t.Fatalf("%q never arrived within %v", payload, limit)
		}
		if message.Payload == payload && bytes.Equal(net.ParseIP(message.From), meshIP(from)) {
			return time.Since(started)
		}
	}
}
