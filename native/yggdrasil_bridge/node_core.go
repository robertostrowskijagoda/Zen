package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"regexp"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/ipv6rwc"
	"github.com/yggdrasil-network/yggdrasil-go/src/multicast"
)

func responseOK(data any) *C.char {
	payload, _ := json.Marshal(bridgeResponse{OK: true, Data: data})
	return C.CString(string(payload))
}

func responseError(err error) *C.char {
	payload, _ := json.Marshal(bridgeResponse{OK: false, Error: err.Error()})
	return C.CString(string(payload))
}

func withNode(handle C.int, fn func(*bridgeNode) *C.char) *C.char {
	value, ok := nodes.Load(int32(handle))
	if !ok {
		return responseError(fmt.Errorf("node handle %d does not exist", int(handle)))
	}
	node := value.(*bridgeNode)
	// Whether anyone still uses the node (node_identity.go).
	node.touch()
	defer node.touch()
	return fn(node)
}

func createNode(configJSON string) (*bridgeNode, error) {
	logger := log.New(os.Stdout, "", 0)
	logger.EnableLevel("error")
	logger.EnableLevel("warn")
	logger.EnableLevel("info")

	cfg := config.GenerateConfig()
	cfg.IfName = "none"
	cfg.AdminListen = "none"
	configJSON, peerTarget := takeZenPeerTarget(configJSON)
	if err := cfg.UnmarshalHJSON([]byte(configJSON)); err != nil {
		return nil, err
	}
	// One node per identity in this process (node_identity.go).
	identity, err := claimNodeIdentity(nodeIdentityKey(cfg))
	if err != nil {
		logger.Warnf("not starting a second node with this identity: another one still runs in this process")
		return nil, err
	}
	started := false
	defer func() {
		if !started {
			identity.release()
		}
	}()
	ensureDefaultRuntimeConfig(cfg)
	cfg.IfName = "none"
	cfg.AdminListen = "none"
	// A phone dials a few of its pool (phone_peers.go); a computer on
	// battery is no bridge and dials a few too (power_source.go).
	var phonePeers *phonePeerKeeper
	var power *desktopPowerSaver
	if isPhoneOS() {
		phonePeers = newPhonePeerKeeper(cfg.Peers, phonePeerTarget(peerTarget))
		cfg.Peers = append([]string(nil), phonePeers.dialled...)
	} else {
		onBattery := onBatteryPower()
		power = newDesktopPowerSaver(onBattery, cfg.Peers)
		if onBattery {
			cfg.Peers = firstPeers(cfg.Peers, desktopBatteryPeerCount)
		}
	}

	iprange := net.IPNet{
		IP:   net.ParseIP("200::"),
		Mask: net.CIDRMask(7, 128),
	}
	options := []core.SetupOption{
		core.PeerFilter(func(ip net.IP) bool {
			return !iprange.Contains(ip)
		}),
	}
	options = append(options, nodeInfoPrivacyOptions()...)
	if len(cfg.Peers) > 0 {
		logger.Infof("starting node with %d outbound peers (first=%s)", len(cfg.Peers), cfg.Peers[0])
	} else {
		logger.Warnf("starting node with no outbound peers")
	}
	for _, peer := range cfg.Peers {
		options = append(options, core.Peer{URI: peer})
	}
	for intf, peers := range cfg.InterfacePeers {
		for _, peer := range peers {
			options = append(options, core.Peer{URI: peer, SourceInterface: intf})
		}
	}
	for _, allowed := range cfg.AllowedPublicKeys {
		k, err := hex.DecodeString(allowed)
		if err != nil {
			return nil, err
		}
		options = append(options, core.AllowedPublicKey(k[:]))
	}
	listenOptions := make([]core.SetupOption, 0, len(cfg.Listen))
	activeListen := make([]string, 0, len(cfg.Listen))
	var peerGuards []*peerListenGuard
	closePeerGuards := func() {
		for _, guard := range peerGuards {
			guard.close()
		}
		peerGuards = nil
	}
	for _, listenAddr := range cfg.Listen {
		nodeListen := listenAddr
		if _, _, guarded := guardedListenAddress(listenAddr); guarded && !isPhoneOS() {
			// A bridge's public port goes through the connection and
			// transfer limits (peer_guard.go); the node listens on loopback.
			guard, backendURI, guardErr := startPeerListenGuard(listenAddr, defaultPeerGuardLimits, func(ip net.IP) bool {
				return !iprange.Contains(ip)
			})
			if guardErr != nil {
				// The inbound peering port is fixed, so another process (an
				// older Zen instance that is still shutting down, or an
				// unrelated service) can hold it. The node then stays a leaf
				// for this address and reaches the mesh through outbound peers.
				logger.Warnf("listen address %s unavailable (%v), starting without it", listenAddr, guardErr)
				continue
			}
			peerGuards = append(peerGuards, guard)
			nodeListen = backendURI
		}
		listenOptions = append(listenOptions, core.ListenAddress(nodeListen))
		activeListen = append(activeListen, listenAddr)
	}

	yggCore, err := core.New(cfg.Certificate, logger, append(options, listenOptions...)...)
	if err != nil && len(listenOptions) > 0 {
		// Same as above, for a listener the node binds itself. Falling back
		// to a leaf node keeps the mesh reachable through outbound peers
		// instead of leaving the user with no network at all.
		logger.Warnf("listen address unavailable (%v), starting without an inbound listener", err)
		closePeerGuards()
		yggCore, err = core.New(cfg.Certificate, logger, options...)
		activeListen = []string{}
	}
	if err != nil {
		closePeerGuards()
		return nil, err
	}
	cfg.Listen = activeListen

	var multicastModule *multicast.Multicast
	if len(cfg.MulticastInterfaces) > 0 {
		multicastOptions := []multicast.SetupOption{}
		for _, intf := range cfg.MulticastInterfaces {
			multicastOptions = append(multicastOptions, multicast.MulticastInterface{
				Regex:    regexp.MustCompile(intf.Regex),
				Beacon:   intf.Beacon,
				Listen:   intf.Listen,
				Port:     intf.Port,
				Priority: uint8(intf.Priority),
				Password: intf.Password,
			})
		}
		multicastModule, err = multicast.New(yggCore, logger, multicastOptions...)
		if err != nil {
			// LAN discovery is optional. A multicast bind failure on Android
			// (cellular/dummy interfaces, missing lock) used to abort the
			// whole node, which left the UI stuck on "Łączę..." with no mesh.
			logger.Warnf("multicast unavailable (%v), continuing without LAN discovery", err)
			multicastModule = nil
		}
	}

	iprwc := ipv6rwc.NewReadWriteCloser(yggCore)
	mtu := cfg.IfMTU
	if iprwc.MaxMTU() < mtu {
		mtu = iprwc.MaxMTU()
	}
	iprwc.SetMTU(mtu)

	node := &bridgeNode{
		publicPeers:    publicPeersOf(cfg.Peers),
		core:           yggCore,
		iprwc:          iprwc,
		config:         cfg,
		multicast:      multicastModule,
		logger:         logger,
		signalPartials: make(map[string]*signalReassembly),
		relays:         make(map[string]*relayState),
		peerProbe:      newPeerProbeState(),
		nudgeStop:      make(chan struct{}),
		peerGuards:     peerGuards,
		phonePeers:     phonePeers,
		power:          power,
		identity:       identity,
	}
	started = true
	if phonePeers != nil {
		go node.watchPhonePeers()
	}
	if isPhoneOS() {
		// Strangers' traffic through the phone (transit_guard.go).
		node.transitGuard = &transitGuard{}
		node.transitStop = make(chan struct{})
		node.startTransitWatch()
	}
	if power != nil {
		if power.onBattery {
			// The full list stays in power for when it is plugged in again.
			for _, guard := range peerGuards {
				guard.setPaused(true)
			}
		}
		go node.watchDesktopPower()
	}
	if !isPhoneOS() {
		node.startPeerProbeMonitor()
	}
	if shouldUseStrictLeafMode() {
		node.leafMonitor = newLeafPeerMonitor()
		node.startLeafMonitor()
	}
	yggCore.RetryPeersNow()
	node.startPeerNudge()
	return node, nil
}

