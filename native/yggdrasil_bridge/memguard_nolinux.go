//go:build !linux || android

package main

// hardenProcess: nothing here on these systems (Android makes release apps
// non-dumpable itself; the Windows runner hardens the process; the app
// detects debuggers on all of them, device_integrity.dart).
func hardenProcess() {}

// processDumpable reports whether the process is dumpable (tests).
func processDumpable() bool { return true }
