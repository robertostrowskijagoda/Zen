package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/url"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/config"
)

func ensureDefaultRuntimeConfig(cfg *config.NodeConfig) {
	// LAN discovery (multicast) beacons carry this node's public key, which
	// is also the person's Zen identity. On a café or office network anyone
	// listening could recognise (and follow) them, and every Yggdrasil node
	// there would peer with them on its own. So it stays off unless the app
	// turns it on with a password (one only the person's own devices share).
	cfg.MulticastInterfaces = lanDiscoveryInterfaces(cfg.MulticastInterfaces)
	switch {
	case isPhoneOS():
		// iOS gets the phone profile too: no inbound port to open, and
		// multicast needs an entitlement only paid accounts can get.
		applyAndroidRuntimeConfig(cfg)
	default:
		cfg.Peers = desktopRuntimePeers(cfg.Peers)
		// Desktops always expose a stable TLS peering port so other Zen
		// nodes (and the wider mesh) can reach them; the app opens it in the
		// home router and announces it once friends confirm it works.
		cfg.Listen = []string{defaultDesktopPeerListen}
	}
}

// lanDiscoveryInterfaces keeps LAN discovery only when it was configured
// with a password: devices then peer only with others that know it.
// Yggdrasil's generated default (beacon and listen everywhere, no password),
// which older app versions stored in their config, is dropped.
func lanDiscoveryInterfaces(configured []config.MulticastInterfaceConfig) []config.MulticastInterfaceConfig {
	for _, intf := range configured {
		if intf.Password == "" || (!intf.Beacon && !intf.Listen) {
			continue
		}
		return []config.MulticastInterfaceConfig{
			{
				Regex:    multicastInterfaceRegex(),
				Beacon:   intf.Beacon,
				Listen:   intf.Listen,
				Port:     intf.Port,
				Priority: intf.Priority,
				Password: intf.Password,
			},
		}
	}
	return []config.MulticastInterfaceConfig{}
}

func multicastInterfaceRegex() string {
	if runtime.GOOS == "android" {
		return androidMulticastInterfaceRegex
	}
	return defaultMulticastInterfaceRegex
}

func applyAndroidRuntimeConfig(cfg *config.NodeConfig) {
	// Leaf node: no inbound listener, no TUN, no multicast. Multicast on
	// Android walks interfaces via net.InterfaceByName, which SELinux
	// rejects — and that used to stall outbound public peering too.
	// Always replace Peers with the live curated set so a saved snapshot of
	// dead :443 IPs cannot pin the phone on "Łączę..." across resets.
	cfg.Listen = []string{}
	cfg.IfName = "none"
	cfg.AdminListen = "none"
	cfg.MulticastInterfaces = []config.MulticastInterfaceConfig{}
	cfg.InterfacePeers = map[string][]string{}
	cfg.AllowedPublicKeys = []string{}
	cfg.Peers = androidBootstrapPeers()
}

func countNonLoopbackPeers(peers []string) int {
	count := 0
	for _, peer := range peers {
		if peer != "" && !isLoopbackPeerURI(peer) {
			count++
		}
	}
	return count
}

func androidBootstrapPeers() []string {
	return append([]string(nil), androidPublicPeers...)
}

func ipv4LiteralPublicPeers() []string {
	peers := make([]string, 0, len(defaultPublicPeers))
	for _, peer := range prioritizedPublicPeers() {
		parsed, err := url.Parse(strings.TrimSpace(peer))
		if err != nil {
			continue
		}
		ip := net.ParseIP(parsed.Hostname())
		if ip == nil || ip.To4() == nil {
			continue
		}
		peers = append(peers, peer)
	}
	return peers
}

func prioritizedPublicPeers() []string {
	peers := append([]string(nil), defaultPublicPeers...)
	sort.SliceStable(peers, func(i, j int) bool {
		si, sj := publicPeerScore(peers[i]), publicPeerScore(peers[j])
		if si != sj {
			return si > sj
		}
		return peers[i] < peers[j]
	})
	return peers
}

