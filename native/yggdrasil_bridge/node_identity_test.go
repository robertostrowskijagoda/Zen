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

func appClaim() nodeOwner { return nodeOwner{Role: nodeOwnerApp, Claim: true} }

func TestAClaimWhileTheNodeStillStartsIsRefused(t *testing.T) {
	key := nodeIdentityKey(config.GenerateConfig())
	first, err := claimNodeIdentity(key, appClaim())
	if err != nil || first == nil {
		t.Fatalf("the first node takes the key: %v", err)
	}
	if _, err := claimNodeIdentity(key, appClaim()); !errors.Is(err, errNodeIdentityRunning) {
		t.Fatalf("a second node while the first still starts is refused, got %v", err)
	}
	other, err := claimNodeIdentity(nodeIdentityKey(config.GenerateConfig()), appClaim())
	if err != nil {
		t.Fatalf("another identity starts beside it: %v", err)
	}
	other.release()

	first.release()
	again, err := claimNodeIdentity(key, appClaim())
	if err != nil {
		t.Fatalf("once the first stopped the key is free: %v", err)
	}
	again.release()
}

func TestEveryNewOwnerGetsANewerEngineNumber(t *testing.T) {
	first, _ := claimNodeIdentity(nodeIdentityKey(config.GenerateConfig()), appClaim())
	defer first.release()
	second, _ := claimNodeIdentity(nodeIdentityKey(config.GenerateConfig()), nodeOwner{Role: nodeOwnerService, Claim: true})
	defer second.release()
	if first.engine() == 0 || second.engine() <= first.engine() {
		t.Fatalf("engine numbers grow: %d then %d", first.engine(), second.engine())
	}
	// An owner that ran before keeps its number.
	again, _ := claimNodeIdentity(nodeIdentityKey(config.GenerateConfig()), nodeOwner{Role: nodeOwnerApp, Engine: first.engine()})
	defer again.release()
	if again.engine() != first.engine() {
		t.Fatalf("a known owner keeps its number, got %d", again.engine())
	}
}

func TestAStaleReleaseLeavesTheRunningNodesKey(t *testing.T) {
	key := nodeIdentityKey(config.GenerateConfig())
	old, _ := claimNodeIdentity(key, appClaim())
	old.release()
	current, err := claimNodeIdentity(key, appClaim())
	if err != nil {
		t.Fatal(err)
	}
	defer current.release()
	// A second stop of the old node comes late.
	old.release()
	if _, err := claimNodeIdentity(key, appClaim()); !errors.Is(err, errNodeIdentityRunning) {
		t.Fatalf("the running node still holds its key, got %v", err)
	}
}

func TestAConfigWithoutAKeyHoldsNothing(t *testing.T) {
	claim, err := claimNodeIdentity(nodeIdentityKey(&config.NodeConfig{}), appClaim())
	if err != nil || claim != nil {
		t.Fatalf("no key, no claim: %v %v", claim, err)
	}
	claim.release()
	if claim.engine() != 0 {
		t.Fatal("no claim, no engine")
	}
}

func TestTheOwnerComesOutOfTheConfig(t *testing.T) {
	cleaned, owner := takeZenNodeOwner(`{"Peers":[],"ZenNodeOwner":{"role":"service","engine":7,"claim":true,"onScreen":false}}`)
	if owner != (nodeOwner{Role: nodeOwnerService, Engine: 7, Claim: true}) {
		t.Fatalf("owner read: %+v", owner)
	}
	if cleaned != `{"Peers":[]}` {
		t.Fatalf("the key is taken out: %s", cleaned)
	}
	if _, legacy := takeZenNodeOwner(`{"Peers":[]}`); legacy != appClaim() {
		t.Fatalf("no owner is an app's claim: %+v", legacy)
	}
	if _, odd := takeZenNodeOwner(`{"ZenNodeOwner":{"role":"tray"}}`); odd.Role != nodeOwnerApp {
		t.Fatalf("an unknown role counts as the app: %+v", odd)
	}
}

// The refusal comes before the core is made: nothing is dialled or bound.
func TestCreateNodeRefusesAnIdentityStillStarting(t *testing.T) {
	cfg := config.GenerateConfig()
	cfg.Peers = nil
	cfg.Listen = nil
	data, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	held, err := claimNodeIdentity(nodeIdentityKey(cfg), appClaim())
	if err != nil {
		t.Fatal(err)
	}
	defer held.release()
	node, err := createNode(string(data))
	if !errors.Is(err, errNodeIdentityRunning) || node != nil {
		t.Fatalf("a second node with a key still starting is refused, got %v", err)
	}
	// The refused start left the starting node's claim alone.
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg), appClaim()); !errors.Is(err, errNodeIdentityRunning) {
		t.Fatalf("the key is still held, got %v", err)
	}
}

