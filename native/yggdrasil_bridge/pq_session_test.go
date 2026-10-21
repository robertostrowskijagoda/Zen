package main

import (
	"bytes"
	"crypto/ed25519"
	"fmt"
	"io"
	"net"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/ipv6rwc"
)

// pqTestNet carries frames between session endpoints in memory, in order,
// so a test can look at (and change) every one.
type pqTestNet struct {
	t         *testing.T
	endpoints map[string]*pqEndpoint
	queue     []pqTestFrame
	sent      []pqTestFrame
	delivered map[string][]string
	clock     time.Time
}

type pqTestFrame struct {
	from, to net.IP
	wire     []byte
}

func newPQTestNet(t *testing.T) *pqTestNet {
	return &pqTestNet{
		t:         t,
		endpoints: make(map[string]*pqEndpoint),
		delivered: make(map[string][]string),
		clock:     time.Unix(1_800_000_000, 0),
	}
}

// add makes an endpoint for the node key made from fill.
func (n *pqTestNet) add(fill byte) (*pqEndpoint, net.IP) {
	n.t.Helper()
	nodeKey, ip := pqTestNode(n.t, fill)
	endpoint, err := newPQEndpoint(nodeKey, ip, func(to net.IP, wire []byte) error {
		frame := pqTestFrame{from: ip, to: bytes.Clone(to), wire: bytes.Clone(wire)}
		n.queue = append(n.queue, frame)
		n.sent = append(n.sent, frame)
		return nil
	})
	if err != nil {
		n.t.Fatal(err)
	}
	endpoint.now = func() time.Time { return n.clock }
	n.endpoints[ip.String()] = endpoint
	return endpoint, ip
}

func (n *pqTestNet) deliver(frame pqTestFrame) {
	endpoint := n.endpoints[frame.to.String()]
	if endpoint == nil {
		return
	}
	if plain, ok := endpoint.receive(frame.from, frame.wire); ok {
		n.delivered[frame.to.String()] = append(n.delivered[frame.to.String()], string(plain))
	}
}

// pump delivers everything queued, and what that makes, until it is quiet.
func (n *pqTestNet) pump() {
	for len(n.queue) > 0 {
		frame := n.queue[0]
		n.queue = n.queue[1:]
		n.deliver(frame)
	}
}

func (n *pqTestNet) take(to net.IP) []string {
	got := n.delivered[to.String()]
	delete(n.delivered, to.String())
	return got
}

func (n *pqTestNet) lastData(from net.IP) pqTestFrame {
	for index := len(n.sent) - 1; index >= 0; index-- {
		frame := n.sent[index]
		if frame.from.Equal(from) && frame.wire[len(pqMagic)] == pqKindData {
			return frame
		}
	}
	n.t.Fatal("no data frame was sent")
	return pqTestFrame{}
}

func mustSend(t *testing.T, endpoint *pqEndpoint, to net.IP, text string) {
	t.Helper()
	if err := endpoint.send(to, []byte(text)); err != nil {
		t.Fatalf("send: %v", err)
	}
}

func TestPQSessionEstablishesOnFirstContactAndCarriesFramesBothWays(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)

	// A knows nothing of B: the frame waits for B's key record.
	mustSend(t, a, bIP, `{"type":"message","text":"hej"}`)
	if len(network.queue) != 1 || network.queue[0].wire[len(pqMagic)] != pqKindKeys {
		t.Fatal("the first contact must be a key request")
	}
	network.pump()
	if got := network.take(bIP); len(got) != 1 || got[0] != `{"type":"message","text":"hej"}` {
		t.Fatalf("B got %q", got)
	}
	first := network.lastData(aIP)
	if first.wire[len(pqMagic)+1]&pqFlagCiphertext == 0 {
		t.Fatal("the first frame of a session carries its ciphertext")
	}
	if strings.Contains(string(first.wire), "hej") {
		t.Fatal("the frame is not sealed")
	}
	session := a.peers[bIP.String()].send
	if session == nil || !session.acked {
		t.Fatal("B must have acknowledged the session")
	}

	// Acknowledged: later frames carry no ciphertext, and no new KEM
	// operation happens per message.
	for index := range 10 {
		mustSend(t, a, bIP, fmt.Sprintf("m%d", index))
	}
	network.pump()
	if got := network.take(bIP); len(got) != 10 || got[9] != "m9" {
		t.Fatalf("B got %q", got)
	}
	later := network.lastData(aIP)
	if later.wire[len(pqMagic)+1]&pqFlagCiphertext != 0 || len(later.wire) != pqDataHeaderSize+2+16 {
		t.Fatalf("an acknowledged session's frame is %d bytes", len(later.wire))
	}
	if a.peers[bIP.String()].send != session {
		t.Fatal("the session must be kept, not made anew per message")
	}

	// B learnt A's record from the request: it answers at once.
	mustSend(t, b, aIP, "odp")
	if network.queue[0].wire[len(pqMagic)] != pqKindData {
		t.Fatal("B already holds A's key")
	}
	network.pump()
	if got := network.take(aIP); len(got) != 1 || got[0] != "odp" {
		t.Fatalf("A got %q", got)
	}
}

