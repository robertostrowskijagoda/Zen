package main

import (
	"encoding/json"
	"sort"
	"strings"
	"time"
)

// A phone keeps few links to public peers. Every peer of the Yggdrasil tree
// passes on its signed updates (each node renews its own every few minutes)
// and every link has its own keepalives, so each extra link means more small
// packets that wake the mobile radio with nobody writing. Yggdrasil's own
// advice for end nodes is two or three peers. A phone dials phonePeerCount
// of its pool (its picks first, then the rest of the public pool in
// reserve: phonePeerCandidates); a node that only receives in the
// background dials phoneExtraAccountPeerCount: one. A node with two
// peerings can become the shortest way between them, and strangers' traffic
// then passes through it (traffic_meter.go): a locked phone with two public
// peers carried 1-6 KB/s of it, in and out, for seven hours, under the
// transit guard's limits (made for data, not for the radio), and lost a
// third of its battery in a day. With one peering a node is nobody's
// shortcut. The rest of the pool waits: a dialled peer that goes down or
// does not come up is replaced by the next candidates within seconds
// (peerRotation), a lone peer at once.
const (
	phonePeerCount             = 4
	phoneExtraAccountPeerCount = 1
	maxPhonePeerTarget         = 8
	// How often a phone looks whether its dialled peers are up, besides
	// each time one of its links comes up or goes down (peerEventLogger).
	// A ticker of the Go runtime: it runs only while the phone is awake.
	phonePeerCheckInterval = 5 * time.Second
	// A peer dialled this long that did not come up has failed: the next
	// candidate takes its place (a TLS link to a public peer is up in a
	// second or two, also over mobile data).
	phonePeerDialGrace = 8 * time.Second
	// A link that went down is dialled again by the core at once: it stays
	// beside its stand-ins this long, in case it is back first.
	phonePeerDropGrace = 30 * time.Second
	// With none of its peers up the phone most likely has no network: fresh
	// candidates come in waves, the first after phonePeerOfflineFirst (the
	// core redials the peers that just went down within two seconds), then
	// after phonePeerOfflineWave, doubling up to phonePeerOfflineWaveMax.
	// Each wave also has the core redial the peers it keeps at once: its
	// own waits between redials grow to an hour and, like every Go timer,
	// stand still while the phone sleeps, so after an outage a locked phone
	// would otherwise come back only long after the network did. The waves
	// go by the wall clock (the time asleep counts) and come due on the
	// first look after a wake.
	phonePeerOfflineFirst   = 5 * time.Second
	phonePeerOfflineWave    = 15 * time.Second
	phonePeerOfflineWaveMax = 15 * time.Minute
	// The app sends while no peer is up: the phone is awake (a wake after
	// an outage asks the mailboxes for mail), so the core redials every
	// peer at once, between the waves too, at most this often.
	phonePeerWakeRedialEvery = time.Minute
	// A node that only receives on a QUIC or WebSocket peer (no TLS peer
	// worked) dials a TLS peer again this often, and moves to it once up.
	phonePeerLightRetry = 15 * time.Minute
	// The key in the node config the app may add to ask for a number of
	// public peers (a node that only receives asks for fewer).
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

// lightPeer tells whether a link to uri wakes the radio no more than the
// mesh's own traffic: TLS (or plain TCP). QUIC sends a keepalive of its own
// every 20 s; a phone dials QUIC and WebSocket peers only behind every TLS
// one.
func lightPeer(uri string) bool {
	scheme := peerScheme(uri)
	return scheme == "tls" || scheme == "tcp"
}

// lightFirst is peers with the light ones first, in their order otherwise.
func lightFirst(peers []string) []string {
	sort.SliceStable(peers, func(i, j int) bool {
		return lightPeer(peers[i]) && !lightPeer(peers[j])
	})
	return peers
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

// samePeers reports whether a and b list the same peers in the same order.
func samePeers(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// peerRotation picks which of a pool a phone dials and keeps target of them
// up: a dialled peer that goes down gets stand-ins from the pool at once
// (one more than missing, so one dead candidate costs no extra wait), a
// candidate that does not come up within phonePeerDialGrace is replaced by
// the next, and once target are up again the rest is let go. With none up
// (no network, most likely) fresh candidates come only in waves that thin
// out, so a phone without network does not dial round and round.
type peerRotation struct {
	pool   []string
	target int
	// Where in the pool the next candidate is taken.
	next int
	// When each dialled peer was first dialled, whether it was up since
	// then, and since when it is down.
	dialledAt map[string]time.Time
	wasUp     map[string]bool
	downSince map[string]time.Time
	// The public peers a transit hold set aside (transit_guard.go): while it
	// holds, candidates only when the pool has nothing else.
	aside map[string]bool
	// No dialled peer up since offlineSince (zero: some are up); the next
	// wave of fresh candidates comes at nextWave, after waves of them.
	offlineSince time.Time
	nextWave     time.Time
	waves        int
	// When the core last redialled every peer (a wave, or a wake).
	lastRedial time.Time
	// Peers that failed (did not come up, or stayed down) since a peer was
	// last up after a time with none: a node that only receives (target 1)
	// dials QUIC or WebSocket peers only once every TLS peer is among them,
	// and then a TLS peer again at nextLight.
	failed    map[string]bool
	nextLight time.Time
}

// lightOnly tells whether the rotation keeps to TLS peers while one may
// work: a node with one peer (one that only receives, or holds) keeps that
// link for hours with the phone locked.
func (r *peerRotation) lightOnly() bool {
	return r.target == 1
}

// redialOnWake reports whether the core should redial every peer now that
// the app sends while none of the dialled peers is up (redialled at most
// every phonePeerWakeRedialEvery, waves included).
func (r *peerRotation) redialOnWake(now time.Time) bool {
	if r.offlineSince.IsZero() || now.Sub(r.lastRedial) < phonePeerWakeRedialEvery {
		return false
	}
	r.lastRedial = now
	return true
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
	lightFirst(r.pool)
	r.next = 0
	r.dialledAt = make(map[string]time.Time)
	r.wasUp = make(map[string]bool)
	r.downSince = make(map[string]time.Time)
	r.failed = make(map[string]bool)
	r.nextLight = time.Time{}
	r.offlineSince = time.Time{}
	r.waves = 0
}

// initial is what to dial first: the first target of the pool.
func (r *peerRotation) initial() []string {
	picked := firstPeers(r.pool, r.target)
	if len(r.pool) > 0 {
		r.next = len(picked) % len(r.pool)
	}
	return picked
}

// setAside keeps peers from being candidates (nil: none any more).
func (r *peerRotation) setAside(peers []string) {
	if len(peers) == 0 {
		r.aside = nil
		return
	}
	r.aside = make(map[string]bool, len(peers))
	for _, peer := range peers {
		r.aside[peer] = true
	}
}

// offlineWait is how long the wave after waves waves waits.
func offlineWait(waves int) time.Duration {
	if waves > 10 {
		return phonePeerOfflineWaveMax
	}
	wait := phonePeerOfflineWave << waves
	if wait > phonePeerOfflineWaveMax {
		return phonePeerOfflineWaveMax
	}
	return wait
}

// note takes what is dialled now and which of it is up, and forgets the
// peers no longer dialled.
func (r *peerRotation) note(now time.Time, dialled []string, up func(string) bool) {
	seen := make(map[string]bool, len(dialled))
	for _, peer := range dialled {
		seen[peer] = true
		if _, ok := r.dialledAt[peer]; !ok {
			r.dialledAt[peer] = now
		}
		if up(peer) {
			r.wasUp[peer] = true
			delete(r.downSince, peer)
		} else if _, ok := r.downSince[peer]; !ok {
			r.downSince[peer] = now
		}
	}
	for peer := range r.dialledAt {
		if !seen[peer] {
			delete(r.dialledAt, peer)
			delete(r.wasUp, peer)
			delete(r.downSince, peer)
		}
	}
}

// check takes one look at now: dialled is what the phone dials and up tells
// which of those are up. It returns what to dial from now on, whether that
// differs, and whether a wave without network is due (the core should then
// redial every peer at once, also the ones it keeps).
func (r *peerRotation) check(now time.Time, dialled []string, up func(string) bool) ([]string, bool, bool) {
	r.note(now, dialled, up)
	var upNow, dropped, pending, failed []string
	for _, peer := range dialled {
		switch {
		case up(peer):
			upNow = append(upNow, peer)
		case r.wasUp[peer] && now.Sub(r.downSince[peer]) < phonePeerDropGrace:
			dropped = append(dropped, peer)
		case !r.wasUp[peer] && now.Sub(r.dialledAt[peer]) < phonePeerDialGrace:
			pending = append(pending, peer)
		default:
			failed = append(failed, peer)
			r.failed[peer] = true
		}
	}
	if len(upNow) > 0 && !r.offlineSince.IsZero() {
		// Up again after a time with none: what failed meanwhile failed
		// for want of a network, most likely.
		clear(r.failed)
	}
	for _, peer := range upNow {
		delete(r.failed, peer)
	}
	if len(upNow) >= r.target {
		// Enough are up: the stand-ins and the peers that stay down go.
		r.offlineSince = time.Time{}
		r.waves = 0
		out := firstPeers(lightFirst(upNow), r.target)
		if !r.lightOnly() || lightPeer(out[0]) {
			r.nextLight = time.Time{}
		} else {
			out = r.backToLight(now, out, pending, dialled)
		}
		return out, !samePeers(out, dialled), false
	}
	missing := r.target - len(upNow) - len(pending)
	wave := false
	if len(upNow) == 0 {
		if r.offlineSince.IsZero() {
			r.offlineSince = now
			r.nextWave = now.Add(phonePeerOfflineFirst)
			if r.target == 1 && len(dropped) > 0 {
				// The one peer of a node that only receives went down: most
				// likely that peer, not the network (a network that goes
				// takes every link). Its stand-ins go out now, while the
				// packet that ended the link keeps the phone awake.
				r.nextWave = now
			}
			r.waves = 0
		}
		if now.Before(r.nextWave) {
			return dialled, false, false
		}
		r.nextWave = now.Add(offlineWait(r.waves))
		r.waves++
		r.lastRedial = now
		wave = true
		if missing > 0 && r.target == 1 {
			// A node with one peer dials two candidates a wave, as one with
			// two does: a dead one does not cost it a wave.
			missing++
		}
	} else {
		r.offlineSince = time.Time{}
		r.waves = 0
		if missing > 0 && r.target > 1 {
			// One more than missing: a dead candidate costs no dial grace.
			missing++
		}
	}
	used := make(map[string]bool, len(dialled))
	for _, peer := range dialled {
		used[peer] = true
	}
	out := make([]string, 0, 2*r.target)
	out = append(out, upNow...)
	out = append(out, dropped...)
	out = append(out, pending...)
	for ; missing > 0; missing-- {
		candidate, ok := r.candidate(used)
		if !ok {
			break
		}
		used[candidate] = true
		r.dialledAt[candidate] = now
		out = append(out, candidate)
	}
	// Peers that failed stay only while nothing else is left to dial.
	for _, peer := range failed {
		if len(out) >= r.target {
			break
		}
		out = append(out, peer)
	}
	// Never more than twice the target at once: the peers that went down
	// longest ago go first.
	for len(out) > 2*r.target && len(dropped) > 0 {
		out, _ = withoutPeer(out, dropped[0])
		dropped = dropped[1:]
	}
	out = firstPeers(out, 2*r.target)
	return out, !samePeers(out, dialled), wave
}

// fill is dialled with candidates of the pool added until there are target
// (all of the pool when it has fewer).
func (r *peerRotation) fill(dialled []string) []string {
	used := make(map[string]bool, len(dialled))
	for _, peer := range dialled {
		used[peer] = true
	}
	out := append([]string(nil), dialled...)
	for len(out) < r.target {
		candidate, ok := r.candidate(used)
		if !ok {
			break
		}
		used[candidate] = true
		out = append(out, candidate)
	}
	return out
}

// backToLight is what a node with one peer, up on a QUIC or WebSocket peer
// (out), dials: beside it a TLS peer under way, or a new one once
// phonePeerLightRetry passed since it settled there; the TLS peer takes
// over once up (check keeps the light ones first).
func (r *peerRotation) backToLight(now time.Time, out, pending, dialled []string) []string {
	for _, peer := range pending {
		if lightPeer(peer) {
			return append(out, peer)
		}
	}
	if r.nextLight.IsZero() {
		r.nextLight = now.Add(phonePeerLightRetry)
		return out
	}
	if now.Before(r.nextLight) {
		return out
	}
	r.nextLight = now.Add(phonePeerLightRetry)
	used := make(map[string]bool, len(dialled))
	for _, peer := range dialled {
		used[peer] = true
	}
	if peer, ok := r.pick(used, func(peer string) bool {
		return lightPeer(peer) && !r.failed[peer] && !r.aside[peer]
	}); ok {
		r.dialledAt[peer] = now
		out = append(out, peer)
	}
	return out
}

// candidate is the next peer of the pool that is not dialled already, and
// not set aside unless the pool has nothing else (a holding phone must not
// be left without a way to the mesh). A node with one peer takes a TLS
// peer while one has not failed, then any that has not failed, then any.
func (r *peerRotation) candidate(used map[string]bool) (string, bool) {
	for _, skipAside := range []bool{true, false} {
		allowed := func(peer string) bool { return !skipAside || !r.aside[peer] }
		if r.lightOnly() {
			if peer, ok := r.pick(used, func(peer string) bool {
				return allowed(peer) && lightPeer(peer) && !r.failed[peer]
			}); ok {
				return peer, true
			}
			if peer, ok := r.pick(used, func(peer string) bool {
				return allowed(peer) && !r.failed[peer]
			}); ok {
				return peer, true
			}
		}
		if peer, ok := r.pick(used, allowed); ok {
			return peer, true
		}
		if len(r.aside) == 0 {
			break
		}
	}
	return "", false
}

// pick is the next peer of the pool from r.next on that is not used and
// that ok takes.
func (r *peerRotation) pick(used map[string]bool, ok func(string) bool) (string, bool) {
	for i := 0; i < len(r.pool); i++ {
		index := (r.next + i) % len(r.pool)
		peer := r.pool[index]
		if used[peer] || !ok(peer) {
			continue
		}
		r.next = (index + 1) % len(r.pool)
		return peer, true
	}
	return "", false
}
