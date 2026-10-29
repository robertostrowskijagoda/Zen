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
//
// Anyone on the mesh can send this node packets it drops (junk that does
// not open, packets the mesh reader refuses), and ironwood answers some of
// them (a session init back): bytes in and out that are not the node's own
// as the packet loop counts them, yet no transit either. So the node's own
// traffic is also taken from its end-to-end sessions (everything that
// opened, whatever the reader made of it), and transit is at most what came in
// on one peering while another one sent as much: junk and the answers to it
// travel over the same peering.
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

// writeMesh hands one of the node's own packets to its mesh writer, which
// counts it once written (mesh_io.go). It never waits for the mesh.
func (node *bridgeNode) writeMesh(packet []byte, relay bool) error {
	if node.mesh == nil {
		return errMeshStopped
	}
	return node.mesh.send(packet, relay)
}

// writeMeshSealed is writeMesh for a fragment of a sealed signal frame,
// which the writer sends again while the way to its node settles
// (mesh_io.go, echoes).
func (node *bridgeNode) writeMeshSealed(packet []byte) error {
	if node.mesh == nil {
		return errMeshStopped
	}
	return node.mesh.sendSealed(packet)
}

// trafficLink is what a peering (or a session) had carried when it was last
// looked at.
type trafficLink struct {
	rx, tx uint64
	uptime time.Duration
}

// trafficDelta is what came in and went out since a moment before.
type trafficDelta struct {
	rx, tx uint64
}

// trafficTotals are byte counts since the node started.
type trafficTotals struct {
	peerRx, peerTx             uint64
	ownRx, ownTx               uint64
	ownPacketsRx, ownPacketsTx uint64
	// What the node's end-to-end sessions carried (payloads that opened).
	sessionRx, sessionTx uint64
	// A friend's own traffic over a local link, passed on.
	friend uint64
}

// transitEstimate is the transit of a window that ended.
type transitEstimate struct {
	bytes uint64
	// Bytes per second.
	rate uint64
	// Most of it could have come in on a peering nearby (a device on the
	// LAN, a friend's bridge) and gone out to a public peer, or the other way
	// round: what a home computer routing through the phone looks like, and
	// what a stranger far away cannot make up.
	crossed bool
}

// peerTrafficMeter adds up what the node's peerings carried, also of
// peerings that are gone since, and estimates transit per window. The zero
// value is ready to use; it is safe for concurrent use.
type peerTrafficMeter struct {
	mu    sync.Mutex
	links map[string]trafficLink
	// The node's sessions as last seen, by key, and what all of them carried
	// since the node started.
	sessions             map[string]trafficLink
	sessionRx, sessionTx uint64
	// Bytes over public peerings and over local ones (devices nearby, the
	// LAN, loopback) since the node started.
	publicRx, publicTx uint64
	localRx, localTx   uint64
	// The window that is being measured: when it started, the totals then,
	// and what each peering carried in it (by peering, and nearby or far).
	windowStart time.Time
	windowBase  trafficTotals
	windowLinks map[string]trafficDelta
	windowNear  trafficDelta
	windowFar   trafficDelta
	// Transit since the node started, and the rate over the last whole
	// window.
	transitBytes  uint64
	transitRate   uint64
	transitWindow time.Duration
}

// counterDelta is what a counter that may have started again (a new
// connection or session under the same name) added since last.
func counterDelta(last trafficLink, rx, tx uint64, uptime time.Duration) (uint64, uint64) {
	if rx < last.rx || tx < last.tx || uptime < last.uptime {
		last = trafficLink{}
	}
	return rx - last.rx, tx - last.tx
}

