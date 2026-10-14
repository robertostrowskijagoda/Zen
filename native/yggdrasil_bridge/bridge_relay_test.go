package main

import (
	"net"
	"testing"
)

func TestOpenRelayBindsToUnspecified(t *testing.T) {
	node := &bridgeNode{
		relays: make(map[string]*relayState),
	}

	const callID = "call-unspecified-bind"
	port, err := node.openRelay(callID, "200:1111::1")
	if err != nil {
		t.Fatalf("openRelay failed: %v", err)
	}
	if port <= 0 {
		t.Fatalf("expected a positive relay port, got %d", port)
	}
	defer node.closeRelay(callID)

	node.relayMu.Lock()
	relay := node.relays[callID]
	node.relayMu.Unlock()
	if relay == nil {
		t.Fatal("expected relay state to be stored")
	}

	localAddr, ok := relay.conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		t.Fatalf("expected UDP local addr, got %T", relay.conn.LocalAddr())
	}
	if !localAddr.IP.IsUnspecified() {
		t.Fatalf("expected relay to bind to 0.0.0.0, got %s", localAddr.IP)
	}
}

func TestRelayAcceptsMultipleLocalMediaSources(t *testing.T) {
	relay := &relayState{callID: "call-pin", localTargets: make(map[string]*net.UDPAddr)}

	first := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 51000}
	second := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 52000}

	if !relay.acceptLocalSource(first) {
		t.Fatal("expected the first local source to be accepted")
	}
	if !relay.acceptLocalSource(second) {
		t.Fatal("expected the second local source (e.g. video) to also be accepted")
	}

	relay.outboundPackets = 10

	// Even when media flows, subsequent packets from both audio (first) and video (second) must be accepted.
	if !relay.acceptLocalSource(first) {
		t.Fatal("expected the audio source to remain accepted")
	}
	if !relay.acceptLocalSource(second) {
		t.Fatal("expected the video source to remain accepted")
	}
	if len(relay.localTargets) != 2 {
		t.Fatalf("expected 2 local targets, got %d", len(relay.localTargets))
	}
}

func TestRelayRejectsNonLocalSources(t *testing.T) {
	relay := &relayState{callID: "call-nonlocal"}
	remote := &net.UDPAddr{IP: net.ParseIP("8.8.8.8"), Port: 51000}
	if relay.acceptLocalSource(remote) {
		t.Fatal("expected a public source address to be rejected")
	}
}

func TestRelayAcceptsOnlyThisDevicesOwnAddresses(t *testing.T) {
	own := net.ParseIP("192.168.1.20")
	previous := isOwnHostAddress
	isOwnHostAddress = func(ip net.IP) bool { return ip.Equal(own) }
	defer func() { isOwnHostAddress = previous }()

	relay := &relayState{callID: "call-lan"}
	if !relay.acceptLocalSource(&net.UDPAddr{IP: own, Port: 50000}) {
		t.Fatal("this device's LAN address (WebRTC host candidate) must be accepted")
	}
	if relay.acceptLocalSource(&net.UDPAddr{IP: net.ParseIP("192.168.1.30"), Port: 50000}) {
		t.Fatal("another machine on the LAN must be rejected")
	}
	if relay.acceptLocalSource(&net.UDPAddr{IP: net.ParseIP("10.0.0.7"), Port: 50000}) {
		t.Fatal("another private address must be rejected")
	}
	if !relay.acceptLocalSource(&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 50001}) {
		t.Fatal("loopback must be accepted")
	}
}

func TestIsOwnHostAddress(t *testing.T) {
	if !isOwnHostAddress(net.ParseIP("127.0.0.1")) {
		t.Fatal("loopback belongs to this device")
	}
	if isOwnHostAddress(net.ParseIP("192.0.2.123")) {
		t.Fatal("a documentation address is not assigned to this device")
	}
}
