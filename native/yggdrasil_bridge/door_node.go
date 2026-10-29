package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// The flat's door (neighbours). The sticker on the door carries the
// address of a second, minimal Yggdrasil node with its own random key, not
// the address of anyone who lives there. Each resident's phone runs one, and
// the flat's profile names the residents' doors, never their phones: all
// traffic between flats goes from door to door. The door takes only flat
// frames on the signal port and hands them to the app through the main
// node's signal inbox, marked as door traffic; it sends only flat frames the
// app gives it (YggDoorSendSignal). Yggdrasil's own queries (getSelf,
// getPeers, getTree, nodeinfo) are dropped unanswered.
//
// The doors are never peered with the main node, so neither lists the other
// in its getPeers/getTree answers and the door's mesh path does not hang
// below the person's node. All doors of a phone (the flat's own and the
// mailbox doors it runs for friends) hang below one "door host": a third
// node with a random key made anew whenever it starts, that dials up to
// doorHostPeerCount of the main node's public peers on its own (avoiding the
// main node's tree parent) and answers nothing either. One host instead of
// a connection per door: a phone may run up to 1+maxHostedDoors doors, and
// each own upstream connection would cost a TLS session, keepalives and
// tree traffic. What the shared host gives away: the doors of one phone sit
// next to each other in the tree, so someone who knows two door addresses
// can tell that one phone runs both (that flat A keeps a mailbox for flat B);
// it does not name the phone or its person. LAN peers are left out: a LAN
// node has few peers, so the main node and the host side by side there
// would be easy to pair.
//
// Mailbox doors: the same kind of node, run for a friend whose phone may be
// offline (flat_door_mail.dart). Its key is one of the friend's door "slots",
// derived from the friend's door key and handed over by the friend's app;
// the door sticker lists the slot addresses, never who runs them. A
// mailbox door takes only sealed knocks (flat_seal) that name its own
// address; the app here holds them for the friend without being able to
// read them. It never sends.
//
// The sticker lists the other residents' doors in the same list, mixed in
// with the mailbox doors: so the flat's own door also takes a sealed knock
// that names it, and the app opens it with the household's key. A knock so
// reaches every resident's phone that is on, also when the phone that
// printed the sticker is off.
//
// Every door runs the session layer of the main node (pq_session.go) with
// its own key: all traffic between doors — knocks, profiles, messages,
// sealed knocks — goes sealed with hybrid post-quantum keys inside
// Yggdrasil's own encryption, and a door takes nothing unsealed. The
// session's device key comes from the door's key, so it is nobody's
// identity either. A mailbox door sends only the session layer's own
// control frames (its key record, challenges), never a flat frame.
const (
	// The only frame a mailbox door takes ("flat_seal").
	doorSealType = "flat_seal"
	// Largest flat frame, decompressed: a flat profile with its photo
	// (FlatProfile.maxPhotoChars) and room to spare.
	maxDoorFrameBytes = 512 * 1024
	// Largest sealed knock: a flat's card without its photo
	// (kMaxSealedChars in flat_door_mail.dart) and room to spare.
	maxDoorSealBytes = 64 * 1024
	// Longest base64 text a door buffers for one signal: its largest frame,
	// sealed. A door's fragments never need the main node's room for a
	// signal of the largest size (maxSignalEncodedBytes).
	maxDoorEncodedBytes = ((maxDoorFrameBytes + pqMaxFrameOverhead + 2) / 3) * 4
	// Bytes one door buffers for half-received signals at once: a few
	// frames of the largest size. Up to 1+maxHostedDoors doors run next to
	// the main node, each with its own buffers.
	maxDoorPartialBytes = 4 * 1024 * 1024
	// Mailbox doors one phone runs for friends at most (kMaxHostedDoors).
	maxHostedDoors = 8
	// Where a door listens for the door host's peering.
	doorListenURI = "tcp://127.0.0.1:0"
	// The first byte of a packet out of the core's session layer
	// (yggdrasil core/types.go): traffic, or the core's own protocol
	// (nodeinfo and debug queries), which the doors never answer.
	doorSessionTraffic = 1
	// Public peers the door host dials at once. One: a Yggdrasil node with
	// two or more peers may be picked as the next hop between them
	// (ironwood routes greedily over every peer, weighted by link latency),
	// so a host with two public peers could carry strangers' traffic
	// through the phone. With one it is a leaf; watch moves it to another
	// peer when that one stays down.
	doorHostPeerCount = 1
	// How often the door host checks that it is on the mesh, and how many
	// failed checks in a row make it try other peers.
	doorHostCheckInterval = 30 * time.Second
	doorHostMissedChecks  = 2
)

