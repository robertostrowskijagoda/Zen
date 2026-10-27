package main

import (
	"net/url"
	"sync"
	"time"
)

// A phone passes strangers' traffic on only up to a budget. Every node with
// two or more peerings may become the shortest way between them, and
// ironwood weighs links by their latency: a link to a computer on the same
// Wi-Fi (a local link, or the friend's bridge reached through the home
// router) costs a millisecond or two against tens for an internet peer, so
// a home computer that is a bridge with many peers routes a share of the
// strangers' traffic it carries through the phone, which sends it out
// again to its own public peers. Nothing in Yggdrasil caps that: one night
// it was about 0.6-0.9 MB/s in and as much out for most of an hour.
//
// The guard takes the transit estimate of every window (traffic_meter.go).
// A window above phoneTransitRateLimit, or transit in the last hour above
// phoneTransitHourBudget, makes the phone keep a single peering for a
// while: a node with one peering is nobody's shortcut. It keeps one public
// peer (or, with none up, one device nearby), sets aside its other public
// peers, friends' bridges and links nearby, and takes them back when the
// hold ends. What a friend nearby sends or gets through the phone itself
// is no transit (local_link_traffic.go), and the link to a friend the
// phone talks with stays through a hold. Holds grow (transitHoldBase, doubled for every hold within
// transitHoldMemory, at most transitHoldMax), so a home that keeps routing
// through the phone costs at most a window or two of transit per hold.
const (
	// How often a phone samples its peerings for the guard; a window is
	// trafficWindow long.
	transitWatchInterval = 10 * time.Second
	// Transit over one window that starts a hold, bytes per second.
	phoneTransitRateLimit = 64 * 1024
	// Transit within the last hour that starts a hold, bytes.
	phoneTransitHourBudget = 32 << 20
	transitHourSpan        = time.Hour
	transitHoldBase        = 30 * time.Minute
	transitHoldMax         = 6 * time.Hour
	// Holds within this long of the last one count for the next one's
	// length.
	transitHoldMemory = 24 * time.Hour
)

// transitSpan is the transit of one window that ended at at.
type transitSpan struct {
	at    time.Time
	bytes uint64
}

// transitGuard decides when a phone holds. The zero value is ready to use;
// it is safe for concurrent use.
type transitGuard struct {
	mu sync.Mutex
	// Windows of the last transitHourSpan that had transit.
	spans []transitSpan
	// The hold running now ends at holdUntil (zero: none).
	holdUntil time.Time
	// Holds within transitHoldMemory of each other, and the last one.
	recent   int
	lastHold time.Time
	// Holds and transit since the node started, for diagnostics.
	holds       int
	lastRate    uint64
	totalBytes  uint64
	heldSeconds int64
}

func (guard *transitGuard) pruneLocked(now time.Time) {
	keep := guard.spans[:0]
	for _, span := range guard.spans {
		if now.Sub(span.at) < transitHourSpan {
			keep = append(keep, span)
		}
	}
	guard.spans = keep
}

func (guard *transitGuard) hourBytesLocked() uint64 {
	var total uint64
	for _, span := range guard.spans {
		total += span.bytes
	}
	return total
}

// observe takes a window that ended at now with bytes of transit at rate
// (bytes per second). It returns how long a hold that starts now lasts, or
// 0 when none starts (no reason, or one runs already).
func (guard *transitGuard) observe(now time.Time, bytes, rate uint64) time.Duration {
	guard.mu.Lock()
	defer guard.mu.Unlock()
	guard.pruneLocked(now)
	if bytes > 0 {
		guard.spans = append(guard.spans, transitSpan{at: now, bytes: bytes})
		guard.totalBytes += bytes
	}
	if !guard.holdUntil.IsZero() && now.Before(guard.holdUntil) {
		return 0
	}
	overRate := rate >= phoneTransitRateLimit
	// The hour's budget counts only while transit goes on: an hour that was
	// over it stops a phone that passes anything again, not one that is
	// quiet now.
	overHour := bytes > 0 && guard.hourBytesLocked() >= phoneTransitHourBudget
	if !overRate && !overHour {
		return 0
	}
	if !guard.lastHold.IsZero() && now.Sub(guard.lastHold) > transitHoldMemory {
		guard.recent = 0
	}
	hold := transitHoldBase
	for i := 0; i < guard.recent && hold < transitHoldMax; i++ {
		hold *= 2
	}
	hold = min(hold, transitHoldMax)
	guard.recent++
	guard.holds++
	guard.lastHold = now
	guard.lastRate = rate
	guard.holdUntil = now.Add(hold)
	guard.heldSeconds += int64(hold / time.Second)
	return hold
}

