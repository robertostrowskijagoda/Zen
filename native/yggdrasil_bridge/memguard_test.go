package main

import (
	"bytes"
	"runtime"
	"testing"
)

func TestWipeBytesOverwritesASecret(t *testing.T) {
	secret := bytes.Repeat([]byte{0xa5}, 64)
	wipeBytes(secret)
	if !bytes.Equal(secret, make([]byte, 64)) {
		t.Fatal("the secret is still there")
	}
	wipeBytes(nil)
}

func TestLockedMemoryStaysUsable(t *testing.T) {
	buffer := bytes.Repeat([]byte{1}, 4096)
	locked := lockMemory(buffer)
	t.Logf("locked: %v", locked)
	buffer[100] = 7
	if buffer[100] != 7 {
		t.Fatal("locked memory must stay writable")
	}
	unlockMemory(buffer)
	if lockMemory(nil) {
		t.Fatal("nothing to lock")
	}
	unlockMemory(nil)
}

func TestLocalPeersAreWipedWhenReleased(t *testing.T) {
	peers := []localPeer{testLocalPeer(t, 1), testLocalPeer(t, 2)}
	lockMemory(sliceBytes(peers))
	if len(sliceBytes(peers)) == 0 || len(bytesOf(&peers[0])) == 0 {
		t.Fatal("the peers' memory is seen")
	}
	releaseLocalPeers(peers)
	var zero [32]byte
	for _, peer := range peers {
		if peer.tagKey != zero || peer.selKey != zero || peer.linkKey != zero {
			t.Fatal("released link keys must be overwritten")
		}
		if peer.address == "" {
			t.Fatal("only the keys go")
		}
	}
}

func TestTheProcessIsNotDumpableOnLinux(t *testing.T) {
	if runtime.GOOS != "linux" || debugAllowed() {
		t.Skip("hardened on Linux computers only, unless debugging is allowed")
	}
	if processDumpable() {
		t.Fatal("the bridge makes the process non-dumpable when it loads")
	}
}
