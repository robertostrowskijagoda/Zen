package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

func startPacketLoop(node *bridgeNode) {
	if !node.packetStarted.CompareAndSwap(false, true) {
		return
	}
	debugf("[ZEN-GO] packet loop started, local=%s\n", node.core.Address().String())

	go func() {
		// Reset on exit so the loop can be restarted by the next
		// sendSignal / pollSignal / startSignaling call.
		defer node.packetStarted.Store(false)

		buffer := make([]byte, 64*1024)
		consecutiveErrors := 0
		var limiter signalRateLimiter
		for {
			count, err := node.iprwc.Read(buffer)
			if err != nil {
				fmt.Printf("[ZEN-GO] packet loop read error: %v\n", err)
				consecutiveErrors++
				// Permanent shutdown — stop the loop.
				if strings.Contains(err.Error(), "closed") ||
					strings.Contains(err.Error(), "use of closed") {
					fmt.Printf("[ZEN-GO] packet loop stopping (closed)\n")
					return
				}
				// Transient error — back off and retry.
				if consecutiveErrors > 50 {
					fmt.Printf("[ZEN-GO] packet loop stopping after %d consecutive errors\n", consecutiveErrors)
					return
				}
				time.Sleep(time.Duration(consecutiveErrors*20) * time.Millisecond)
				continue
			}
			consecutiveErrors = 0

			source, port, payload, ok := parseYggPacket(buffer[:count])
			if !ok {
				continue
			}
			if !isYggNodeAddress(source) {
				// ipv6rwc also delivers packets from any address in the
				// sender's own /64 (300::/8). Zen never sends from those, and
				// accepting them would give one node 2^64 identities.
				continue
			}

			switch port {
			case yggSignalPort:
				network := signalSourceNetOf(source)
				if !limiter.allow(network, time.Now()) {
					// Faster than any Zen peer sends: dropped before any
					// parsing, until the source's budget refills.
					debugf("[ZEN-GO] signal rate limit, dropping from=%s\n", source.String())
					continue
				}
				debugf("[ZEN-GO] recv signal from=%s len=%d\n", source.String(), len(payload))
				message, ok := node.reassembleSignal(source.String(), payload)
				if !ok {
					continue
				}
				debugf("[ZEN-GO] signal reassembled from=%s msgLen=%d\n", source.String(), len(message))
				// Never blocks, so relay (call audio/video) processing is not
				// held up; over budget, older signals of the heaviest source
				// make room (signal_inbox.go).
				dropped, queued := node.signalInbox.push(signalMessage{
					From:    source.String(),
					Payload: message,
				}, network)
				if dropped > 0 || !queued {
					fmt.Printf("[ZEN-GO] signal inbox over budget, dropped %d queued signal(s), queued new=%v from=%s len=%d\n",
						dropped, queued, source.String(), len(message))
				}
			case yggRelayPort:
				node.handleRelayPacket(source, payload)
			}
		}
	}()
}

func sendSignal(node *bridgeNode, remoteAddress string, payload string) error {
	localAddress := net.ParseIP(node.core.Address().String())
	if localAddress == nil {
		return errors.New("could not resolve local yggdrasil address")
	}

	destination := net.ParseIP(strings.TrimSpace(remoteAddress))
	if destination == nil {
		return fmt.Errorf("invalid remote yggdrasil address: %s", remoteAddress)
	}
	if len(payload) > maxSignalPayloadBytes {
		// Receivers refuse anything larger (decodeSignalWire); the app
		// never sends it (kRuntimeSignalMaxBytes).
		return fmt.Errorf("signal payload is %d bytes, over the %d byte limit", len(payload), maxSignalPayloadBytes)
	}

	wirePayload := buildSignalWirePayload(payload)

	chunks := splitSignalPayloadRaw(wirePayload)
	packetID := fmt.Sprintf("%d-%d", time.Now().UnixNano(), nextSignalPacket.Add(1))
	debugf("[ZEN-GO] sendSignal to=%s chunks=%d rawLen=%d wireLen=%d\n",
		remoteAddress, len(chunks), len(payload), len(wirePayload))
	for index, chunk := range chunks {
		envelopeBytes, err := json.Marshal(
			signalEnvelope{
				ID:      packetID,
				Index:   index,
				Total:   len(chunks),
				Payload: chunk,
			},
		)
		if err != nil {
			return err
		}

		packet, err := buildYggPacket(localAddress, destination, yggSignalPort, envelopeBytes)
		if err != nil {
			return err
		}

		if _, err := node.iprwc.Write(packet); err != nil {
			fmt.Printf("[ZEN-GO] sendSignal write error: %v\n", err)
			return err
		}
	}

	debugf("[ZEN-GO] sendSignal done\n")
	return nil
}

