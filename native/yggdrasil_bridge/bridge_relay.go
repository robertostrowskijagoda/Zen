package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

// Where the relay listens. On computers it is loopback only: nothing off
// this device needs it. Phones keep every IPv4 interface because the Dart
// side also offers WebRTC this device's own LAN address as a relay candidate
// (_ensureRelayCandidate in call_media_session.dart /
// group_call_media_webrtc.dart): Android's WebRTC binds its sockets to the
// active network and may not reach the loopback adapter from there. Either
// way packets are only taken from addresses of this very device (see
// isLocalSourceLocked), and a socket is admitted only with the call's ICE
// credentials (relay_admission.go), never because it spoke first.
func relayBindHost() string {
	if isPhoneOS() {
		return "0.0.0.0"
	}
	return "127.0.0.1"
}

// Remembered verdicts per relay (cleared with it at the end of the call).
const maxRelaySourceVerdicts = 64

// Local sockets admitted per relay (audio and video may use separate ones).
const maxRelayLocalTargets = 8

func cloneUDPAddr(address *net.UDPAddr) *net.UDPAddr {
	if address == nil {
		return nil
	}
	return &net.UDPAddr{
		IP:   append(net.IP(nil), address.IP...),
		Port: address.Port,
		Zone: address.Zone,
	}
}

// admitLocalDatagram decides about a datagram that arrived on the relay
// port from a local socket. Media may come from several local UDP ports
// (separate audio and video sockets), so every admitted socket is
// remembered; a new one is admitted only when its datagram carries the
// call's ICE credentials (relayAdmission.judgeFirstDatagram).
func (relay *relayState) admitLocalDatagram(source *net.UDPAddr, payload []byte) relayAdmissionVerdict {
	if source == nil || source.IP == nil {
		return relayDrop
	}
	relay.mu.Lock()
	defer relay.mu.Unlock()
	if !relay.isLocalSourceLocked(source.IP) {
		return relayDrop
	}
	if relay.localTargets == nil {
		relay.localTargets = make(map[string]*net.UDPAddr)
	}
	key := source.String()
	if _, admitted := relay.localTargets[key]; admitted {
		relay.activeTarget = cloneUDPAddr(source)
		return relayAdmit
	}
	verdict := relay.admission.judgeFirstDatagram(payload)
	if verdict != relayAdmit {
		return verdict
	}
	if len(relay.localTargets) >= maxRelayLocalTargets {
		return relayDrop
	}
	relay.localTargets[key] = cloneUDPAddr(source)
	relay.activeTarget = cloneUDPAddr(source)
	return relayAdmit
}

// isLocalSourceLocked reports whether ip belongs to this device: loopback,
// or one of its own interface addresses. Any other host on the LAN (a café
// or office network) is refused. The caller holds relay.mu.
func (relay *relayState) isLocalSourceLocked(ip net.IP) bool {
	if ip.IsLoopback() {
		return true
	}
	key := ip.String()
	if verdict, known := relay.sourceVerdicts[key]; known {
		return verdict
	}
	verdict := isOwnHostAddress(ip)
	if relay.sourceVerdicts == nil {
		relay.sourceVerdicts = make(map[string]bool)
	}
	if len(relay.sourceVerdicts) < maxRelaySourceVerdicts {
		relay.sourceVerdicts[key] = verdict
	}
	return verdict
}

// isOwnHostAddress reports whether ip is assigned to this device: a socket
// can only be bound to a local address. Unlike listing interfaces, this also
// works on Android, where apps may not read the interface list.
var isOwnHostAddress = func(ip net.IP) bool {
	if ip == nil || ip.IsUnspecified() || ip.IsMulticast() {
		return false
	}
	network := "udp6"
	if ip.To4() != nil {
		network = "udp4"
	}
	probe, err := net.ListenUDP(network, &net.UDPAddr{IP: ip, Port: 0})
	if err != nil {
		return false
	}
	_ = probe.Close()
	return true
}

