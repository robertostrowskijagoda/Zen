package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/config"
)

// One node per identity in a process. The app and a background engine
// (Android's service, an iPhone's engine without a screen) use this one
// library in one process, each from a Dart isolate of its own, and an app
// that opens again (another account, a restored copy, a new Activity) makes
// a new engine of its own while the old one may still be around. Two nodes
// with one key side by side split the person's traffic: the mesh routes to
// whichever spoke last and two packet loops answer for one address.
//
// So every start names its owner (zenNodeOwnerKey in the config): the app or
// the background service, an engine number the bridge gives each owner at
// its first start, whether this start claims the identity (an owner's first
// start, or one its own logic asked for again) or only restarts a node of
// its own, and whether the app is on screen. When a node with the key runs
// already, the newest legitimate owner wins at once: the old node is stopped
// (and logged), the new one starts, and every later call on the old node's
// handle says it was taken over, so its owner goes quiet instead of starting
// it again. Who outranks whom (outranks):
//   - a newer app engine beats an older one (an old engine never wins back);
//   - the app's claim beats the service (it asked the service to let go);
//   - the service's claim beats an app that is not on screen (gone, locked,
//     long in the background), never one on screen; "on screen" is a word
//     the app keeps saying (nodeOnScreenFor), and an engine the service
//     names as gone is on no screen;
//   - the same owner always takes its own node back;
//   - a start that only restarts (no claim) never takes anyone's node over,
//     except one nobody calls on any more.
//
// A node nobody calls on any more is stopped for anyone: its engine went
// away without stopping it (Android ends the app's engine when the app is
// swiped away, the process lives on with the service). Whoever runs a node
// calls on it all the time (a thread of the app waits for signals in
// YggWaitSignal, at most a signal wait apart), so a node that heard from
// nobody for nodeOrphanAfter is stopped, and the new start takes its key.
const nodeOrphanAfter = 60 * time.Second

// The app's word that it is on screen lasts this long unless it says it
// again (it does every two seconds while on screen,
// runtime_native_signal_transport.dart). An app engine that went away
// without saying it left the screen keeps the service off its identity this
// long at most: Android ends the engine of an app closed with "back" or
// swiped away right after the last lifecycle events, and the Dart code that
// would say "off screen" may never run. The service also names the engine
// Android ended (nodeOwner.GoneApp), which frees the identity at once.
const nodeOnScreenFor = 5 * time.Second

// The key in the node config the app adds to name the owner of the node.
const zenNodeOwnerKey = "ZenNodeOwner"

// The roles of an owner.
const (
	nodeOwnerApp     = "app"
	nodeOwnerService = "service"
)

var (
	// A node with the key is still starting: the start may come again in a
	// moment.
	errNodeIdentityRunning = errors.New("a node with this identity already runs in this process")
	// The start is outranked by the owner that runs the key: its owner
	// stays quiet (no retries) until its own logic claims the key again.
	errNodeSuperseded = errors.New("a newer owner runs this identity in this process")
	// The same for an app engine a newer one replaced: it never runs the
	// key again.
	errNodeNewerApp = errors.New("a newer app engine runs this identity in this process")
	// The background service may not take the key from the app on screen.
	errNodeAppOnScreen = errors.New("the app runs this identity on screen in this process")
	// A call on a node that a newer owner took the key of.
	errNodeTakenOver = errors.New("this node was taken over by a newer owner of its identity")
)

// nodeOwner is who starts a node, as the app tells it.
type nodeOwner struct {
	Role string `json:"role"`
	// The owner's number: 0 for one that never ran a node yet (the bridge
	// gives it the next number); higher is newer.
	Engine uint64 `json:"engine"`
	// Takes the key over from an owner this one outranks (an owner's first
	// start, or a start its own logic asked for again); without it the start
	// only takes a key that is free (or its own, or an orphan's).
	Claim    bool `json:"claim"`
	OnScreen bool `json:"onScreen"`
	// The service's word that the app engine with this number is gone
	// (Android ended it): that engine's node is not on screen, whatever it
	// said last. 0 for none.
	GoneApp uint64 `json:"goneApp,omitempty"`
	// The file a fatal Go error of this process is written to
	// (crash_output.go); empty for none.
	CrashFile string `json:"crashFile,omitempty"`
}

// The next engine number (process-wide: the app's and the service's isolates
// share it).
var nodeEngines atomic.Uint64

// takeZenNodeOwner removes zenNodeOwnerKey from a JSON node config and
// returns the config without it and the owner it names. A config without
// one (tests, tools) is an app's claim.
func takeZenNodeOwner(configJSON string) (string, nodeOwner) {
	legacy := nodeOwner{Role: nodeOwnerApp, Claim: true}
	if !strings.Contains(configJSON, zenNodeOwnerKey) {
		return configJSON, legacy
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(configJSON), &fields); err != nil {
		return configJSON, legacy
	}
	raw, ok := fields[zenNodeOwnerKey]
	if !ok {
		return configJSON, legacy
	}
	delete(fields, zenNodeOwnerKey)
	cleaned, err := json.Marshal(fields)
	if err != nil {
		return configJSON, legacy
	}
	var owner nodeOwner
	if err := json.Unmarshal(raw, &owner); err != nil {
		return string(cleaned), legacy
	}
	if owner.Role != nodeOwnerService {
		owner.Role = nodeOwnerApp
	}
	return string(cleaned), owner
}

