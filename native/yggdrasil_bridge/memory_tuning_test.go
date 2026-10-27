package main

import (
	"math"
	"net"
	"runtime/debug"
	"testing"
)

func TestGoMemoryStatsReportTheHeap(t *testing.T) {
	stats := goMemoryStats()
	for _, sample := range goMemorySamples {
		if _, ok := stats[sample.name].(uint64); !ok {
			t.Fatalf("%s is missing: %v", sample.name, stats)
		}
	}
	if stats["heapBytes"].(uint64) == 0 || stats["goroutines"].(uint64) == 0 {
		t.Fatalf("the heap and goroutines are seen: %v", stats)
	}
	if stats["retainedBytes"].(uint64) > stats["mappedBytes"].(uint64) {
		t.Fatalf("retained more than mapped: %v", stats)
	}
}

func TestMemoryLimitIsSetOnPhonesOnly(t *testing.T) {
	limit := debug.SetMemoryLimit(-1)
	if isPhoneOS() {
		if limit != phoneMemoryLimit {
			t.Fatalf("a phone's memory limit is %d", limit)
		}
		return
	}
	if limit == phoneMemoryLimit {
		t.Fatal("computers keep Go's default memory limit")
	}
	if limit == math.MaxInt64 {
		if stats := goMemoryStats(); stats["memoryLimitBytes"].(uint64) != 0 {
			t.Fatalf("no limit reports 0: %v", stats)
		}
	}
}

func TestAnyRelayOpenSeesRelaysOfAllNodes(t *testing.T) {
	const handle = -4242
	node := &bridgeNode{relays: make(map[string]*relayState)}
	nodes.Store(int32(handle), node)
	defer nodes.Delete(int32(handle))
	if anyRelayOpen() {
		t.Fatal("no call runs")
	}
	node.relayMu.Lock()
	node.relays["call"] = &relayState{remoteIP: net.ParseIP("200::1")}
	node.relayMu.Unlock()
	if !anyRelayOpen() {
		t.Fatal("a call runs")
	}
}

func TestIdleTrimWaitsUntilTheGoSideGrew(t *testing.T) {
	const trimmed = 20 << 20
	if trimDue(trimmed+phoneMemoryTrimGrowth-1, trimmed) {
		t.Fatal("a phone that holds about what it did after the last trim is not trimmed again")
	}
	if !trimDue(trimmed+phoneMemoryTrimGrowth, trimmed) {
		t.Fatal("a phone that grew is trimmed")
	}
	if trimDue(trimmed/2, trimmed) {
		t.Fatal("less than after the last trim is no reason to trim")
	}
}

func TestATrimRemembersWhatTheGoSideHeldAfterIt(t *testing.T) {
	trimMemory()
	after := trimmedRetained.Load()
	if after == 0 || trimDue(retainedMemory(), after) {
		t.Fatalf("after a trim it holds %d, remembered %d", retainedMemory(), after)
	}
}
