package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/rand/v2"
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
	}
}

func TestReassembleSignalRejectsOversizedPayload(t *testing.T) {
	node := newTestBridgeNode()
	oversized := strings.Repeat("A", maxSignalPayloadBytes+1)

	_, ok := node.reassembleSignal("200:1111::1", singleChunkEnvelope(t, oversized))
	if ok {
		t.Fatal("expected an oversized signal to be rejected")
	}
}

func TestReassembleSignalAcceptsPayloadAtTheLimit(t *testing.T) {
	node := newTestBridgeNode()
	largest := strings.Repeat("A", maxSignalPayloadBytes)

	message, ok := node.reassembleSignal("200:1111::1", singleChunkEnvelope(t, largest))
	if !ok || message != largest {
		t.Fatal("a signal of exactly the largest size must be accepted")
	}
}

func TestReassembleSignalRejectsDecompressionBomb(t *testing.T) {
	node := newTestBridgeNode()
	// Highly compressible payload that expands past the signal limit.
	bomb := make([]byte, maxSignalPayloadBytes+1)
	compressed := zstdEncoder.EncodeAll(bomb, nil)
	wire := zstdMagicPrefix + base64.StdEncoding.EncodeToString(compressed)

	_, ok := node.reassembleSignal("200:1111::1", singleChunkEnvelope(t, wire))
	if ok {
		t.Fatal("expected a decompression bomb to be rejected")
	}
}

func TestReassembleSignalRejectsCompressionPastTheRatio(t *testing.T) {
	node := newTestBridgeNode()
	// Well under the size limit, but a few dozen bytes inflating to 256 KiB.
	payload := `{"type":"message","text":"` + strings.Repeat("a", 256*1024) + `"}`
	compressed := zstdEncoder.EncodeAll([]byte(payload), nil)
	if limit := signalDecompressionLimit(len(compressed)); len(payload) <= limit {
		t.Fatalf("test payload inflates to %d bytes, within the %d byte limit", len(payload), limit)
	}
	wire := zstdMagicPrefix + base64.StdEncoding.EncodeToString(compressed)

	if _, ok := node.reassembleSignal("200:1111::1", singleChunkEnvelope(t, wire)); ok {
		t.Fatal("expected a signal past the compression ratio limit to be rejected")
	}
}

func TestSignalDecompressionLimit(t *testing.T) {
	cases := map[int]int{
		0:         minSignalDecompressionLimit,
		100:       minSignalDecompressionLimit,
		2000:      2000 * maxSignalCompressionRatio,
		1 << 20:   maxSignalPayloadBytes,
		1<<20 + 1: maxSignalPayloadBytes,
	}
	for compressed, want := range cases {
		if got := signalDecompressionLimit(compressed); got != want {
			t.Fatalf("signalDecompressionLimit(%d) = %d, want %d", compressed, got, want)
		}
	}
}

func TestLargeCompressedSignalRoundTripsThroughFragments(t *testing.T) {
	node := newTestBridgeNode()
	// JSON that compresses a few times over, like real signals.
	random := rand.New(rand.NewPCG(1, 2))
	var text strings.Builder
	for text.Len() < 512*1024 {
		fmt.Fprintf(&text, "word%d ", random.IntN(500))
	}
	payload := `{"type":"message","text":"` + text.String() + `"}`
	wire := buildSignalWirePayload(payload)
	if !strings.HasPrefix(wire, zstdMagicPrefix) {
		t.Fatal("expected the bridge to compress the test payload")
	}

	fragments := fragmentEnvelopes(t, "compressed", wire)
	var message string
	var ok bool
	for _, fragment := range fragments {
		message, ok = node.reassembleSignal("200:1111::1", fragment)
	}
	if !ok || message != payload {
		t.Fatal("a compressed multi-fragment signal must round-trip")
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

func TestPartialLimitsOfADoorAreTighter(t *testing.T) {
	door := &bridgeNode{
		signalPartials: make(map[string]*signalReassembly),
		partialLimits:  signalPartialLimits{total: maxDoorPartialBytes, perSignal: maxDoorEncodedBytes},
	}
	half := strings.Repeat("A", maxDoorEncodedBytes/2+4)
	door.reassembleSignal("200:4444::4", partialEnvelope(t, "big", 0, 3, half))
	door.reassembleSignal("200:4444::4", partialEnvelope(t, "big", 1, 3, half))
	if len(door.signalPartials) != 0 || door.signalPartialBytes != 0 {
		t.Fatal("a door keeps no signal larger than its largest frame")
	}
	main := newTestBridgeNode()
	main.reassembleSignal("200:4444::4", partialEnvelope(t, "big", 0, 3, half))
	main.reassembleSignal("200:4444::4", partialEnvelope(t, "big", 1, 3, half))
	if len(main.signalPartials) != 1 {
		t.Fatal("the main node keeps it")
	}

	chunk := strings.Repeat("B", maxDoorEncodedBytes/2)
	for index := range 2 * maxDoorPartialBytes / len(chunk) {
		source := fmt.Sprintf("200:%x::1", index+1)
		door.reassembleSignal(source, partialEnvelope(t, "p", 0, 2, chunk))
	}
	if door.signalPartialBytes > maxDoorPartialBytes {
		t.Fatalf("a door buffers %d bytes, over %d", door.signalPartialBytes, maxDoorPartialBytes)
	}
}

func TestPhonesBufferLessForOthers(t *testing.T) {
	if isPhoneOS() {
		if signalPartialBudget != maxPhoneSignalPartialBytesTotal || signalInboxBytes != maxPhoneSignalInboxBytes {
			t.Fatal("a phone takes the phone budgets")
		}
	} else if signalPartialBudget != maxSignalPartialBytesTotal || signalInboxBytes != maxSignalInboxBytes {
		t.Fatal("a computer takes the full budgets")
	}
	if maxSignalInboxBytesPerSource >= maxPhoneSignalInboxBytes || maxSignalEncodedBytes >= maxPhoneSignalPartialBytesTotal {
		t.Fatal("a phone still has room for a signal of the largest size")
	}
	if maxDoorEncodedBytes >= maxDoorPartialBytes || maxDoorEncodedBytes >= maxSignalEncodedBytes {
		t.Fatal("a door has room for its largest frame, and less than the main node")
	}
}
