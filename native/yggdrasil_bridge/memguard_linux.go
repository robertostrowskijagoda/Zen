//go:build linux && !android

package main

import "syscall"

// prSetDumpable and prGetDumpable are prctl's PR_SET_DUMPABLE and
// PR_GET_DUMPABLE.
const (
	prGetDumpable = 3
	prSetDumpable = 4
)

// hardenProcess makes the process non-dumpable (see memguard.go).
func hardenProcess() {
	_, _, _ = syscall.RawSyscall6(syscall.SYS_PRCTL, prSetDumpable, 0, 0, 0, 0, 0)
}

// processDumpable reports whether the process is dumpable (tests).
func processDumpable() bool {
	value, _, errno := syscall.RawSyscall6(syscall.SYS_PRCTL, prGetDumpable, 0, 0, 0, 0, 0)
	return errno == 0 && value != 0
}
