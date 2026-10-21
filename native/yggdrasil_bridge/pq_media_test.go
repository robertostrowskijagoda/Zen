package main

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"testing"
	"time"
)

// pqTestPair is A and B with signal sessions both ways, acknowledged.
func pqTestPair(t *testing.T) (*pqTestNet, *pqEndpoint, net.IP, *pqEndpoint, net.IP) {
	t.Helper()
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	mustSend(t, a, bIP, "hej")
	network.pump()
	mustSend(t, b, aIP, "cześć")
	network.pump()
	network.take(aIP)
	network.take(bIP)
	return network, a, aIP, b, bIP
}

func TestPQMediaIsNeverHeldNorSentInClear(t *testing.T) {
	network := newPQTestNet(t)
	a, _ := network.add(1)
	_, bIP := network.add(2)
	frame, _ := buildRelayFrame("call-1", []byte("rtp"))

	sealed, err := a.sealMedia(bIP, frame)
	if !errors.Is(err, errPQNotReady) || sealed != nil {
		t.Fatalf("media without a session: %v %x", err, sealed)
	}
	if len(network.queue) != 1 || network.queue[0].wire[len(pqMagic)] != pqKindKeys {
		t.Fatal("media without a session must ask for the keys, and only that")
	}
	if peer := a.peers[bIP.String()]; len(peer.pending) != 0 {
		t.Fatal("media must not be held")
	}
	network.pump()
	sealed, err = a.sealMedia(bIP, frame)
	if err != nil {
		t.Fatalf("after one round trip media goes: %v", err)
	}
	if bytes.Contains(sealed, []byte("call-1")) || bytes.Contains(sealed, []byte("rtp")) {
		t.Fatal("the relay frame (call id and media) must be sealed")
	}
}

func TestPQMediaRoundTripOverheadAndReplay(t *testing.T) {
	network, a, aIP, b, bIP := pqTestPair(t)
	frame, _ := buildRelayFrame("call-1", bytes.Repeat([]byte{0x80}, 1200))

	var sealed [][]byte
	for range 4 {
		packet, err := a.sealMedia(bIP, frame)
		if err != nil {
			t.Fatal(err)
		}
		if len(packet) != len(frame)+pqMediaOverhead {
			t.Fatalf("a media packet grew by %d bytes, want %d", len(packet)-len(frame), pqMediaOverhead)
		}
		sealed = append(sealed, packet)
	}
	// Out of order: every packet opens on its own (no waiting for a gap).
	for _, index := range []int{2, 0, 3, 1} {
		plain, ok := b.receiveMedia(aIP, sealed[index])
		if !ok || !bytes.Equal(plain, frame) {
			t.Fatalf("packet %d did not open", index)
		}
	}
	for index, packet := range sealed {
		if _, ok := b.receiveMedia(aIP, packet); ok {
			t.Fatalf("a repeated packet %d was taken", index)
		}
	}
	// Media is not a signal, nor the other way round.
	fresh, _ := a.sealMedia(bIP, frame)
	if _, ok := b.receive(aIP, fresh); ok {
		t.Fatal("a media frame was taken as a signal")
	}
	relabelled := bytes.Clone(fresh)
	relabelled[len(pqMagic)] = pqKindData
	if _, ok := b.receive(aIP, relabelled); ok {
		t.Fatal("a media frame relabelled as a signal must not open")
	}
	mustSend(t, a, bIP, "sygnał")
	signal := network.queue[len(network.queue)-1].wire
	if _, ok := b.receiveMedia(aIP, signal); ok {
		t.Fatal("a signal was taken as media")
	}
	// Another sender address opens nothing.
	_, cIP := pqTestNode(t, 3)
	if _, ok := b.receiveMedia(cIP, fresh); ok {
		t.Fatal("media of A's session came through from C")
	}
	// Each counter is its own: signals keep their order after media.
	if a.peers[bIP.String()].send.mediaNext != 5 {
		t.Fatalf("media counter %d", a.peers[bIP.String()].send.mediaNext)
	}
}

func TestPQMediaCanOpenASessionAndIsAcknowledged(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	// B wrote to A first: A holds B's record and a challenge from B, but
	// never sent B anything.
	mustSend(t, b, aIP, "dzwonię")
	network.pump()
	network.take(aIP)
	if a.peers[bIP.String()].send != nil {
		t.Fatal("A has no session to B yet")
	}
	frame, _ := buildRelayFrame("call-2", []byte{0x80, 0x60, 0, 1})
	first, err := a.sealMedia(bIP, frame)
	if err != nil {
		t.Fatal(err)
	}
	if first[len(pqMagic)+1]&pqFlagCiphertext == 0 || len(first) != len(frame)+pqMediaOverhead+pqOpeningSize {
		t.Fatal("the first media of a session carries its opening")
	}
	if plain, ok := b.receiveMedia(aIP, first); !ok || !bytes.Equal(plain, frame) {
		t.Fatal("media must be able to open a session")
	}
	network.pump() // B's acknowledgement goes over the signal port
	next, _ := a.sealMedia(bIP, frame)
	if len(next) != len(frame)+pqMediaOverhead {
		t.Fatal("after the acknowledgement media goes without the opening")
	}
	if _, ok := b.receiveMedia(aIP, next); !ok {
		t.Fatal("acknowledged media must open")
	}
}

