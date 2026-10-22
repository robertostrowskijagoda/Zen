package main

import (
	"net/url"
	"sync"
	"time"
)

// phonePeerKeeper is a phone node's share of the public pool: what it dials
// now and the rotation that swaps a peer that stays down (phone_peers.go).
type phonePeerKeeper struct {
	mu       sync.Mutex
	rotation *peerRotation
	dialled  []string
	stop     chan struct{}
	stopOnce sync.Once
}

func newPhonePeerKeeper(pool []string, target int) *phonePeerKeeper {
	rotation := newPeerRotation(pool, target)
	return &phonePeerKeeper{
		rotation: rotation,
		dialled:  rotation.initial(),
		stop:     make(chan struct{}),
	}
}

func (keeper *phonePeerKeeper) stopWatch() {
	keeper.stopOnce.Do(func() { close(keeper.stop) })
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

// watchPhonePeers swaps the phone's public peers that stay down for others
// of its pool. A ticker of the Go runtime: it does not wake a sleeping
// phone, it only runs while the phone is awake anyway.
func (node *bridgeNode) watchPhonePeers() {
	keeper := node.phonePeers
	if keeper == nil {
		return
	}
	ticker := time.NewTicker(phonePeerCheckInterval)
	defer ticker.Stop()
	for {
		select {
		case <-keeper.stop:
			return
		case <-ticker.C:
		}
		up := node.upPeers()
		keeper.mu.Lock()
		before := keeper.dialled
		after, changed := keeper.rotation.check(before, func(uri string) bool {
			return up[peerURIBase(uri)]
		})
		if changed {
			keeper.dialled = after
		}
		keeper.mu.Unlock()
		if changed {
			node.logger.Infof("public peers down for a while; dialling %d others of the pool", len(after))
			node.swapPublicPeers(before, after)
		}
	}
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