// runningNode is a node with cfg's key run by owner that holds its claim
// under handle, as YggStartNode leaves one.
func runningNode(t *testing.T, cfg *config.NodeConfig, handle int32, owner nodeOwner) *bridgeNode {
	t.Helper()
	claim, err := claimNodeIdentity(nodeIdentityKey(cfg), owner)
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

// stillRuns tells whether handle's node runs.
func stillRuns(handle int32) bool {
	_, running := nodes.Load(handle)
	return running
}

// takenOver checks that handle's node was stopped by a takeover: calls on
// it say so, and a thread waiting on it was let go.
func takenOver(t *testing.T, handle int32, node *bridgeNode) {
	t.Helper()
	if stillRuns(handle) {
		t.Fatal("the node taken over still runs")
	}
	if !node.signalInbox.isClosed() {
		t.Fatal("a thread still waiting on the node taken over is not let go")
	}
	if err := takenOverError(handle); !errors.Is(err, errNodeTakenOver) {
		t.Fatalf("calls on the node taken over do not say so: %v", err)
	}
}

// Robert's phone after a restore: the app opened again while its old engine
// still ran a node with the key and kept calling on it. The new engine's
// first start takes the key at once.
func TestANewerAppEngineTakesTheIdentityOverAtOnce(t *testing.T) {
	cfg := config.GenerateConfig()
	const oldHandle = -6101
	old := runningNode(t, cfg, oldHandle, appClaim())
	old.touch()
	current := runningNode(t, cfg, -6102, appClaim())
	takenOver(t, oldHandle, old)
	if err := takenOverError(oldHandle); err.Error() != "this node was taken over by a newer owner of its identity (by the app)" {
		t.Fatalf("the old engine hears who took over: %v", err)
	}
	if takenOverError(-6102) != nil {
		t.Fatal("the running node counts as taken over")
	}
	if current.identity.engine() <= old.identity.engine() {
		t.Fatalf("the new owner is newer: %d after %d", current.identity.engine(), old.identity.engine())
	}
	// The old node's own late stop leaves the new claim alone.
	old.identity.release()
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg), nodeOwner{Role: nodeOwnerService}); !errors.Is(err, errNodeSuperseded) {
		t.Fatalf("the new node lost its key to a late stop, got %v", err)
	}
}

// No ping-pong: the old engine's restarts, claims included, never win the
// key back from the newer one.
func TestAnOlderAppEngineNeverWinsBack(t *testing.T) {
	cfg := config.GenerateConfig()
	const oldHandle, newHandle = -6201, -6202
	old := runningNode(t, cfg, oldHandle, appClaim())
	oldEngine := old.identity.engine()
	current := runningNode(t, cfg, newHandle, appClaim())
	takenOver(t, oldHandle, old)
	for _, claim := range []bool{false, true} {
		_, err := claimNodeIdentity(nodeIdentityKey(cfg), nodeOwner{Role: nodeOwnerApp, Engine: oldEngine, Claim: claim})
		if !errors.Is(err, errNodeNewerApp) {
			t.Fatalf("the older engine (claim %v) is refused as superseded, got %v", claim, err)
		}
	}
	if !stillRuns(newHandle) || current.signalInbox.isClosed() {
		t.Fatal("the newer engine's node was disturbed")
	}
	// The newer engine restarting its own node takes it back as its own.
	again, err := claimNodeIdentity(nodeIdentityKey(cfg), nodeOwner{Role: nodeOwnerApp, Engine: current.identity.engine()})
	if err != nil {
		t.Fatalf("an owner takes its own node back, got %v", err)
	}
	again.release()
}

// The app on screen asked the service to let go: its claim wins even while
// the service's node still runs.
func TestTheAppsClaimBeatsTheService(t *testing.T) {
	cfg := config.GenerateConfig()
	const serviceHandle = -6301
	service := runningNode(t, cfg, serviceHandle, nodeOwner{Role: nodeOwnerService, Claim: true})
	runningNode(t, cfg, -6302, nodeOwner{Role: nodeOwnerApp, Claim: true, OnScreen: true})
	takenOver(t, serviceHandle, service)
	// The service's own restart (no claim, even a claim) stays down.
	for _, claim := range []bool{false, true} {
		if _, err := claimNodeIdentity(nodeIdentityKey(cfg), nodeOwner{Role: nodeOwnerService, Engine: service.identity.engine(), Claim: claim}); !errors.Is(err, errNodeAppOnScreen) {
			t.Fatalf("the service's restart is refused, got %v", err)
		}
	}
}