// doorTrafficTypes are the frames the flat's own door takes and sends
// (FlatTypes.atDoor in neighbors_service.dart): knocks and everything
// between neighbour flats. Frames between housemates go phone to phone.
var doorTrafficTypes = map[string]bool{
	"flat_hello":     true,
	"flat_nope":      true,
	"flat_profile":   true,
	"flat_get":       true,
	"flat_msg":       true,
	"flat_signup":    true,
	"flat_signup_ok": true,
	"flat_moved":     true,
	"flat_newkey":    true,
	"flat_reveal":    true,
	"flat_ack":       true,
	// The household's card for a flat that knocked, before "Wpuść".
	"flat_card": true,
}

// doorHostPeerAllowed tells which of the main node's peers the door host may
// dial: public ones only (see above). Tests let loopback hubs through.
var doorHostPeerAllowed = func(uri string) bool {
	return !isLocalPeerURI(uri)
}

type doorNode struct {
	core     *core.Core
	listener *core.Listener
	// The host's peering to the door (no query, as GetPeers lists it).
	linkURI string
	// The full peering URI, with the door's key pinned.
	peerURI *url.URL
	seed    string
	address string
	// The door's own mesh address, as packets to it carry it.
	ip address.Address
	// Only its fragment buffers (signal_reassembly.go) are used, so knocks
	// split into fragments do not mix with the main node's.
	assembler *bridgeNode
	// The door's packets on the mesh: run reads (below Core.ReadFrom, which
	// would answer the core's protocol packets) and never writes; a writer
	// of its own sends (mesh_io.go).
	mesh *meshIO
	// The session layer of the door (nil: plain, tests of the main node's
	// plain mode only).
	pq *pqEndpoint
	// What the door saw and did, for diagnostics (doorStats).
	stats    doorStats
	host     *doorHost
	stopOnce sync.Once
	// Closed by stop; done is closed when run has returned.
	quit chan struct{}
	done chan struct{}
	// A mailbox door run for a friend: it takes sealed knocks only.
	mailbox bool
}

// doorStats counts what a door did with signals, for diagnostics (tests,
// the log): what came in, what the session layer kept for itself, opened
// or refused, what the door took, and what it wrote.
type doorStats struct {
	mu        sync.Mutex
	counts    map[string]int
	lastError string
}

func (s *doorStats) add(what string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.counts == nil {
		s.counts = make(map[string]int)
	}
	s.counts[what]++
}

func (s *doorStats) fail(what string, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.counts == nil {
		s.counts = make(map[string]int)
	}
	s.counts[what]++
	s.lastError = what + ": " + err.Error()
}

// String is the counts, sorted, and the last error.
func (s *doorStats) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	keys := make([]string, 0, len(s.counts))
	for key := range s.counts {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys)+1)
	for _, key := range keys {
		parts = append(parts, fmt.Sprintf("%s=%d", key, s.counts[key]))
	}
	if s.lastError != "" {
		parts = append(parts, "last error: "+s.lastError)
	}
	return strings.Join(parts, " ")
}

// doorHost carries a phone's doors to the mesh (see above).
type doorHost struct {
	core *core.Core
	main *bridgeNode
	mu   sync.Mutex
	// The public peers it dials now: as GetPeers lists them → as dialled.
	peers  map[string]string
	offset int
	// Its peerings as the app reads them, asked off the app's thread
	// (node_view.go).
	links    coreQuery[[]core.PeerInfo]
	quit     chan struct{}
	done     chan struct{}
	stopOnce sync.Once
}