func buildSignalWirePayload(payload string) string {
	if !shouldCompressSignalPayload(payload) {
		return payload
	}
	compressed := zstdEncoder.EncodeAll([]byte(payload), nil)
	encodedCompressed := zstdMagicPrefix + base64.StdEncoding.EncodeToString(compressed)
	if len(encodedCompressed)+64 >= len(payload) {
		return payload
	}
	return encodedCompressed
}

func shouldCompressSignalPayload(payload string) bool {
	if len(payload) < 8*1024 {
		return false
	}
	return !strings.Contains(payload, "\"chunkData\"") &&
		!strings.Contains(payload, "\"attachmentData\"") &&
		!strings.Contains(payload, "\"_zenEncoding\"") &&
		!strings.Contains(payload, "\"_zenPayload\"")
}

// splitSignalPayloadRaw splits an already-encoded wire string into chunks.
func splitSignalPayloadRaw(encoded string) []string {
	if encoded == "" {
		return []string{""}
	}
	// Base64-encode the wire string for chunk transport.
	b64 := base64.StdEncoding.EncodeToString([]byte(encoded))
	chunks := make([]string, 0, len(b64)/signalChunkSize+1)
	for start := 0; start < len(b64); start += signalChunkSize {
		end := start + signalChunkSize
		if end > len(b64) {
			end = len(b64)
		}
		chunks = append(chunks, b64[start:end])
	}
	return chunks
}

func splitSignalPayload(payload string) []string {
	encoded := base64.StdEncoding.EncodeToString([]byte(payload))
	if encoded == "" {
		return []string{""}
	}

	chunks := make([]string, 0, len(encoded)/signalChunkSize+1)
	for start := 0; start < len(encoded); start += signalChunkSize {
		end := start + signalChunkSize
		if end > len(encoded) {
			end = len(encoded)
		}
		chunks = append(chunks, encoded[start:end])
	}
	return chunks
}

func buildYggPacket(source net.IP, destination net.IP, port uint16, payload []byte) ([]byte, error) {
	sourceBytes := source.To16()
	destinationBytes := destination.To16()
	if sourceBytes == nil || destinationBytes == nil {
		return nil, errors.New("bridge packets require IPv6 source and destination addresses")
	}

	udpLength := 8 + len(payload)
	if udpLength > 0xffff {
		return nil, errors.New("signal payload is too large for a single IPv6 datagram")
	}

	packet := make([]byte, 40+udpLength)
	packet[0] = 0x60
	binary.BigEndian.PutUint16(packet[4:6], uint16(udpLength))
	packet[6] = 17
	packet[7] = 64
	copy(packet[8:24], sourceBytes)
	copy(packet[24:40], destinationBytes)
	binary.BigEndian.PutUint16(packet[40:42], port)
	binary.BigEndian.PutUint16(packet[42:44], port)
	binary.BigEndian.PutUint16(packet[44:46], uint16(udpLength))
	copy(packet[48:], payload)

	checksum := udpChecksum(sourceBytes, destinationBytes, packet[40:48], payload)
	binary.BigEndian.PutUint16(packet[46:48], checksum)
	return packet, nil
}

func parseYggPacket(packet []byte) (net.IP, uint16, []byte, bool) {
	if len(packet) < 48 {
		return nil, 0, nil, false
	}
	if packet[0]>>4 != 6 || packet[6] != 17 {
		return nil, 0, nil, false
	}

	payloadLength := int(binary.BigEndian.Uint16(packet[4:6]))
	if payloadLength < 8 || len(packet) < 40+payloadLength {
		return nil, 0, nil, false
	}

	udpLength := int(binary.BigEndian.Uint16(packet[44:46]))
	if udpLength < 8 || udpLength > payloadLength || len(packet) < 40+udpLength {
		return nil, 0, nil, false
	}

	source := net.IP(append([]byte(nil), packet[8:24]...))
	destinationPort := binary.BigEndian.Uint16(packet[42:44])
	payload := append([]byte(nil), packet[48:40+udpLength]...)
	return source, destinationPort, payload, true
}

func udpChecksum(source []byte, destination []byte, udpHeader []byte, payload []byte) uint16 {
	pseudoHeader := make([]byte, 40)
	copy(pseudoHeader[0:16], source)
	copy(pseudoHeader[16:32], destination)
	binary.BigEndian.PutUint32(pseudoHeader[32:36], uint32(len(udpHeader)+len(payload)))
	pseudoHeader[39] = 17

	headerCopy := append([]byte(nil), udpHeader...)
	headerCopy[6] = 0
	headerCopy[7] = 0

	sum := checksum16(pseudoHeader) + checksum16(headerCopy) + checksum16(payload)
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + (sum >> 16)
	}

	result := ^uint16(sum)
	if result == 0 {
		return 0xffff
	}
	return result
}

func checksum16(data []byte) uint32 {
	var sum uint32
	for index := 0; index+1 < len(data); index += 2 {
		sum += uint32(binary.BigEndian.Uint16(data[index : index+2]))
	}
	if len(data)%2 == 1 {
		sum += uint32(data[len(data)-1]) << 8
	}
	return sum
}