// The app's engine went (swiped away) or the app sits in the background:
// the service's claim takes the key from it.
func TestTheServiceBeatsAnAppOffScreen(t *testing.T) {
	cfg := config.GenerateConfig()
	const appHandle = -6401
	app := runningNode(t, cfg, appHandle, nodeOwner{Role: nodeOwnerApp, Claim: true, OnScreen: true})
	app.identity.setOnScreen(false)
	app.touch()
	service := runningNode(t, cfg, -6402, nodeOwner{Role: nodeOwnerService, Claim: true})
	takenOver(t, appHandle, app)
	// The app's automatic restart does not take it back...
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg), nodeOwner{Role: nodeOwnerApp, Engine: app.identity.engine()}); !errors.Is(err, errNodeSuperseded) {
		t.Fatalf("the app's restart without a claim is refused, got %v", err)
	}
	// ...its claim (back on screen, the service asked to let go) does.
	runningNode(t, cfg, -6403, nodeOwner{Role: nodeOwnerApp, Engine: app.identity.engine(), Claim: true, OnScreen: true})
	takenOver(t, -6402, service)
}

// The app closed with "back" (or swiped away): Android ends its engine, and
// the Dart code that would have said "off screen" never runs. Its word that
// it is on screen lapses without a new one, so the service is kept off the
// identity for nodeOnScreenFor at most, not until the node counts as unused.
func TestTheWordOfAnAppGoneWithoutLeavingTheScreenLapses(t *testing.T) {
	cfg := config.GenerateConfig()
	const appHandle = -6451
	app := runningNode(t, cfg, appHandle, nodeOwner{Role: nodeOwnerApp, Claim: true, OnScreen: true})
	service := nodeOwner{Role: nodeOwnerService, Claim: true}
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg), service); !errors.Is(err, errNodeAppOnScreen) {
		t.Fatalf("the app's fresh word keeps the service off, got %v", err)
	}
	// The app's engine is gone: no word since; the node was called on a
	// moment ago (a signal wait still running out).
	ageOnScreenWord(app, nodeOnScreenFor)
	app.touch()
	runningNode(t, cfg, -6452, service)
	takenOver(t, appHandle, app)
}

// While on screen the app keeps saying so: its word holds again after any
// pause, and "off screen" ends it at once.
func TestTheAppsWordThatItIsOnScreenHoldsWhileItSaysIt(t *testing.T) {
	cfg := config.GenerateConfig()
	app := runningNode(t, cfg, -6461, nodeOwner{Role: nodeOwnerApp, Claim: true, OnScreen: true})
	service := nodeOwner{Role: nodeOwnerService, Claim: true}
	ageOnScreenWord(app, nodeOnScreenFor)
	app.identity.setOnScreen(true)
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg), service); !errors.Is(err, errNodeAppOnScreen) {
		t.Fatalf("said again, the word holds, got %v", err)
	}
	app.identity.setOnScreen(false)
	runningNode(t, cfg, -6462, service)
	takenOver(t, -6461, app)
}

// Android ended the app's engine and the service says which one: the
// service takes that engine's node at once, on screen or not, and never the
// node of another engine on screen (the app opened again).
func TestTheServiceTakesTheNodeOfTheEngineAndroidEndedAtOnce(t *testing.T) {
	cfg := config.GenerateConfig()
	const appHandle = -6471
	app := runningNode(t, cfg, appHandle, nodeOwner{Role: nodeOwnerApp, Claim: true, OnScreen: true})
	gone := app.identity.engine()
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg), nodeOwner{Role: nodeOwnerService, Claim: true, GoneApp: gone + 1000}); !errors.Is(err, errNodeAppOnScreen) {
		t.Fatalf("another engine's end frees nothing, got %v", err)
	}
	runningNode(t, cfg, -6472, nodeOwner{Role: nodeOwnerService, Claim: true, GoneApp: gone})
	takenOver(t, appHandle, app)
}

// ageOnScreenWord makes the app's last word that it is on screen by long
// ago.
func ageOnScreenWord(node *bridgeNode, by time.Duration) {
	nodeIdentities.Lock()
	defer nodeIdentities.Unlock()
	node.identity.onScreenUntil -= by
}

