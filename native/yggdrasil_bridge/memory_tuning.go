package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"math"
	"os"
	"runtime/debug"
	"runtime/metrics"
	"time"
)

// The Go side's memory on a phone. Go's collector lets the heap grow to
// twice what is live before it collects (GOGC=100) and has no ceiling at
// all, and pages it freed stay with the process until its scavenger hands
// them back bit by bit. On a phone that is memory Android counts against
// the app: what sits there unused is swapped out, and the low memory killer
// ends the background service sooner.
//
//   - phoneMemoryLimit is a soft ceiling (debug.SetMemoryLimit): near it
//     the collector runs more often instead of letting the heap grow. It
//     sits above what everything the bridge buffers for others may hold at
//     once on a phone (signal inbox, half-received signals and the session
//     layer's queue, 16 MiB each) plus the Yggdrasil nodes themselves, so
//     even a bridge flooded to its budgets does not collect without end. A
//     GOMEMLIMIT in the environment (development) wins.
//   - trimMemoryWhileIdle hands every freed page back to the system every
//     phoneMemoryTrimInterval while no call runs (debug.FreeOSMemory): the
//     runtime collects about every two minutes anyway when idle, so this
//     mostly adds the return of pages, not work. During a call it waits,
//     not to add a pause to the media path. A Go ticker does not wake a
//     sleeping phone.
//
// Computers keep Go's defaults.
const (
	phoneMemoryLimit        = 96 * 1024 * 1024
	phoneMemoryTrimInterval = 5 * time.Minute
)

func init() {
	if !isPhoneOS() {
		return
	}
	if os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(phoneMemoryLimit)
	}
	go trimMemoryWhileIdle()
}

func trimMemoryWhileIdle() {
	ticker := time.NewTicker(phoneMemoryTrimInterval)
	defer ticker.Stop()
	for range ticker.C {
		if !anyRelayOpen() {
			debug.FreeOSMemory()
		}
	}
}

// anyRelayOpen reports whether a node of this process relays a call now.
func anyRelayOpen() bool {
	open := false
	nodes.Range(func(_, value any) bool {
		node := value.(*bridgeNode)
		node.relayMu.Lock()
		open = len(node.relays) > 0
		node.relayMu.Unlock()
		return !open
	})
	return open
}

// goMemorySamples are the runtime metrics goMemoryStats reports, by the
// name it reports them under.
var goMemorySamples = []struct {
	name   string
	metric string
}{
	// Heap objects, live and not yet swept.
	{"heapBytes", "/memory/classes/heap/objects:bytes"},
	// Heap size at which the next collection starts.
	{"heapGoalBytes", "/gc/heap/goal:bytes"},
	// Everything the runtime has mapped, and what of it went back to the
	// system (no longer resident).
	{"mappedBytes", "/memory/classes/total:bytes"},
	{"releasedBytes", "/memory/classes/heap/released:bytes"},
	{"memoryLimitBytes", "/gc/gomemlimit:bytes"},
	{"goroutines", "/sched/goroutines:goroutines"},
	{"gcCycles", "/gc/cycles/total:gc-cycles"},
}

// goMemoryStats is how much memory the Go side holds, for diagnostics. It
// reads runtime metrics, which does not stop the program as
// runtime.ReadMemStats does.
func goMemoryStats() map[string]any {
	samples := make([]metrics.Sample, len(goMemorySamples))
	for i, sample := range goMemorySamples {
		samples[i].Name = sample.metric
	}
	metrics.Read(samples)
	stats := make(map[string]any, len(samples)+1)
	for i, sample := range samples {
		if sample.Value.Kind() != metrics.KindUint64 {
			continue
		}
		stats[goMemorySamples[i].name] = sample.Value.Uint64()
	}
	if limit, ok := stats["memoryLimitBytes"].(uint64); ok && limit >= math.MaxInt64 {
		// No limit set.
		stats["memoryLimitBytes"] = uint64(0)
	}
	mapped, _ := stats["mappedBytes"].(uint64)
	released, _ := stats["releasedBytes"].(uint64)
	if mapped >= released {
		stats["retainedBytes"] = mapped - released
	}
	return stats
}

// YggGetMemoryJson tells how much memory the Go side holds now (see
// goMemoryStats).
//
//export YggGetMemoryJson
func YggGetMemoryJson() *C.char {
	return responseOK(goMemoryStats())
}

// YggTrimMemory hands every page the Go side does not use back to the
// system now, for when the app learns the system runs short of memory or
// it went to the background; returns goMemoryStats afterwards.
//
//export YggTrimMemory
func YggTrimMemory() *C.char {
	debug.FreeOSMemory()
	return responseOK(goMemoryStats())
}