func TestPQSessionRefusesPlaintextTamperingAndReplay(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	c, cIP := network.add(3)
	mustSend(t, a, bIP, "one")
	network.pump()
	network.take(bIP)
	frame := network.lastData(aIP)

	// Unsealed, classical-only signals are not taken.
	for _, plain := range []string{`{"type":"message","text":"x"}`, "ZSTD:AAAA", ""} {
		if _, ok := b.receive(aIP, []byte(plain)); ok {
			t.Fatalf("an unsealed signal %q was taken", plain)
		}
	}
	// The same frame again.
	if _, ok := b.receive(aIP, frame.wire); ok {
		t.Fatal("a replayed frame was taken")
	}
	// Any changed byte: header, counter, sealed text, tag.
	for _, at := range []int{len(pqMagic) + 2, pqDataHeaderSize - 1, pqDataHeaderSize, -1} {
		mustSend(t, a, bIP, "fresh")
		fresh := network.queue[len(network.queue)-1]
		network.queue = network.queue[:len(network.queue)-1]
		if at < 0 {
			at = len(fresh.wire) - 1
		}
		damaged := bytes.Clone(fresh.wire)
		damaged[at] ^= 0x01
		if _, ok := b.receive(aIP, damaged); ok {
			t.Fatalf("a frame changed at %d was taken", at)
		}
		if _, ok := b.receive(aIP, fresh.wire); !ok {
			t.Fatalf("the unchanged frame (after a change at %d) must still open", at)
		}
	}
	// A frame of A's session shown by C (another sender address) opens
	// nothing: the session is bound to the pair.
	if _, ok := b.receive(cIP, frame.wire); ok {
		t.Fatal("a frame of another pair's session was taken")
	}
	_ = c
	// Counters far behind the window are refused even when unseen.
	session := b.peers[aIP.String()].receive[0]
	if session.window.fresh(0) {
		t.Fatal("counter 0 was used")
	}
}

func TestPQSessionRecoversWhenTheReceiverLostIt(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	_, bIP := network.add(2)
	mustSend(t, a, bIP, "one")
	network.pump()
	network.take(bIP)

	// B starts again (a restart, the other process of the device): same
	// key, no sessions, no challenges.
	network.clock = network.clock.Add(pqKeyRequestInterval)
	network.add(2)
	mustSend(t, a, bIP, "lost")
	network.pump()
	if got := network.take(bIP); len(got) != 0 {
		t.Fatalf("a frame of a session B does not know opened: %q", got)
	}
	if a.peers[bIP.String()].send != nil {
		t.Fatal("B's answer must make A start a new session")
	}
	mustSend(t, a, bIP, "again")
	network.pump()
	if got := network.take(bIP); len(got) != 1 || got[0] != "again" {
		t.Fatalf("B got %q", got)
	}
	_ = aIP
}