// due reports whether the hold that ran has ended by now; it then counts
// as over.
func (guard *transitGuard) due(now time.Time) bool {
	guard.mu.Lock()
	defer guard.mu.Unlock()
	if guard.holdUntil.IsZero() || now.Before(guard.holdUntil) {
		return false
	}
	guard.holdUntil = time.Time{}
	return true
}

// snapshot is what the guard knows, for trafficState.
func (guard *transitGuard) snapshot(now time.Time) map[string]any {
	guard.mu.Lock()
	defer guard.mu.Unlock()
	guard.pruneLocked(now)
	var left int64
	if !guard.holdUntil.IsZero() && now.Before(guard.holdUntil) {
		left = int64(guard.holdUntil.Sub(now) / time.Second)
	}
	return map[string]any{
		"hourBytes":        guard.hourBytesLocked(),
		"guardedBytes":     guard.totalBytes,
		"holds":            guard.holds,
		"holdSecondsLeft":  left,
		"lastHoldRate":     guard.lastRate,
		"rateLimit":        uint64(phoneTransitRateLimit),
		"hourBudget":       uint64(phoneTransitHourBudget),
		"heldSecondsTotal": guard.heldSeconds,
	}
}

// transitLink is a live link nearby, as the hold looks at it.
type transitLink struct {
	address string
	peerURI string
	own     bool
	since   time.Time
}

// transitHold is what a phone set aside while it holds.
type transitHold struct {
	// The public peer kept, or the device nearby kept (its mesh address);
	// at most one of them is set.
	keepPublic string
	keepLink   string
	// How many public peers the phone dialled before.
	target int
	// Configured peers other than public ones (friends' bridges, devices
	// on the LAN) taken out, and ones the app added meanwhile.
	extras []string
}

// chooseTransitKeep picks the one peering a holding phone keeps: the first
// of its public peers that is up, else the first device nearby that is up
// (own devices and the oldest links first), else the first public peer it
// dials (it may come up), else the first device nearby.
func chooseTransitKeep(public []string, links []transitLink, up map[string]bool) (keepPublic, keepLink string) {
	for _, peer := range public {
		if up[peerURIBase(peer)] {
			return peer, ""
		}
	}
	for _, link := range links {
		if up[peerURIBase(link.peerURI)] {
			return "", link.address
		}
	}
	if len(public) > 0 {
		return public[0], ""
	}
	if len(links) > 0 {
		return "", links[0].address
	}
	return "", ""
}

// startTransitWatch samples a phone's peerings for its guard. A ticker of
// the Go runtime: it does not wake a sleeping phone, and transit keeps one
// awake anyway.
func (node *bridgeNode) startTransitWatch() {
	if node.transitGuard == nil || node.transitStop == nil {
		return
	}
	go func() {
		ticker := time.NewTicker(transitWatchInterval)
		defer ticker.Stop()
		for {
			select {
			case <-node.transitStop:
				return
			case <-ticker.C:
			}
			node.sampleTraffic()
		}
	}()
}

func (node *bridgeNode) stopTransitWatch() {
	if node.transitStop == nil {
		return
	}
	node.transitStopOnce.Do(func() { close(node.transitStop) })
}

// observeTransit hands a window's transit to the guard and starts a hold
// when it says so.
func (node *bridgeNode) observeTransit(now time.Time, bytes, rate uint64) {
	guard := node.transitGuard
	if guard == nil {
		return
	}
	if hold := guard.observe(now, bytes, rate); hold > 0 {
		node.beginTransitHold(hold, rate)
	}
}

// checkTransitHold ends a hold that ran out, and keeps a hold that kept a
// device nearby from leaving the phone with no peering once that link is
// gone: it then dials one public peer instead.
func (node *bridgeNode) checkTransitHold(now time.Time) {
	guard := node.transitGuard
	if guard == nil {
		return
	}
	if guard.due(now) {
		node.endTransitHold()
		return
	}
	keepLink, held := node.transitHoldLink()
	if !held || keepLink == "" {
		return
	}
	manager := node.existingLocalLinks()
	if manager != nil && manager.hasLink(keepLink) {
		return
	}
	node.transitHoldMu.Lock()
	if node.transitHold != nil {
		node.transitHold.keepLink = ""
	}
	node.transitHoldMu.Unlock()
	if manager != nil {
		manager.hold("")
	}
	if keeper := node.phonePeers; keeper != nil {
		keeper.mu.Lock()
		keeper.rotation.target = 1
		before := keeper.dialled
		after := keeper.rotation.fill(before)
		keeper.dialled = after
		keeper.mu.Unlock()
		node.swapPublicPeers(before, after)
	}
}

