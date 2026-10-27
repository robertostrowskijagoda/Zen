package main

import (
	"io"
	"net"
	"net/url"
	"sync/atomic"
	"testing"
	"time"

	iwt "github.com/Arceliar/ironwood/types"
	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// windowAt is the transit of one window at rate (bytes per second).
func windowAt(rate uint64, crossed bool) transitEstimate {
	return transitEstimate{bytes: rate * uint64(trafficWindow/time.Second), rate: rate, crossed: crossed}
}

// untilHold feeds the guard windows of estimate from now on until it holds;
// returns the hold, how many windows it took and when the last one ended.
func untilHold(t *testing.T, guard *transitGuard, now time.Time, estimate transitEstimate) (time.Duration, int, time.Time) {
	t.Helper()
	for windows := 1; windows <= 10; windows++ {
		now = now.Add(trafficWindow)
		if hold := guard.observe(now, estimate); hold > 0 {
			return hold, windows, now
		}
	}
	t.Fatal("no hold after 10 windows")
	return 0, 0, now
}

func TestTransitOverSeveralWindowsStartsAHold(t *testing.T) {
	var guard transitGuard
	now := time.Unix(1000, 0)
	if hold := guard.observe(now, windowAt(1024, false)); hold != 0 {
		t.Fatalf("a trickle of transit is no reason to hold, got %s", hold)
	}
	// What the phone carried that night: about 930 kB/s.
	fast := windowAt(930_000, false)
	for i := 1; i < transitConfirmWindows; i++ {
		now = now.Add(trafficWindow)
		if hold := guard.observe(now, fast); hold != 0 {
			t.Fatalf("window %d alone starts a hold of %s", i, hold)
		}
	}
	now = now.Add(trafficWindow)
	if hold := guard.observe(now, fast); hold != transitHoldBase {
		t.Fatalf("hold %s, want %s", hold, transitHoldBase)
	}
	if hold := guard.observe(now.Add(trafficWindow), transitEstimate{}); hold != 0 {
		t.Fatal("no second hold while one runs")
	}
	if guard.due(now.Add(transitHoldBase - time.Second)) {
		t.Fatal("the hold runs its time")
	}
	if !guard.due(now.Add(transitHoldBase)) {
		t.Fatal("the hold ends")
	}
	if guard.due(now.Add(transitHoldBase + time.Second)) {
		t.Fatal("a hold ends once")
	}
}

// A burst, however fast, that does not last starts nothing.
func TestAShortBurstStartsNoHold(t *testing.T) {
	var guard transitGuard
	now := time.Unix(1000, 0)
	for range 5 {
		for i := 1; i < transitConfirmWindows; i++ {
			now = now.Add(trafficWindow)
			if hold := guard.observe(now, windowAt(1<<20, true)); hold != 0 {
				t.Fatalf("a burst of %d windows held for %s", i, hold)
			}
		}
		now = now.Add(trafficWindow)
		if hold := guard.observe(now, transitEstimate{}); hold != 0 {
			t.Fatal("a quiet window holds")
		}
	}
}

func TestSlowTransitIsStoppedByTheHoursBudget(t *testing.T) {
	var guard transitGuard
	now := time.Unix(1000, 0)
	// Under the rate limit, window after window.
	slow := windowAt(40*1024, false)
	var passed uint64
	for i := 0; i < 240; i++ {
		now = now.Add(trafficWindow)
		passed += slow.bytes
		if hold := guard.observe(now, slow); hold > 0 {
			if passed < phoneTransitHourBudget || passed > phoneTransitHourBudget+transitConfirmWindows*slow.bytes {
				t.Fatalf("hold after %d bytes, budget %d", passed, phoneTransitHourBudget)
			}
			return
		}
	}
	t.Fatal("slow transit for two hours started no hold")
}

func TestAQuietPhoneOverTheHoursBudgetDoesNotHold(t *testing.T) {
	var guard transitGuard
	over := transitEstimate{bytes: phoneTransitHourBudget, rate: phoneTransitRateLimit - 1, crossed: true}
	hold, _, now := untilHold(t, &guard, time.Unix(1000, 0), over)
	if hold != transitHoldBase {
		t.Fatalf("the hour's budget used up starts a hold, got %s", hold)
	}
	now = now.Add(hold)
	if !guard.due(now) {
		t.Fatal("hold not over")
	}
	// Still within the hour of those windows, but nothing passes now.
	if hold := guard.observe(now.Add(trafficWindow), transitEstimate{}); hold != 0 {
		t.Fatal("no transit now, no hold")
	}
	again := transitEstimate{bytes: 1000, rate: 33, crossed: true}
	if hold := guard.observe(now.Add(2*trafficWindow), again); hold != 2*transitHoldBase {
		t.Fatalf("transit again within that hour: hold %s", hold)
	}
}

func TestHoldsGrowWhileTransitComesBackAndAreForgotten(t *testing.T) {
	var guard transitGuard
	now := time.Unix(1000, 0)
	home := windowAt(1<<20, true)
	want := []time.Duration{30 * time.Minute, time.Hour, 2 * time.Hour, 4 * time.Hour, 6 * time.Hour, 6 * time.Hour}
	for i, expected := range want {
		hold, windows, end := untilHold(t, &guard, now, home)
		if hold != expected {
			t.Fatalf("hold %d: %s, want %s", i+1, hold, expected)
		}
		// The first hold waits for the windows in a row; transit that
		// comes back after one that crossed holds at once.
		wantWindows := 1
		if i == 0 {
			wantWindows = transitConfirmWindows
		}
		if windows != wantWindows {
			t.Fatalf("hold %d after %d windows, want %d", i+1, windows, wantWindows)
		}
		now = end.Add(hold)
		if !guard.due(now) {
			t.Fatal("hold not over")
		}
	}
	now = now.Add(transitHoldMemory + time.Minute)
	hold, windows, _ := untilHold(t, &guard, now, home)
	if hold != transitHoldBase || windows != transitConfirmWindows {
		t.Fatalf("after a quiet day the hold is short again, got %s after %d windows", hold, windows)
	}
}

// Transit that never crossed between a peering nearby and a public one
// (all a stranger far away can send) holds for transitHoldBase at most,
// each time after the windows in a row.
func TestHoldsDoNotGrowWithoutCrossing(t *testing.T) {
	var guard transitGuard
	now := time.Unix(1000, 0)
	for i := range 6 {
		hold, windows, end := untilHold(t, &guard, now, windowAt(1<<20, false))
		if hold != transitHoldBase || windows != transitConfirmWindows {
			t.Fatalf("hold %d: %s after %d windows", i+1, hold, windows)
		}
		now = end.Add(hold)
		if !guard.due(now) {
			t.Fatal("hold not over")
		}
	}
}

// The episode of the logs: for 55 minutes about 930 kB/s came in from the
// home computer and went out again to the public peers. With the guard, a
// phone that keeps routing for it passes a few windows of it before it
// holds for the rest of the episode.
func TestTheNightOfTheEpisodeIsBounded(t *testing.T) {
	var guard transitGuard
	home := windowAt(930_000, true)
	start := time.Unix(1000, 0)
	end := start.Add(55 * time.Minute)
	var passed, unguarded uint64
	holding := false
	for now := start.Add(trafficWindow); !now.After(end); now = now.Add(trafficWindow) {
		unguarded += home.bytes
		if guard.due(now) {
			holding = false
		}
		if holding {
			// One way to the mesh: nobody's shortcut.
			guard.observe(now, transitEstimate{})
			continue
		}
		passed += home.bytes
		if guard.observe(now, home) > 0 {
			holding = true
		}
	}
	if passed > (transitConfirmWindows+1)*home.bytes {
		t.Fatalf("passed %d bytes, want at most %d", passed, (transitConfirmWindows+1)*home.bytes)
	}
	if unguarded < 3_000_000_000 || passed*25 > unguarded {
		t.Fatalf("unguarded %d, guarded %d", unguarded, passed)
	}
}

func TestAHoldKeepsAPublicPeerThatIsUpOrElseADeviceNearby(t *testing.T) {
	public := []string{"tls://a:1?key=x", "tls://b:1"}
	links := []transitLink{
		{address: "200::1", peerURI: "tcp://127.0.0.1:1"},
		{address: "200::2", peerURI: "tcp://127.0.0.1:2"},
	}
	cases := []struct {
		up                   map[string]bool
		wantPublic, wantLink string
	}{
		{map[string]bool{"tls://b:1": true, "tcp://127.0.0.1:1": true}, "tls://b:1", ""},
		{map[string]bool{"tls://a:1": true}, "tls://a:1?key=x", ""},
		{map[string]bool{"tcp://127.0.0.1:2": true}, "", "200::2"},
		{map[string]bool{}, "tls://a:1?key=x", ""},
	}
	for i, c := range cases {
		gotPublic, gotLink := chooseTransitKeep(public, links, c.up)
		if gotPublic != c.wantPublic || gotLink != c.wantLink {
			t.Fatalf("case %d: kept %q %q, want %q %q", i, gotPublic, gotLink, c.wantPublic, c.wantLink)
		}
	}
	if gotPublic, gotLink := chooseTransitKeep(nil, links, nil); gotPublic != "" || gotLink != "200::1" {
		t.Fatalf("no public peers: kept %q %q", gotPublic, gotLink)
	}
}

func TestAHoldNeverSetsFriendsBridgesAside(t *testing.T) {
	pool := testPool(6)
	keeper := newPhonePeerKeeper(pool, 4)
	bridge := "tls://[200::b1]:443"
	node := testNode(t, keeper.dialled)
	node.phonePeers = keeper
	node.configMu.Lock()
	node.config.Peers = append(node.config.Peers, bridge)
	node.configMu.Unlock()
	node.transitGuard = &transitGuard{}

	// The bridge is not up: the phone keeps one public peer beside it.
	node.beginTransitHold(transitHoldBase, 1<<20)
	if got := node.dialledPublicPeers(); len(got) != 1 || got[0] != pool[0] {
		t.Fatalf("holding: dials %v, want only %s", got, pool[0])
	}
	if extras := node.configuredExtras(); len(extras) != 1 || extras[0] != bridge {
		t.Fatalf("holding: the friend's bridge was set aside, extras %v", extras)
	}
	if state := node.transitGuardState(time.Now()); state["setAside"] != 3 || state["onBridges"] != false {
		t.Fatalf("holding: %v", state)
	}

	node.endTransitHold()
	if got := node.dialledPublicPeers(); len(got) != 4 {
		t.Fatalf("after the hold: %d public peers, want 4", len(got))
	}
	if extras := node.configuredExtras(); len(extras) != 1 || extras[0] != bridge {
		t.Fatalf("after the hold: extras %v", extras)
	}
}

// With a friend's bridge up the phone goes through the bridges alone; when
// none is up any more it dials one public peer again.
func TestAHoldGoesThroughAFriendsBridgeThatIsUp(t *testing.T) {
	bridgeCore, bridge := listeningCore(t)
	pool := testPool(6)
	keeper := newPhonePeerKeeper(pool, 4)
	node := testNode(t, keeper.dialled)
	node.phonePeers = keeper
	node.transitGuard = &transitGuard{}
	parsed, _ := url.Parse(bridge)
	if err := node.core.AddPeer(parsed, ""); err != nil {
		t.Fatal(err)
	}
	node.updateConfiguredPeer(bridge, true)
	waitForPeer(t, node.core, bridgeCore.PublicKey(), true)

	node.beginTransitHold(transitHoldBase, 1<<20)
	if got := node.dialledPublicPeers(); len(got) != 0 {
		t.Fatalf("holding on a bridge: dials %v", got)
	}
	if state := node.transitGuardState(time.Now()); state["onBridges"] != true {
		t.Fatalf("holding: %v", state)
	}
	node.checkTransitHold(time.Now())
	if got := node.dialledPublicPeers(); len(got) != 0 {
		t.Fatalf("the bridge is up: dials %v", got)
	}

	// The bridge goes down.
	if err := node.core.RemovePeer(parsed, ""); err != nil {
		t.Fatal(err)
	}
	waitForPeer(t, node.core, bridgeCore.PublicKey(), false)
	node.checkTransitHold(time.Now())
	if got := node.dialledPublicPeers(); len(got) != 1 {
		t.Fatalf("no bridge up: dials %v, want one public peer", got)
	}
	if extras := node.configuredExtras(); len(extras) != 1 || extras[0] != bridge {
		t.Fatalf("the bridge stays configured, extras %v", extras)
	}
}

func TestHeldLocalLinksCloseAndTakeNoNewOnes(t *testing.T) {
	coreA, coreB, managerA, managerB := testManagers(t)
	link := func() error {
		left, right := net.Pipe()
		done := make(chan error, 1)
		go func() {
			_, err := managerB.handshakeAndAttach(right, "test", "")
			done <- err
		}()
		_, err := managerA.handshakeAndAttach(left, "test", "")
		if err != nil {
			_ = right.Close()
			<-done
			return err
		}
		return <-done
	}
	if err := link(); err != nil {
		t.Fatal(err)
	}
	waitForPeer(t, coreA, coreB.PublicKey(), true)

	managerA.hold("")
	waitForPeer(t, coreA, coreB.PublicKey(), false)
	if managerA.mayLink(coreB.Address().String()) {
		t.Fatal("no links while held")
	}
	if err := link(); err == nil {
		t.Fatal("a held manager links with nobody")
	}

	managerA.release()
	if err := link(); err != nil {
		t.Fatal(err)
	}
	waitForPeer(t, coreA, coreB.PublicKey(), true)
}

// listeningCore is a node that takes peerings on a loopback port.
func listeningCore(t *testing.T) (*core.Core, string) {
	t.Helper()
	cfg := config.GenerateConfig()
	c, err := core.New(cfg.Certificate, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Stop)
	listenURL, _ := url.Parse("tcp://127.0.0.1:0")
	listener, err := c.Listen(listenURL, "")
	if err != nil {
		t.Fatal(err)
	}
	return c, "tcp://" + listener.Addr().String()
}

// A phone dials two peers that have no other way to each other, so all
// their traffic goes through it, as strangers' traffic went through the
// phone between the home computer and its public peers. The guard sees
// the transit over several windows and the phone keeps one peering:
// nothing passes any more. When the hold ends it dials both again.
func TestAPhoneBetweenTwoPeersStopsCarryingTheirTraffic(t *testing.T) {
	coreA, uriA := listeningCore(t)
	coreB, uriB := listeningCore(t)
	keeper := newPhonePeerKeeper([]string{uriA, uriB}, 2)
	node := testNode(t, nil)
	node.phonePeers = keeper
	node.transitGuard = &transitGuard{}
	node.swapPublicPeers(nil, keeper.dialled)
	waitForPeer(t, node.core, coreA.PublicKey(), true)
	waitForPeer(t, node.core, coreB.PublicKey(), true)

	var received atomic.Uint64
	go func() {
		// A takes its side of the session handshake in its reads.
		buf := make([]byte, 65535)
		for {
			if _, _, err := coreA.ReadFrom(buf); err != nil {
				return
			}
		}
	}()
	go func() {
		buf := make([]byte, 65535)
		for {
			n, _, err := coreB.ReadFrom(buf)
			if err != nil {
				return
			}
			received.Add(uint64(n))
		}
	}()
	payload := make([]byte, 1200)
	toB := iwt.Addr(coreB.PublicKey())
	sendUntil := func(total uint64, limit time.Duration) bool {
		deadline := time.Now().Add(limit)
		for received.Load() < total && time.Now().Before(deadline) {
			for range 16 {
				_, _ = coreA.WriteTo(payload, toB)
			}
			time.Sleep(time.Millisecond)
		}
		return received.Load() >= total
	}
	// The path and the session first, one packet at a time.
	probeUntil := time.Now().Add(20 * time.Second)
	for received.Load() == 0 && time.Now().Before(probeUntil) {
		_, _ = coreA.WriteTo(payload, toB)
		time.Sleep(100 * time.Millisecond)
	}
	if received.Load() == 0 {
		t.Fatalf("no path from A to B through the phone: paths %d sessions %d/%d peersA %d tree %d",
			len(coreA.GetPaths()), len(coreA.GetSessions()), len(coreB.GetSessions()), len(coreA.GetPeers()), len(coreA.GetTree()))
	}

	start := time.Now()
	node.sampleTrafficAt(start)
	held := start
	for i := 1; i <= transitConfirmWindows; i++ {
		if !sendUntil(received.Load()+3<<20, 30*time.Second) {
			t.Fatal("A's traffic did not reach B")
		}
		held = start.Add(time.Duration(i) * trafficWindow)
		node.sampleTrafficAt(held)
		holding := node.transitGuardState(held)["holding"] == true
		if holding != (i == transitConfirmWindows) {
			t.Fatalf("3 MB through the phone in each of %d windows, holding %v: %v", i, holding, node.peerTraffic.snapshot())
		}
	}
	kept := node.dialledPublicPeers()
	if len(kept) != 1 {
		t.Fatalf("holding: dials %v", kept)
	}
	dropped := coreB
	if kept[0] == uriB {
		dropped = coreA
	}
	waitForPeer(t, node.core, dropped.PublicKey(), false)

	before := received.Load()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for range 64 {
			_, _ = coreA.WriteTo(payload, toB)
		}
		time.Sleep(time.Millisecond)
	}
	if got := received.Load(); got != before {
		t.Fatalf("%d bytes still went through the holding phone", got-before)
	}

	node.sampleTrafficAt(held.Add(transitHoldBase))
	waitForPeer(t, node.core, coreA.PublicKey(), true)
	waitForPeer(t, node.core, coreB.PublicKey(), true)
}