// doorSeed reads a 32-byte ed25519 seed written as hex.
func doorSeed(seedHex string) (ed25519.PrivateKey, error) {
	seed, err := hex.DecodeString(strings.TrimSpace(seedHex))
	if err != nil {
		return nil, fmt.Errorf("door key: %w", err)
	}
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("door key must be %d bytes, got %d", ed25519.SeedSize, len(seed))
	}
	return ed25519.NewKeyFromSeed(seed), nil
}

func doorLogger(main *bridgeNode) *log.Logger {
	if main.logger != nil {
		return main.logger
	}
	return log.New(io.Discard, "", 0)
}

// peerURIBase is a peering URI without its query, as GetPeers lists it.
func peerURIBase(uri string) string {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil {
		return uri
	}
	parsed.RawQuery = ""
	parsed.Fragment = ""
	return parsed.String()
}

// newDoorHost starts the door host with a fresh random key, on the mesh
// through the main node's public peers but never peered with the main node.
func newDoorHost(main *bridgeNode) (*doorHost, error) {
	cfg := config.GenerateConfig()
	iprange := net.IPNet{IP: net.ParseIP("200::"), Mask: net.CIDRMask(7, 128)}
	hostCore, err := core.New(
		cfg.Certificate,
		doorLogger(main),
		// As the main node: no peering over mesh addresses.
		core.PeerFilter(func(ip net.IP) bool { return !iprange.Contains(ip) }),
		// Nodeinfo would tell the platform and the version to whoever asks.
		core.NodeInfoPrivacy(true),
	)
	if err != nil {
		return nil, err
	}
	host := &doorHost{
		core:   hostCore,
		main:   main,
		peers:  make(map[string]string),
		offset: rand.IntN(1 << 16),
		quit:   make(chan struct{}),
		done:   make(chan struct{}),
	}
	host.repeer()
	go host.drain()
	go host.watch()
	return host, nil
}

// drain reads what reaches the host itself and drops it, below Core.ReadFrom
// (which would answer getSelf, getPeers, getTree and nodeinfo).
func (host *doorHost) drain() {
	defer close(host.done)
	buffer := make([]byte, 65535+1)
	for {
		if _, _, err := host.core.PacketConn.ReadFrom(buffer); err != nil {
			select {
			case <-host.quit:
				return
			case <-time.After(50 * time.Millisecond):
			}
		}
	}
}

// watch moves the host to other public peers while it is off the mesh.
func (host *doorHost) watch() {
	missed := 0
	ticker := time.NewTicker(doorHostCheckInterval)
	defer ticker.Stop()
	for {
		select {
		case <-host.quit:
			return
		case <-ticker.C:
		}
		if host.meshUp(host.core.GetPeers()) {
			missed = 0
			continue
		}
		missed++
		if missed >= doorHostMissedChecks || host.peerCount() == 0 {
			missed = 0
			host.mu.Lock()
			host.offset += doorHostPeerCount
			host.mu.Unlock()
			host.repeer()
		}
	}
}

func (host *doorHost) peerCount() int {
	host.mu.Lock()
	defer host.mu.Unlock()
	return len(host.peers)
}

// meshUp reports whether the host has a working link to one of its public
// peers, among links as GetPeers listed them.
func (host *doorHost) meshUp(links []core.PeerInfo) bool {
	host.mu.Lock()
	peers := make(map[string]bool, len(host.peers))
	for base := range host.peers {
		peers[base] = true
	}
	host.mu.Unlock()
	for _, peer := range links {
		if peer.Up && peers[peerURIBase(peer.URI)] {
			return true
		}
	}
	return false
}

// peerView is the host's peerings as the app reads them: never waiting for
// its core longer than nodeViewWait.
func (host *doorHost) peerView() []core.PeerInfo {
	return host.links.get(nodeViewFresh, nodeViewWait, host.core.GetPeers)
}