// A higher-priority owner that is active keeps its node: the service never
// takes the key from the app on screen.
func TestTheServiceNeverTakesTheNodeOfTheAppOnScreen(t *testing.T) {
	cfg := config.GenerateConfig()
	const appHandle = -6501
	app := runningNode(t, cfg, appHandle, nodeOwner{Role: nodeOwnerApp, Claim: true, OnScreen: true})
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg), nodeOwner{Role: nodeOwnerService, Claim: true}); !errors.Is(err, errNodeAppOnScreen) {
		t.Fatalf("the service is refused while the app is on screen, got %v", err)
	}
	if !stillRuns(appHandle) || app.signalInbox.isClosed() {
		t.Fatal("the app's node was disturbed")
	}
}

// A newer service engine (the task restarted) beats an older one; the older
// never wins back.
func TestANewerServiceEngineBeatsAnOlderOne(t *testing.T) {
	cfg := config.GenerateConfig()
	const oldHandle = -6601
	old := runningNode(t, cfg, oldHandle, nodeOwner{Role: nodeOwnerService, Claim: true})
	runningNode(t, cfg, -6602, nodeOwner{Role: nodeOwnerService, Claim: true})
	takenOver(t, oldHandle, old)
	if _, err := claimNodeIdentity(nodeIdentityKey(cfg), nodeOwner{Role: nodeOwnerService, Engine: old.identity.engine(), Claim: true}); !errors.Is(err, errNodeSuperseded) {
		t.Fatalf("the older service is refused, got %v", err)
	}
}

// Android ends the app's engine when the app is swiped away, without
// stopping its node; even a start that only restarts takes the key of a
// node nobody calls on any more.
func TestAnUnusedNodeGivesItsKeyToTheNextStart(t *testing.T) {
	cfg := config.GenerateConfig()
	const handle = -5252
	node := runningNode(t, cfg, handle, nodeOwner{Role: nodeOwnerApp, Claim: true, OnScreen: true})
	node.lastCall.Store(int64(time.Since(processClock) - 2*nodeOrphanAfter))
	runningNode(t, cfg, -5253, nodeOwner{Role: nodeOwnerService, Engine: 1 << 40})
	takenOver(t, handle, node)
}

// The policy as a table: who may take the key from whom.
func TestWhoOutranksWhom(t *testing.T) {
	app := func(engine uint64, claim, onScreen bool) nodeOwner {
		return nodeOwner{Role: nodeOwnerApp, Engine: engine, Claim: claim, OnScreen: onScreen}
	}
	service := func(engine uint64, claim bool) nodeOwner {
		return nodeOwner{Role: nodeOwnerService, Engine: engine, Claim: claim}
	}
	cases := []struct {
		name      string
		contender nodeOwner
		holder    nodeOwner
		wins      bool
		err       error
	}{
		{"newer app engine", app(0, true, true), app(3, true, true), true, nil},
		{"newer app engine restarting", app(5, false, true), app(3, false, true), true, nil},
		{"older app engine claiming", app(3, true, true), app(5, false, true), false, errNodeNewerApp},
		{"own node", app(3, false, false), app(3, true, true), true, nil},
		{"app claim over the service", app(3, true, true), service(9, true), true, nil},
		{"app restart over the service", app(3, false, false), service(9, true), false, errNodeSuperseded},
		{"service claim over the app off screen", service(9, true), app(3, true, false), true, nil},
		{"service claim over the app on screen", service(9, true), app(3, true, true), false, errNodeAppOnScreen},
		{"service claim over the gone app on screen", nodeOwner{Role: nodeOwnerService, Engine: 9, Claim: true, GoneApp: 3}, app(3, true, true), true, nil},
		{"service claim over a newer app on screen", nodeOwner{Role: nodeOwnerService, Engine: 9, Claim: true, GoneApp: 3}, app(5, true, true), false, errNodeAppOnScreen},
		{"service restart over the gone app", nodeOwner{Role: nodeOwnerService, Engine: 9, GoneApp: 3}, app(3, true, true), false, errNodeSuperseded},
		{"service restart over the app off screen", service(9, false), app(3, true, false), false, errNodeSuperseded},
		{"newer service", service(0, true), service(4, true), true, nil},
		{"older service", service(4, true), service(6, false), false, errNodeSuperseded},
	}
	for _, c := range cases {
		wins, err := outranks(c.contender, c.holder)
		if wins != c.wins || !errors.Is(err, c.err) {
			t.Errorf("%s: wins %v (%v), want %v (%v)", c.name, wins, err, c.wins, c.err)
		}
	}
}
