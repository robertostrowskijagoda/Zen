package main

import (
	"os"
	"runtime"
	"unsafe"
)

// Keeping secrets out of reach in memory, as far as a library inside the
// app's process can (the app's own side is on the Dart and native sides):
//
//   - wipeBytes overwrites a secret once it has done its work (seeds of keys,
//     KEM secrets, link keys), so a later memory dump or a swapped-out page
//     does not find it;
//   - lockMemory keeps the pages of long-lived secrets in RAM (mlock,
//     VirtualLock): never written to swap or a hibernation file. Best
//     effort: the system may refuse (limits), and Go copies values it
//     passes around, so it narrows, not closes, the window;
//   - hardenProcess, at load: on Linux computers the process is made
//     non-dumpable (no core dumps; other processes of the same user can no
//     longer attach a debugger or read and write its memory through
//     /proc). ZEN_ALLOW_DEBUG=1 in the environment leaves it debuggable
//     (development). Android makes release apps non-dumpable itself;
//     Windows is hardened by its runner (windows/runner/main.cpp).
//
// None of this stops someone who owns the device (root, a debugger the
// system lets in); the app detects and refuses what it can there
// (device_integrity.dart). What matters most does not rest on memory at
// all: money and pyramid records are signed records every member's phone
// checks, so a modified app on one phone cannot mint money or forge others'
// records — at most misuse the keys held on that phone.

// wipeBytes overwrites b with zeros.
func wipeBytes(b []byte) {
	clear(b)
	runtime.KeepAlive(b)
}

// bytesOf is the memory of v (a value that holds secrets), as bytes.
func bytesOf[T any](v *T) []byte {
	return unsafe.Slice((*byte)(unsafe.Pointer(v)), unsafe.Sizeof(*v))
}

// sliceBytes is the backing memory of s, as bytes.
func sliceBytes[T any](s []T) []byte {
	if len(s) == 0 {
		return nil
	}
	var zero T
	return unsafe.Slice((*byte)(unsafe.Pointer(&s[0])), len(s)*int(unsafe.Sizeof(zero)))
}

// debugAllowed is set in development to leave the process debuggable.
func debugAllowed() bool {
	return os.Getenv("ZEN_ALLOW_DEBUG") == "1"
}

func init() {
	if !debugAllowed() {
		hardenProcess()
	}
}
