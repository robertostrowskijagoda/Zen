package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"
)

const (
	// Longest base64 text a fragment set may add up to: the encoding of a
	// signal of the largest size, sealed (maxSignalWireBytes). Anything
	// longer is refused as it grows, not after it has been buffered whole.
	maxSignalEncodedBytes = ((maxSignalWireBytes + 2) / 3) * 4
	// Most fragments a signal can have, derived from the byte cap.
	maxSignalChunks = (maxSignalEncodedBytes + signalChunkSize - 1) / signalChunkSize
	// Signals half-received at once, from everyone together and from one
	// source address. When full, the oldest of whoever holds the most goes,
	// so one sender cannot crowd out everyone else's signals.
	maxSignalPartials          = 1024
	maxSignalPartialsPerSource = 32
	// Bytes buffered for all half-received signals together.
	maxSignalPartialBytesTotal = 64 * 1024 * 1024
	maxSignalIDLength          = 128
	// Yggdrasil node addresses start with 0x02. A node may also send from
	// any address in its own /64 subnet (0x03 prefix), which would give it
	// 2^64 identities; Zen only ever sends from node addresses.
	yggNodeAddressPrefix = 0x02
)

type signalReassembly struct {
	source    string
	total     int
	received  int
	bytes     int
	chunks    map[int]string
	updatedAt time.Time
}

// isYggNodeAddress reports whether ip is a Yggdrasil node address (200::/8),
// the only kind of source address Zen peers use.
func isYggNodeAddress(ip net.IP) bool {
	ip16 := ip.To16()
	return ip16 != nil && ip.To4() == nil && ip16[0] == yggNodeAddressPrefix
}

func (node *bridgeNode) reassembleSignal(source string, payload []byte) (string, bool) {
	var envelope signalEnvelope
	if err := json.Unmarshal(payload, &envelope); err != nil {
		return "", false
	}
	if envelope.Total <= 0 || envelope.Index < 0 || envelope.Index >= envelope.Total {
		return "", false
	}
	if envelope.Total > maxSignalChunks || len(envelope.Payload) > maxSignalEncodedBytes {
		fmt.Printf("[ZEN-GO] rejecting signal with %d chunks from %s\n", envelope.Total, source)
		return "", false
	}
	if envelope.Total == 1 {
		// Most signals fit one datagram: nothing to buffer or share.
		return decodeSignalWire(source, envelope.Payload)
	}
	if envelope.ID == "" || len(envelope.ID) > maxSignalIDLength {
		return "", false
	}

	node.signalMu.Lock()
	encoded, complete := node.addSignalFragment(source, envelope, time.Now())
	node.signalMu.Unlock()
	if !complete {
		return "", false
	}
	return decodeSignalWire(source, encoded)
}

// addSignalFragment buffers one fragment of a multi-fragment signal and
// returns the joined base64 text once all fragments are in. The caller holds
// node.signalMu.
func (node *bridgeNode) addSignalFragment(source string, envelope signalEnvelope, now time.Time) (string, bool) {
	if node.signalPartials == nil {
		node.signalPartials = make(map[string]*signalReassembly)
	}
	for key, partial := range node.signalPartials {
		if now.Sub(partial.updatedAt) > signalTTL {
			node.dropSignalPartial(key)
		}
	}

	key := source + "|" + envelope.ID
	partial, ok := node.signalPartials[key]
	if ok && partial.total != envelope.Total {
		node.dropSignalPartial(key)
		ok = false
	}
	if !ok {
		if node.countSignalPartials(source) >= maxSignalPartialsPerSource {
			// Usually leftovers of signals that lost a fragment.
			node.dropOldestSignalPartial(source)
		}
		for len(node.signalPartials) >= maxSignalPartials {
			node.dropOldestSignalPartial(node.busiestSignalSource(false))
		}
		partial = &signalReassembly{
			source:    source,
			total:     envelope.Total,
			chunks:    make(map[int]string),
			updatedAt: now,
		}
		node.signalPartials[key] = partial
	}

	if previous, present := partial.chunks[envelope.Index]; present {
		partial.bytes -= len(previous)
		node.signalPartialBytes -= len(previous)
	} else {
		partial.received++
	}
	partial.chunks[envelope.Index] = envelope.Payload
	partial.bytes += len(envelope.Payload)
	node.signalPartialBytes += len(envelope.Payload)
	partial.updatedAt = now

	if partial.bytes > maxSignalEncodedBytes {
		fmt.Printf("[ZEN-GO] dropping oversized signal (%d bytes so far) from %s\n", partial.bytes, source)
		node.dropSignalPartial(key)
		return "", false
	}
	for node.signalPartialBytes > maxSignalPartialBytesTotal && len(node.signalPartials) > 0 {
		node.dropOldestSignalPartial(node.busiestSignalSource(true))
	}
	if node.signalPartials[key] != partial || partial.received != partial.total {
		return "", false
	}

	var joined strings.Builder
	joined.Grow(partial.bytes)
	for index := 0; index < partial.total; index++ {
		joined.WriteString(partial.chunks[index])
	}
	node.dropSignalPartial(key)
	return joined.String(), true
}