func TestPQSessionsRotate(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	_, bIP := network.add(2)
	mustSend(t, a, bIP, "one")
	network.pump()
	old := a.peers[bIP.String()].send
	network.clock = network.clock.Add(pqSessionLifetime + time.Second)
	mustSend(t, a, bIP, "two")
	network.pump()
	fresh := a.peers[bIP.String()].send
	if fresh == old || fresh.id == old.id {
		t.Fatal("the session must be new after its lifetime")
	}
	if got := network.take(bIP); len(got) != 2 || got[1] != "two" {
		t.Fatalf("B got %q", got)
	}
	// A frame of the old session still on its way opens.
	sealed, err := func() ([]byte, error) {
		a.mu.Lock()
		defer a.mu.Unlock()
		peer := a.peers[bIP.String()]
		peer.send = old
		old.created = network.clock
		defer func() { peer.send = fresh }()
		return a.sealLocked(peer, []byte("late"), network.clock)
	}()
	if err != nil {
		t.Fatal(err)
	}
	if plain, ok := network.endpoints[bIP.String()].receive(aIP, sealed); !ok || string(plain) != "late" {
		t.Fatal("a late frame of the previous session must still open")
	}
}

func TestPQKeyRecordsCannotBeSwapped(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	_, cIP := network.add(3)
	// C shows B's record as its own: A does not take it.
	forged := append([]byte(pqMagic), pqKindKeys, 0)
	forged = append(forged, b.record...)
	a.receive(cIP, forged)
	if peer := a.peers[cIP.String()]; peer != nil && peer.publicKey != nil {
		t.Fatal("A took another node's record from C")
	}
	// A record with a changed key does not verify either.
	changed := append([]byte(pqMagic), pqKindKeys, 0)
	changed = append(changed, b.record...)
	changed[len(pqMagic)+2+40] ^= 1
	a.receive(bIP, changed)
	if peer := a.peers[bIP.String()]; peer != nil && peer.publicKey != nil {
		t.Fatal("A took a changed record")
	}
	_ = aIP
}

func TestPQPendingFramesAreBounded(t *testing.T) {
	network := newPQTestNet(t)
	a, _ := network.add(1)
	_, silent := pqTestNode(t, 9) // never answers
	for index := range pqPendingPerPeer + 20 {
		mustSend(t, a, silent, fmt.Sprintf("m%d", index))
	}
	peer := a.peers[silent.String()]
	if len(peer.pending) != pqPendingPerPeer || peer.pending[0].wire[1] != '2' {
		t.Fatalf("%d frames held, first %q", len(peer.pending), peer.pending[0].wire)
	}
	requests := 0
	for _, frame := range network.sent {
		if frame.wire[len(pqMagic)] == pqKindKeys {
			requests++
		}
	}
	if requests != 1 {
		t.Fatalf("%d key requests within %v", requests, pqKeyRequestInterval)
	}
	network.clock = network.clock.Add(pqPendingTTL + time.Second)
	mustSend(t, a, silent, "last")
	if len(peer.pending) != 1 || a.pendingBytes != len("last") {
		t.Fatalf("expired frames stayed: %d held, %d bytes", len(peer.pending), a.pendingBytes)
	}
}

func TestPQReplayWindow(t *testing.T) {
	var window pqReplay
	for _, counter := range []uint64{0, 1, 5, 3} {
		if !window.fresh(counter) {
			t.Fatalf("%d is new", counter)
		}
		window.mark(counter)
	}
	for _, counter := range []uint64{0, 1, 3, 5} {
		if window.fresh(counter) {
			t.Fatalf("%d came already", counter)
		}
	}
	if !window.fresh(2) || !window.fresh(4) {
		t.Fatal("skipped counters may still come")
	}
	window.mark(5 + pqReplayWindow)
	if window.fresh(5) || window.fresh(2) {
		t.Fatal("counters a window behind are refused")
	}
	if !window.fresh(4+pqReplayWindow) || !window.fresh(6) {
		t.Fatal("a skipped counter inside the window is new")
	}
}