// repeer dials the public peers doorHostPeers picks now and drops the ones
// it dialled before.
func (host *doorHost) repeer() {
	candidates := make([]string, 0)
	for _, peer := range host.main.configSnapshot().Peers {
		if peer != "" && doorHostPeerAllowed(peer) {
			candidates = append(candidates, peer)
		}
	}
	host.mu.Lock()
	offset := host.offset
	host.mu.Unlock()
	chosen := doorHostPeers(candidates, host.main.treeParentURI(), offset, doorHostPeerCount)
	next := make(map[string]string, len(chosen))
	for _, uri := range chosen {
		next[peerURIBase(uri)] = uri
	}
	host.mu.Lock()
	previous := host.peers
	host.peers = next
	host.mu.Unlock()
	for base, uri := range next {
		if _, had := previous[base]; had {
			continue
		}
		if parsed, err := url.Parse(uri); err == nil {
			_ = host.core.AddPeer(parsed, "")
		}
	}
	for base, uri := range previous {
		if _, kept := next[base]; kept {
			continue
		}
		if parsed, err := url.Parse(uri); err == nil {
			_ = host.core.RemovePeer(parsed, "")
		}
	}
	host.core.RetryPeersNow()
}

// doorHostPeers picks up to count of candidates, going round from offset,
// leaving out avoid (the main node's tree parent) while there are others:
// with another parent, the doors' mesh paths and the main node's part early.
func doorHostPeers(candidates []string, avoid string, offset, count int) []string {
	pool := make([]string, 0, len(candidates))
	seen := make(map[string]bool, len(candidates))
	for _, uri := range candidates {
		base := peerURIBase(uri)
		if seen[base] || (avoid != "" && base == peerURIBase(avoid)) {
			continue
		}
		seen[base] = true
		pool = append(pool, uri)
	}
	if len(pool) == 0 {
		for _, uri := range candidates {
			if !seen[peerURIBase(uri)] {
				seen[peerURIBase(uri)] = true
				pool = append(pool, uri)
			}
		}
	}
	if len(pool) == 0 || count <= 0 {
		return nil
	}
	if offset < 0 {
		offset = -offset
	}
	picked := make([]string, 0, count)
	for index := 0; index < len(pool) && len(picked) < count; index++ {
		picked = append(picked, pool[(offset+index)%len(pool)])
	}
	return picked
}

// treeParentURI is the peering of the main node's parent in the mesh tree
// ("" while it has none), from the node's view: a door starts on the app's
// thread (node_view.go).
func (node *bridgeNode) treeParentURI() string {
	self := node.core.PublicKey()
	var parent ed25519.PublicKey
	for _, entry := range node.viewTree() {
		if bytes.Equal(entry.Key, self) {
			parent = entry.Parent
		}
	}
	if len(parent) == 0 || bytes.Equal(parent, self) {
		return ""
	}
	for _, peer := range node.view().peers {
		if bytes.Equal(peer.Key, parent) {
			return peer.URI
		}
	}
	return ""
}

func (host *doorHost) stop() {
	host.stopOnce.Do(func() {
		close(host.quit)
		stopCore(host.core, nodeStopWait)
	})
}

