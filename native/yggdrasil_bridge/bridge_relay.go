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

// The relay listens on every IPv4 interface because the Dart side offers
// WebRTC two relay candidates: 127.0.0.1 and this device's own LAN address
// (_ensureRelayCandidate in call_media_session.dart / group_call_media_webrtc.dart),
// the latter for WebRTC stacks that ignore the loopback adapter. Packets are
// only accepted from addresses of this very device (see acceptLocalSource),
// never from other machines on the LAN.
const localRelayBindHost = "0.0.0.0"

// Remembered verdicts per relay (cleared with it at the end of the call).
const maxRelaySourceVerdicts = 64

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

// acceptLocalSource records local WebRTC endpoints sending media through this
// relay. Media may arrive from multiple local UDP ports (e.g. separate audio
// and video RTP sockets), so all local sources are remembered and accepted.
func (relay *relayState) acceptLocalSource(source *net.UDPAddr) bool {
	if source == nil || source.IP == nil {
		return false
	}
	relay.mu.Lock()
	defer relay.mu.Unlock()
	if !relay.isLocalSourceLocked(source.IP) {
		return false
	}
	if relay.localTargets == nil {
		relay.localTargets = make(map[string]*net.UDPAddr)
	}
	key := source.String()
	if _, exists := relay.localTargets[key]; !exists {
		if len(relay.localTargets) < 8 {
			relay.localTargets[key] = cloneUDPAddr(source)
		}
	}
	relay.activeTarget = cloneUDPAddr(source)
	return true
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
		IP:   net.ParseIP(localRelayBindHost),
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
	buffer := make([]byte, 64*1024)
	debugf("[ZEN-GO] relay %s: loop started, listening on %s\n", relay.callID, relay.conn.LocalAddr())
	for {
		count, source, err := relay.conn.ReadFromUDP(buffer)
		if err != nil {
			fmt.Printf("[ZEN-GO] relay %s: read error (loop ending): %v\n", relay.callID, err)
			return
		}

		debugf("[ZEN-GO] relay %s: local→ygg %d bytes from %s\n", relay.callID, count, source)
		if !relay.acceptLocalSource(source) {
			// The relay is already pinned to the local WebRTC endpoint that
			// started sending media. Ignore any other local process trying to
			// hijack the relay mid-call.
			continue
		}
		relay.mu.Lock()
		pendingPackets := relay.pendingPackets
		relay.pendingPackets = nil
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

		payload := append([]byte(nil), buffer[:count]...)
		if err := sendRelay(node, relay.remoteIP, relay.callID, payload); err != nil {
			fmt.Printf("[ZEN-GO] relay %s: send to ygg failed: %v\n", relay.callID, err)
		}
		if outboundPacketOrdinal <= 2 {
			payloadCopy := append([]byte(nil), payload...)
			remoteIPCopy := append(net.IP(nil), relay.remoteIP...)
			callID := relay.callID
			go func() {
				for _, delay := range []time.Duration{
					25 * time.Millisecond,
					75 * time.Millisecond,
				} {
					time.Sleep(delay)
					if err := sendRelay(node, remoteIPCopy, callID, payloadCopy); err != nil {
						debugf("[ZEN-GO] relay %s: warm resend failed: %v\n", callID, err)
					}
				}
			}()
		}
	}
}

func sendRelay(node *bridgeNode, remoteIP net.IP, callID string, payload []byte) error {
	localAddress := net.ParseIP(node.core.Address().String())
	if localAddress == nil {
		return errors.New("could not resolve local yggdrasil address")
	}

	frame, err := buildRelayFrame(callID, payload)
	if err != nil {
		return err
	}

	packet, err := buildYggPacket(localAddress, remoteIP, yggRelayPort, frame)
	if err != nil {
		return err
	}

	_, err = node.iprwc.Write(packet)
	return err
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
	callID, framePayload, ok := parseRelayFrame(payload)
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
		if queued < maxRelayBacklog {
			relay.pendingPackets = append(relay.pendingPackets, append([]byte(nil), framePayload...))
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
