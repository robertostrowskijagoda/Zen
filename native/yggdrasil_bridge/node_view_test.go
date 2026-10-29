package main

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// R5-F4: a question to a core that never answers costs a caller at most
// the wait, once: later callers get the last answer at once, and no further
// goroutine is left waiting on the core meanwhile.
func TestCoreQueryNeverWaitsLongerThanItsWait(t *testing.T) {
	var q coreQuery[int]
	release := make(chan struct{})
	var asked atomic.Int32
	ask := func() int {
		asked.Add(1)
		<-release
		return 7
	}
	started := time.Now()
	if got := q.get(time.Second, 100*time.Millisecond, ask); got != 0 {
		t.Fatalf("got %d before any answer", got)
	}
	if took := time.Since(started); took > time.Second {
		t.Fatalf("the first call waited %v", took)
	}
	started = time.Now()
	for range 50 {
		q.get(time.Second, 100*time.Millisecond, ask)
	}
	if took := time.Since(started); took > 200*time.Millisecond {
		t.Fatalf("later calls waited %v for a question long under way", took)
	}
	if asked.Load() != 1 {
		t.Fatalf("the core was asked %d times at once", asked.Load())
	}
	close(release)
	waitMeshIO(t, "the answer never came", func() bool {
		return q.get(time.Second, 100*time.Millisecond, ask) == 7
	})
	// Fresh: no question until it gets old or stale.
	q.get(time.Second, 100*time.Millisecond, ask)
	if asked.Load() != 1 {
		t.Fatal("a fresh answer was asked again")
	}
	q.stale()
	q.get(time.Second, 100*time.Millisecond, ask)
	if asked.Load() != 2 {
		t.Fatal("a stale answer was not asked again")
	}
}

// R5-F4: a change of the peerings on a core that never answers gives up
// after nodeActionWait, and once nodeActionsAtOnce are under way the next
// is refused at once.
func TestCoreActionGivesUpOnAStuckCore(t *testing.T) {
	node := &bridgeNode{}
	release := make(chan struct{})
	defer close(release)
	stuck := func() error {
		<-release
		return nil
	}
	var wait sync.WaitGroup
	errs := make([]error, nodeActionsAtOnce)
	started := time.Now()
	for index := range nodeActionsAtOnce {
		wait.Add(1)
		go func() {
			defer wait.Done()
			errs[index] = node.coreAction(stuck)
		}()
	}
	waitMeshIO(t, "the actions never started", func() bool { return node.actions.Load() == nodeActionsAtOnce })
	refusedAt := time.Now()
	if err := node.coreAction(stuck); !errors.Is(err, errNodeBusy) {
		t.Fatalf("one more action on a stuck core: %v", err)
	}
	if took := time.Since(refusedAt); took > 100*time.Millisecond {
		t.Fatalf("the refusal waited %v", took)
	}
	wait.Wait()
	if took := time.Since(started); took > nodeActionWait+time.Second {
		t.Fatalf("the actions waited %v", took)
	}
	for _, err := range errs {
		if !errors.Is(err, errNodeBusy) {
			t.Fatalf("an action on a stuck core said %v", err)
		}
	}
	if err := (&bridgeNode{}).coreAction(func() error { return errors.New("refused") }); err == nil || errors.Is(err, errNodeBusy) {
		t.Fatalf("a quick answer is passed on: %v", err)
	}
}
