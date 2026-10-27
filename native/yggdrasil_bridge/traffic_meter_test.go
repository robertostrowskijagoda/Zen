package main

import (
	"testing"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

func TestTransitIsWhatGoesInAndOutBeyondTheNodesOwnPackets(t *testing.T) {
	var own ownTraffic
	var meter peerTrafficMeter
	start := time.Unix(1000, 0)
	peers := []core.PeerInfo{
		{URI: "tls://a:443", Uptime: time.Minute},
		{URI: "tls://b:443", Uptime: time.Minute},
	}
	if _, ended := meter.sample(peers, &own, start); ended {
		t.Fatal("the first sample only starts a window")
	}
	// A minute later: 6 MB came in on a and went out on b (strangers'
	// traffic), and the node itself sent and took 100 packets of 1000 bytes
	// over a.
	for range 100 {
		own.received(yggSignalPort, 1000)
		own.sent(1000, true)
	}
	ownWire := uint64(100 * (1000 + trafficPacketOverhead))
	peers = []core.PeerInfo{
		{URI: "tls://a:443", Uptime: 2 * time.Minute, RXBytes: 6_000_000 + ownWire, TXBytes: ownWire},
		{URI: "tls://b:443", Uptime: 2 * time.Minute, TXBytes: 6_000_000},
	}
	rate, ended := meter.sample(peers, &own, start.Add(time.Minute))
	if !ended {
		t.Fatal("a window of a minute ends")
	}
	upkeep := uint64(2 * trafficLinkUpkeep * 60)
	want := (6_000_000 - upkeep) / 60
	if rate != want {
		t.Fatalf("transit rate %d, want %d", rate, want)
	}
	state := meter.snapshot()
	if state["publicRxBytes"].(uint64) != 6_000_000+ownWire || state["localRxBytes"].(uint64) != 0 {
		t.Fatalf("peering bytes are not added up: %v", state)
	}
}

func TestOwnTrafficAloneIsNoTransit(t *testing.T) {
	var own ownTraffic
	var meter peerTrafficMeter
	start := time.Unix(1000, 0)
	meter.sample(nil, &own, start)
	// A call: 2000 packets of 900 bytes each way over one peering.
	for range 2000 {
		own.received(yggRelayPort, 900)
		own.sent(900, true)
	}
	wire := uint64(2000 * (900 + 120))
	peers := []core.PeerInfo{{URI: "tls://a:443", Uptime: time.Minute, RXBytes: wire, TXBytes: wire}}
	if rate, ended := meter.sample(peers, &own, start.Add(time.Minute)); !ended || rate != 0 {
		t.Fatalf("own traffic counted as transit: %d (window ended %v)", rate, ended)
	}
}

func TestTrafficMeterKeepsBytesOfReconnectedAndLocalLinks(t *testing.T) {
	var own ownTraffic
	var meter peerTrafficMeter
	now := time.Unix(1000, 0)
	meter.sample([]core.PeerInfo{
		{URI: "tls://a:443", Uptime: time.Hour, RXBytes: 500, TXBytes: 400},
		{URI: "tcp://127.0.0.1:4000", Uptime: time.Hour, RXBytes: 70, TXBytes: 80},
	}, &own, now)
	// a reconnected (counters start again), the local link went away.
	meter.sample([]core.PeerInfo{
		{URI: "tls://a:443", Uptime: time.Second, RXBytes: 30, TXBytes: 20},
	}, &own, now.Add(time.Second))
	state := meter.snapshot()
	if state["publicRxBytes"].(uint64) != 530 || state["publicTxBytes"].(uint64) != 420 {
		t.Fatalf("a reconnected peering lost or doubled bytes: %v", state)
	}
	if state["localRxBytes"].(uint64) != 70 || state["localTxBytes"].(uint64) != 80 {
		t.Fatalf("a local link's bytes are kept after it went: %v", state)
	}
	if len(meter.links) != 1 {
		t.Fatalf("gone peerings are forgotten, %d remembered", len(meter.links))
	}
}

func TestShortWindowsGiveNoTransitRate(t *testing.T) {
	var own ownTraffic
	var meter peerTrafficMeter
	now := time.Unix(1000, 0)
	meter.sample(nil, &own, now)
	if _, ended := meter.sample(nil, &own, now.Add(trafficWindow/2)); ended {
		t.Fatal("a window shorter than trafficWindow does not end")
	}
	if _, ended := meter.sample(nil, &own, now.Add(trafficWindow)); !ended {
		t.Fatal("a window of trafficWindow ends")
	}
}

func TestOwnTrafficIsCountedByPort(t *testing.T) {
	var own ownTraffic
	own.received(yggSignalPort, 10)
	own.received(yggRelayPort, 20)
	own.received(7, 30)
	own.sent(40, false)
	own.sent(50, true)
	rx, tx, packetsRx, packetsTx := own.totals()
	if rx != 60 || tx != 90 || packetsRx != 3 || packetsTx != 2 {
		t.Fatalf("totals %d %d %d %d", rx, tx, packetsRx, packetsTx)
	}
	if own.signalRx.Load() != 10 || own.relayRx.Load() != 20 || own.otherRx.Load() != 30 ||
		own.signalTx.Load() != 40 || own.relayTx.Load() != 50 {
		t.Fatal("bytes are counted under the wrong kind")
	}
}

func TestHostTrafficSplitsPublicAndDoorLinks(t *testing.T) {
	state := hostTraffic([]core.PeerInfo{
		{URI: "tls://a:443", RXBytes: 100, TXBytes: 200, RXRate: 1, TXRate: 2},
		{URI: "tcp://127.0.0.1:5000", RXBytes: 10, TXBytes: 20, RXRate: 3, TXRate: 4},
	})
	if state["publicRxBytes"].(uint64) != 100 || state["doorTxBytes"].(uint64) != 20 ||
		state["rxRate"].(uint64) != 4 || state["txRate"].(uint64) != 6 {
		t.Fatalf("door host traffic: %v", state)
	}
}
