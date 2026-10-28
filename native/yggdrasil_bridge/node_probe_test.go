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
	// The phone's picks; the rest of its pool is reserve behind them.
	peers := androidBootstrapPeers()[:phonePeerPoolSize]
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
	if len(cfg.Peers) != len(androidBootstrapPeers()) {
		t.Fatalf("stale peers were kept: %v", cfg.Peers)
	}
	if cfg.Peers[0] != androidBootstrapPeers()[0] {
		t.Fatalf("first peer = %q, want %q", cfg.Peers[0], androidBootstrapPeers()[0])
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
	if len(peers) < phonePeerPoolSize {
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

func TestDefaultRuntimeConfigTurnsYggdrasilMulticastOff(t *testing.T) {
	for _, configured := range [][]config.MulticastInterfaceConfig{
		// What Yggdrasil generates.
		{{Regex: ".*", Beacon: true, Listen: true}},
		// Even with a password: the beacons would still carry the node key.
		{{Regex: "eth0", Beacon: true, Listen: true, Password: "own-devices"}},
	} {
		cfg := config.GenerateConfig()
		cfg.MulticastInterfaces = configured
		ensureDefaultRuntimeConfig(cfg)
		if len(cfg.MulticastInterfaces) != 0 {
			t.Fatalf("Yggdrasil multicast must stay off, got %#v", cfg.MulticastInterfaces)
		}
	}
}

func TestDesktopPeerListenIsGuarded(t *testing.T) {
	if defaultDesktopPeerListen != defaultDesktopPeerListenForTest {
		t.Fatalf("peer_guard_test.go spells the listener %q, the bridge uses %q", defaultDesktopPeerListenForTest, defaultDesktopPeerListen)
	}
	if _, _, ok := guardedListenAddress(defaultDesktopPeerListen); !ok {
		t.Fatal("the desktop bridge port must go through the connection and transfer limits")
	}
}
