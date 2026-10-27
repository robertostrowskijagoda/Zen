package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"errors"
	"sync"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/config"
)

// One node per identity in a process. The app and a background engine
// (Android's service, an iPhone's engine without a screen) use this one
// library in one process, each from a Dart isolate of its own, and their
// hand-over stops one node before the other starts. Should a hand-over slip,
// two nodes with one key would run side by side: the mesh would route the
// person's traffic to whichever spoke last and two packet loops would answer
// for one address. So a start with a key that already runs is refused (and
// logged) instead; the app's start retries on its own a moment later.
//
// A node nobody calls on any more is another matter: its engine went away
// without stopping it (Android ends the app's engine when the app is swiped
// away, the process lives on with the service). Whoever runs a node calls on
// it all the time (a thread of the app waits for signals in YggWaitSignal,
// at most a signal wait apart), so a node that heard from nobody for
// nodeOrphanAfter is stopped, and the new start takes its key.
const nodeOrphanAfter = 60 * time.Second

var errNodeIdentityRunning = errors.New("a node with this identity already runs in this process")

// nodeIdentityClaim is the owner token of a running identity: only the node
// that took it lets it go, so a late second stop of an old node never frees
// the key of the node that runs now.
type nodeIdentityClaim struct {
	key string
	// The node holding it once it runs (guarded by nodeIdentities).
	node   *bridgeNode
	handle int32
}

var nodeIdentities = struct {
	sync.Mutex
	claims map[string]*nodeIdentityClaim
}{claims: make(map[string]*nodeIdentityClaim)}

// processClock is what the node's last call is measured from (monotonic: a
// sleeping phone's time does not count).
var processClock = time.Now()

// touch notes a call on the node.
func (node *bridgeNode) touch() {
	node.lastCall.Store(int64(time.Since(processClock)))
}

// idle is how long nobody called on the node.
func (node *bridgeNode) idle() time.Duration {
	return time.Since(processClock) - time.Duration(node.lastCall.Load())
}

// nodeIdentityKey is the public key of cfg's private key as hex, "" when it
// holds none (the node then fails to start anyway).
func nodeIdentityKey(cfg *config.NodeConfig) string {
	if len(cfg.PrivateKey) != ed25519.PrivateKeySize {
		return ""
	}
	return hex.EncodeToString(ed25519.PrivateKey(cfg.PrivateKey).Public().(ed25519.PublicKey))
}

// claimNodeIdentity takes key for a node about to start; errNodeIdentityRunning
// when a node in use (or one still starting) holds it. A node with the key
// that nobody calls on any more is stopped first. A nil claim (an empty key)
// holds nothing.
func claimNodeIdentity(key string) (*nodeIdentityClaim, error) {
	if key == "" {
		return nil, nil
	}
	nodeIdentities.Lock()
	held := nodeIdentities.claims[key]
	if held != nil && (held.node == nil || held.node.idle() < nodeOrphanAfter) {
		nodeIdentities.Unlock()
		return nil, errNodeIdentityRunning
	}
	var orphan *bridgeNode
	var orphanHandle int32
	if held != nil {
		orphan, orphanHandle = held.node, held.handle
	}
	claim := &nodeIdentityClaim{key: key}
	nodeIdentities.claims[key] = claim
	nodeIdentities.Unlock()
	if orphan != nil {
		// Outside the lock: stopping takes a moment, and the node lets go
		// of a claim that is no longer its own.
		if orphan.logger != nil {
			orphan.logger.Warnf("stopping a node with this identity that nobody used for %s", orphan.idle().Round(time.Second))
		}
		if err := orphan.shutdown(orphanHandle); err != nil && orphan.logger != nil {
			orphan.logger.Warnf("stopping the unused node: %v", err)
		}
	}
	return claim, nil
}

// running tells the claim which node holds it now.
func (claim *nodeIdentityClaim) running(handle int32, node *bridgeNode) {
	if claim == nil {
		return
	}
	nodeIdentities.Lock()
	defer nodeIdentities.Unlock()
	claim.handle = handle
	claim.node = node
}

// release lets the key go once its node stopped (or did not start).
func (claim *nodeIdentityClaim) release() {
	if claim == nil {
		return
	}
	nodeIdentities.Lock()
	defer nodeIdentities.Unlock()
	if nodeIdentities.claims[claim.key] == claim {
		delete(nodeIdentities.claims, claim.key)
	}
}
