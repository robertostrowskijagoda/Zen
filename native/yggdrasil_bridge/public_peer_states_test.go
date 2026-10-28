package main

import (
	"testing"
	"time"
)

func TestAPhoneKeepsTheWholePoolInReserveBehindItsPicks(t *testing.T) {
	candidates := phonePeerCandidates(publicPeerPool)
	picks := selectAndroidBootstrapPeers(publicPeerPool, phonePeerPoolSize)
	if len(candidates) != len(builtInPublicPeers()) {
		t.Fatalf("%d candidates, %d encrypted peers built in", len(candidates), len(builtInPublicPeers()))
	}
	for index, uri := range picks {
		if candidates[index] != uri {
			t.Fatalf("candidate %d is %s, want the pick %s", index, candidates[index], uri)
		}
	}
	stable := make(map[string]bool, len(publicPeerPool))
	for _, peer := range publicPeerPool {
		stable[peer.uri] = peer.stable
	}
	seen := make(map[string]bool, len(candidates))
	sawIPv6, sawUnstable := false, false
	for _, uri := range candidates[len(picks):] {
		if seen[uri] || !isEncryptedPeerURI(uri) {
			t.Fatalf("reserve peer %s twice or unencrypted", uri)
		}
		seen[uri] = true
		v6 := peerHostIsIPv6Literal(uri)
		if sawIPv6 && !v6 {
			t.Fatalf("%s comes after an IPv6 literal", uri)
		}
		if !v6 && sawUnstable && stable[uri] {
			t.Fatalf("stable %s comes after an unstable peer", uri)
		}
		sawIPv6 = sawIPv6 || v6
		sawUnstable = sawUnstable || (!v6 && !stable[uri])
	}
}

func TestAPhoneWhosePicksAreDeadMovesOnToItsReserve(t *testing.T) {
	candidates := phonePeerCandidates(publicPeerPool)
	picks := map[string]bool{}
	for _, uri := range selectAndroidBootstrapPeers(publicPeerPool, phonePeerPoolSize) {
		picks[uri] = true
	}
	w := newPeerWorld(t, candidates, phonePeerCount)
	for uri := range picks {
		w.dead[uri] = true
	}
	w.run(10 * time.Minute)
	dialled := w.dialled
	for _, uri := range dialled {
		if picks[uri] {
			t.Fatalf("still dials the dead pick %s: %v", uri, dialled)
		}
	}
	if len(dialled) != phonePeerCount {
		t.Fatalf("dials %d, want %d", len(dialled), phonePeerCount)
	}
}

func TestPhonePoolIsTheUsersWholeList(t *testing.T) {
	mine := testPool(phonePeerPoolSize + 10)
	withUserPublicPeers(t, mine)
	if got := androidBootstrapPeers(); len(got) != len(mine) {
		t.Fatalf("phone pool has %d of the user's %d peers", len(got), len(mine))
	}
	if got := desktopPublicPeers(desktopPublicPeerCount); len(got) != desktopPublicPeerCount || got[0] != mine[0] {
		t.Fatalf("a computer dials the first %d of the user's list, got %v", desktopPublicPeerCount, got)
	}
}

func TestPublicPeerStatesTellDialledReserveAndSetAside(t *testing.T) {
	pool := testPool(6)
	withUserPublicPeers(t, pool)
	keeper := newPhonePeerKeeper(pool, 4)
	node := testNode(t, keeper.dialled)
	node.phonePeers = keeper
	node.transitGuard = &transitGuard{}

	states := node.publicPeerStates()
	for _, uri := range pool[:4] {
		if states[uri] != peerStateConnecting {
			t.Fatalf("dialled %s is %q, want connecting: %v", uri, states[uri], states)
		}
	}
	if _, ok := states[pool[4]]; ok {
		t.Fatalf("a node tells only what it dials or set aside: %v", states)
	}

	const handle = -7342
	nodes.Store(int32(handle), node)
	defer nodes.Delete(int32(handle))
	all := publicPeerStates()
	if all[pool[0]] != peerStateConnecting || all[pool[4]] != peerStateStandby || all[pool[5]] != peerStateStandby {
		t.Fatalf("states %v", all)
	}

	// The transit guard holds: one peer kept, three set aside.
	node.beginTransitHold(transitHoldBase, 1<<20)
	all = publicPeerStates()
	if all[pool[0]] != peerStateConnecting {
		t.Fatalf("kept %s is %q", pool[0], all[pool[0]])
	}
	for _, uri := range pool[1:4] {
		if all[uri] != peerStateAside {
			t.Fatalf("%s is %q, want aside: %v", uri, all[uri], all)
		}
	}
	if all[pool[4]] != peerStateStandby {
		t.Fatalf("reserve %s is %q", pool[4], all[pool[4]])
	}

	// Over: four dialled again (the next ones of the pool), none aside.
	node.endTransitHold()
	all = publicPeerStates()
	dialled := 0
	for uri, state := range all {
		switch state {
		case peerStateConnecting:
			dialled++
		case peerStateAside:
			t.Fatalf("after the hold %s is still aside: %v", uri, all)
		}
	}
	if dialled != 4 {
		t.Fatalf("after the hold %d dialled: %v", dialled, all)
	}
}

func TestPeerStatesOfSeveralNodesTellTheMostUsefulOne(t *testing.T) {
	for _, pair := range [][2]string{
		{peerStateStandby, peerStateAside},
		{peerStateAside, peerStateFailing},
		{peerStateFailing, peerStateConnecting},
		{peerStateConnecting, peerStateUp},
	} {
		if peerStateRank[pair[0]] >= peerStateRank[pair[1]] {
			t.Fatalf("%s should rank below %s", pair[0], pair[1])
		}
	}
}
