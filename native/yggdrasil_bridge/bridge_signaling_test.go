package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"testing"
)

func TestSplitSignalPayloadRawRoundTripsAndFitsDatagramBudget(t *testing.T) {
	payload := `{"type":"message_chunk","msgId":"transfer-1","text":"Zażółć gęślą jaźń","chunkData":"` +
		strings.Repeat("abcd1234", 24*1024) +
		`","state":"foreground"}`

	chunks := splitSignalPayloadRaw(payload)
	if len(chunks) < 2 {
		t.Fatalf("expected payload to be split into multiple chunks, got %d", len(chunks))
	}

	joined := strings.Join(chunks, "")
	decoded, err := base64.StdEncoding.DecodeString(joined)
	if err != nil {
		t.Fatalf("failed to decode joined chunks: %v", err)
	}
	if string(decoded) != payload {
		t.Fatal("reassembled payload does not match original")
	}

	source := net.ParseIP("200:1111::1")
	destination := net.ParseIP("200:2222::2")
	for index, chunk := range chunks {
		envelopeBytes, err := json.Marshal(signalEnvelope{
			ID:      "test-packet",
			Index:   index,
			Total:   len(chunks),
			Payload: chunk,
		})
		if err != nil {
			t.Fatalf("failed to marshal envelope %d: %v", index, err)
		}
		if _, err := buildYggPacket(source, destination, yggSignalPort, envelopeBytes); err != nil {
			t.Fatalf("chunk %d does not fit into a single datagram: %v", index, err)
		}
	}
}

func newTestBridgeNode() *bridgeNode {
	return &bridgeNode{
		signalPartials: make(map[string]*signalReassembly),
		signalInbox:    make(chan signalMessage, signalInboxCapacity),
	}
}

func TestReassembleSignalRejectsOversizedPayload(t *testing.T) {
	node := newTestBridgeNode()
	oversized := strings.Repeat("A", maxReassembledSignalBytes+1)

	_, ok := node.reassembleSignal("200:1111::1", singleChunkEnvelope(t, oversized))
	if ok {
		t.Fatal("expected an oversized signal to be rejected")
	}
}

func TestReassembleSignalRejectsDecompressionBomb(t *testing.T) {
	node := newTestBridgeNode()
	// Highly compressible payload that expands past the reassembly cap.
	bomb := make([]byte, maxReassembledSignalBytes+1)
	compressed := zstdEncoder.EncodeAll(bomb, nil)
	wire := zstdMagicPrefix + base64.StdEncoding.EncodeToString(compressed)

	_, ok := node.reassembleSignal("200:1111::1", singleChunkEnvelope(t, wire))
	if ok {
		t.Fatal("expected a decompression bomb to be rejected")
	}
}

func TestReassembleSignalAcceptsCompressedPayloadWithinCap(t *testing.T) {
	node := newTestBridgeNode()
	payload := `{"type":"message","text":"hello zen"}`
	compressed := zstdEncoder.EncodeAll([]byte(payload), nil)
	wire := zstdMagicPrefix + base64.StdEncoding.EncodeToString(compressed)

	message, ok := node.reassembleSignal("200:1111::1", singleChunkEnvelope(t, wire))
	if !ok {
		t.Fatal("expected a small compressed signal to be accepted")
	}
	if message != payload {
		t.Fatalf("expected %q, got %q", payload, message)
	}
}

func singleChunkEnvelope(t *testing.T, wirePayload string) []byte {
	t.Helper()
	envelopeBytes, err := json.Marshal(signalEnvelope{
		ID:      "test-envelope",
		Index:   0,
		Total:   1,
		Payload: base64.StdEncoding.EncodeToString([]byte(wirePayload)),
	})
	if err != nil {
		t.Fatalf("failed to marshal envelope: %v", err)
	}
	return envelopeBytes
}

func partialEnvelope(t *testing.T, id string, index, total int, payload string) []byte {
	t.Helper()
	envelopeBytes, err := json.Marshal(signalEnvelope{
		ID:      id,
		Index:   index,
		Total:   total,
		Payload: payload,
	})
	if err != nil {
		t.Fatalf("failed to marshal envelope: %v", err)
	}
	return envelopeBytes
}

func fragmentEnvelopes(t *testing.T, id string, wirePayload string) [][]byte {
	t.Helper()
	chunks := splitSignalPayloadRaw(wirePayload)
	out := make([][]byte, 0, len(chunks))
	for index, chunk := range chunks {
		out = append(out, partialEnvelope(t, id, index, len(chunks), chunk))
	}
	return out
}