// transitHoldLink reports whether the node holds and which device nearby
// it keeps ("" none).
func (node *bridgeNode) transitHoldLink() (string, bool) {
	node.transitHoldMu.Lock()
	defer node.transitHoldMu.Unlock()
	if node.transitHold == nil {
		return "", false
	}
	return node.transitHold.keepLink, true
}

// configuredExtras are the configured peers that are not public ones.
func (node *bridgeNode) configuredExtras() []string {
	node.configMu.RLock()
	defer node.configMu.RUnlock()
	var extras []string
	for _, peer := range node.config.Peers {
		if !node.publicPeers[peer] {
			extras = append(extras, peer)
		}
	}
	return extras
}

// beginTransitHold makes the phone keep a single peering for hold.
func (node *bridgeNode) beginTransitHold(hold time.Duration, rate uint64) {
	// The manager's lock is never taken under transitHoldMu
	// (localLinkManager takes them the other way round).
	var links []transitLink
	if manager := node.existingLocalLinks(); manager != nil {
		links = manager.linkedDevices()
	}
	keepPublic, keepLink := chooseTransitKeep(node.dialledPublicPeers(), links, node.upPeers())
	state := &transitHold{keepPublic: keepPublic, keepLink: keepLink, extras: node.configuredExtras()}
	node.transitHoldMu.Lock()
	if node.transitHold != nil {
		node.transitHoldMu.Unlock()
		return
	}
	node.transitHold = state
	node.transitHoldMu.Unlock()

	if keeper := node.phonePeers; keeper != nil {
		keeper.mu.Lock()
		state.target = keeper.rotation.target
		keeper.rotation.target = 0
		var after []string
		if keepPublic != "" {
			keeper.rotation.target = 1
			after = []string{keepPublic}
		}
		before := keeper.dialled
		keeper.dialled = after
		keeper.mu.Unlock()
		node.swapPublicPeers(before, after)
	}
	for _, uri := range state.extras {
		if parsed, err := url.Parse(uri); err == nil {
			_ = node.core.RemovePeer(parsed, "")
		}
		node.updateConfiguredPeer(uri, false)
	}
	if manager := node.existingLocalLinks(); manager != nil {
		manager.hold(keepLink)
	}
	if node.logger != nil {
		node.logger.Warnf("about %d B/s of others' mesh traffic passed through this node; one peering only for %s",
			rate, hold)
	}
}

// endTransitHold takes back what a hold set aside.
func (node *bridgeNode) endTransitHold() {
	node.transitHoldMu.Lock()
	state := node.transitHold
	node.transitHold = nil
	node.transitHoldMu.Unlock()
	if state == nil {
		return
	}
	if keeper := node.phonePeers; keeper != nil {
		keeper.mu.Lock()
		keeper.rotation.target = state.target
		before := keeper.dialled
		after := keeper.rotation.fill(before)
		keeper.dialled = after
		keeper.mu.Unlock()
		node.swapPublicPeers(before, after)
	}
	for _, uri := range state.extras {
		parsed, err := url.Parse(uri)
		if err != nil {
			continue
		}
		if err := node.core.AddPeer(parsed, ""); err == nil {
			node.updateConfiguredPeer(uri, true)
		}
	}
	if manager := node.existingLocalLinks(); manager != nil {
		manager.release()
	}
	if node.logger != nil {
		node.logger.Infof("transit hold over: all peerings again")
	}
}

// deferDuringTransitHold keeps a peer the app adds while the phone holds
// for when the hold ends; reports whether it did.
func (node *bridgeNode) deferDuringTransitHold(uri string) bool {
	node.transitHoldMu.Lock()
	defer node.transitHoldMu.Unlock()
	state := node.transitHold
	if state == nil {
		return false
	}
	state.extras, _ = withoutPeer(state.extras, uri)
	state.extras = append(state.extras, uri)
	return true
}

// forgetDuringTransitHold drops a peer the app removes from what a hold set
// aside; reports whether it was there (and so not dialled).
func (node *bridgeNode) forgetDuringTransitHold(uri string) bool {
	node.transitHoldMu.Lock()
	defer node.transitHoldMu.Unlock()
	state := node.transitHold
	if state == nil {
		return false
	}
	var found bool
	state.extras, found = withoutPeer(state.extras, uri)
	return found
}

// transitGuardState is the guard and the hold, for trafficState.
func (node *bridgeNode) transitGuardState(now time.Time) map[string]any {
	state := node.transitGuard.snapshot(now)
	node.transitHoldMu.Lock()
	if hold := node.transitHold; hold != nil {
		state["holding"] = true
		state["setAside"] = len(hold.extras)
		state["keepsLink"] = hold.keepLink != ""
	} else {
		state["holding"] = false
	}
	node.transitHoldMu.Unlock()
	return state
}