func (node *bridgeNode) openRelay(callID string, remoteAddress string) (int, error) {
	remoteIP := net.ParseIP(strings.TrimSpace(remoteAddress))
	if remoteIP == nil {
		return 0, fmt.Errorf("invalid remote yggdrasil address: %s", remoteAddress)
	}

	node.relayMu.Lock()
	defer node.relayMu.Unlock()

	if existingRelay, ok := node.relays[callID]; ok {
		return existingRelay.conn.LocalAddr().(*net.UDPAddr).Port, nil
	}

	listener, err := net.ListenUDP("udp4", &net.UDPAddr{
		IP:   net.ParseIP(relayBindHost()),
		Port: 0,
	})
	if err != nil {
		return 0, err
	}

	relay := &relayState{
		callID:       callID,
		remoteIP:     remoteIP,
		conn:         listener,
		localTargets: make(map[string]*net.UDPAddr),
	}
	node.relays[callID] = relay

	go node.runRelayLoop(relay)
	return listener.LocalAddr().(*net.UDPAddr).Port, nil
}

func (node *bridgeNode) closeRelay(callID string) {
	node.relayMu.Lock()
	relay, ok := node.relays[callID]
	if !ok {
		node.relayMu.Unlock()
		return
	}
	delete(node.relays, callID)
	node.relayMu.Unlock()
	_ = relay.conn.Close()
}

func (node *bridgeNode) closeAllRelays() {
	node.relayMu.Lock()
	callIDs := make([]string, 0, len(node.relays))
	for callID := range node.relays {
		callIDs = append(callIDs, callID)
	}
	node.relayMu.Unlock()

	for _, callID := range callIDs {
		node.closeRelay(callID)
	}
}

func (node *bridgeNode) runRelayLoop(relay *relayState) {
	// A fault in a call's relay ends the call, not the app.
	defer survive("relay " + relay.callID)
	buffer := make([]byte, 64*1024)
	debugf("[ZEN-GO] relay %s: loop started, listening on %s\n", relay.callID, relay.conn.LocalAddr())
	for {
		count, source, err := relay.conn.ReadFromUDP(buffer)
		if err != nil {
			fmt.Printf("[ZEN-GO] relay %s: read error (loop ending): %v\n", relay.callID, err)
			return
		}

		debugf("[ZEN-GO] relay %s: local→ygg %d bytes from %s\n", relay.callID, count, source)
		switch relay.admitLocalDatagram(source, buffer[:count]) {
		case relayDrop:
			// Another host, or a local socket without this call's ICE
			// credentials: never let it take the relay.
			continue
		case relayForwardOnly:
			// An ICE check the relay cannot verify yet: the peer still needs
			// it (it teaches the peer's relay our credentials), but its sender
			// gets nothing back until it proves itself.
			if err := sendRelay(node, relay.remoteIP, relay.callID, buffer[:count]); err != nil {
				debugf("[ZEN-GO] relay %s: unadmitted check not sent: %v\n", relay.callID, err)
			}
			continue
		}
		relay.mu.Lock()
		pendingPackets := relay.pendingPackets
		relay.pendingPackets = nil
		relay.pendingBytes = 0
		var targets []*net.UDPAddr
		for _, target := range relay.localTargets {
			targets = append(targets, cloneUDPAddr(target))
		}
		if len(targets) == 0 && relay.activeTarget != nil {
			targets = append(targets, cloneUDPAddr(relay.activeTarget))
		}
		relay.outboundPackets++
		outboundPacketOrdinal := relay.outboundPackets
		relay.mu.Unlock()

		if len(pendingPackets) > 0 {
			debugf("[ZEN-GO] relay %s: flushing %d pending packets to %d targets\n", relay.callID, len(pendingPackets), len(targets))
			for _, pendingPacket := range pendingPackets {
				for _, target := range targets {
					_, _ = relay.conn.WriteToUDP(pendingPacket, target)
				}
			}
		}

		packet, err := buildRelayPacket(node, relay.remoteIP, relay.callID, buffer[:count])
		if err != nil {
			debugf("[ZEN-GO] relay %s: packet not sealed: %v\n", relay.callID, err)
			continue
		}
		if err := node.writeMesh(packet, true); err != nil {
			fmt.Printf("[ZEN-GO] relay %s: send to ygg failed: %v\n", relay.callID, err)
		}
		if outboundPacketOrdinal <= 2 {
			// The first packets again, while the mesh path warms up: the
			// same sealed bytes, so a copy that arrives twice is dropped by
			// the receiver's replay window.
			callID := relay.callID
			go func() {
				defer survive("relay " + callID + " warm resend")
				for _, delay := range []time.Duration{
					25 * time.Millisecond,
					75 * time.Millisecond,
				} {
					time.Sleep(delay)
					if err := node.writeMesh(packet, true); err != nil {
						debugf("[ZEN-GO] relay %s: warm resend failed: %v\n", callID, err)
					}
				}
			}()
		}
	}
}