func TestPQMediaWindowTakesReorderingAcrossCalls(t *testing.T) {
	var window pqMediaReplay
	window.mark(pqMediaReplayWindow + 10)
	if !window.fresh(11) || window.fresh(10) {
		t.Fatal("the media window spans pqMediaReplayWindow counters")
	}
	window.mark(11)
	if window.fresh(11) {
		t.Fatal("a counter is taken once")
	}
}

// pqBridgeNode is a bridge node whose session layer is endpoint (no mesh).
func pqBridgeNode(endpoint *pqEndpoint) *bridgeNode {
	node := &bridgeNode{relays: make(map[string]*relayState), pq: endpoint}
	node.pqOnce.Do(func() {})
	return node
}

func TestRelayTakesOnlyMediaSealedByTheCallPeer(t *testing.T) {
	_, a, aIP, b, _ := pqTestPair(t)
	receiverNode := pqBridgeNode(b)
	senderNode := pqBridgeNode(a)

	relayConn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer relayConn.Close()
	webrtc, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer webrtc.Close()
	target := webrtc.LocalAddr().(*net.UDPAddr)
	receiverNode.relays["call-3"] = &relayState{
		callID:       "call-3",
		remoteIP:     aIP,
		conn:         relayConn,
		localTargets: map[string]*net.UDPAddr{target.String(): target},
	}
	read := func() ([]byte, bool) {
		buffer := make([]byte, 2048)
		_ = webrtc.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
		count, _, err := webrtc.ReadFromUDP(buffer)
		if err != nil {
			return nil, false
		}
		return buffer[:count], true
	}

	rtp := []byte{0x80, 0x6f, 0x12, 0x34, 'm', 'e', 'd', 'i', 'a'}
	frame, _ := buildRelayFrame("call-3", rtp)
	sealed, err := senderNode.sealRelayFrame(receiverNode.pq.local, frame)
	if err != nil {
		t.Fatal(err)
	}
	receiverNode.handleRelayPacket(aIP, sealed)
	if got, ok := read(); !ok || !bytes.Equal(got, rtp) {
		t.Fatalf("WebRTC got %x (%v)", got, ok)
	}
	// The same packet again, an unsealed frame, and media of another node
	// never reach WebRTC.
	receiverNode.handleRelayPacket(aIP, sealed)
	receiverNode.handleRelayPacket(aIP, frame)
	_, cIP := pqTestNode(t, 3)
	receiverNode.handleRelayPacket(cIP, sealed)
	if got, ok := read(); ok {
		t.Fatalf("WebRTC got %x", got)
	}
}

// The cost of the media layer per packet (seal on one side, open on the
// other; no KEM): an Opus audio packet and a full video packet. Nothing is
// buffered, so this is the whole latency it adds.
func BenchmarkPQMediaPacket(b *testing.B) {
	for _, size := range []int{160, 1200} {
		b.Run(fmt.Sprintf("%dB", size), func(b *testing.B) {
			t := &testing.T{}
			_, sender, senderIP, receiver, receiverIP := pqTestPair(t)
			frame, _ := buildRelayFrame("bench-call-0123456789", bytes.Repeat([]byte{0x80}, size))
			b.SetBytes(int64(len(frame)))
			b.ReportMetric(float64(pqMediaOverhead), "overhead-B/packet")
			b.ResetTimer()
			for range b.N {
				packet, err := sender.sealMedia(receiverIP, frame)
				if err != nil {
					b.Fatal(err)
				}
				if _, ok := receiver.receiveMedia(senderIP, packet); !ok {
					b.Fatal("packet did not open")
				}
			}
		})
	}
}

// Calls (one relay goroutine each) and signals seal with one session at
// the same time; every packet opens once.
func TestPQMediaSealsConcurrentlyWithSignals(t *testing.T) {
	network, a, aIP, b, bIP := pqTestPair(t)
	const perCall = 300
	frame, _ := buildRelayFrame("call-4", bytes.Repeat([]byte{0x80}, 600))
	packets := make(chan []byte, 3*perCall)
	done := make(chan struct{})
	for range 3 {
		go func() {
			defer func() { done <- struct{}{} }()
			for range perCall {
				packet, err := a.sealMedia(bIP, frame)
				if err != nil {
					t.Error(err)
					return
				}
				packets <- packet
			}
		}()
	}
	for index := range 50 {
		if err := a.send(bIP, []byte(fmt.Sprintf("s%d", index))); err != nil {
			t.Fatal(err)
		}
	}
	for range 3 {
		<-done
	}
	close(packets)
	opened := 0
	for packet := range packets {
		if _, ok := b.receiveMedia(aIP, packet); ok {
			opened++
		}
	}
	if opened != 3*perCall {
		t.Fatalf("%d of %d media packets opened", opened, 3*perCall)
	}
	network.pump()
	if got := network.take(bIP); len(got) != 50 {
		t.Fatalf("%d signals arrived", len(got))
	}
}
