package main

import (
	"encoding/json"
	"errors"
	"io"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

func TestASecondClaimOfOneIdentityIsRefused(t *testing.T) {
	key := nodeIdentityKey(config.GenerateConfig())
	first, err := claimNodeIdentity(key)
	if err != nil || first == nil {
		t.Fatalf("the first node takes the key: %v", err)
	}
	if _, err := claimNodeIdentity(key); !errors.Is(err, errNodeIdentityRunning) {
		t.Fatalf("a second node with the same key is refused, got %v", err)
	}
	other, err := claimNodeIdentity(nodeIdentityKey(config.GenerateConfig()))
	if err != nil {
		t.Fatalf("another identity starts beside it: %v", err)
	}
	other.release()

	first.release()
	again, err := claimNodeIdentity(key)
	if err != nil {
		t.Fatalf("once the first stopped the key is free: %v", err)
	}
	again.release()
}

func TestAStaleReleaseLeavesTheRunningNodesKey(t *testing.T) {
	key := nodeIdentityKey(config.GenerateConfig())
	old, _ := claimNodeIdentity(key)
	old.release()
	current, err := claimNodeIdentity(key)
	if err != nil {
		t.Fatal(err)
	}
	defer current.release()
	// A second stop of the old node comes late.
	old.release()
	if _, err := claimNodeIdentity(key); !errors.Is(err, errNodeIdentityRunning) {
		t.Fatalf("the running node still holds its key, got %v", err)
	}
}

func TestAConfigWithoutAKeyHoldsNothing(t *testing.T) {
	claim, err := claimNodeIdentity(nodeIdentityKey(&config.NodeConfig{}))
	if err != nil || claim != nil {
		t.Fatalf("no key, no claim: %v %v", claim, err)
	}
	claim.release()
}

// The refusal comes before the core is made: nothing is dialled or bound.
func TestCreateNodeRefusesAnIdentityThatRuns(t *testing.T) {
	cfg := config.GenerateConfig()
	cfg.Peers = nil
	cfg.Listen = nil
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	held, err := claimNodeIdentity(nodeIdentityKey(cfg))
	if err != nil {
		t.Fatal(err)
	}
	defer held.release()
	node, err := createNode(string(data))
	if !errors.Is(err, errNodeIdentityRunning) || node != nil {
		t.Fatalf("a second node with a running key is refused, got %v", err)
	}
	// The refused start left the running node's claim alone.
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg)); !errors.Is(err, errNodeIdentityRunning) {
		t.Fatalf("the key is still held, got %v", err)
	}
}

// runningNode is a node with cfg's key that holds its claim under handle,
// as YggStartNode leaves one.
func runningNode(t *testing.T, cfg *config.NodeConfig, handle int32) *bridgeNode {
	t.Helper()
	claim, err := claimNodeIdentity(nodeIdentityKey(cfg))
	if err != nil {
		t.Fatal(err)
	}
	c, err := core.New(cfg.Certificate, log.New(io.Discard, "", 0))
	if err != nil {
		claim.release()
		t.Fatal(err)
	}
	node := &bridgeNode{core: c, config: cfg, logger: log.New(io.Discard, "", 0), identity: claim}
	node.touch()
	nodes.Store(handle, node)
	claim.running(handle, node)
	t.Cleanup(func() {
		if _, still := nodes.Load(handle); still {
			_ = node.shutdown(handle)
		}
	})
	return node
}

func TestANodeInUseKeepsItsKey(t *testing.T) {
	cfg := config.GenerateConfig()
	node := runningNode(t, cfg, -5151)
	node.touch()
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg)); !errors.Is(err, errNodeIdentityRunning) {
		t.Fatalf("a node the app calls on is not replaced, got %v", err)
	}
	if _, still := nodes.Load(int32(-5151)); !still {
		t.Fatal("the node in use was stopped")
	}
}

// Android ends the app's engine when the app is swiped away, without
// stopping its node; the service's node takes the key.
func TestAnUnusedNodeGivesItsKeyToTheNextStart(t *testing.T) {
	cfg := config.GenerateConfig()
	const handle = -5252
	node := runningNode(t, cfg, handle)
	node.lastCall.Store(int64(time.Since(processClock) - 2*nodeOrphanAfter))
	claim, err := claimNodeIdentity(nodeIdentityKey(cfg))
	if err != nil || claim == nil {
		t.Fatalf("a node nobody used for long gives its key up, got %v", err)
	}
	defer claim.release()
	if _, still := nodes.Load(int32(handle)); still {
		t.Fatal("the unused node still runs")
	}
	if !node.signalInbox.isClosed() {
		t.Fatal("a thread still waiting on the unused node is not let go")
	}
	// The old node's own late stop leaves the new claim alone.
	node.identity.release()
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg)); !errors.Is(err, errNodeIdentityRunning) {
		t.Fatalf("the new node holds the key, got %v", err)
	}
}