// newDoorNode starts a door with the key from seedHex below host; a mailbox
// door (for a friend) when mailbox is set.
func newDoorNode(main *bridgeNode, host *doorHost, seedHex string, mailbox bool) (*doorNode, error) {
	private, err := doorSeed(seedHex)
	if err != nil {
		return nil, err
	}
	cfg := &config.NodeConfig{PrivateKey: config.KeyBytes(private)}
	if err := cfg.GenerateSelfSignedCertificate(); err != nil {
		return nil, err
	}
	doorCore, err := core.New(
		cfg.Certificate,
		doorLogger(main),
		// Only this phone's door host may peer with the door.
		core.AllowedPublicKey(host.core.PublicKey()),
		// Nodeinfo would tell the platform and the version to whoever asks.
		core.NodeInfoPrivacy(true),
	)
	if err != nil {
		return nil, err
	}
	listenURL, _ := url.Parse(doorListenURI)
	listener, err := doorCore.Listen(listenURL, "")
	if err != nil {
		doorCore.Stop()
		return nil, err
	}
	tcpAddr, ok := listener.Addr().(*net.TCPAddr)
	if !ok {
		doorCore.Stop()
		return nil, errors.New("door listener has no TCP address")
	}
	linkURI := fmt.Sprintf("tcp://127.0.0.1:%d", tcpAddr.Port)
	peerURI, err := url.Parse(linkURI + "?key=" + hex.EncodeToString(doorCore.PublicKey()))
	if err != nil {
		doorCore.Stop()
		return nil, err
	}
	assembler := &bridgeNode{
		signalPartials: make(map[string]*signalReassembly),
		partialLimits:  signalPartialLimits{total: maxDoorPartialBytes, perSignal: maxDoorEncodedBytes},
	}
	door := &doorNode{
		core:      doorCore,
		listener:  listener,
		linkURI:   linkURI,
		peerURI:   peerURI,
		seed:      strings.ToLower(strings.TrimSpace(seedHex)),
		address:   doorCore.Address().String(),
		ip:        *address.AddrForKey(doorCore.PublicKey()),
		assembler: assembler,
		host:      host,
		quit:      make(chan struct{}),
		done:      make(chan struct{}),
		mailbox:   mailbox,
	}
	if !main.pqPlain {
		door.pq, err = newPQEndpoint(private, net.IP(append([]byte(nil), door.ip[:]...)), door.writeWire)
		if err != nil {
			doorCore.Stop()
			return nil, err
		}
	}
	door.mesh = newMeshIO(doorCore, nil)
	door.mesh.start()
	// The host calls the door (the door dials nobody).
	if err := host.core.AddPeer(peerURI, ""); err != nil {
		door.mesh.stop()
		doorCore.Stop()
		return nil, err
	}
	host.core.RetryPeersNow()
	go door.run(main)
	return door, nil
}

// run takes flat frames until the door stops.
func (door *doorNode) run(main *bridgeNode) {
	defer close(door.done)
	// The largest packet the core yields (Core.MTU) and its session byte.
	buffer := make([]byte, 65535+1)
	var limiter signalRateLimiter
	for {
		count, from, err := door.core.PacketConn.ReadFrom(buffer)
		if err != nil {
			select {
			case <-door.quit:
				return
			case <-time.After(50 * time.Millisecond):
			}
			continue
		}
		packet, ok := door.trafficPacket(buffer[:count], from)
		if !ok {
			continue
		}
		source, port, payload, ok := parseYggPacket(packet)
		if !ok || port != yggSignalPort || !isYggNodeAddress(source) {
			continue
		}
		network := signalSourceNetOf(source)
		if !limiter.allow(network, time.Now()) {
			continue
		}
		message, ok := door.assembler.reassembleSignal(source.String(), payload)
		if !ok {
			door.stats.add("fragment")
			continue
		}
		door.stats.add("signal in")
		message, ok = door.open(source, message)
		if !ok {
			continue
		}
		if !door.takes(message) {
			door.stats.add("not taken")
			continue
		}
		door.stats.add("taken")
		main.signalInbox.push(signalMessage{
			From:    source.String(),
			Payload: message,
			Door:    true,
		}, network)
	}
}

// trafficPacket is the IPv6 packet in what the door's session layer read
// from the key from, or false for anything else. The door reads below
// Core.ReadFrom, which would answer the core's protocol packets (getSelf,
// getPeers, getTree, nodeinfo) itself; here they are dropped. The packet
// must be addressed to the door and come from the sender key's own address
// (meshIO.accept, which notes the key for the answers).
func (door *doorNode) trafficPacket(session []byte, from net.Addr) ([]byte, bool) {
	if len(session) < 1+40 || session[0] != doorSessionTraffic {
		return nil, false
	}
	packet := session[1:]
	if !door.mesh.accept(packet, from) {
		return nil, false
	}
	return packet, true
}

