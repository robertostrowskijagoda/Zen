package main

import (
	"fmt"
	"os"
	"runtime/debug"
	"sync"
)

// The file a fatal Go error of this process is written to (its message and
// the goroutines' stacks), as the app names it in the node's owner
// (node_identity.go): Android records only "signal 11" for a Go crash in
// the app's process, with no stack and no tombstone, so the app reads this
// file at its next start into the diagnostics log
// (lib/src/core/logging/zen_tech_log.dart, noteGoCrash).
var (
	crashOutputMu   sync.Mutex
	crashOutputPath string
)

// setCrashFile makes path the crash output of this process, once per path
// (the app's and the service's nodes name the same one). It only appends:
// the app empties the file once it has read it.
func setCrashFile(path string) {
	if path == "" {
		return
	}
	crashOutputMu.Lock()
	defer crashOutputMu.Unlock()
	if path == crashOutputPath {
		return
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		fmt.Printf("[ZEN-GO] crash file not opened: %v\n", err)
		return
	}
	// The runtime keeps its own copy of the descriptor.
	defer file.Close()
	if err := debug.SetCrashOutput(file, debug.CrashOptions{}); err != nil {
		fmt.Printf("[ZEN-GO] crash file not set: %v\n", err)
		return
	}
	crashOutputPath = path
}

// survive ends a panic of a background goroutine of the bridge ([where]
// names it) instead of the whole app; deferred first in such a goroutine.
// The panic and its stack are printed, and the goroutine ends.
func survive(where string) {
	if value := recover(); value != nil {
		fmt.Printf("[ZEN-GO] %s: panic stopped: %v\n%s\n", where, value, debug.Stack())
	}
}