func publicPeerScore(uri string) int {
	parsed, err := url.Parse(strings.TrimSpace(uri))
	if err != nil {
		return 0
	}
	score := 0
	switch strings.ToLower(parsed.Scheme) {
	case "quic":
		// UDP: the TCP probe cannot measure it, so never spend a probe slot.
		score -= 1000
	case "tls":
		score += 20
	}
	if peerHostIsIPv6Literal(uri) {
		score -= 20
	}
	switch parsed.Port() {
	case "443":
		score += 100
	case "8443", "993":
		score += 30
	}
	host := parsed.Hostname()
	if ip := net.ParseIP(host); ip != nil && ip.To4() != nil {
		score += 50
	}
	return score
}

func ensureRuntimePublicPeers(existing []string, limit int) []string {
	peers := make([]string, 0, len(existing)+len(defaultPublicPeers))
	seen := make(map[string]bool, len(existing)+len(defaultPublicPeers))
	appendPeer := func(peer string) {
		if peer == "" || seen[peer] {
			return
		}
		seen[peer] = true
		peers = append(peers, peer)
	}
	for _, peer := range existing {
		appendPeer(peer)
		if limit > 0 && len(peers) >= limit {
			return peers[:limit]
		}
	}
	if shouldUseConfiguredPeersOnly(existing) {
		return peers
	}
	for _, peer := range defaultPublicPeers {
		appendPeer(peer)
		if limit > 0 && len(peers) >= limit {
			return peers[:limit]
		}
	}
	return peers
}

func shouldUseConfiguredPeersOnly(existing []string) bool {
	if len(existing) == 0 {
		return false
	}
	for _, peer := range existing {
		if !isLoopbackPeerURI(peer) {
			return false
		}
	}
	return true
}

