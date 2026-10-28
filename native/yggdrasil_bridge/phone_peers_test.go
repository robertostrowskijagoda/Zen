package main

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"
)

func testPool(count int) []string {
	pool := make([]string, count)
	for i := range pool {
		pool[i] = fmt.Sprintf("tls://192.0.2.%d:443", i+1)
	}
	return pool
}

func TestPhoneDialsAFewOfItsPool(t *testing.T) {
	pool := testPool(phonePeerPoolSize)
	keeper := newPeerRotation(pool, phonePeerTarget(0))
	dialled := keeper.initial()
	if len(dialled) != phonePeerCount {
		t.Fatalf("a phone dials %d peers, got %d", phonePeerCount, len(dialled))
	}
	if phonePeerCount < 3 || phonePeerCount > 4 {
		t.Fatalf("a phone keeps 3-4 public peers, not %d", phonePeerCount)
	}
	if phonePeerTarget(phoneExtraAccountPeerCount) != 2 {
		t.Fatal("an extra account's node dials 2 peers")
	}
	if phonePeerTarget(100) != maxPhonePeerTarget || phonePeerTarget(-1) != phonePeerCount {
		t.Fatal("a nonsense request falls back to sane numbers")
	}
	for i, peer := range dialled {
		if peer != pool[i] {
			t.Fatalf("the best of the pool come first: %v", dialled)
		}
	}
}

// peerWorld runs a phone's rotation on a fake clock: a dialled peer comes
// up connect after it was dialled unless it is dead, and the phone looks
// each time a link comes up or goes down (as peerEventLogger tells it) and
// every phonePeerCheckInterval.
type peerWorld struct {
	t        *testing.T
	rotation *peerRotation
	start    time.Time
	now      time.Time
	connect  time.Duration
	dialled  []string
	dialAt   map[string]time.Time
	dead     map[string]bool
	// Peers newly dialled (not counting the first ones), when each was
	// dialled, and the most dialled at once.
	dials   int
	dialLog []time.Time
	// Waves without network (the core redials everything then).
	redials int
	most    int
	lastUp  string
	nextTic time.Time
}

func newPeerWorld(t *testing.T, pool []string, target int) *peerWorld {
	start := time.Unix(1_800_000_000, 0)
	w := &peerWorld{
		t:        t,
		rotation: newPeerRotation(pool, target),
		start:    start,
		now:      start,
		connect:  2 * time.Second,
		dialAt:   map[string]time.Time{},
		dead:     map[string]bool{},
		nextTic:  start.Add(phonePeerCheckInterval),
	}
	w.dialled = w.rotation.initial()
	for _, peer := range w.dialled {
		w.dialAt[peer] = start
	}
	w.most = len(w.dialled)
	return w
}

func (w *peerWorld) up(peer string) bool {
	at, ok := w.dialAt[peer]
	return ok && !w.dead[peer] && !w.now.Before(at.Add(w.connect))
}

func (w *peerWorld) upCount() int {
	count := 0
	for _, peer := range w.dialled {
		if w.up(peer) {
			count++
		}
	}
	return count
}

func (w *peerWorld) upKey() string {
	key := ""
	for _, peer := range w.dialled {
		if w.up(peer) {
			key += peer + " "
		}
	}
	return key
}

// look is one check of the rotation; what it dials anew is dialled now.
func (w *peerWorld) look() {
	next, changed, wave := w.rotation.check(w.now, w.dialled, w.up)
	if wave {
		w.redials++
	}
	if !changed {
		return
	}
	had := map[string]bool{}
	for _, peer := range w.dialled {
		had[peer] = true
	}
	for _, peer := range next {
		if !had[peer] {
			w.dialAt[peer] = w.now
			w.dials++
			w.dialLog = append(w.dialLog, w.now)
		}
	}
	for peer := range had {
		found := false
		for _, kept := range next {
			found = found || kept == peer
		}
		if !found {
			delete(w.dialAt, peer)
		}
	}
	w.dialled = next
	if len(next) > w.most {
		w.most = len(next)
	}
	w.lastUp = w.upKey()
}

// run lets d pass a second at a time.
func (w *peerWorld) run(d time.Duration) {
	end := w.now.Add(d)
	for w.now.Before(end) {
		w.now = w.now.Add(time.Second)
		switch {
		case w.upKey() != w.lastUp:
			w.look()
		case !w.now.Before(w.nextTic):
			w.look()
		}
		for !w.now.Before(w.nextTic) {
			w.nextTic = w.nextTic.Add(phonePeerCheckInterval)
		}
	}
}

// kill makes peers dead; the phone hears the link go down at once.
func (w *peerWorld) kill(peers ...string) {
	for _, peer := range peers {
		w.dead[peer] = true
	}
	w.look()
}

// untilUp is how long it takes until want peers are up (fails after limit).
func (w *peerWorld) untilUp(want int, limit time.Duration) time.Duration {
	from := w.now
	for w.upCount() < want {
		if w.now.Sub(from) > limit {
			w.t.Fatalf("%d of %d up after %v: %v", w.upCount(), want, limit, w.dialled)
		}
		w.run(time.Second)
	}
	return w.now.Sub(from)
}

