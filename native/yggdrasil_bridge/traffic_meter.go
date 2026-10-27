package main

import (
	"sync"
	"sync/atomic"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// How much goes over a node's peerings, and how much of it is the node's own
// (signals, call media) rather than strangers' traffic passing through.
// Every Yggdrasil node forwards: ironwood sends a packet to whichever peer
// takes it closest to its destination, weighted by link latency, so a node
// with two or more peerings can become the shortest way between them. A
// phone dials several public peers and may link with devices nearby
// (local_link.go), whose LAN link looks almost free to the router; nothing
// in Yggdrasil keeps such a node a leaf. Strangers' traffic shows as bytes
// that come in on one peering and go out on another: the meter takes what
// the peerings carried in each direction, removes the node's own packets
// (with room for the mesh's headers) and Yggdrasil's own upkeep, and calls
// what is left in both directions alike transit. An estimate, for
// diagnostics (the app's log, normalizeNodeState's "traffic") and for a
// phone's limit on it (transit_guard.go).
const (
	// Mesh headers around one of the node's own packets on a peering
	// (keys, path, session and link framing), counted generously so an
	// own packet is never taken for transit.
	trafficPacketOverhead = 192
	// Yggdrasil's own upkeep per peering (keepalives, tree and path
	// messages), bytes per second, allowed for the same reason.
	trafficLinkUpkeep = 1024
	// Shortest window a transit rate is taken over.
	trafficWindow = 30 * time.Second
	// Transit rate a phone logs as unusual, bytes per second.
	phoneTransitNotice = 32 * 1024
)

// ownTraffic counts the IPv6 packets the node itself reads from and writes
// to the mesh. The zero value is ready to use; it is safe for concurrent
// use.
type ownTraffic struct {
	signalRx  atomic.Uint64
	signalTx  atomic.Uint64
	relayRx   atomic.Uint64
	relayTx   atomic.Uint64
	otherRx   atomic.Uint64
	packetsRx atomic.Uint64
	packetsTx atomic.Uint64
	// Traffic of the devices at the other end of local links (a friend's
	// own packets) that the node passed on (local_link_traffic.go).
	friendForwarded atomic.Uint64
}

// received counts a packet of size bytes the node read, sent to port.
func (own *ownTraffic) received(port uint16, size int) {
	own.packetsRx.Add(1)
	switch port {
	case yggSignalPort:
		own.signalRx.Add(uint64(size))
	case yggRelayPort:
		own.relayRx.Add(uint64(size))
	default:
		own.otherRx.Add(uint64(size))
	}
}

// sent counts a packet of size bytes the node wrote (call media when relay).
func (own *ownTraffic) sent(size int, relay bool) {
	own.packetsTx.Add(1)
	if relay {
		own.relayTx.Add(uint64(size))
	} else {
		own.signalTx.Add(uint64(size))
	}
}

func (own *ownTraffic) totals() (rx, tx, packetsRx, packetsTx uint64) {
	rx = own.signalRx.Load() + own.relayRx.Load() + own.otherRx.Load()
	tx = own.signalTx.Load() + own.relayTx.Load()
	return rx, tx, own.packetsRx.Load(), own.packetsTx.Load()
}

// writeMesh writes one of the node's own packets to the mesh and counts it.
func (node *bridgeNode) writeMesh(packet []byte, relay bool) error {
	if _, err := node.iprwc.Write(packet); err != nil {
		return err
	}
	node.traffic.sent(len(packet), relay)
	return nil
}

// trafficLink is what a peering had carried when it was last looked at.
type trafficLink struct {
	rx, tx uint64
	uptime time.Duration
}

// trafficTotals are byte counts since the node started.
type trafficTotals struct {
	peerRx, peerTx             uint64
	ownRx, ownTx               uint64
	ownPacketsRx, ownPacketsTx uint64
	// A friend's own traffic over a local link, passed on.
	friend uint64
}

// peerTrafficMeter adds up what the node's peerings carried, also of
// peerings that are gone since, and estimates transit per window. The zero
// value is ready to use; it is safe for concurrent use.
type peerTrafficMeter struct {
	mu    sync.Mutex
	links map[string]trafficLink
	// Bytes over public peerings and over local ones (devices nearby, the
	// LAN, loopback) since the node started.
	publicRx, publicTx uint64
	localRx, localTx   uint64
	// The window that is being measured: when it started and the totals
	// then.
	windowStart time.Time
	windowBase  trafficTotals
	// Transit since the node started, and over the last whole window.
	transitBytes  uint64
	transitLast   uint64
	transitRate   uint64
	transitWindow time.Duration
}

// sample takes in the peerings as GetPeers lists them now and the node's
// own totals. It returns the transit rate of a window that ended now (and
// true), or false while the window runs.
func (meter *peerTrafficMeter) sample(peers []core.PeerInfo, own *ownTraffic, now time.Time) (uint64, bool) {
	ownRx, ownTx, ownPacketsRx, ownPacketsTx := own.totals()
	meter.mu.Lock()
	defer meter.mu.Unlock()
	if meter.links == nil {
		meter.links = make(map[string]trafficLink)
	}
	seen := make(map[string]bool, len(peers))
	for _, peer := range peers {
		key := peer.URI
		if peer.Inbound {
			key = "in|" + key
		}
		seen[key] = true
		last, known := meter.links[key]
		if known && (peer.RXBytes < last.rx || peer.TXBytes < last.tx || peer.Uptime < last.uptime) {
			// The same address, a new connection.
			known = false
		}
		if !known {
			last = trafficLink{}
		}
		rx := peer.RXBytes - last.rx
		tx := peer.TXBytes - last.tx
		if isLocalPeerURI(peer.URI) {
			meter.localRx += rx
			meter.localTx += tx
		} else {
			meter.publicRx += rx
			meter.publicTx += tx
		}
		meter.links[key] = trafficLink{rx: peer.RXBytes, tx: peer.TXBytes, uptime: peer.Uptime}
	}
	for key := range meter.links {
		if !seen[key] {
			delete(meter.links, key)
		}
	}
	totals := trafficTotals{
		peerRx:       meter.publicRx + meter.localRx,
		peerTx:       meter.publicTx + meter.localTx,
		ownRx:        ownRx,
		ownTx:        ownTx,
		ownPacketsRx: ownPacketsRx,
		ownPacketsTx: ownPacketsTx,
		friend:       own.friendForwarded.Load(),
	}
	if meter.windowStart.IsZero() {
		meter.windowStart = now
		meter.windowBase = totals
		return 0, false
	}
	elapsed := now.Sub(meter.windowStart)
	if elapsed < trafficWindow {
		return 0, false
	}
	transit := estimateTransit(meter.windowBase, totals, len(peers), elapsed)
	meter.transitBytes += transit
	meter.transitLast = transit
	meter.transitRate = uint64(float64(transit) / elapsed.Seconds())
	meter.transitWindow = elapsed
	meter.windowStart = now
	meter.windowBase = totals
	return meter.transitRate, true
}

// estimateTransit is the traffic that went both in and out over the
// peerings between before and after, beyond the node's own packets, the
// upkeep of links peerings over elapsed and what friends nearby sent or
// got through the node themselves (each such packet came in on one
// peering and went out on another, so it is taken from both).
func estimateTransit(before, after trafficTotals, links int, elapsed time.Duration) uint64 {
	upkeep := uint64(links) * trafficLinkUpkeep * uint64(elapsed/time.Second)
	friend := after.friend - before.friend
	in := remainder(after.peerRx-before.peerRx,
		after.ownRx-before.ownRx+(after.ownPacketsRx-before.ownPacketsRx)*trafficPacketOverhead+upkeep+friend)
	out := remainder(after.peerTx-before.peerTx,
		after.ownTx-before.ownTx+(after.ownPacketsTx-before.ownPacketsTx)*trafficPacketOverhead+upkeep+friend)
	return min(in, out)
}

// remainder is total less used, or 0.
func remainder(total, used uint64) uint64 {
	if used >= total {
		return 0
	}
	return total - used
}

// snapshot is what the meter knows, for trafficState.
func (meter *peerTrafficMeter) snapshot() map[string]any {
	meter.mu.Lock()
	defer meter.mu.Unlock()
	return map[string]any{
		"publicRxBytes":        meter.publicRx,
		"publicTxBytes":        meter.publicTx,
		"localRxBytes":         meter.localRx,
		"localTxBytes":         meter.localTx,
		"transitBytes":         meter.transitBytes,
		"transitRate":          meter.transitRate,
		"transitWindowSeconds": int64(meter.transitWindow / time.Second),
	}
}

// lastTransit is the transit of the last whole window, in bytes.
func (meter *peerTrafficMeter) lastTransit() uint64 {
	meter.mu.Lock()
	defer meter.mu.Unlock()
	return meter.transitLast
}

// sampleTraffic feeds the meter with the node's peerings now; a phone logs
// a window with unusual transit, and its transit guard (transit_guard.go)
// takes every window.
func (node *bridgeNode) sampleTraffic() {
	node.sampleTrafficAt(time.Now())
}

func (node *bridgeNode) sampleTrafficAt(now time.Time) {
	node.checkTransitHold(now)
	rate, ended := node.peerTraffic.sample(node.core.GetPeers(), &node.traffic, now)
	if !ended {
		return
	}
	if (isPhoneOS() || node.transitGuard != nil) && rate >= phoneTransitNotice && node.logger != nil {
		node.logger.Warnf("about %d B/s of others' mesh traffic passed through this node", rate)
	}
	node.observeTransit(now, node.peerTraffic.lastTransit(), rate)
}

// trafficState is the node's traffic for diagnostics: bytes over its
// peerings since it started, their rates now (bytes per second), its own
// packets and the transit estimate (see the top of this file), and the
// links of the door host (door_node.go) when one runs.
func (node *bridgeNode) trafficState() map[string]any {
	node.sampleTraffic()
	state := node.peerTraffic.snapshot()
	var rxRate, txRate uint64
	for _, peer := range node.core.GetPeers() {
		rxRate += peer.RXRate
		txRate += peer.TXRate
	}
	state["rxRate"] = rxRate
	state["txRate"] = txRate
	own := &node.traffic
	state["ownSignalRxBytes"] = own.signalRx.Load()
	state["ownSignalTxBytes"] = own.signalTx.Load()
	state["ownRelayRxBytes"] = own.relayRx.Load()
	state["ownRelayTxBytes"] = own.relayTx.Load()
	state["ownOtherRxBytes"] = own.otherRx.Load()
	state["friendForwardedBytes"] = own.friendForwarded.Load()
	if node.transitGuard != nil {
		state["transitGuard"] = node.transitGuardState(time.Now())
	}
	node.doorMu.Lock()
	host := node.doorHost
	node.doorMu.Unlock()
	if host != nil {
		state["doorHost"] = hostTraffic(host.core.GetPeers())
	}
	return state
}

// hostTraffic is what the door host's current links carried: its public
// peering and its links to the doors (loopback), and their rates now.
func hostTraffic(peers []core.PeerInfo) map[string]any {
	var publicRx, publicTx, doorRx, doorTx, rxRate, txRate uint64
	for _, peer := range peers {
		if isLocalPeerURI(peer.URI) {
			doorRx += peer.RXBytes
			doorTx += peer.TXBytes
		} else {
			publicRx += peer.RXBytes
			publicTx += peer.TXBytes
		}
		rxRate += peer.RXRate
		txRate += peer.TXRate
	}
	return map[string]any{
		"publicRxBytes": publicRx,
		"publicTxBytes": publicTx,
		"doorRxBytes":   doorRx,
		"doorTxBytes":   doorTx,
		"rxRate":        rxRate,
		"txRate":        txRate,
	}
}