func isLoopbackPeerURI(peer string) bool {
	parsed, err := url.Parse(strings.TrimSpace(peer))
	if err != nil {
		return false
	}
	host := parsed.Hostname()
	if host == "" {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func runtimePeerCandidatePool(cfg *config.NodeConfig) []string {
	if isPhoneOS() {
		return ensureRuntimePublicPeers(prioritizedPublicPeers(), 0)
	}
	return ensureRuntimePublicPeers(cfg.Peers, 0)
}

func runtimeManagedPeerCount() int {
	// Never shrink the live peer list down to a handful of probe winners.
	// On Android that replaced working (or Dart-injected) peers with a tiny
	// set and left the node unable to join the mesh.
	return 0
}

func runtimePeerProbeCandidateLimit() int {
	if isPhoneOS() {
		return androidPeerProbeCandidateLimit
	}
	return desktopPeerProbeCandidateLimit
}

func runtimePeerProbeRefreshInterval() time.Duration {
	if runtimeManagedPeerCount() > 0 {
		return 3 * time.Minute
	}
	return peerProbeRefreshInterval
}

func shouldUseStrictLeafMode() bool {
	return false
}

// isPhoneOS reports Android and iOS, which run Zen as a leaf node.
func isPhoneOS() bool {
	return runtime.GOOS == "android" || runtime.GOOS == "ios"
}

func newLeafPeerMonitor() *leafPeerMonitor {
	return &leafPeerMonitor{
		trigger: make(chan struct{}, 1),
		stop:    make(chan struct{}),
	}
}

func newPeerProbeState() *peerProbeState {
	return &peerProbeState{
		trigger: make(chan struct{}, 1),
		stop:    make(chan struct{}),
	}
}

func (monitor *leafPeerMonitor) state() (string, time.Time) {
	monitor.mu.RLock()
	defer monitor.mu.RUnlock()
	return monitor.activePeer, monitor.activeSince
}

func (monitor *leafPeerMonitor) setActive(peer string) {
	monitor.mu.Lock()
	defer monitor.mu.Unlock()
	monitor.activePeer = peer
	if peer == "" {
		monitor.activeSince = time.Time{}
		return
	}
	monitor.activeSince = time.Now()
}

func (monitor *leafPeerMonitor) resetFailures() {
	monitor.mu.Lock()
	defer monitor.mu.Unlock()
	monitor.failures = 0
}

func (monitor *leafPeerMonitor) nextBackoff() time.Duration {
	monitor.mu.Lock()
	defer monitor.mu.Unlock()
	index := monitor.failures
	if index >= len(leafRetryBackoff) {
		index = len(leafRetryBackoff) - 1
	}
	delay := leafRetryBackoff[index]
	if monitor.failures < len(leafRetryBackoff)-1 {
		monitor.failures++
	}
	return delay
}

func (monitor *leafPeerMonitor) triggerNow() {
	select {
	case monitor.trigger <- struct{}{}:
	default:
	}
}

func (monitor *leafPeerMonitor) stopLoop() {
	monitor.stopOnce.Do(func() {
		close(monitor.stop)
	})
}

func (probe *peerProbeState) snapshot() (string, time.Duration, int, int, time.Time) {
	probe.mu.RLock()
	defer probe.mu.RUnlock()
	return probe.bestPeer, probe.bestLatency, probe.availableCount, probe.candidateCount, probe.lastCheckedAt
}

func (probe *peerProbeState) setSnapshot(bestPeer string, bestLatency time.Duration, availableCount, candidateCount int) {
	probe.mu.Lock()
	defer probe.mu.Unlock()
	probe.bestPeer = bestPeer
	probe.bestLatency = bestLatency
	probe.availableCount = availableCount
	probe.candidateCount = candidateCount
	probe.lastCheckedAt = time.Now()
}

func (probe *peerProbeState) triggerNow() {
	select {
	case probe.trigger <- struct{}{}:
	default:
	}
}

func (probe *peerProbeState) stopLoop() {
	probe.stopOnce.Do(func() {
		close(probe.stop)
	})
}

func (node *bridgeNode) configSnapshot() *config.NodeConfig {
	node.configMu.RLock()
	defer node.configMu.RUnlock()
	snapshot := *node.config
	snapshot.Peers = append([]string(nil), node.config.Peers...)
	snapshot.Listen = append([]string(nil), node.config.Listen...)
	snapshot.AllowedPublicKeys = append([]string(nil), node.config.AllowedPublicKeys...)
	snapshot.MulticastInterfaces = append([]config.MulticastInterfaceConfig(nil), node.config.MulticastInterfaces...)
	if node.config.InterfacePeers != nil {
		snapshot.InterfacePeers = make(map[string][]string, len(node.config.InterfacePeers))
		for key, peers := range node.config.InterfacePeers {
			snapshot.InterfacePeers[key] = append([]string(nil), peers...)
		}
	}
	return &snapshot
}

func (node *bridgeNode) setConfiguredPeers(peers []string) {
	node.configMu.Lock()
	node.config.Peers = append([]string(nil), peers...)
	node.configMu.Unlock()
	if node.peerProbe != nil {
		node.peerProbe.triggerNow()
	}
}

func (node *bridgeNode) updateConfiguredPeer(uri string, add bool) {
	node.configMu.Lock()
	updatePeerList(node.config, uri, add)
	node.configMu.Unlock()
	if node.peerProbe != nil {
		node.peerProbe.triggerNow()
	}
}

func sameConfiguredPeerOrder(current []string, desired []string) bool {
	if len(current) != len(desired) {
		return false
	}
	for index, peer := range current {
		if peer != desired[index] {
			return false
		}
	}
	return true
}

func (node *bridgeNode) syncConfiguredPeers(peers []string) error {
	if len(peers) == 0 {
		return errors.New("no peers selected")
	}
	current := node.configSnapshot().Peers
	currentSet := make(map[string]bool, len(current))
	for _, peer := range current {
		currentSet[peer] = true
	}
	desiredSet := make(map[string]bool, len(peers))
	for _, peer := range peers {
		desiredSet[peer] = true
		if currentSet[peer] {
			continue
		}
		parsed, err := url.Parse(peer)
		if err != nil {
			return err
		}
		if err := node.core.AddPeer(parsed, ""); err != nil {
			return err
		}
	}
	for _, peer := range current {
		if desiredSet[peer] {
			continue
		}
		parsed, err := url.Parse(peer)
		if err != nil {
			return err
		}
		if err := node.core.RemovePeer(parsed, ""); err != nil {
			return err
		}
	}
	if !sameConfiguredPeerOrder(current, peers) {
		node.setConfiguredPeers(peers)
	}
	node.core.RetryPeersNow()
	return nil
}

func (node *bridgeNode) startPeerProbeMonitor() {
	if node.peerProbe == nil {
		return
	}
	go func() {
		wait := time.Duration(0)
		for {
			if wait > 0 {
				timer := time.NewTimer(wait)
				select {
				case <-node.peerProbe.stop:
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
					return
				case <-node.peerProbe.trigger:
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
				case <-timer.C:
				}
			} else {
				select {
				case <-node.peerProbe.stop:
					return
				case <-node.peerProbe.trigger:
				default:
				}
			}
			wait = node.runPeerProbeCycle()
		}
	}()
	node.peerProbe.triggerNow()
}

func (node *bridgeNode) stopPeerProbeMonitor() {
	if node.peerProbe == nil {
		return
	}
	node.peerProbe.stopLoop()
}

func (node *bridgeNode) runPeerProbeCycle() time.Duration {
	results, availableCount, candidateCount, _ := node.probePeerPoolResults("")
	var (
		bestPeer    string
		bestLatency time.Duration
	)
	currentPeers := append([]string(nil), node.configSnapshot().Peers...)
	if len(results) > 0 {
		bestPeer = results[0].uri
		bestLatency = results[0].latency
	} else if len(currentPeers) > 0 {
		bestPeer = currentPeers[0]
	}
	target := runtimeManagedPeerCount()
	if target > 0 {
		desiredPeers := make([]string, 0, target)
		selected := make(map[string]bool, target)
		for _, result := range results {
			if len(desiredPeers) >= target {
				break
			}
			if selected[result.uri] {
				continue
			}
			desiredPeers = append(desiredPeers, result.uri)
			selected[result.uri] = true
		}
		for _, peer := range currentPeers {
			if len(desiredPeers) >= target {
				break
			}
			if peer == "" || selected[peer] {
				continue
			}
			desiredPeers = append(desiredPeers, peer)
			selected[peer] = true
		}
		if len(desiredPeers) > 0 {
			_ = node.syncConfiguredPeers(desiredPeers)
		}
	}
	if node.peerProbe != nil {
		node.peerProbe.setSnapshot(bestPeer, bestLatency, availableCount, candidateCount)
	}
	if node.leafMonitor != nil {
		node.leafMonitor.triggerNow()
	}
	return runtimePeerProbeRefreshInterval()
}

func (node *bridgeNode) startLeafMonitor() {
	if node.leafMonitor == nil {
		return
	}
	go func() {
		wait := time.Duration(0)
		for {
			if wait > 0 {
				timer := time.NewTimer(wait)
				select {
				case <-node.leafMonitor.stop:
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
					return
				case <-node.leafMonitor.trigger:
					if !timer.Stop() {
						select {
						case <-timer.C:
						default:
						}
					}
				case <-timer.C:
				}
			} else {
				select {
				case <-node.leafMonitor.stop:
					return
				case <-node.leafMonitor.trigger:
				default:
				}
			}
			wait = node.runLeafPeerCycle()
		}
	}()
	node.leafMonitor.triggerNow()
}

func (node *bridgeNode) stopLeafMonitor() {
	if node.leafMonitor == nil {
		return
	}
	node.leafMonitor.stopLoop()
}

func (node *bridgeNode) runLeafPeerCycle() time.Duration {
	activePeer, activeSince := node.leafMonitor.state()
	if activePeer != "" {
		if node.isLeafPeerHealthy(activePeer, activeSince) {
			bestPeer, _, _, _, checkedAt := node.peerProbe.snapshot()
			if bestPeer == "" || bestPeer == activePeer || !checkedAt.After(activeSince) {
				return leafHealthCheckInterval
			}
		}
		node.disconnectLeafPeer(activePeer)
		node.leafMonitor.setActive("")
	}
	nextPeer, err := node.selectBestLeafPeer(activePeer)
	if err != nil {
		node.leafMonitor.setActive("")
		return node.leafMonitor.nextBackoff()
	}
	if err := node.connectLeafPeer(nextPeer); err != nil {
		node.leafMonitor.setActive("")
		return node.leafMonitor.nextBackoff()
	}
	node.leafMonitor.setActive(nextPeer)
	node.leafMonitor.resetFailures()
	return leafConnectGracePeriod
}

func (node *bridgeNode) isLeafPeerHealthy(peer string, activeSince time.Time) bool {
	if time.Since(activeSince) < leafConnectGracePeriod {
		return true
	}
	for _, info := range node.core.GetPeers() {
		if info.URI != peer {
			continue
		}
		return info.Up
	}
	return false
}

func (node *bridgeNode) selectBestLeafPeer(exclude string) (string, error) {
	if exclude == "" {
		bestPeer, _, _, _, checkedAt := node.peerProbe.snapshot()
		if bestPeer != "" && !checkedAt.IsZero() {
			return bestPeer, nil
		}
	}
	bestPeer, _, _, _, err := node.probePeerPool(exclude)
	if err != nil {
		return "", err
	}
	if exclude == "" && node.peerProbe != nil {
		node.peerProbe.triggerNow()
	}
	return bestPeer, nil
}

func (node *bridgeNode) probePeerPoolResults(exclude string) ([]leafPeerProbeResult, int, int, error) {
	allCandidates := runtimePeerCandidatePool(node.configSnapshot())
	if limit := runtimePeerProbeCandidateLimit(); limit > 0 && len(allCandidates) > limit {
		allCandidates = allCandidates[:limit]
	}
	candidateCount := len(allCandidates)
	candidates := make([]string, 0, candidateCount)
	for _, peer := range allCandidates {
		if peer == "" || peer == exclude {
			continue
		}
		candidates = append(candidates, peer)
	}
	if len(candidates) == 0 {
		return nil, 0, candidateCount, errors.New("no public peers configured")
	}
	var (
		mu        sync.Mutex
		available []leafPeerProbeResult
		lastError error
	)
	var waitGroup sync.WaitGroup
	for _, peer := range candidates {
		waitGroup.Add(1)
		go func(uri string) {
			defer waitGroup.Done()
			latency, err := probePeerLatency(uri)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				lastError = err
				return
			}
			available = append(available, leafPeerProbeResult{uri: uri, latency: latency})
		}(peer)
	}
	done := make(chan struct{})
	go func() {
		waitGroup.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(leafProbeCycleBudget):
	}
	mu.Lock()
	availableCount := len(available)
	snapshot := append([]leafPeerProbeResult(nil), available...)
	errSnapshot := lastError
	mu.Unlock()
	if len(snapshot) == 0 {
		if errSnapshot == nil {
			errSnapshot = errors.New("no public peers reachable")
		}
		return nil, availableCount, candidateCount, errSnapshot
	}
	sort.Slice(snapshot, func(i, j int) bool {
		if snapshot[i].latency == snapshot[j].latency {
			return snapshot[i].uri < snapshot[j].uri
		}
		return snapshot[i].latency < snapshot[j].latency
	})
	return snapshot, availableCount, candidateCount, nil
}

func (node *bridgeNode) probePeerPool(exclude string) (string, time.Duration, int, int, error) {
	results, availableCount, candidateCount, err := node.probePeerPoolResults(exclude)
	if err != nil {
		return "", 0, availableCount, candidateCount, err
	}
	bestPeer := results[0].uri
	bestLatency := results[0].latency
	return bestPeer, bestLatency, availableCount, candidateCount, nil
}

func probePeerLatency(peerURI string) (time.Duration, error) {
	parsed, err := url.Parse(peerURI)
	if err != nil {
		return 0, err
	}
	address, err := peerProbeAddress(parsed)
	if err != nil {
		return 0, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), leafProbeTimeout)
	defer cancel()
	dialer := net.Dialer{}
	startedAt := time.Now()
	conn, err := dialer.DialContext(ctx, "tcp", address)
	if err != nil {
		return 0, err
	}
	_ = conn.Close()
	return time.Since(startedAt), nil
}

