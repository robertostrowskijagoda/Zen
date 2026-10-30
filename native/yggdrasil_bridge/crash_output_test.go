package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSurviveStopsAGoroutinePanic(t *testing.T) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer survive("test")
		var node *bridgeNode
		_ = node.core
	}()
	<-done
}

func TestBuildRelayPacketWithoutCoreIsAnError(t *testing.T) {
	node := &bridgeNode{}
	if _, err := buildRelayPacket(node, nil, "call", []byte{1}); err == nil {
		t.Fatal("a node without a core sealed a relay packet")
	}
}

func TestTakeZenNodeOwnerReadsTheCrashFile(t *testing.T) {
	_, owner := takeZenNodeOwner(`{"ZenNodeOwner":{"role":"service","crashFile":"/x/go-crash"}}`)
	if owner.CrashFile != "/x/go-crash" {
		t.Fatalf("crash file %q", owner.CrashFile)
	}
}

func TestSetCrashFileCreatesTheFileOnce(t *testing.T) {
	// The runtime keeps the file open for good (Windows cannot remove it):
	// not in t.TempDir.
	dir, err := os.MkdirTemp("", "zen-crash")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "go-crash")
	setCrashFile(path)
	setCrashFile(path)
	if _, err := os.Stat(path); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		crashOutputMu.Lock()
		crashOutputPath = ""
		crashOutputMu.Unlock()
	})
}
