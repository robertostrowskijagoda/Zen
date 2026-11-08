package main

import (
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// silentProxy passes a TCP connection on to target until it is frozen: then
// it passes nothing more either way and closes nothing, as a mobile network
// that forgot the connection, or a server gone off the network, does.
type silentProxy struct {
	listener net.Listener
	frozen   atomic.Bool
	mu       sync.Mutex
	conns    []net.Conn
}

func newSilentProxy(t *testing.T, target string) (*silentProxy, string) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := &silentProxy{listener: listener}
	t.Cleanup(p.close)
	go func() {
		for {
			in, err := listener.Accept()
			if err != nil {
				return
			}
			out, err := net.Dial("tcp", target)
			if err != nil {
				_ = in.Close()
				continue
			}
			p.mu.Lock()
			p.conns = append(p.conns, in, out)
			p.mu.Unlock()
			go p.pipe(in, out)
			go p.pipe(out, in)
		}
	}()
	return p, "tcp://" + listener.Addr().String()
}

func (p *silentProxy) pipe(from, to net.Conn) {
	buf := make([]byte, 32<<10)
	for {
		n, err := from.Read(buf)
		if err != nil {
			return
		}
		if p.frozen.Load() {
			// Swallowed: nothing goes on, nothing is closed.
			continue
		}
		if _, err := to.Write(buf[:n]); err != nil {
			return
		}
	}
}

func (p *silentProxy) close() {
	_ = p.listener.Close()
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, c := range p.conns {
		_ = c.Close()
	}
}

// phoneNodeWith is a phone node that dials one public peer of pool, with
// its keeper told of the links that come and go, as the bridge starts one.
func phoneNodeWith(t *testing.T, pool []string) *bridgeNode {
	t.Helper()
	keeper := newPhonePeerKeeper(pool, phonePeerTarget(phoneExtraAccountPeerCount))
	cfg := config.GenerateConfig()
	yggCore, err := core.New(cfg.Certificate, withPeerEvents(newBridgeLogger(io.Discard), keeper))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(yggCore.Stop)
	node := &bridgeNode{
		core:        yggCore,
		config:      cfg,
		logger:      newBridgeLogger(io.Discard),
		publicPeers: map[string]bool{},
		phonePeers:  keeper,
	}
	node.swapPublicPeers(nil, keeper.dialled)
	go node.watchPhonePeers()
	t.Cleanup(keeper.stopWatch)
	return node
}

// A link that is there answers the check within about a second, and the
// check leaves it as it was.
func TestALinkThatIsThereAnswersTheCheck(t *testing.T) {
	coreA, uriA := listeningCore(t)
	node := phoneNodeWith(t, []string{uriA})
	waitForPeer(t, node.core, coreA.PublicKey(), true)
	// The link's first exchanges over: the check sees its own answer.
	time.Sleep(2 * time.Second)

	got := node.checkLinks()
	t.Logf("check: %+v", got)
	if got.Probed != 1 || got.Answered != 1 || got.Dropped != 0 || got.Up != 1 {
		t.Fatalf("a link that is there: %+v", got)
	}
	if got.Ms > 2500 {
		t.Fatalf("the answer took %d ms", got.Ms)
	}
	if dialled := node.dialledPublicPeers(); len(dialled) != 1 || dialled[0] != uriA {
		t.Fatalf("the check changed the peers: %v", dialled)
	}
}

// The one peer of a phone goes silent (no FIN, no RST: its link stays "up"
// for as long as nothing is sent). A check on the next wake ends the link
// within the core's peer timeout, and a stand-in is up before it returns:
// the phone is reachable again within one wake instead of at its next
// mailbox poll, up to half an hour later.
func TestACheckOnAWakeReplacesALinkThatDiedWithoutAWord(t *testing.T) {
	coreA, targetA := listeningCore(t)
	coreC, uriC := listeningCore(t)
	proxy, uriA := newSilentProxy(t, strings.TrimPrefix(targetA, "tcp://"))
	node := phoneNodeWith(t, []string{uriA, uriC})
	waitForPeer(t, node.core, coreA.PublicKey(), true)
	// The tree's first exchanges over (an idle link that went silent then
	// stayed "up" for longer than 90 s here).
	time.Sleep(10 * time.Second)

	proxy.frozen.Store(true)
	// Nothing is sent over an idle link: it still counts as up.
	time.Sleep(4 * time.Second)
	if _, up := node.peerLinks(); !up[string(coreA.PublicKey())] {
		t.Fatal("the silent link went down without a check: the test shows nothing")
	}

	got := node.checkLinks()
	t.Logf("check: %+v", got)
	if got.Probed != 1 || got.Dropped != 1 || got.Up < 1 {
		t.Fatalf("a link that died without a word: %+v", got)
	}
	if got.Ms > int64((linkCheckAnswerWait + linkCheckRedialWait).Milliseconds()) {
		t.Fatalf("the check took %d ms", got.Ms)
	}
	waitForPeer(t, node.core, coreC.PublicKey(), true)
	deadline := time.Now().Add(10 * time.Second)
	for {
		dialled := node.dialledPublicPeers()
		if len(dialled) == 1 && dialled[0] == uriC {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("back to one peer, got %v", dialled)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// A node that is not a phone's (a computer) checks nothing.
func TestAComputerChecksNoLinks(t *testing.T) {
	node := testNode(t, nil)
	if got := node.checkLinks(); got != (linkCheck{}) {
		t.Fatalf("a computer's check: %+v", got)
	}
}
