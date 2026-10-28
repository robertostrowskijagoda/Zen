package main

import (
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

func testNode(t *testing.T, peers []string) *bridgeNode {
	t.Helper()
	cfg := config.GenerateConfig()
	yggCore, err := core.New(cfg.Certificate, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(yggCore.Stop)
	cfg.Peers = append([]string(nil), peers...)
	return &bridgeNode{
		core:        yggCore,
		config:      cfg,
		logger:      log.New(io.Discard, "", 0),
		publicPeers: publicPeersOf(cfg.Peers),
	}
}

func TestPhoneNodeDialsOnlyItsShareOfANewList(t *testing.T) {
	keeper := newPhonePeerKeeper(testPool(8), 3)
	local := "tls://127.0.0.1:9001"
	node := testNode(t, append([]string{local}, keeper.dialled...))
	node.phonePeers = keeper

	mine := testPool(12)[4:]
	withUserPublicPeers(t, mine)
	node.applyPublicPeers()
	got := node.dialledPublicPeers()
	if strings.Join(got, " ") != strings.Join(mine[:3], " ") {
		t.Fatalf("a phone dials 3 of the new list, got %v", got)
	}
	if peers := node.configSnapshot().Peers; peers[0] != local {
		t.Fatalf("other peers stay: %v", peers)
	}
}

func TestComputerOnBatteryIsNoBridgeAndDialsAFew(t *testing.T) {
	pool := testPool(20)
	node := testNode(t, pool)
	node.power = newDesktopPowerSaver(false, pool)

	node.setDesktopOnBattery(true)
	if got := node.dialledPublicPeers(); len(got) != desktopBatteryPeerCount {
		t.Fatalf("on battery: %d public peers, want %d", len(got), desktopBatteryPeerCount)
	}
	if !node.onDesktopBattery() {
		t.Fatal("the battery mode shows")
	}
	node.setDesktopOnBattery(false)
	if got := node.dialledPublicPeers(); len(got) != len(pool) {
		t.Fatalf("plugged in: all %d peers again, got %d", len(pool), len(got))
	}
}

func TestComputerOnBatteryKeepsOneFriendsBridge(t *testing.T) {
	pool := testPool(8)
	node := testNode(t, pool)
	node.power = newDesktopPowerSaver(false, pool)
	bridges := []string{
		"tls://[200::b1]:443",
		"tls://[200::b2]:443",
		"tls://[200::b3]:443",
	}
	node.configMu.Lock()
	node.config.Peers = append(node.config.Peers, bridges...)
	node.configMu.Unlock()

	node.setDesktopOnBattery(true)
	if got := node.dialledBridges(); len(got) != desktopBatteryBridgeCount || got[0] != bridges[0] {
		t.Fatalf("on battery: the first bridge only, got %v", got)
	}
	// A bridge chosen meanwhile waits too.
	if !node.setBridgeAside("tls://[200::b4]:443") {
		t.Fatal("a new bridge on battery is set aside")
	}
	// Dropped by the app meanwhile: forgotten, not dialled later.
	if !node.forgetBridgeAside(bridges[2]) {
		t.Fatal("a set-aside bridge is forgotten")
	}

	node.setDesktopOnBattery(false)
	got := node.dialledBridges()
	want := []string{bridges[0], bridges[1], "tls://[200::b4]:443"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Fatalf("plugged in: %v, want %v", got, want)
	}
	if node.setBridgeAside("tls://[200::b5]:443") {
		t.Fatal("plugged in: nothing is set aside")
	}
}

func TestSplitBridges(t *testing.T) {
	kept, aside := splitBridges([]string{"a", "b", "c"}, 1)
	if strings.Join(kept, ",") != "a" || strings.Join(aside, ",") != "b,c" {
		t.Fatalf("got %v / %v", kept, aside)
	}
	kept, aside = splitBridges([]string{"a"}, 1)
	if len(kept) != 1 || aside != nil {
		t.Fatalf("got %v / %v", kept, aside)
	}
}

// deadPeerURI is a peer nobody answers at (a port just closed).
func deadPeerURI(t *testing.T) string {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.Addr().String()
	_ = listener.Close()
	return "tcp://" + addr
}

// A phone node that only receives dials two public peers. One goes away
// (its node stops): the core's log line tells the keeper, which dials
// stand-ins at once, past a dead candidate in line, and two links are up
// again within seconds, back to two peers.
func TestAPhoneNodeReplacesAPeerThatWentAwayWithinSeconds(t *testing.T) {
	coreA, uriA := listeningCore(t)
	coreB, uriB := listeningCore(t)
	coreC, uriC := listeningCore(t)
	keeper := newPhonePeerKeeper([]string{uriA, uriB, deadPeerURI(t), uriC}, phoneExtraAccountPeerCount)
	cfg := config.GenerateConfig()
	yggCore, err := core.New(cfg.Certificate, withPeerEvents(log.New(io.Discard, "", 0), keeper))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(yggCore.Stop)
	node := &bridgeNode{
		core:        yggCore,
		config:      cfg,
		logger:      log.New(io.Discard, "", 0),
		publicPeers: map[string]bool{},
		phonePeers:  keeper,
	}
	node.swapPublicPeers(nil, keeper.dialled)
	waitForPeer(t, yggCore, coreA.PublicKey(), true)
	waitForPeer(t, yggCore, coreB.PublicKey(), true)
	go node.watchPhonePeers()
	t.Cleanup(keeper.stopWatch)

	started := time.Now()
	coreA.Stop()
	waitForPeer(t, yggCore, coreC.PublicKey(), true)
	took := time.Since(started)
	t.Logf("two links up again %v after a peer went away", took)
	if took > 15*time.Second {
		t.Fatalf("two links up again only after %v", took)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		dialled := node.dialledPublicPeers()
		if len(dialled) == 2 && dialled[0] == uriB && dialled[1] == uriC {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("back to two peers, got %v", dialled)
		}
		time.Sleep(50 * time.Millisecond)
	}
}
