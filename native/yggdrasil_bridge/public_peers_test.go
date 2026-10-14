package main

import (
	"net/url"
	"testing"
)

func TestPublicPeerPoolIsLargeAndParseable(t *testing.T) {
	if len(publicPeerPool) < 80 {
		t.Fatalf("public peer pool too small: %d", len(publicPeerPool))
	}
	seen := map[string]bool{}
	for _, peer := range publicPeerPool {
		parsed, err := url.Parse(peer.uri)
		if err != nil || parsed.Hostname() == "" {
			t.Fatalf("bad peer URI %q", peer.uri)
		}
		switch parsed.Scheme {
		case "tls", "tcp", "quic", "ws", "wss":
		default:
			t.Fatalf("unsupported scheme in %q", peer.uri)
		}
		if seen[peer.uri] {
			t.Fatalf("duplicate peer %q", peer.uri)
		}
		seen[peer.uri] = true
	}
}

func TestDesktopPeersAreSpreadAcrossCountries(t *testing.T) {
	peers := desktopPublicPeers(desktopPublicPeerCount)
	if len(peers) != desktopPublicPeerCount {
		t.Fatalf("want %d desktop peers, got %d", desktopPublicPeerCount, len(peers))
	}
	country := map[string]string{}
	for _, peer := range publicPeerPool {
		country[peer.uri] = peer.country
	}
	firstRound := map[string]bool{}
	for _, peer := range peers[:10] {
		if firstRound[country[peer]] {
			t.Fatalf("country %s repeated before others got a peer: %v", country[peer], peers)
		}
		firstRound[country[peer]] = true
		if peerHostIsIPv6Literal(peer) {
			t.Fatalf("desktop peer %q is an IPv6 literal", peer)
		}
	}
}

func TestDesktopRuntimePeersDropStalePublicEntriesButKeepLocalOnes(t *testing.T) {
	existing := []string{
		"tls://127.0.0.1:9001",
		"tls://192.168.1.20:32913",
		"tls://203.0.113.10:443",
	}
	got := desktopRuntimePeers(existing)
	if got[0] != existing[0] || got[1] != existing[1] {
		t.Fatalf("local peers were not kept first: %v", got)
	}
	for _, peer := range got {
		if peer == existing[2] {
			t.Fatalf("stale public peer was kept: %v", got)
		}
	}
	if len(got) != 2+desktopPublicPeerCount {
		t.Fatalf("unexpected desktop peer count %d", len(got))
	}
}

func TestAndroidBootstrapPeersAreStableTLS(t *testing.T) {
	peers := selectAndroidBootstrapPeers(publicPeerPool, androidBootstrapPeerCount)
	if len(peers) != androidBootstrapPeerCount {
		t.Fatalf("want %d android peers, got %d", androidBootstrapPeerCount, len(peers))
	}
	stable := map[string]bool{}
	for _, peer := range publicPeerPool {
		stable[peer.uri] = peer.stable
	}
	for _, peer := range peers {
		if peerScheme(peer) != "tls" || !stable[peer] {
			t.Fatalf("android peer %q is not a stable TLS peer", peer)
		}
	}
	if !peerHostIsIPv4(peers[0]) {
		t.Fatalf("first android peer %q must be an IPv4 literal", peers[0])
	}
}

func TestQuicPeersAreNeverProbedFirst(t *testing.T) {
	peers := prioritizedPublicPeers()
	for _, peer := range peers[:androidPeerProbeCandidateLimit] {
		if peerScheme(peer) == "quic" {
			t.Fatalf("quic peer %q would waste a TCP probe slot", peer)
		}
	}
}