// sample takes in the peerings as GetPeers lists them now, the sessions as
// GetSessions does and the node's own totals; near tells a peering nearby
// (nil: only local addresses). It returns the transit of a window that ended
// now (and true), or false while the window runs.
func (meter *peerTrafficMeter) sample(peers []core.PeerInfo, sessions []core.SessionInfo, own *ownTraffic, near func(uri string) bool, now time.Time) (transitEstimate, bool) {
	ownRx, ownTx, ownPacketsRx, ownPacketsTx := own.totals()
	if near == nil {
		near = isLocalPeerURI
	}
	meter.mu.Lock()
	defer meter.mu.Unlock()
	if meter.links == nil {
		meter.links = make(map[string]trafficLink)
	}
	if meter.windowLinks == nil {
		meter.windowLinks = make(map[string]trafficDelta)
	}
	seen := make(map[string]bool, len(peers))
	for _, peer := range peers {
		key := peer.URI
		if peer.Inbound {
			key = "in|" + key
		}
		seen[key] = true
		rx, tx := counterDelta(meter.links[key], peer.RXBytes, peer.TXBytes, peer.Uptime)
		if isLocalPeerURI(peer.URI) {
			meter.localRx += rx
			meter.localTx += tx
		} else {
			meter.publicRx += rx
			meter.publicTx += tx
		}
		window := meter.windowLinks[key]
		window.rx += rx
		window.tx += tx
		meter.windowLinks[key] = window
		group := &meter.windowFar
		if near(peer.URI) {
			group = &meter.windowNear
		}
		group.rx += rx
		group.tx += tx
		meter.links[key] = trafficLink{rx: peer.RXBytes, tx: peer.TXBytes, uptime: peer.Uptime}
	}
	for key := range meter.links {
		if !seen[key] {
			delete(meter.links, key)
		}
	}
	meter.sampleSessionsLocked(sessions)
	totals := trafficTotals{
		peerRx:       meter.publicRx + meter.localRx,
		peerTx:       meter.publicTx + meter.localTx,
		ownRx:        ownRx,
		ownTx:        ownTx,
		ownPacketsRx: ownPacketsRx,
		ownPacketsTx: ownPacketsTx,
		sessionRx:    meter.sessionRx,
		sessionTx:    meter.sessionTx,
		friend:       own.friendForwarded.Load(),
	}
	if meter.windowStart.IsZero() {
		meter.startWindowLocked(now, totals)
		return transitEstimate{}, false
	}
	elapsed := now.Sub(meter.windowStart)
	if elapsed < trafficWindow {
		return transitEstimate{}, false
	}
	transit := estimateTransit(meter.windowBase, totals, len(peers), elapsed)
	transit = min(transit, crossLinkBound(meter.windowLinks))
	crossing := min(meter.windowNear.rx, meter.windowFar.tx) + min(meter.windowFar.rx, meter.windowNear.tx)
	estimate := transitEstimate{
		bytes:   transit,
		rate:    uint64(float64(transit) / elapsed.Seconds()),
		crossed: transit > 0 && 2*min(crossing, transit) >= transit,
	}
	meter.transitBytes += transit
	meter.transitRate = estimate.rate
	meter.transitWindow = elapsed
	meter.startWindowLocked(now, totals)
	return estimate, true
}

func (meter *peerTrafficMeter) startWindowLocked(now time.Time, totals trafficTotals) {
	meter.windowStart = now
	meter.windowBase = totals
	clear(meter.windowLinks)
	meter.windowNear = trafficDelta{}
	meter.windowFar = trafficDelta{}
}

// sampleSessionsLocked adds what the node's sessions carried since the last
// sample.
func (meter *peerTrafficMeter) sampleSessionsLocked(sessions []core.SessionInfo) {
	if meter.sessions == nil {
		meter.sessions = make(map[string]trafficLink)
	}
	seen := make(map[string]bool, len(sessions))
	for _, session := range sessions {
		key := string(session.Key)
		seen[key] = true
		rx, tx := counterDelta(meter.sessions[key], session.RXBytes, session.TXBytes, session.Uptime)
		meter.sessionRx += rx
		meter.sessionTx += tx
		meter.sessions[key] = trafficLink{rx: session.RXBytes, tx: session.TXBytes, uptime: session.Uptime}
	}
	for key := range meter.sessions {
		if !seen[key] {
			delete(meter.sessions, key)
		}
	}
}