// sendRelay seals payload (a datagram of the local WebRTC) for the call's
// relay at remoteIP and sends it over the mesh.
func sendRelay(node *bridgeNode, remoteIP net.IP, callID string, payload []byte) error {
	packet, err := buildRelayPacket(node, remoteIP, callID, payload)
	if err != nil {
		return err
	}
	return node.writeMesh(packet, true)
}

// buildRelayPacket is the mesh packet that carries payload to the call's
// relay at remoteIP: the relay frame, sealed by the post-quantum session
// with that node (pq_session.go, a media frame: ChaCha20-Poly1305 with a
// 256-bit key from the hybrid KEM, one AEAD per packet, nothing buffered).
// Without a session yet the packet is dropped, never sent in clear; WebRTC
// repeats what matters (ICE checks, DTLS) and the session is there after
// one round trip.
func buildRelayPacket(node *bridgeNode, remoteIP net.IP, callID string, payload []byte) ([]byte, error) {
	if node.core == nil {
		return nil, errors.New("the node has no core")
	}
	localAddress := net.ParseIP(node.core.Address().String())
	if localAddress == nil {
		return nil, errors.New("could not resolve local yggdrasil address")
	}
	frame, err := buildRelayFrame(callID, payload)
	if err != nil {
		return nil, err
	}
	sealed, err := node.sealRelayFrame(remoteIP, frame)
	if err != nil {
		return nil, err
	}
	return buildYggPacket(localAddress, remoteIP, yggRelayPort, sealed)
}

func buildRelayFrame(callID string, payload []byte) ([]byte, error) {
	if len(callID) == 0 || len(callID) > 255 {
		return nil, errors.New("call id length must be between 1 and 255 bytes")
	}

	frame := make([]byte, 1+len(callID)+len(payload))
	frame[0] = byte(len(callID))
	copy(frame[1:], []byte(callID))
	copy(frame[1+len(callID):], payload)
	return frame, nil
}

func parseRelayFrame(payload []byte) (string, []byte, bool) {
	if len(payload) < 1 {
		return "", nil, false
	}

	callIDLength := int(payload[0])
	if callIDLength == 0 || len(payload) < 1+callIDLength {
		return "", nil, false
	}

	callID := string(payload[1 : 1+callIDLength])
	framePayload := append([]byte(nil), payload[1+callIDLength:]...)
	return callID, framePayload, true
}

func (node *bridgeNode) handleRelayPacket(source net.IP, payload []byte) {
	// Only media sealed by a session of the sender is taken.
	frame, ok := node.openRelayFrame(source, payload)
	if !ok {
		return
	}
	callID, framePayload, ok := parseRelayFrame(frame)
	if !ok {
		return
	}

	node.relayMu.Lock()
	relay, ok := node.relays[callID]
	node.relayMu.Unlock()
	if !ok || !relay.remoteIP.Equal(source) {
		if !ok {
			debugf("[ZEN-GO] relay: no relay for callID=%s\n", callID)
		} else {
			debugf("[ZEN-GO] relay: source %s != expected %s for callID=%s\n", source, relay.remoteIP, callID)
		}
		return
	}

	// The peer's ICE checks name the credentials our local WebRTC must show.
	relay.admission.learnFromPeer(framePayload)

	relay.mu.Lock()
	var targets []*net.UDPAddr
	for _, target := range relay.localTargets {
		targets = append(targets, cloneUDPAddr(target))
	}
	if len(targets) == 0 && relay.activeTarget != nil {
		targets = append(targets, cloneUDPAddr(relay.activeTarget))
	}
	if len(targets) == 0 {
		queued := len(relay.pendingPackets)
		if queued < maxRelayBacklog && relay.pendingBytes+len(framePayload) <= maxRelayBacklogBytes {
			relay.pendingPackets = append(relay.pendingPackets, framePayload)
			relay.pendingBytes += len(framePayload)
		}
		relay.mu.Unlock()
		debugf("[ZEN-GO] relay %s: ygg→local %d bytes QUEUED (no targets yet, queue=%d)\n", callID, len(framePayload), queued+1)
		return
	}
	relay.mu.Unlock()

	debugf("[ZEN-GO] relay %s: ygg→local %d bytes to %d targets\n", callID, len(framePayload), len(targets))
	for _, target := range targets {
		_, _ = relay.conn.WriteToUDP(framePayload, target)
	}
}