func peerProbeAddress(parsed *url.URL) (string, error) {
	scheme := strings.ToLower(parsed.Scheme)
	switch scheme {
	case "tls", "tcp", "ws", "wss":
	default:
		return "", fmt.Errorf("unsupported peer scheme %q", parsed.Scheme)
	}
	host := parsed.Hostname()
	if host == "" {
		return "", errors.New("peer URI missing host")
	}
	port := parsed.Port()
	if port == "" {
		switch scheme {
		case "tls", "wss":
			port = "443"
		case "tcp":
			port = "80"
		case "ws":
			port = "80"
		}
	}
	return net.JoinHostPort(host, port), nil
}

func (node *bridgeNode) connectLeafPeer(peer string) error {
	parsed, err := url.Parse(peer)
	if err != nil {
		return err
	}
	if err := node.core.AddPeer(parsed, ""); err != nil {
		return err
	}
	node.setConfiguredPeers([]string{peer})
	return nil
}

func (node *bridgeNode) disconnectLeafPeer(peer string) {
	if peer == "" {
		node.setConfiguredPeers([]string{})
		return
	}
	parsed, err := url.Parse(peer)
	if err == nil {
		_ = node.core.RemovePeer(parsed, "")
	}
	node.setConfiguredPeers([]string{})
}