// A peer of the two a locked phone dials goes away: stand-ins are dialled
// right then, and two links are up again within seconds, also when the
// candidates first in line are dead.
func TestALockedPhoneReplacesAPeerThatGoesDownWithinSeconds(t *testing.T) {
	for dead := 0; dead <= 3; dead++ {
		pool := testPool(16)
		w := newPeerWorld(t, pool, phoneExtraAccountPeerCount)
		w.untilUp(2, time.Minute)
		w.run(time.Minute)
		// The first candidates in line are dead too.
		for i := 0; i < dead; i++ {
			w.dead[pool[2+i]] = true
		}
		dialsBefore := w.dials
		w.kill(pool[0])
		if w.dials == dialsBefore {
			t.Fatalf("%d dead: no stand-in dialled the moment the link went down", dead)
		}
		took := w.untilUp(2, time.Minute)
		t.Logf("%d dead candidate(s) in line: two links up again after %v", dead, took)
		// Two stand-ins at once, then two more after a dial grace: up to
		// three dead candidates in line still make it within 15 s.
		limit := 15 * time.Second
		if took > limit {
			t.Fatalf("%d dead: two links up after %v, want at most %v", dead, took, limit)
		}
		if w.most > 2*phoneExtraAccountPeerCount {
			t.Fatalf("%d dead: %d peers dialled at once", dead, w.most)
		}
		w.run(time.Minute)
		if len(w.dialled) != 2 || w.upCount() != 2 {
			t.Fatalf("%d dead: back to two peers, both up, got %v", dead, w.dialled)
		}
		for _, peer := range w.dialled {
			if peer == pool[0] || w.dead[peer] {
				t.Fatalf("%d dead: still dials %s: %v", dead, peer, w.dialled)
			}
		}
	}
}

// A link that comes back by itself (the core redials it) before its
// stand-ins keeps its place; the stand-ins go.
func TestAPeerThatComesBackKeepsItsPlace(t *testing.T) {
	pool := testPool(8)
	w := newPeerWorld(t, pool, 2)
	w.untilUp(2, time.Minute)
	w.run(time.Minute)
	w.connect = 3 * time.Second
	w.kill(pool[1])
	if len(w.dialled) != 4 {
		t.Fatalf("one up, one gone, two stand-ins: %v", w.dialled)
	}
	// It is back a second later, before the stand-ins.
	delete(w.dead, pool[1])
	w.run(time.Second)
	if len(w.dialled) != 2 || w.dialled[0] != pool[0] || w.dialled[1] != pool[1] {
		t.Fatalf("the first two again, got %v", w.dialled)
	}
}

// Without network nothing comes up: fresh candidates come in waves that
// thin out to one every phonePeerOfflineWaveMax, never more than twice the
// target at once; once the network is back the phone settles on two again.
func TestAPhoneWithoutNetworkDialsInWavesThatThinOut(t *testing.T) {
	pool := testPool(64)
	w := newPeerWorld(t, pool, 2)
	w.untilUp(2, time.Minute)
	for _, peer := range pool {
		w.dead[peer] = true
	}
	w.look()
	lost := w.now
	if w.dials != 0 {
		t.Fatalf("nothing dialled the moment everything went down: %d", w.dials)
	}
	w.run(time.Hour)
	if w.most > 4 {
		t.Fatalf("%d dialled at once without network", w.most)
	}
	// Waves after 5 s, then 15 s, 30 s, 1, 2, 4, 8 and 15 minutes: nine
	// in the hour, two fresh candidates each.
	if w.dials > 20 {
		t.Fatalf("%d dials in an hour without network", w.dials)
	}
	late := 0
	for _, at := range w.dialLog {
		if at.Sub(lost) > 30*time.Minute {
			late++
		}
	}
	if late > 4 {
		t.Fatalf("%d dials in the second half hour without network", late)
	}
	first := w.dialLog[0].Sub(lost)
	if first < phonePeerOfflineFirst || first > phonePeerOfflineFirst+phonePeerCheckInterval {
		t.Fatalf("the first wave came after %v", first)
	}
	t.Logf("an hour without network: %d dials, %d in the second half hour", w.dials, late)

	// The network is back.
	w.dead = map[string]bool{}
	w.untilUp(2, phonePeerOfflineWaveMax+time.Minute)
	w.run(time.Minute)
	if len(w.dialled) != 2 || w.rotation.waves != 0 {
		t.Fatalf("back to two peers, the waves start over: %v, %d waves", w.dialled, w.rotation.waves)
	}
}

