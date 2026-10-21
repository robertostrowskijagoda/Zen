//go:build windows

package main

import (
	"syscall"
	"unsafe"
)

// lockMemory keeps b's pages in RAM; false when the system refused.
func lockMemory(b []byte) bool {
	if len(b) == 0 {
		return false
	}
	return syscall.VirtualLock(uintptr(unsafe.Pointer(&b[0])), uintptr(len(b))) == nil
}

// unlockMemory releases what lockMemory locked.
func unlockMemory(b []byte) {
	if len(b) > 0 {
		_ = syscall.VirtualUnlock(uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)))
	}
}