// nodeInfoPrivacyOptions: any node of the mesh may ask any other for its
// NodeInfo. The node key is this person's address, so by default the
// answer would tell everyone which system, architecture and Yggdrasil
// version they run: nothing is answered beyond an empty object.
func nodeInfoPrivacyOptions() []core.SetupOption {
	return []core.SetupOption{
		core.NodeInfoPrivacy(true),
		core.NodeInfo(map[string]interface{}{}),
	}
}

func (node *bridgeNode) startPeerNudge() {
	if node.nudgeStop == nil {
		return
	}
	go func() {
		for i := 0; i < 15; i++ {
			select {
			case <-node.nudgeStop:
				return
			case <-time.After(2 * time.Second):
			}
			if node.hasUpPeer() {
				return
			}
			node.logger.Infof("no mesh peers yet; retrying outbound connections")
			node.core.RetryPeersNow()
		}
	}()
}

func (node *bridgeNode) stopPeerNudge() {
	if node.nudgeStop == nil {
		return
	}
	node.nudgeStopOnce.Do(func() {
		close(node.nudgeStop)
	})
}

func (node *bridgeNode) hasUpPeer() bool {
	for _, peer := range node.core.GetPeers() {
		if peer.Up {
			return true
		}
	}
	return false
}

func summarizeConfig(cfg *config.NodeConfig) *configSummary {
	pub := ed25519.PrivateKey(cfg.PrivateKey).Public().(ed25519.PublicKey)
	addrBytes := address.AddrForKey(pub)
	addr := net.IP(addrBytes[:])
	subnetBytes := address.SubnetForKey(pub)
	subnet := net.IPNet{
		IP:   append(subnetBytes[:], 0, 0, 0, 0, 0, 0, 0, 0),
		Mask: net.CIDRMask(64, 128),
	}
	return &configSummary{
		PublicKey:   hex.EncodeToString(pub),
		IPv6Address: addr.String(),
		IPv6Subnet:  subnet.String(),
	}
}

