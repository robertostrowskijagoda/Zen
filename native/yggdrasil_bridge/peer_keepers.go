package main

import (
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// phonePeerKeeper is a phone node's share of the public pool: what it dials
// now and the rotation that replaces a peer that goes down (phone_peers.go).
type phonePeerKeeper struct {
	mu       sync.Mutex
	rotation *peerRotation
	dialled  []string
	// Something worth a look now (lookNow).
	events   chan struct{}
	stop     chan struct{}
	stopOnce sync.Once
}

func newPhonePeerKeeper(pool []string, target int) *phonePeerKeeper {
	rotation := newPeerRotation(pool, target)
	return &phonePeerKeeper{
		rotation: rotation,
		dialled:  rotation.initial(),
		events:   make(chan struct{}, 1),
		stop:     make(chan struct{}),
	}
}

func (keeper *phonePeerKeeper) stopWatch() {
	keeper.stopOnce.Do(func() { close(keeper.stop) })
}

// lookNow has the keeper look at its peers now: one of the node's links came
// up or went down, or the app sends something (so the phone is awake, and a
// wave without network that came due while it slept goes out at once). It
// never blocks.
func (keeper *phonePeerKeeper) lookNow() {
	if keeper == nil {
		return
	}
	select {
	case keeper.events <- struct{}{}:
	default:
	}
}

// peerEventLogger passes the core's log on and tells the phone's keeper
// each time a link comes up or goes down (the core's "Connected ..." and
// "Disconnected ..." lines, link.go in yggdrasil-go; it has no other hook).
// The packet that ends a link wakes a sleeping phone, so the stand-ins are
// dialled right then, not at the next look. Should the core word its lines
// otherwise, the keeper still looks every phonePeerCheckInterval.
type peerEventLogger struct {
	core.Logger
	keeper *phonePeerKeeper
}

func (logger peerEventLogger) Infof(format string, args ...interface{}) {
	logger.Logger.Infof(format, args...)
	if strings.HasPrefix(format, "Connected ") || strings.HasPrefix(format, "Disconnected ") {
		logger.keeper.lookNow()
	}
}

// withPeerEvents is logger for the core of a node: on a phone it also tells
// keeper about links that come and go.
func withPeerEvents(logger core.Logger, keeper *phonePeerKeeper) core.Logger {
	if keeper == nil {
		return logger
	}
	return peerEventLogger{Logger: logger, keeper: keeper}
}

// upPeers are the peerings that are up now, as GetPeers lists them.
func (node *bridgeNode) upPeers() map[string]bool {
	up := make(map[string]bool)
	for _, info := range node.core.GetPeers() {
		if info.Up {
			up[peerURIBase(info.URI)] = true
		}
	}
	return up
}

// watchPhonePeers keeps the phone's public peers up: it looks each time a
// link comes up or goes down, and every phonePeerCheckInterval. A ticker of
// the Go runtime: it does not wake a sleeping phone, it only runs while the
// phone is awake anyway.
func (node *bridgeNode) watchPhonePeers() {
	keeper := node.phonePeers
	if keeper == nil {
		return
	}
	ticker := time.NewTicker(phonePeerCheckInterval)
	defer ticker.Stop()
	var sampled time.Time
	for {
		select {
		case <-keeper.stop:
			return
		case <-ticker.C:
		case <-keeper.events:
		}
		now := time.Now()
		if now.Sub(sampled) >= time.Minute {
			sampled = now
			node.sampleTraffic()
		}
		// The wall clock: the time the phone slept counts.
		node.checkPhonePeers(now.Round(0))
	}
}

// checkPhonePeers takes one look at the phone's public peers and dials
// what its rotation says.
func (node *bridgeNode) checkPhonePeers(now time.Time) {
	keeper := node.phonePeers
	if keeper == nil {
		return
	}
	up := node.upPeers()
	keeper.mu.Lock()
	before := keeper.dialled
	after, changed, wave := keeper.rotation.check(now, before, func(uri string) bool {
		return up[peerURIBase(uri)]
	})
	if changed {
		keeper.dialled = after
	}
	keeper.mu.Unlock()
	switch {
	case changed:
		node.logger.Infof("public peers: %d dialled, %d of them up before", len(after), countUp(before, up))
		// Redials every peer at once too.
		node.swapPublicPeers(before, after)
	case wave:
		node.core.RetryPeersNow()
	}
}

// countUp is how many of peers are up.
func countUp(peers []string, up map[string]bool) int {
	count := 0
	for _, peer := range peers {
		if up[peerURIBase(peer)] {
			count++
		}
	}
	return count
}

// swapPublicPeers stops dialling the public peers of before that are not in
// after and dials those of after that are new, leaving every other peer
// (friends' bridges, devices on the LAN) alone. Returns how many were added
// and removed.
func (node *bridgeNode) swapPublicPeers(before, after []string) (int, int) {
	keep := make(map[string]bool, len(after))
	for _, peer := range after {
		keep[peer] = true
	}
	had := make(map[string]bool, len(before))
	for _, peer := range before {
		had[peer] = true
	}
	var drop, add []string
	for _, peer := range before {
		if !keep[peer] {
			drop = append(drop, peer)
		}
	}
	for _, peer := range after {
		if !had[peer] {
			add = append(add, peer)
		}
	}
	node.configMu.Lock()
	dropSet := make(map[string]bool, len(drop))
	for _, peer := range drop {
		dropSet[peer] = true
	}
	configured := make(map[string]bool, len(node.config.Peers))
	kept := make([]string, 0, len(node.config.Peers)+len(add))
	for _, peer := range node.config.Peers {
		if dropSet[peer] {
			continue
		}
		configured[peer] = true
		kept = append(kept, peer)
	}
	for _, peer := range add {
		if !configured[peer] {
			kept = append(kept, peer)
		}
	}
	node.config.Peers = kept
	public := make(map[string]bool, len(after))
	for _, peer := range after {
		public[peer] = true
	}
	node.publicPeers = public
	node.configMu.Unlock()

	for _, peer := range drop {
		if parsed, err := url.Parse(peer); err == nil {
			// A peer the core no longer knows is gone already.
			_ = node.core.RemovePeer(parsed, "")
		}
	}
	added := 0
	for _, peer := range add {
		parsed, err := url.Parse(peer)
		if err != nil {
			continue
		}
		if err := node.core.AddPeer(parsed, ""); err != nil {
			node.logger.Warnf("public peer %s not added: %v", peer, err)
			continue
		}
		added++
	}
	if len(drop) > 0 || added > 0 {
		node.core.RetryPeersNow()
	}
	return added, len(drop)
}

// dialledPublicPeers are the public peers in the node's list now, in order.
func (node *bridgeNode) dialledPublicPeers() []string {
	node.configMu.RLock()
	defer node.configMu.RUnlock()
	peers := make([]string, 0, len(node.publicPeers))
	for _, peer := range node.config.Peers {
		if node.publicPeers[peer] {
			peers = append(peers, peer)
		}
	}
	return peers
}

// onDesktopBattery reports whether this computer's node is in its battery
// mode now (false on phones).
func (node *bridgeNode) onDesktopBattery() bool {
	saver := node.power
	if saver == nil {
		return false
	}
	saver.mu.Lock()
	defer saver.mu.Unlock()
	return saver.onBattery
}

// watchDesktopPower follows the power source of a computer.
func (node *bridgeNode) watchDesktopPower() {
	saver := node.power
	if saver == nil {
		return
	}
	ticker := time.NewTicker(desktopPowerCheckInterval)
	defer ticker.Stop()
	for {
		select {
		case <-saver.stop:
			return
		case <-ticker.C:
		}
		node.setDesktopOnBattery(onBatteryPower())
	}
}

// setDesktopOnBattery switches the computer between its battery mode (no
// bridge, desktopBatteryPeerCount public peers) and the full one.
func (node *bridgeNode) setDesktopOnBattery(onBattery bool) {
	saver := node.power
	if saver == nil {
		return
	}
	saver.mu.Lock()
	if saver.onBattery == onBattery {
		saver.mu.Unlock()
		return
	}
	saver.onBattery = onBattery
	before := node.dialledPublicPeers()
	var after []string
	if onBattery {
		saver.full = append([]string(nil), before...)
		after = firstPeers(before, desktopBatteryPeerCount)
	} else {
		after = append([]string(nil), saver.full...)
		if len(after) == 0 {
			after = before
		}
	}
	saver.mu.Unlock()
	if onBattery {
		node.logger.Infof("on battery: no bridge, %d public peers", len(after))
	} else {
		node.logger.Infof("plugged in: bridge again, %d public peers", len(after))
	}
	for _, guard := range node.peerGuards {
		guard.setPaused(onBattery)
	}
	node.swapPublicPeers(before, after)
	node.limitBridges(onBattery)
}

// dialledBridges are the friends' bridges in the node's list now (every
// configured peer that is neither a public one nor on the local network),
// in order.
func (node *bridgeNode) dialledBridges() []string {
	node.configMu.RLock()
	defer node.configMu.RUnlock()
	var bridges []string
	for _, peer := range node.config.Peers {
		if !node.publicPeers[peer] && !isLocalPeerURI(peer) {
			bridges = append(bridges, peer)
		}
	}
	return bridges
}

// splitBridges keeps the first keep of bridges and sets the rest aside.
func splitBridges(bridges []string, keep int) (kept, aside []string) {
	if keep < 0 {
		keep = 0
	}
	if len(bridges) <= keep {
		return append([]string(nil), bridges...), nil
	}
	return append([]string(nil), bridges[:keep]...),
		append([]string(nil), bridges[keep:]...)
}

// withoutPeer is peers without uri.
func withoutPeer(peers []string, uri string) ([]string, bool) {
	out := make([]string, 0, len(peers))
	found := false
	for _, peer := range peers {
		if peer == uri {
			found = true
			continue
		}
		out = append(out, peer)
	}
	return out, found
}

// limitBridges keeps at most desktopBatteryBridgeCount friends' bridges
// dialled while a computer runs on battery, and dials the ones set aside
// again once it is plugged in.
func (node *bridgeNode) limitBridges(onBattery bool) {
	saver := node.power
	if saver == nil {
		return
	}
	if onBattery {
		_, aside := splitBridges(node.dialledBridges(), desktopBatteryBridgeCount)
		if len(aside) == 0 {
			return
		}
		saver.mu.Lock()
		for _, uri := range aside {
			saver.bridges, _ = withoutPeer(saver.bridges, uri)
			saver.bridges = append(saver.bridges, uri)
		}
		saver.mu.Unlock()
		for _, uri := range aside {
			if parsed, err := url.Parse(uri); err == nil {
				_ = node.core.RemovePeer(parsed, "")
			}
			node.updateConfiguredPeer(uri, false)
		}
		node.logger.Infof("on battery: %d friends' bridge(s) set aside", len(aside))
		return
	}
	saver.mu.Lock()
	again := saver.bridges
	saver.bridges = nil
	saver.mu.Unlock()
	for _, uri := range again {
		parsed, err := url.Parse(uri)
		if err != nil {
			continue
		}
		if err := node.core.AddPeer(parsed, ""); err == nil {
			node.updateConfiguredPeer(uri, true)
		}
	}
}

// setBridgeAside keeps a friend's bridge asked for while the computer runs
// on battery and already dials its share for later instead of dialling it.
// Reports whether it did.
func (node *bridgeNode) setBridgeAside(uri string) bool {
	saver := node.power
	if saver == nil || !node.onDesktopBattery() {
		return false
	}
	dialled := node.dialledBridges()
	for _, peer := range dialled {
		if peer == uri {
			return false
		}
	}
	if len(dialled) < desktopBatteryBridgeCount {
		return false
	}
	saver.mu.Lock()
	defer saver.mu.Unlock()
	saver.bridges, _ = withoutPeer(saver.bridges, uri)
	saver.bridges = append(saver.bridges, uri)
	return true
}

// forgetBridgeAside drops uri from the bridges set aside; reports whether
// it was there (and so not dialled).
func (node *bridgeNode) forgetBridgeAside(uri string) bool {
	saver := node.power
	if saver == nil {
		return false
	}
	saver.mu.Lock()
	defer saver.mu.Unlock()
	var found bool
	saver.bridges, found = withoutPeer(saver.bridges, uri)
	return found
}

// limitPublicPeers is what a node dials of desired, the public peers asked
// for now: a phone its share of the pool, a computer on battery a few, a
// plugged-in computer all of them.
func (node *bridgeNode) limitPublicPeers(desired []string) []string {
	if keeper := node.phonePeers; keeper != nil {
		keeper.mu.Lock()
		defer keeper.mu.Unlock()
		keeper.rotation.setPool(desired)
		keeper.dialled = keeper.rotation.initial()
		return append([]string(nil), keeper.dialled...)
	}
	if saver := node.power; saver != nil {
		saver.mu.Lock()
		defer saver.mu.Unlock()
		if saver.onBattery {
			saver.full = append([]string(nil), desired...)
			return firstPeers(desired, desktopBatteryPeerCount)
		}
	}
	return desired
}