// estimateTransit is the traffic that went both in and out over the
// peerings between before and after, beyond the node's own packets (as the
// packet loop or the sessions counted them, whichever saw more), the upkeep
// of links peerings over elapsed and what friends nearby sent or got
// through the node themselves (each such packet came in on one peering and
// went out on another, so it is taken from both).
func estimateTransit(before, after trafficTotals, links int, elapsed time.Duration) uint64 {
	upkeep := uint64(links) * trafficLinkUpkeep * uint64(elapsed/time.Second)
	friend := after.friend - before.friend
	ownRx := max(after.ownRx-before.ownRx, after.sessionRx-before.sessionRx)
	ownTx := max(after.ownTx-before.ownTx, after.sessionTx-before.sessionTx)
	in := remainder(after.peerRx-before.peerRx,
		ownRx+(after.ownPacketsRx-before.ownPacketsRx)*trafficPacketOverhead+upkeep+friend)
	out := remainder(after.peerTx-before.peerTx,
		ownTx+(after.ownPacketsTx-before.ownPacketsTx)*trafficPacketOverhead+upkeep+friend)
	return min(in, out)
}

// crossLinkBound is the most that can have passed through: every byte of
// transit came in on one peering and left on another, so what came in on a
// peering counts only up to what the other peerings sent, and the other way
// round. Junk sent to the node and what it answers stay on one peering.
func crossLinkBound(links map[string]trafficDelta) uint64 {
	var rx, tx uint64
	for _, link := range links {
		rx += link.rx
		tx += link.tx
	}
	var in, out uint64
	for _, link := range links {
		in += min(link.rx, tx-link.tx)
		out += min(link.tx, rx-link.rx)
	}
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

// sampleTraffic feeds the meter with the node's peerings now; a phone logs
// a window with unusual transit, and its transit guard (transit_guard.go)
// takes every window. Only goroutines of the node's own call it: it asks
// the core, which the app's thread never waits for (node_view.go).
func (node *bridgeNode) sampleTraffic() {
	node.sampleTrafficAt(time.Now())
}

func (node *bridgeNode) sampleTrafficAt(now time.Time) {
	node.sampleTrafficWith(node.core.GetPeers(), node.core.GetSessions(), now)
}

// sampleTrafficWith is sampleTraffic with the peerings and sessions the
// core listed at now.
func (node *bridgeNode) sampleTrafficWith(peers []core.PeerInfo, sessions []core.SessionInfo, now time.Time) {
	node.checkTransitHold(now)
	estimate, ended := node.peerTraffic.sample(peers, sessions, &node.traffic, node.nearPeers(), now)
	if !ended {
		return
	}
	if (isPhoneOS() || node.transitGuard != nil) && estimate.rate >= phoneTransitNotice && node.logger != nil {
		node.logger.Warnf("about %d B/s of others' mesh traffic passed through this node", estimate.rate)
	}
	node.observeTransit(now, estimate)
}

// nearPeers tells the peerings nearby: local addresses (devices nearby, the
// LAN) and the friends' bridges the app configured.
func (node *bridgeNode) nearPeers() func(uri string) bool {
	bridges := make(map[string]bool)
	for _, extra := range node.configuredExtras() {
		bridges[peerURIBase(extra)] = true
	}
	return func(uri string) bool {
		return isLocalPeerURI(uri) || bridges[peerURIBase(uri)]
	}
}

// trafficStateWith is the node's traffic for diagnostics: bytes over its
// peerings since it started, their rates now (bytes per second, from peers
// as the core listed them), its own packets and the transit estimate (see
// the top of this file), and the links of the door host (door_node.go)
// when one runs. The node's view takes it with every sample (node_view.go).
func (node *bridgeNode) trafficStateWith(peers []core.PeerInfo) map[string]any {
	state := node.peerTraffic.snapshot()
	var rxRate, txRate uint64
	for _, peer := range peers {
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
		state["doorHost"] = hostTraffic(host.peerView())
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