func currentLeafPeer(node *bridgeNode) string {
	if node.leafMonitor == nil {
		return ""
	}
	peer, _ := node.leafMonitor.state()
	return peer
}

func currentSelectedPeer(node *bridgeNode, peers []peerJSON) (string, string, int, int) {
	bestPeer, bestLatency, availableCount, candidateCount, _ := node.peerProbe.snapshot()
	selectedPeer := bestPeer
	selectedPeerLatency := ""
	activeLeafPeer := currentLeafPeer(node)
	if activeLeafPeer != "" {
		selectedPeer = activeLeafPeer
		for _, peer := range peers {
			if peer.URI == activeLeafPeer && peer.Latency != "" {
				selectedPeerLatency = peer.Latency
				break
			}
		}
	}
	if selectedPeerLatency == "" && selectedPeer == bestPeer && bestLatency > 0 {
		selectedPeerLatency = bestLatency.String()
	}
	return selectedPeer, selectedPeerLatency, availableCount, candidateCount
}

func normalizeNodeState(handle int32, node *bridgeNode) map[string]any {
	self := node.core.GetSelf()
	peers := buildPeerJSON(node.core.GetPeers())
	subnet := node.core.Subnet()
	cfg := node.configSnapshot()
	// Never leak the node identity key across the FFI boundary; Dart only
	// needs peering/routing details for the runtime dashboard. A nil key is
	// omitted from the JSON entirely (omitempty).
	cfg.PrivateKey = nil
	// Nor the LAN discovery password (the snapshot's slice is a copy).
	for i := range cfg.MulticastInterfaces {
		cfg.MulticastInterfaces[i].Password = ""
	}
	activeLeafPeer := currentLeafPeer(node)
	selectedPeer, selectedPeerLatency, availablePeerCount, candidatePeerCount := currentSelectedPeer(node, peers)
	if candidatePeerCount == 0 {
		candidatePeerCount = len(runtimePeerCandidatePool(cfg))
	}
	return map[string]any{
		"handle":              handle,
		"publicKey":           hex.EncodeToString(self.Key),
		"address":             node.core.Address().String(),
		"subnet":              subnet.String(),
		"routingEntries":      self.RoutingEntries,
		"mtu":                 node.core.MTU(),
		"listen":              append([]string(nil), cfg.Listen...),
		"peers":               peers,
		"signalPort":          yggSignalPort,
		"config":              cfg,
		"strictLeafMode":      node.leafMonitor != nil,
		"trustedPeerCount":    candidatePeerCount,
		"activeLeafPeer":      activeLeafPeer,
		"availablePeerCount":  availablePeerCount,
		"peerPoolCount":       candidatePeerCount,
		"selectedPeer":        selectedPeer,
		"selectedPeerLatency": selectedPeerLatency,
		"publicPeersCustom":   customPublicPeers(),
		"pqKey":               node.ownSignalKey(),
		"traffic":             node.trafficState(),
		"goMemory":            goMemoryStats(),
	}
}

// ownSignalKey is the fingerprint of this node's device key (pq_session.go),
// "" before it can be made.
func (node *bridgeNode) ownSignalKey() string {
	if node.pqPlain {
		return ""
	}
	endpoint, err := node.pqEndpointOf()
	if err != nil {
		return ""
	}
	return endpoint.ownFingerprint()
}

func buildPeerJSON(peers []core.PeerInfo) []peerJSON {
	result := make([]peerJSON, 0, len(peers))
	for _, peer := range peers {
		item := peerJSON{
			URI:     peer.URI,
			Up:      peer.Up,
			Inbound: peer.Inbound,
		}
		if peer.Key != nil {
			addr := address.AddrForKey(peer.Key)
			item.IP = net.IP(addr[:]).String()
		}
		if peer.Latency > 0 {
			item.Latency = peer.Latency.String()
		}
		if peer.LastError != nil {
			item.LastError = peer.LastError.Error()
		}
		result = append(result, item)
	}
	return result
}

func updatePeerList(cfg *config.NodeConfig, uri string, add bool) {
	filtered := make([]string, 0, len(cfg.Peers))
	found := false
	for _, peer := range cfg.Peers {
		if peer == uri {
			found = true
			if !add {
				continue
			}
		}
		filtered = append(filtered, peer)
	}
	if add && !found {
		filtered = append(filtered, uri)
	}
	cfg.Peers = filtered
}