// open is the signal text a reassembled signal from source carries, opened
// by the door's session layer (control frames are answered there and give
// nothing); anything unsealed is refused.
func (door *doorNode) open(source net.IP, wire string) (string, bool) {
	if door.pq == nil {
		return wire, true
	}
	if !isPQWire(wire) {
		door.stats.add("unsealed refused")
		return "", false
	}
	plain, ok := door.pq.receive(source, []byte(wire))
	if !ok {
		// A control frame (answered inside), or data that did not open.
		if len(wire) > len(pqMagic) && wire[len(pqMagic)] == pqKindData {
			door.stats.add("sealed refused")
		} else {
			door.stats.add("session control")
		}
		return "", false
	}
	door.stats.add("opened")
	return inflateSignalText(source.String(), string(plain))
}

// send sends a flat frame (payload, as the app encodes it) from the door to
// remoteAddress, sealed by the door's session layer and split into signal
// fragments as sendSignal does: to another flat's door, or a sealed knock to
// a mailbox door.
func (door *doorNode) send(remoteAddress, payload string) error {
	if door.mailbox {
		return errors.New("a mailbox door sends nothing")
	}
	destination := net.ParseIP(strings.TrimSpace(remoteAddress))
	if destination == nil || destination.To4() != nil {
		return fmt.Errorf("invalid remote yggdrasil address: %s", remoteAddress)
	}
	if !isDoorSendable(payload) {
		return errors.New("the door sends flat frames only")
	}
	wirePayload := buildSignalWirePayload(payload)
	if door.pq == nil {
		return door.writeWire(destination, []byte(wirePayload))
	}
	if err := door.pq.send(destination, []byte(wirePayload)); err != nil {
		door.stats.fail("seal error", err)
		return err
	}
	door.stats.add("sent")
	return nil
}

// writeWire splits a signal text into fragments and sends them from the
// door's address to destination (the session layer's frames too).
func (door *doorNode) writeWire(destination net.IP, wire []byte) error {
	size := signalSendChunkSize
	if limit := door.mesh.MTU() - 1024; limit < size {
		size = max(limit, signalChunkSize)
	}
	chunks := splitSignalWire(string(wire), size)
	packetID := fmt.Sprintf("%d-%d", time.Now().UnixNano(), nextSignalPacket.Add(1))
	source := net.IP(append([]byte(nil), door.ip[:]...))
	for index, chunk := range chunks {
		envelope, err := json.Marshal(signalEnvelope{
			ID:      packetID,
			Index:   index,
			Total:   len(chunks),
			Payload: chunk,
		})
		if err != nil {
			return err
		}
		packet, err := buildYggPacket(source, destination, yggSignalPort, envelope)
		if err != nil {
			door.stats.fail("write error", err)
			return err
		}
		if err := door.mesh.send(packet, false); err != nil {
			door.stats.fail("write error", err)
			return err
		}
		door.stats.add("packet out")
	}
	return nil
}

// stop shuts the door and drops the host's peering to it. It runs on the
// app's thread: neither core is waited for longer than nodeStopWait.
func (door *doorNode) stop() {
	door.stopOnce.Do(func() {
		close(door.quit)
		door.mesh.stop()
		within(nodeStopWait, func() { _ = door.host.core.RemovePeer(door.peerURI, "") })
		door.listener.Cancel()
		// Stopping the core ends run's reads.
		stopCore(door.core, nodeStopWait)
	})
}

// linked reports whether the door's host has its link to the door up and is
// on the mesh itself (from the host's view, node_view.go).
func (door *doorNode) linked() bool {
	links := door.host.peerView()
	for _, peer := range links {
		if peer.URI == door.linkURI && peer.Up {
			return door.host.meshUp(links)
		}
	}
	return false
}

// takes reports whether this door lets the signal text in: a flat frame or
// a sealed knock naming this door at the flat's own door (a housemate's
// sticker lists it among the mailbox doors), only a sealed knock naming
// this door at a mailbox door.
func (door *doorNode) takes(message string) bool {
	if door.mailbox {
		return isSealedKnockFor(message, door.ip)
	}
	return isDoorTraffic(message) || isSealedKnockFor(message, door.ip)
}