// outranks tells whether contender may take the key of a node held by
// holder, and the reason when not.
func outranks(contender, holder nodeOwner) (bool, error) {
	if contender.Engine != 0 && contender.Engine == holder.Engine {
		// Its own node (a restart after it lost track of it).
		return true, nil
	}
	if contender.Role == holder.Role {
		// Two apps (or two services): the newer engine; an older one never
		// wins back, claim or not. An owner new to the bridge is the newest.
		if contender.Engine == 0 || contender.Engine > holder.Engine {
			return true, nil
		}
		if contender.Role == nodeOwnerApp {
			return false, errNodeNewerApp
		}
		return false, errNodeSuperseded
	}
	if contender.Role == nodeOwnerApp {
		// The app's claim: it asked the service to let go first. A restart
		// of an app whose node the service took stays down.
		if contender.Claim {
			return true, nil
		}
		return false, errNodeSuperseded
	}
	// The service against the app (an engine the service knows is gone is
	// on no screen).
	if holder.OnScreen && (contender.GoneApp == 0 || contender.GoneApp != holder.Engine) {
		return false, errNodeAppOnScreen
	}
	if contender.Claim {
		return true, nil
	}
	return false, errNodeSuperseded
}

// nodeIdentityClaim is the owner token of a running identity: only the node
// that took it lets it go, so a late second stop of an old node never frees
// the key of the node that runs now.
type nodeIdentityClaim struct {
	key string
	// Who runs it (OnScreen changes; guarded by nodeIdentities).
	owner nodeOwner
	// Until when the app's word that it is on screen holds (on processClock;
	// guarded by nodeIdentities): nodeOnScreenFor past its last word.
	onScreenUntil time.Duration
	// The node holding it once it runs (guarded by nodeIdentities).
	node   *bridgeNode
	handle int32
}

var nodeIdentities = struct {
	sync.Mutex
	claims map[string]*nodeIdentityClaim
}{claims: make(map[string]*nodeIdentityClaim)}

// Handles of nodes a newer owner took the key of, with the role of that
// owner: calls on them say so (takenOverError) instead of "no such handle",
// so their owner goes quiet.
var takenOverHandles sync.Map

// takenOverError is what a call on handle answers once a newer owner took
// its node's key, nil for any other handle.
func takenOverError(handle int32) error {
	role, taken := takenOverHandles.Load(handle)
	if !taken {
		return nil
	}
	return fmt.Errorf("%w (by the %s)", errNodeTakenOver, role)
}

// processClock is what the node's last call is measured from (monotonic: a
// sleeping phone's time does not count).
var processClock = time.Now()

// touch notes a call on the node.
func (node *bridgeNode) touch() {
	node.lastCall.Store(int64(time.Since(processClock)))
}

// sinceProcessStart is the time on processClock.
func sinceProcessStart() time.Duration {
	return time.Since(processClock)
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

// claimNodeIdentity takes key for a node of owner about to start. A node with
// the key that owner outranks (or that nobody calls on any more) is stopped
// first; one still starting refuses with errNodeIdentityRunning, one that
// outranks owner with its reason. An owner new to the bridge gets its engine
// number here. A nil claim (an empty key) holds nothing.
func claimNodeIdentity(key string, owner nodeOwner) (*nodeIdentityClaim, error) {
	if key == "" {
		return nil, nil
	}
	nodeIdentities.Lock()
	held := nodeIdentities.claims[key]
	var reason string
	if held != nil {
		if held.node == nil {
			nodeIdentities.Unlock()
			return nil, errNodeIdentityRunning
		}
		if held.node.idle() >= nodeOrphanAfter {
			reason = "nobody used it for " + held.node.idle().Round(time.Second).String()
		} else if ok, err := outranks(owner, held.holder()); ok {
			reason = "a newer owner (" + owner.Role + ") claimed it from the " + held.owner.Role
		} else {
			nodeIdentities.Unlock()
			return nil, err
		}
	}
	if owner.Engine == 0 {
		owner.Engine = nodeEngines.Add(1)
	}
	var old *bridgeNode
	var oldHandle int32
	if held != nil {
		old, oldHandle = held.node, held.handle
	}
	claim := &nodeIdentityClaim{key: key, owner: owner}
	if owner.OnScreen {
		claim.onScreenUntil = sinceProcessStart() + nodeOnScreenFor
	}
	nodeIdentities.claims[key] = claim
	nodeIdentities.Unlock()
	if old != nil {
		// Outside the lock: stopping takes a moment, and the node lets go
		// of a claim that is no longer its own. Its handle answers "taken
		// over" from before it goes, so its owner never starts it again.
		takenOverHandles.Store(oldHandle, owner.Role)
		if old.logger != nil {
			old.logger.Warnf("taking this identity over from node %d: %s", oldHandle, reason)
		}
		if err := old.shutdown(oldHandle); err != nil && old.logger != nil {
			old.logger.Warnf("stopping the node taken over: %v", err)
		}
	}
	return claim, nil
}

// engine is the owner's number (0 without a claim).
func (claim *nodeIdentityClaim) engine() uint64 {
	if claim == nil {
		return 0
	}
	nodeIdentities.Lock()
	defer nodeIdentities.Unlock()
	return claim.owner.Engine
}

// setOnScreen notes whether the app that runs the node is on screen; "on
// screen" holds for nodeOnScreenFor unless the app says it again.
func (claim *nodeIdentityClaim) setOnScreen(onScreen bool) {
	if claim == nil {
		return
	}
	nodeIdentities.Lock()
	defer nodeIdentities.Unlock()
	claim.owner.OnScreen = onScreen
	claim.onScreenUntil = 0
	if onScreen {
		claim.onScreenUntil = sinceProcessStart() + nodeOnScreenFor
	}
}

// holder is who runs the key now, as outranks weighs it: an app whose word
// that it is on screen lapsed is off screen (guarded by nodeIdentities).
func (claim *nodeIdentityClaim) holder() nodeOwner {
	owner := claim.owner
	if owner.OnScreen && sinceProcessStart() >= claim.onScreenUntil {
		owner.OnScreen = false
	}
	return owner
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
