//go:build linux || darwin

package main

import "syscall"

// lockMemory keeps b's pages in RAM; false when the system refused.
func lockMemory(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	return syscall.Mlock(b) == nil
}

// unlockMemory releases what lockMemory locked.
func unlockMemory(b []byte) {
	if len(b) > 0 {
		_ = syscall.Munlock(b)
	}
}