// isDoorTraffic reports whether a signal text is a flat frame for the
// flat's door: a JSON object whose type is one of doorTrafficTypes, as the
// app sends it (plain, or wrapped by the app's zstd encoding,
// runtime_signal_codec.dart), within maxDoorFrameBytes. It reads the text
// exactly as the app's jsonDecode does (doorObject), so what passes here is
// that frame for the app too.
func isDoorTraffic(message string) bool {
	body, ok := doorFrame(message, maxDoorFrameBytes)
	if !ok {
		return false
	}
	kind, ok := doorString(body, "type")
	return ok && doorTrafficTypes[kind]
}

// isDoorSendable reports whether the flat's door may send a signal text:
// a frame for another flat's door, or a sealed knock for a mailbox door.
func isDoorSendable(message string) bool {
	if isDoorTraffic(message) {
		return true
	}
	body, ok := doorFrame(message, maxDoorSealBytes)
	if !ok {
		return false
	}
	kind, ok := doorString(body, "type")
	return ok && kind == doorSealType
}

// isSealedKnockFor reports whether a signal text is a sealed knock
// (doorSealType, within maxDoorSealBytes) whose "d" names the mailbox door
// at ip, so a knock for one friend's door cannot be dropped at another's.
func isSealedKnockFor(message string, ip address.Address) bool {
	body, ok := doorFrame(message, maxDoorSealBytes)
	if !ok {
		return false
	}
	kind, ok := doorString(body, "type")
	if !ok || kind != doorSealType {
		return false
	}
	target, ok := doorString(body, "d")
	if !ok {
		return false
	}
	parsed := net.ParseIP(target)
	return parsed != nil && parsed.To4() == nil && bytes.Equal(parsed.To16(), ip[:])
}

// doorFrame is the JSON object a signal text carries, read as the app reads
// it: plain, or inside the app's zstd wrapper; either within limit bytes.
func doorFrame(message string, limit int) (map[string]json.RawMessage, bool) {
	if len(message) > limit {
		return nil, false
	}
	head, ok := doorObject([]byte(message))
	if !ok {
		return nil, false
	}
	encoding, ok := doorString(head, "_zenEncoding")
	if !ok {
		return nil, false
	}
	if encoding == "" {
		return head, true
	}
	payload, ok := doorString(head, "_zenPayload")
	if _, typed := head["type"]; encoding != "zstd" || typed || !ok || payload == "" {
		return nil, false
	}
	compressed, err := base64.StdEncoding.DecodeString(payload)
	if err != nil {
		return nil, false
	}
	inner, err := decompressSignal(compressed)
	if err != nil || len(inner) > limit {
		return nil, false
	}
	return doorObject(inner)
}

// doorObject reads text as one JSON object, its keys matched exactly as
// the app's jsonDecode matches them. encoding/json's struct decoding
// matches keys case-insensitively and takes the last of duplicates, so
// {"type":"lg_heads","TYPE":"flat_hello"} read as a knock there while
// the app saw a ledger frame. A key given twice, two keys that differ
// only in case (as encoding/json folds them), and anything after the
// object are refused.
func doorObject(text []byte) (map[string]json.RawMessage, bool) {
	decoder := json.NewDecoder(bytes.NewReader(text))
	if token, err := decoder.Token(); err != nil || token != json.Delim('{') {
		return nil, false
	}
	fields := make(map[string]json.RawMessage)
	folded := make(map[string]struct{})
	for decoder.More() {
		token, err := decoder.Token()
		if err != nil {
			return nil, false
		}
		key, ok := token.(string)
		if !ok {
			return nil, false
		}
		fold := strings.ToUpper(key)
		if _, seen := folded[fold]; seen {
			return nil, false
		}
		folded[fold] = struct{}{}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, false
		}
		fields[key] = value
	}
	if token, err := decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, false
	}
	if _, err := decoder.Token(); err != io.EOF {
		return nil, false
	}
	return fields, true
}

// doorString is the string under key ("" when it is missing or null), or
// false when it holds anything else.
func doorString(fields map[string]json.RawMessage, key string) (string, bool) {
	raw, ok := fields[key]
	if !ok || string(raw) == "null" {
		return "", true
	}
	var value string
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", false
	}
	return value, true
}

