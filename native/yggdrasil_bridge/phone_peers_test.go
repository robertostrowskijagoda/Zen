package main

import (
	"encoding/json"
	"fmt"
	"testing"
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

func TestPhoneSwapsPeersThatStayDown(t *testing.T) {
	pool := testPool(8)
	rotation := newPeerRotation(pool, 3)
	dialled := rotation.initial()
	down := map[string]bool{pool[1]: true}
	up := func(peer string) bool { return !down[peer] }

	next, changed := rotation.check(dialled, up)
	if changed {
		t.Fatalf("one check down is not enough to swap: %v", next)
	}
	next, changed = rotation.check(next, up)
	if !changed {
		t.Fatal("a peer down two checks in a row is swapped")
	}
	want := []string{pool[0], pool[3], pool[2]}
	for i := range want {
		if next[i] != want[i] {
			t.Fatalf("got %v, want %v", next, want)
		}
	}
	if again, changed := rotation.check(next, up); changed {
		t.Fatalf("nothing to swap while all are up: %v", again)
	}
}

func TestPhoneWithoutNetworkSwapsRarely(t *testing.T) {
	pool := testPool(16)
	rotation := newPeerRotation(pool, 4)
	dialled := rotation.initial()
	none := func(string) bool { return false }
	swaps := 0
	for check := 1; check <= 64; check++ {
		var changed bool
		dialled, changed = rotation.check(dialled, none)
		if changed {
			swaps++
		}
		if len(dialled) != 4 {
			t.Fatalf("still 4 peers dialled, got %d", len(dialled))
		}
	}
	// The 2nd, 4th, 8th, 16th, 32nd, 48th and 64th check of an hour with
	// no network, not every minute.
	if swaps != 7 {
		t.Fatalf("expected 7 swaps in 64 checks without network, got %d", swaps)
	}
}

func TestPhoneRotationFillsUpAndSkipsDuplicates(t *testing.T) {
	rotation := newPeerRotation([]string{"a", "a", "b", "", "c"}, 4)
	dialled := rotation.initial()
	if len(dialled) != 3 {
		t.Fatalf("a pool of 3 gives 3 peers, got %v", dialled)
	}
	next, changed := rotation.check([]string{"a"}, func(string) bool { return true })
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
