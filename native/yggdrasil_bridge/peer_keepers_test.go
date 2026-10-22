package main

import (
	"io"
	"strings"
	"testing"

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
