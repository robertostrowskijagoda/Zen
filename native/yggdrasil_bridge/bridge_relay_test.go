package main

import (
	"net"
	"testing"
)

func TestOpenRelayBindHost(t *testing.T) {
	node := &bridgeNode{
		relays: make(map[string]*relayState),
	}

	const callID = "call-bind-host"
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
	if isPhoneOS() {
		if !localAddr.IP.IsUnspecified() {
			t.Fatalf("expected the phone relay on 0.0.0.0, got %s", localAddr.IP)
		}
	} else if !localAddr.IP.IsLoopback() {
		t.Fatalf("expected the desktop relay on loopback only, got %s", localAddr.IP)
	}
}

// admittedRelay is a relay that has learned the peer's check "mine:peer",
// so local checks must carry "peer:mine".
func admittedRelay(callID string) *relayState {
	relay := &relayState{callID: callID, localTargets: make(map[string]*net.UDPAddr)}
	relay.admission.learnFromPeer(stunBindingRequestFor("mine:peer"))
	return relay
}

func TestRelayAcceptsMultipleLocalMediaSources(t *testing.T) {
	relay := admittedRelay("call-pin")
	check := stunBindingRequestFor("peer:mine")

	first := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 51000}
	second := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 52000}

	if relay.admitLocalDatagram(first, check) != relayAdmit {
		t.Fatal("expected the first local source to be admitted")
	}
	if relay.admitLocalDatagram(second, check) != relayAdmit {
		t.Fatal("expected the second local source (e.g. video) to also be admitted")
	}

	relay.outboundPackets = 10

	// Once admitted, any datagram (DTLS, RTP) from both sockets passes.
	media := []byte{0x80, 0x6f, 0x00, 0x01}
	if relay.admitLocalDatagram(first, media) != relayAdmit {
		t.Fatal("expected the audio source to remain admitted")
	}
	if relay.admitLocalDatagram(second, media) != relayAdmit {
		t.Fatal("expected the video source to remain admitted")
	}
	if len(relay.localTargets) != 2 {
		t.Fatalf("expected 2 local targets, got %d", len(relay.localTargets))
	}
}

func TestRelayRefusesALocalAppWithoutTheCallsCredentials(t *testing.T) {
	relay := admittedRelay("call-hijack")
	intruder := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 40000}

	// Speaking first no longer takes the relay.
	if verdict := relay.admitLocalDatagram(intruder, []byte{0x80, 0x00, 0x00, 0x01}); verdict != relayDrop {
		t.Fatalf("media from an unadmitted socket must be dropped, got %v", verdict)
	}
	if verdict := relay.admitLocalDatagram(intruder, stunBindingRequestFor("guess:wrong")); verdict != relayForwardOnly {
		t.Fatalf("a check with other credentials is only passed on, got %v", verdict)
	}
	if len(relay.localTargets) != 0 || relay.activeTarget != nil {
		t.Fatal("the intruder must not become a target of the call's media")
	}

	webrtc := &net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 40001}
	if relay.admitLocalDatagram(webrtc, stunBindingRequestFor("peer:mine")) != relayAdmit {
		t.Fatal("the call's own WebRTC socket must be admitted")
	}
	if relay.admitLocalDatagram(intruder, []byte{0x80, 0x00, 0x00, 0x02}) != relayDrop {
		t.Fatal("the intruder must stay refused after the call is up")
	}
}

func TestRelayRejectsNonLocalSources(t *testing.T) {
	relay := admittedRelay("call-nonlocal")
	remote := &net.UDPAddr{IP: net.ParseIP("8.8.8.8"), Port: 51000}
	if relay.admitLocalDatagram(remote, stunBindingRequestFor("peer:mine")) != relayDrop {
		t.Fatal("expected a public source address to be rejected")
	}
}

func TestRelayAcceptsOnlyThisDevicesOwnAddresses(t *testing.T) {
	own := net.ParseIP("192.168.1.20")
	previous := isOwnHostAddress
	isOwnHostAddress = func(ip net.IP) bool { return ip.Equal(own) }
	defer func() { isOwnHostAddress = previous }()

	relay := admittedRelay("call-lan")
	check := stunBindingRequestFor("peer:mine")
	if relay.admitLocalDatagram(&net.UDPAddr{IP: own, Port: 50000}, check) != relayAdmit {
		t.Fatal("this device's LAN address (WebRTC host candidate) must be accepted")
	}
	if relay.admitLocalDatagram(&net.UDPAddr{IP: net.ParseIP("192.168.1.30"), Port: 50000}, check) != relayDrop {
		t.Fatal("another machine on the LAN must be rejected")
	}
	if relay.admitLocalDatagram(&net.UDPAddr{IP: net.ParseIP("10.0.0.7"), Port: 50000}, check) != relayDrop {
		t.Fatal("another private address must be rejected")
	}
	if relay.admitLocalDatagram(&net.UDPAddr{IP: net.ParseIP("127.0.0.1"), Port: 50001}, check) != relayAdmit {
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

func TestRelayBacklogIsBoundedInBytes(t *testing.T) {
	remote := net.ParseIP("200:1111::1")
	node := &bridgeNode{relays: make(map[string]*relayState), pqPlain: true}
	relay := &relayState{callID: "call-backlog", remoteIP: remote, localTargets: make(map[string]*net.UDPAddr)}
	node.relays[relay.callID] = relay
	datagram := make([]byte, 60*1024)
	for range 20 {
		frame, err := buildRelayFrame(relay.callID, datagram)
		if err != nil {
			t.Fatal(err)
		}
		node.handleRelayPacket(remote, frame)
	}
	if relay.pendingBytes > maxRelayBacklogBytes {
		t.Fatalf("the relay holds %d bytes, over %d", relay.pendingBytes, maxRelayBacklogBytes)
	}
	if want := maxRelayBacklogBytes / len(datagram); len(relay.pendingPackets) != want {
		t.Fatalf("held %d datagrams, want %d", len(relay.pendingPackets), want)
	}
	held := 0
	for _, packet := range relay.pendingPackets {
		held += len(packet)
	}
	if held != relay.pendingBytes {
		t.Fatalf("pendingBytes %d, held %d", relay.pendingBytes, held)
	}
}
