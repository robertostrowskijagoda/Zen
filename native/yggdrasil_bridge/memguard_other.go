//go:build !linux && !darwin && !windows

package main

// lockMemory: nothing to lock with on this system.
func lockMemory(b []byte) bool { return false }

// unlockMemory: see lockMemory.
func unlockMemory(b []byte) {}