// hostLocked is the running door host, started if needed; doorMu is held.
func (node *bridgeNode) hostLocked() (*doorHost, error) {
	if node.doorHost != nil {
		return node.doorHost, nil
	}
	host, err := newDoorHost(node)
	if err != nil {
		return nil, err
	}
	node.doorHost = host
	return host, nil
}

// releaseHostLocked stops the door host once no door runs; doorMu is held.
func (node *bridgeNode) releaseHostLocked() {
	if node.doorHost != nil && node.door == nil && len(node.mailboxDoors) == 0 {
		node.doorHost.stop()
		node.doorHost = nil
	}
}

// startDoor runs the door with the key from seedHex, replacing a door with
// another key. The same key keeps the running door.
func (node *bridgeNode) startDoor(seedHex string) (*doorNode, error) {
	node.doorMu.Lock()
	defer node.doorMu.Unlock()
	if current := node.door; current != nil {
		if current.seed == strings.ToLower(strings.TrimSpace(seedHex)) {
			return current, nil
		}
		current.stop()
		node.door = nil
	}
	if _, err := doorSeed(seedHex); err != nil {
		node.releaseHostLocked()
		return nil, err
	}
	host, err := node.hostLocked()
	if err != nil {
		return nil, err
	}
	door, err := newDoorNode(node, host, seedHex, false)
	if err != nil {
		node.releaseHostLocked()
		return nil, err
	}
	node.door = door
	return door, nil
}

// stopDoor shuts the door, if one runs.
func (node *bridgeNode) stopDoor() {
	node.doorMu.Lock()
	defer node.doorMu.Unlock()
	if node.door != nil {
		node.door.stop()
		node.door = nil
	}
	node.releaseHostLocked()
}

// doorState is what the app learns about the door: never its key.
func (node *bridgeNode) doorState() map[string]any {
	node.doorMu.Lock()
	door := node.door
	node.doorMu.Unlock()
	if door == nil {
		return map[string]any{"running": false}
	}
	return map[string]any{
		"running":   true,
		"address":   door.address,
		"publicKey": hex.EncodeToString(door.core.PublicKey()),
		"linked":    door.linked(),
	}
}

// doorSend sends a flat frame from the flat's door (YggDoorSendSignal).
func (node *bridgeNode) doorSend(remoteAddress, payload string) error {
	node.doorMu.Lock()
	door := node.door
	node.doorMu.Unlock()
	if door == nil {
		return errors.New("no door runs")
	}
	return door.send(remoteAddress, payload)
}

// setMailboxDoors runs exactly the mailbox doors with the keys in seeds (hex,
// at most maxHostedDoors): new keys start, missing ones stop, running ones
// stay. Returns the running doors' addresses by key.
func (node *bridgeNode) setMailboxDoors(seeds []string) (map[string]string, error) {
	node.doorMu.Lock()
	defer node.doorMu.Unlock()
	wanted := make(map[string]bool)
	for _, seed := range seeds {
		seed = strings.ToLower(strings.TrimSpace(seed))
		if _, err := doorSeed(seed); err != nil {
			return nil, err
		}
		if node.door != nil && node.door.seed == seed {
			return nil, errors.New("a mailbox door cannot share the flat door's key")
		}
		wanted[seed] = true
	}
	if len(wanted) > maxHostedDoors {
		return nil, fmt.Errorf("at most %d mailbox doors", maxHostedDoors)
	}
	for seed, door := range node.mailboxDoors {
		if !wanted[seed] {
			door.stop()
			delete(node.mailboxDoors, seed)
		}
	}
	var failed error
	for seed := range wanted {
		if _, running := node.mailboxDoors[seed]; running {
			continue
		}
		host, err := node.hostLocked()
		if err != nil {
			failed = err
			break
		}
		door, err := newDoorNode(node, host, seed, true)
		if err != nil {
			failed = err
			continue
		}
		if node.mailboxDoors == nil {
			node.mailboxDoors = make(map[string]*doorNode)
		}
		node.mailboxDoors[seed] = door
	}
	node.releaseHostLocked()
	addresses := make(map[string]string, len(node.mailboxDoors))
	for seed, door := range node.mailboxDoors {
		addresses[seed] = door.address
	}
	return addresses, failed
}
