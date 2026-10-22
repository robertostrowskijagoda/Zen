package main

import (
	"encoding/json"
	"strings"
	"time"
)

// A phone keeps few links to public peers. Every peer of the Yggdrasil tree
// passes on its signed updates (each node renews its own every few minutes)
// and every link has its own keepalives, so each extra link means more small
// packets that wake the mobile radio with nobody writing. Yggdrasil's own
// advice for end nodes is two or three peers. A phone dials phonePeerCount
// of its pool (phonePeerPoolSize candidates); a node of an extra account
// that only receives in the background dials phoneExtraAccountPeerCount.
// The rest of the pool waits: a dialled peer that stays down is swapped for
// the next candidate (peerRotation).
const (
	phonePeerCount             = 4
	phoneExtraAccountPeerCount = 2
	maxPhonePeerTarget         = 8
	// How often a phone looks whether its dialled peers are up, and how many
	// checks in a row a peer may be down before another takes its place.
	phonePeerCheckInterval = time.Minute
	phonePeerDownChecks    = 2
	// The key in the node config the app may add to ask for a number of
	// public peers (an extra account's node asks for fewer).
	zenPeerTargetKey = "ZenPeerTarget"
)

// takeZenPeerTarget removes zenPeerTargetKey from a JSON node config and
// returns the config without it and the number asked for (0: none). A
// config that is not a JSON object is returned as it is.
func takeZenPeerTarget(configJSON string) (string, int) {
	if !strings.Contains(configJSON, zenPeerTargetKey) {
		return configJSON, 0
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(configJSON), &fields); err != nil {
		return configJSON, 0
	}
	raw, ok := fields[zenPeerTargetKey]
	if !ok {
		return configJSON, 0
	}
	delete(fields, zenPeerTargetKey)
	cleaned, err := json.Marshal(fields)
	if err != nil {
		return configJSON, 0
	}
	var target int
	if err := json.Unmarshal(raw, &target); err != nil {
		target = 0
	}
	return string(cleaned), target
}

// phonePeerTarget is how many public peers a phone node dials: requested
// when the app asked for a sane number, phonePeerCount otherwise.
func phonePeerTarget(requested int) int {
	if requested <= 0 {
		return phonePeerCount
	}
	if requested > maxPhonePeerTarget {
		return maxPhonePeerTarget
	}
	return requested
}

// firstPeers is the first count of peers (all of them when there are fewer).
func firstPeers(peers []string, count int) []string {
	if count < 0 {
		count = 0
	}
	if len(peers) <= count {
		return append([]string(nil), peers...)
	}
	return append([]string(nil), peers[:count]...)
}

// peerRotation picks which of a pool a phone dials, and swaps a dialled peer
// that stays down for the next candidate of the pool, round and round.
type peerRotation struct {
	pool   []string
	target int
	// Where in the pool the next candidate is taken.
	next int
	// Checks in a row each dialled peer was down.
	down map[string]int
	// Checks in a row no dialled peer was up.
	allDown int
}

func newPeerRotation(pool []string, target int) *peerRotation {
	rotation := &peerRotation{target: target}
	rotation.setPool(pool)
	return rotation
}

// setPool starts over with another pool (the user changed the list).
func (r *peerRotation) setPool(pool []string) {
	seen := make(map[string]bool, len(pool))
	r.pool = make([]string, 0, len(pool))
	for _, peer := range pool {
		if peer == "" || seen[peer] {
			continue
		}
		seen[peer] = true
		r.pool = append(r.pool, peer)
	}
	r.next = 0
	r.down = make(map[string]int)
	r.allDown = 0
}

// initial is what to dial first: the first target of the pool.
func (r *peerRotation) initial() []string {
	picked := firstPeers(r.pool, r.target)
	if len(r.pool) > 0 {
		r.next = len(picked) % len(r.pool)
	}
	return picked
}

// rotationRound tells on which of the checks with every peer down the peers
// are swapped anyway: most likely there is no network at all then, so the
// swaps thin out (the 2nd, 4th and 8th check, then every 16th).
func rotationRound(allDown int) bool {
	return allDown == 2 || allDown == 4 || allDown == 8 || (allDown > 0 && allDown%16 == 0)
}

// check takes one look: dialled is what the phone dials now and up tells
// which of those are up. It returns what to dial from now on and whether
// that differs.
func (r *peerRotation) check(dialled []string, up func(string) bool) ([]string, bool) {
	anyUp := false
	counted := make(map[string]int, len(dialled))
	for _, peer := range dialled {
		if up(peer) {
			anyUp = true
			counted[peer] = 0
		} else {
			counted[peer] = r.down[peer] + 1
		}
	}
	r.down = counted
	if anyUp {
		r.allDown = 0
	} else {
		r.allDown++
		if !rotationRound(r.allDown) {
			return dialled, false
		}
	}
	used := make(map[string]bool, len(dialled))
	for _, peer := range dialled {
		used[peer] = true
	}
	changed := false
	out := make([]string, 0, len(dialled))
	for _, peer := range dialled {
		if r.down[peer] >= phonePeerDownChecks {
			if candidate, ok := r.candidate(used); ok {
				used[candidate] = true
				delete(r.down, peer)
				out = append(out, candidate)
				changed = true
				continue
			}
		}
		out = append(out, peer)
	}
	for len(out) < r.target {
		candidate, ok := r.candidate(used)
		if !ok {
			break
		}
		used[candidate] = true
		out = append(out, candidate)
		changed = true
	}
	if !changed {
		return dialled, false
	}
	return out, true
}

// candidate is the next peer of the pool that is not dialled already.
func (r *peerRotation) candidate(used map[string]bool) (string, bool) {
	for i := 0; i < len(r.pool); i++ {
		index := (r.next + i) % len(r.pool)
		peer := r.pool[index]
		if used[peer] {
			continue
		}
		r.next = (index + 1) % len(r.pool)
		return peer, true
	}
	return "", false
}