func TestReassembleSignalJoinsFragmentsInAnyOrder(t *testing.T) {
	node := newTestBridgeNode()
	payload := `{"type":"message","text":"` + strings.Repeat("zażółć ", 600) + `"}`
	fragments := fragmentEnvelopes(t, "multi", payload)
	if len(fragments) < 3 {
		t.Fatalf("expected several fragments, got %d", len(fragments))
	}
	for index := len(fragments) - 1; index > 0; index-- {
		if _, ok := node.reassembleSignal("200:1111::1", fragments[index]); ok {
			t.Fatal("signal completed before its last fragment")
		}
	}
	message, ok := node.reassembleSignal("200:1111::1", fragments[0])
	if !ok || message != payload {
		t.Fatal("reassembled signal does not match the original")
	}
	if len(node.signalPartials) != 0 || node.signalPartialBytes != 0 {
		t.Fatalf("leftover reassembly state: %d partials, %d bytes", len(node.signalPartials), node.signalPartialBytes)
	}
}

func TestSingleFragmentSignalsDoNotNeedAReassemblySlot(t *testing.T) {
	node := newTestBridgeNode()
	// Signals that never complete, from many addresses.
	for index := 0; index < maxSignalPartials+200; index++ {
		node.reassembleSignal(fmt.Sprintf("200:%x::1", index+1), partialEnvelope(t, "junk", 0, 3, "QUFB"))
	}
	if len(node.signalPartials) > maxSignalPartials {
		t.Fatalf("reassembly table grew to %d entries", len(node.signalPartials))
	}

	payload := `{"type":"ping"}`
	message, ok := node.reassembleSignal("200:6666::6", singleChunkEnvelope(t, payload))
	if !ok || message != payload {
		t.Fatal("a one-fragment signal must get through a full table")
	}
	fragments := fragmentEnvelopes(t, "real", strings.Repeat("x", 5000))
	var joined string
	for _, fragment := range fragments {
		joined, ok = node.reassembleSignal("200:6666::6", fragment)
	}
	if !ok || joined != strings.Repeat("x", 5000) {
		t.Fatal("a multi-fragment signal must get through a full table")
	}
}

func TestReassemblyLimitsHalfFinishedSignalsPerSource(t *testing.T) {
	node := newTestBridgeNode()
	for index := 0; index < 500; index++ {
		node.reassembleSignal("200:3333::3", partialEnvelope(t, fmt.Sprintf("p-%d", index), 0, 2, "QUFB"))
	}
	if count := node.countSignalPartials("200:3333::3"); count > maxSignalPartialsPerSource {
		t.Fatalf("one source holds %d half-finished signals", count)
	}
	if _, ok := node.signalPartials["200:3333::3|p-499"]; !ok {
		t.Fatal("the newest half-finished signal should be kept")
	}
	payload := `{"type":"message","text":"hej"}`
	if message, ok := node.reassembleSignal("200:7777::7", singleChunkEnvelope(t, payload)); !ok || message != payload {
		t.Fatal("other sources are unaffected")
	}
}

func TestReassemblyDropsSignalsThatGrowPastTheCap(t *testing.T) {
	node := newTestBridgeNode()
	half := strings.Repeat("A", maxSignalEncodedBytes/2+4)
	node.reassembleSignal("200:4444::4", partialEnvelope(t, "big", 0, 3, half))
	node.reassembleSignal("200:4444::4", partialEnvelope(t, "big", 1, 3, half))
	if len(node.signalPartials) != 0 || node.signalPartialBytes != 0 {
		t.Fatalf("an oversized signal was kept: %d partials, %d bytes", len(node.signalPartials), node.signalPartialBytes)
	}
}

func TestReassemblyRejectsMoreFragmentsThanTheByteCapAllows(t *testing.T) {
	node := newTestBridgeNode()
	if _, ok := node.reassembleSignal("200:5555::5", partialEnvelope(t, "many", 0, maxSignalChunks+1, "QUFB")); ok {
		t.Fatal("expected the signal to be rejected")
	}
	if len(node.signalPartials) != 0 {
		t.Fatal("nothing should be buffered for a rejected signal")
	}
}

func TestOnlyNodeAddressesAreSignalSources(t *testing.T) {
	cases := map[string]bool{
		"200:1111::1":    true,
		"21e:a51c::1":    true,
		"300:1111::1":    false, // a node's /64 subnet
		"fd00::1":        false,
		"127.0.0.1":      false,
		"::ffff:2.0.0.1": false,
	}
	for address, want := range cases {
		if got := isYggNodeAddress(net.ParseIP(address)); got != want {
			t.Fatalf("isYggNodeAddress(%s) = %v, want %v", address, got, want)
		}
	}
}
