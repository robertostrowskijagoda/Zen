package main

import (
	"net"
	"net/url"
	"strings"
	"testing"

	"github.com/yggdrasil-network/yggdrasil-go/src/config"
)

func TestPublicPeerScorePrefers443AndIPv4(t *testing.T) {
	if got := publicPeerScore("tls://203.0.113.10:443"); got < 150 {
		t.Fatalf("443 IPv4 score = %d, want >= 150", got)
	}
	if publicPeerScore("tls://ygg.example:443") <= publicPeerScore("tls://203.0.113.10:1515") {
		t.Fatal("port 443 should outrank a custom-port IPv4 peer")
	}
	if publicPeerScore("not a uri") != 0 {
		t.Fatal("invalid URI should score 0")
	}
}

func TestAndroidBootstrapPeersAreCuratedTlsUris(t *testing.T) {
	peers := androidBootstrapPeers()
	if len(peers) < 6 {
		t.Fatalf("got %d Android bootstrap peers, want at least 6", len(peers))
	}
	seen := make(map[string]bool, len(peers))
	ipv4Count := 0
	for _, peer := range peers {
		if seen[peer] {
			t.Fatalf("duplicate bootstrap peer %q", peer)
		}
		seen[peer] = true
		parsed, err := url.Parse(peer)
		if err != nil {
			t.Fatalf("invalid bootstrap peer %q: %v", peer, err)
		}
		if !strings.EqualFold(parsed.Scheme, "tls") {
			t.Fatalf("bootstrap peer %q is not TLS", peer)
		}
		if ip := net.ParseIP(parsed.Hostname()); ip != nil && ip.To4() != nil {
			ipv4Count++
		}
	}
	if ipv4Count < 4 {
		t.Fatalf("expected several IPv4 literals so Android can connect without DNS, got %d", ipv4Count)
	}
	first := peers[0]
	parsed, err := url.Parse(first)
	if err != nil {
		t.Fatal(err)
	}
	if ip := net.ParseIP(parsed.Hostname()); ip == nil || ip.To4() == nil {
		t.Fatalf("first Android peer %q must be an IPv4 literal", first)
	}
}

func TestApplyAndroidRuntimeConfigUsesCuratedPeersAndDisablesMulticast(t *testing.T) {
	cfg := config.GenerateConfig()
	cfg.Peers = []string{"tls://203.0.113.10:443?sni=stale"}
	applyAndroidRuntimeConfig(cfg)
	if len(cfg.Peers) != len(androidPublicPeers) {
		t.Fatalf("stale peers were kept: %v", cfg.Peers)
	}
	if cfg.Peers[0] != androidPublicPeers[0] {
		t.Fatalf("first peer = %q, want %q", cfg.Peers[0], androidPublicPeers[0])
	}
	if len(cfg.MulticastInterfaces) != 0 {
		t.Fatalf("multicast should be disabled, got %#v", cfg.MulticastInterfaces)
	}
	if cfg.IfName != "none" {
		t.Fatalf("IfName = %q, want none", cfg.IfName)
	}
}

func TestPrioritizedPublicPeersPuts443First(t *testing.T) {
	peers := prioritizedPublicPeers()
	if len(peers) < androidBootstrapPeerLimit {
		t.Fatalf("public peer list is too short: %d", len(peers))
	}
	first := peers[0]
	parsed, err := url.Parse(first)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Port() != "443" {
		t.Fatalf("first prioritized peer %q is not on 443", first)
	}
}

func TestEnsureRuntimePublicPeersKeepsLoopbackOnlyConfigs(t *testing.T) {
	existing := []string{"tls://127.0.0.1:9001"}
	got := ensureRuntimePublicPeers(existing, 0)
	if len(got) != 1 || got[0] != existing[0] {
		t.Fatalf("loopback-only config was expanded: %v", got)
	}
}

func TestDefaultRuntimeConfigDropsUnprotectedLanDiscovery(t *testing.T) {
	cfg := config.GenerateConfig()
	// What Yggdrasil generates, and what older app versions stored.
	cfg.MulticastInterfaces = []config.MulticastInterfaceConfig{
		{Regex: ".*", Beacon: true, Listen: true},
	}
	ensureDefaultRuntimeConfig(cfg)
	if len(cfg.MulticastInterfaces) != 0 {
		t.Fatalf("LAN beacons without a password must be off, got %#v", cfg.MulticastInterfaces)
	}
}

func TestDefaultRuntimeConfigKeepsPasswordProtectedLanDiscovery(t *testing.T) {
	if isPhoneOS() {
		t.Skip("phones never run multicast")
	}
	cfg := config.GenerateConfig()
	cfg.MulticastInterfaces = []config.MulticastInterfaceConfig{
		{Regex: "eth0", Beacon: true, Listen: true, Password: "own-devices"},
	}
	ensureDefaultRuntimeConfig(cfg)
	if len(cfg.MulticastInterfaces) != 1 {
		t.Fatalf("expected one LAN discovery entry, got %#v", cfg.MulticastInterfaces)
	}
	got := cfg.MulticastInterfaces[0]
	if got.Password != "own-devices" || !got.Beacon || !got.Listen {
		t.Fatalf("password-protected LAN discovery was changed: %#v", got)
	}
}