// A locked phone without network sleeps between its wakes, and no Go timer
// runs meanwhile. The waves go by the wall clock: the first look after a
// long sleep (the app sends on its wake) has the core redial at once,
// instead of after its own wait between redials, which stood still.
func TestAWaveWithoutNetworkComesDueOnTheFirstLookAfterASleep(t *testing.T) {
	pool := testPool(16)
	w := newPeerWorld(t, pool, 2)
	w.untilUp(2, time.Minute)
	for _, peer := range pool {
		w.dead[peer] = true
	}
	w.look()
	w.run(time.Hour)
	redials := w.redials
	if redials < 5 {
		t.Fatalf("%d waves in an hour without network", redials)
	}
	// Asleep for 40 minutes: nobody looks.
	w.now = w.now.Add(40 * time.Minute)
	w.nextTic = w.now.Add(phonePeerCheckInterval)
	w.look()
	if w.redials != redials+1 {
		t.Fatal("no redial on the first look after the sleep")
	}
	// The network is back meanwhile: the redial brings the peers up.
	w.dead = map[string]bool{}
	w.untilUp(2, time.Minute)
}

// The app sends on a wake while no peer is up (the poll of the mailboxes
// after an outage): the core redials everything at once, also between the
// waves, but at most once a minute, and never while a peer is up.
func TestASendWithNoPeerUpRedialsAtMostOnceAMinute(t *testing.T) {
	pool := testPool(16)
	w := newPeerWorld(t, pool, 2)
	w.untilUp(2, time.Minute)
	if w.rotation.redialOnWake(w.now) {
		t.Fatal("peers are up: no redial")
	}
	for _, peer := range pool {
		w.dead[peer] = true
	}
	w.look()
	w.run(time.Hour)
	// Asleep for 5 minutes, less than the wait for the next wave.
	w.now = w.now.Add(5 * time.Minute)
	if !w.rotation.redialOnWake(w.now) {
		t.Fatal("no redial on the send of a wake")
	}
	if w.rotation.redialOnWake(w.now.Add(30 * time.Second)) {
		t.Fatal("a second redial within a minute")
	}
	if !w.rotation.redialOnWake(w.now.Add(61 * time.Second)) {
		t.Fatal("no redial a minute later")
	}
}

// A phone that holds (transit_guard.go) keeps one peer: its stand-in is
// never one the hold set aside, unless nothing else is left.
func TestAHoldingPhoneSkipsThePeersSetAside(t *testing.T) {
	pool := testPool(8)
	w := newPeerWorld(t, pool, 4)
	w.untilUp(4, time.Minute)
	w.rotation.target = 1
	w.rotation.setAside(pool[1:4])
	w.dialled = []string{pool[0]}
	w.most = 1
	w.kill(pool[0])
	w.run(phonePeerOfflineFirst + phonePeerCheckInterval)
	for _, peer := range w.dialled {
		for _, aside := range pool[1:4] {
			if peer == aside {
				t.Fatalf("dials %s, set aside by the hold: %v", peer, w.dialled)
			}
		}
	}
	w.untilUp(1, time.Minute)
	if w.most > 2 {
		t.Fatalf("a holding phone dialled %d at once", w.most)
	}

	// Only peers set aside are left: one of them rather than none.
	small := newPeerRotation(pool[:3], 1)
	small.setAside(pool[1:3])
	if got := small.fill(nil); len(got) != 1 || got[0] != pool[0] {
		t.Fatalf("the first not set aside, got %v", got)
	}
	if got := small.fill([]string{pool[0]}); len(got) != 1 {
		t.Fatalf("one is enough, got %v", got)
	}
	small.target = 2
	if got := small.fill([]string{pool[0]}); len(got) != 2 {
		t.Fatalf("set aside, but better than nothing: %v", got)
	}
}

func TestPhoneRotationFillsUpAndSkipsDuplicates(t *testing.T) {
	rotation := newPeerRotation([]string{"a", "a", "b", "", "c"}, 4)
	dialled := rotation.initial()
	if len(dialled) != 3 {
		t.Fatalf("a pool of 3 gives 3 peers, got %v", dialled)
	}
	next, changed, _ := rotation.check(time.Now(), []string{"a"}, func(string) bool { return true })
	if !changed || len(next) != 3 {
		t.Fatalf("missing peers are dialled again: %v", next)
	}
}

func TestTakeZenPeerTarget(t *testing.T) {
	cleaned, target := takeZenPeerTarget(`{"PrivateKey":"ab","ZenPeerTarget":2,"Peers":[]}`)
	if target != 2 {
		t.Fatalf("target = %d", target)
	}
	var fields map[string]any
	if err := json.Unmarshal([]byte(cleaned), &fields); err != nil {
		t.Fatal(err)
	}
	if _, ok := fields[zenPeerTargetKey]; ok || fields["PrivateKey"] != "ab" {
		t.Fatalf("the key goes, the rest stays: %s", cleaned)
	}
	same := `{"PrivateKey":"ab"}`
	if got, target := takeZenPeerTarget(same); got != same || target != 0 {
		t.Fatal("a config without the key is left alone")
	}
	if got, target := takeZenPeerTarget("ZenPeerTarget: 2"); got != "ZenPeerTarget: 2" || target != 0 {
		t.Fatal("HJSON is left to the config parser")
	}
}

func TestFirstPeers(t *testing.T) {
	if got := firstPeers([]string{"a", "b", "c"}, 2); len(got) != 2 || got[1] != "b" {
		t.Fatalf("got %v", got)
	}
	if got := firstPeers([]string{"a"}, 4); len(got) != 1 {
		t.Fatalf("got %v", got)
	}
}