func (node *bridgeNode) dropSignalPartial(key string) {
	partial, ok := node.signalPartials[key]
	if !ok {
		return
	}
	node.signalPartialBytes -= partial.bytes
	delete(node.signalPartials, key)
}

func (node *bridgeNode) countSignalPartials(source string) int {
	count := 0
	for _, partial := range node.signalPartials {
		if partial.source == source {
			count++
		}
	}
	return count
}

// busiestSignalSource is the source with the most half-received signals, or
// with the most bytes buffered when byBytes is set.
func (node *bridgeNode) busiestSignalSource(byBytes bool) string {
	totals := make(map[string]int)
	for _, partial := range node.signalPartials {
		if byBytes {
			totals[partial.source] += partial.bytes
		} else {
			totals[partial.source]++
		}
	}
	busiest := ""
	most := -1
	for source, total := range totals {
		if total > most || (total == most && source < busiest) {
			busiest = source
			most = total
		}
	}
	return busiest
}

func (node *bridgeNode) dropOldestSignalPartial(source string) {
	oldestKey := ""
	var oldest time.Time
	for key, partial := range node.signalPartials {
		if partial.source != source {
			continue
		}
		if oldestKey == "" || partial.updatedAt.Before(oldest) {
			oldestKey = key
			oldest = partial.updatedAt
		}
	}
	if oldestKey == "" {
		// Nothing from that source: never loop forever on a full table.
		for key := range node.signalPartials {
			oldestKey = key
			break
		}
	}
	node.dropSignalPartial(oldestKey)
}

// decodeSignalWire turns the joined base64 fragments into the signal text,
// decompressing zstd payloads, within maxSignalPayloadBytes.
func decodeSignalWire(source string, encodedPayload string) (string, bool) {
	if len(encodedPayload) > maxSignalEncodedBytes {
		return "", false
	}
	decodedPayload, err := base64.StdEncoding.DecodeString(encodedPayload)
	if err != nil {
		return "", false
	}

	wireStr := string(decodedPayload)
	if isPQWire(wireStr) {
		// Sealed (pq_session.go): opened, then decompressed, by the node.
		if len(wireStr) > maxSignalWireBytes {
			return "", false
		}
		return wireStr, true
	}
	return inflateSignalText(source, wireStr)
}

// inflateSignalText is a signal text as the app reads it: decompressed when
// it is zstd, within maxSignalPayloadBytes.
func inflateSignalText(source string, wireStr string) (string, bool) {
	if len(wireStr) > maxSignalPayloadBytes {
		fmt.Printf("[ZEN-GO] rejecting oversized signal (%d bytes) from %s\n", len(wireStr), source)
		return "", false
	}

	// Detect zstd-compressed payloads and decompress.
	if strings.HasPrefix(wireStr, zstdMagicPrefix) {
		compressedB64 := wireStr[len(zstdMagicPrefix):]
		compressedBytes, err := base64.StdEncoding.DecodeString(compressedB64)
		if err != nil {
			fmt.Printf("[ZEN-GO] zstd base64 decode error: %v\n", err)
			return "", false
		}
		decompressed, err := decompressSignal(compressedBytes)
		if err != nil {
			fmt.Printf("[ZEN-GO] rejecting compressed signal from %s: %v\n", source, err)
			return "", false
		}
		return string(decompressed), true
	}

	// Plain JSON.
	return wireStr, true
}

// signalDecompressionLimit is the most a zstd signal of compressedBytes may
// inflate to (see maxSignalCompressionRatio).
func signalDecompressionLimit(compressedBytes int) int {
	limit := max(compressedBytes*maxSignalCompressionRatio, minSignalDecompressionLimit)
	return min(limit, maxSignalPayloadBytes)
}

// decompressSignal inflates a zstd signal, refusing one that would come out
// past signalDecompressionLimit. It decodes as a stream and stops as soon as
// the limit is crossed, so a bomb costs at most the limit (plus one zstd
// block) in memory and work, never its full declared size. Frames whose
// window exceeds maxSignalPayloadBytes are refused before decoding.
func decompressSignal(compressed []byte) ([]byte, error) {
	limit := signalDecompressionLimit(len(compressed))
	// A bytes.Reader (unlike a bytes.Buffer) keeps the decoder on its
	// streaming path; concurrency 1 decodes synchronously, without
	// goroutines.
	decoder, err := zstd.NewReader(
		bytes.NewReader(compressed),
		zstd.WithDecoderConcurrency(1),
		zstd.WithDecoderLowmem(true),
		zstd.WithDecoderMaxMemory(maxSignalPayloadBytes),
	)
	if err != nil {
		return nil, err
	}
	defer decoder.Close()
	decompressed, err := io.ReadAll(io.LimitReader(decoder, int64(limit)+1))
	if err != nil {
		return nil, err
	}
	if len(decompressed) > limit {
		return nil, fmt.Errorf("inflates past %d bytes from %d", limit, len(compressed))
	}
	return decompressed, nil
}