// Two real nodes on a loopback mesh: what one sends with sendSignal comes
// out of the other's signal inbox as the app sent it, and the mesh carried
// only sealed frames.
func TestPQSignalsBetweenTwoMeshNodes(t *testing.T) {
	logger := log.New(io.Discard, "", 0)
	// The hub is the mesh's root (the lowest key), as in newTestMesh.
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
	newNode := func() *bridgeNode {
		cfg := config.GenerateConfig()
		yggCore, err := core.New(cfg.Certificate, logger, core.Peer{URI: hubURI})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(yggCore.Stop)
		iprwc := ipv6rwc.NewReadWriteCloser(yggCore)
		iprwc.SetMTU(iprwc.MaxMTU())
		node := &bridgeNode{
			core:           yggCore,
			iprwc:          iprwc,
			config:         cfg,
			logger:         logger,
			signalPartials: make(map[string]*signalReassembly),
		}
		startPacketLoop(node)
		return node
	}
	a, b := newNode(), newNode()
	if !bytes.Equal(a.core.PublicKey(), ed25519.PrivateKey(a.config.PrivateKey).Public().(ed25519.PublicKey)) {
		t.Fatal("the node key is the config key")
	}
	warmPaths(t, a.core, b.core)
	warmSessions(t, a, b)

	big := `{"type":"message","text":"` + strings.Repeat("zen ", 5000) + `"}`
	for _, payload := range []string{`{"type":"message","text":"hej"}`, big} {
		waitMesh(t, "no sealed signal came through", func() bool {
			if err := sendSignal(a, b.core.Address().String(), payload); err != nil {
				t.Fatalf("send: %v", err)
			}
			message, ok := b.signalInbox.wait(500 * time.Millisecond)
			if !ok {
				return false
			}
			if message.Payload != payload || message.From != a.core.Address().String() {
				t.Fatalf("unexpected signal: %.80q", message.Payload)
			}
			return true
		})
		drainInbox(b)
	}
	if err := sendSignal(b, a.core.Address().String(), `{"type":"pong"}`); err != nil {
		t.Fatal(err)
	}
	if message, ok := a.signalInbox.wait(5 * time.Second); !ok || message.Payload != `{"type":"pong"}` {
		t.Fatalf("A got %+v (%v)", message, ok)
	}
	// An unsealed signal (what an old or foreign sender would send) never
	// reaches the app.
	if err := a.writeSignalWire(net.ParseIP(b.core.Address().String()), []byte(`{"type":"message","text":"plain"}`)); err != nil {
		t.Fatal(err)
	}
	if message, ok := b.signalInbox.wait(800 * time.Millisecond); ok {
		t.Fatalf("an unsealed signal reached the app: %+v", message)
	}
}

// warmSessions waits until a and b have ironwood sessions both ways. Until
// then ironwood holds only the last packet sent to the peer, so the leading
// fragments of a first key request would be lost and the request would come
// again only after pqKeyRequestInterval. The small unsealed signals sent
// here are dropped by the receivers.
func warmSessions(t *testing.T, a, b *bridgeNode) {
	t.Helper()
	hasSession := func(from *core.Core, to ed25519.PublicKey) bool {
		for _, session := range from.GetSessions() {
			if bytes.Equal(session.Key, to) {
				return true
			}
		}
		return false
	}
	aIP := net.ParseIP(a.core.Address().String())
	bIP := net.ParseIP(b.core.Address().String())
	waitMesh(t, "no mesh session between the nodes", func() bool {
		_ = a.writeSignalWire(bIP, []byte("warm"))
		_ = b.writeSignalWire(aIP, []byte("warm"))
		time.Sleep(100 * time.Millisecond)
		return hasSession(a.core, b.core.PublicKey()) && hasSession(b.core, a.core.PublicKey())
	})
}

// The per-frame cost of the session layer (seal and open, no KEM): a
// call-signalling sized frame and a large attachment chunk.
func BenchmarkPQSessionFrame(b *testing.B) {
	for _, size := range []int{1024, 256 * 1024} {
		b.Run(fmt.Sprintf("%dB", size), func(b *testing.B) {
			network := newPQTestNet(&testing.T{})
			a, _ := network.add(1)
			receiver, bIP := network.add(2)
			mustSend(&testing.T{}, a, bIP, "hello")
			network.pump()
			aIP := a.local
			wire := bytes.Repeat([]byte{'x'}, size)
			b.SetBytes(int64(size))
			b.ResetTimer()
			for range b.N {
				a.mu.Lock()
				frame, err := a.sealLocked(a.peers[bIP.String()], wire, network.clock)
				a.mu.Unlock()
				if err != nil {
					b.Fatal(err)
				}
				if _, ok := receiver.receive(aIP, frame); !ok {
					b.Fatal("frame did not open")
				}
			}
		})
	}
}
