package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"fmt"
	"testing"

	"github.com/yggdrasil-network/yggdrasil-go/src/config"
)

// testNodePrivateKey is the private key of the n-th made-up node.
func testNodePrivateKey(n int) ed25519.PrivateKey {
	seed := sha256.Sum256([]byte(fmt.Sprintf("node %d", n)))
	return ed25519.NewKeyFromSeed(seed[:])
}

// The public peers a phone node starts with, as createNode sets them.
func testPhoneStart(privateKey ed25519.PrivateKey) []string {
	cfg := config.GenerateConfig()
	cfg.PrivateKey = config.KeyBytes(privateKey)
	applyAndroidRuntimeConfig(cfg)
	return cfg.Peers
}

// Phones do not all dial the same volunteer's node first: a locked phone
// keeps one peer, so whoever runs the first of a common order would see
// the IP address and Zen address of nearly every locked phone.
func TestPhonesSpreadOverThePublicPeers(t *testing.T) {
	setUserPublicPeers(nil, false)
	const phones = 400
	firstCount := map[string]int{}
	awakeCount := map[string]int{}
	for n := 0; n < phones; n++ {
		peers := testPhoneStart(testNodePrivateKey(n))
		firstCount[peerGroup(peers[0])]++
		for _, uri := range firstPeers(peers, phonePeerCount) {
			awakeCount[peerGroup(uri)]++
		}
	}
	t.Logf("first peer of %d locked phones, by operator: %v", phones, firstCount)
	for group, count := range firstCount {
		if count > phones/5 {
			t.Fatalf("%d of %d locked phones dial %s first: %v", count, phones, group, firstCount)
		}
	}
	if len(firstCount) < 8 {
		t.Fatalf("locked phones start on only %d operators: %v", len(firstCount), firstCount)
	}
	for group, count := range awakeCount {
		if count > phones/2 {
			t.Fatalf("%d of %d awake phones dial %s: %v", count, phones, group, awakeCount)
		}
	}
	a, b := testPhoneStart(testNodePrivateKey(1)), testPhoneStart(testNodePrivateKey(2))
	if a[0] == b[0] {
		t.Fatalf("two phones start on the same peer %s", a[0])
	}
}

// A phone keeps its order across restarts: a new peer on every start would
// show it to more operators, not fewer. Nor is the order that of the node's
// public key (its Zen address), which anyone may know.
func TestAPhoneKeepsItsOrderAcrossRestarts(t *testing.T) {
	setUserPublicPeers(nil, false)
	key := testNodePrivateKey(7)
	first, again := testPhoneStart(key), testPhoneStart(key)
	if !samePeers(first, again) {
		t.Fatalf("the order changed after a restart:\n%v\n%v", first[:4], again[:4])
	}
	public := key.Public().(ed25519.PublicKey)
	if fromPublic := phonePeerCandidates(publicPeerPool, peerOrderSeed(append(append([]byte(nil), public...), public...))); samePeers(fromPublic, first) {
		t.Fatal("the order follows from the public key")
	}
	if peerOrderSeed(nil) != nil || peerOrderSeed([]byte{1, 2, 3}) != nil {
		t.Fatal("no private key, no order of its own")
	}
}

// The order mixes the peers only within what the pool's own order protects:
// stable TLS peers with an IPv4 address first, then the rest of the TLS
// peers, a peer not seen online for a week behind every stable one, IPv6
// literals behind those, and QUIC and WebSocket last.
func TestTheOwnOrderKeepsWeakPeersLast(t *testing.T) {
	stable := make(map[string]bool, len(publicPeerPool))
	for _, peer := range publicPeerPool {
		stable[peer.uri] = peer.stable
	}
	pool := []publicPeer{
		{"tls://198.51.100.1:443", "A", false},
		{"quic://198.51.100.2:443", "A", true},
		{"tls://[2001:db8::1]:443", "A", true},
		{"tls://198.51.100.3:1000", "A", true},
		{"tls://198.51.101.4:1000", "A", true},
		{"tls://peer.example:1000", "A", true},
		{"wss://other.example:443", "A", true},
	}
	for n := 0; n < 50; n++ {
		seed := peerOrderSeed(testNodePrivateKey(n))
		got := phonePeerCandidates(pool, seed)
		if len(got) != len(pool) {
			t.Fatalf("seed %d: %v", n, got)
		}
		for i, uri := range got[:3] {
			if uri != "tls://198.51.100.3:1000" && uri != "tls://198.51.101.4:1000" && uri != "tls://peer.example:1000" {
				t.Fatalf("seed %d: %s is pick %d before the stable TLS peers: %v", n, uri, i, got)
			}
		}
		if got[3] != "tls://198.51.100.1:443" || got[4] != "tls://[2001:db8::1]:443" {
			t.Fatalf("seed %d: the unstable peer and the IPv6 literal must come next: %v", n, got)
		}
		if peerScheme(got[5]) == "tls" || peerScheme(got[6]) == "tls" {
			t.Fatalf("seed %d: QUIC and WebSocket come last: %v", n, got)
		}
		// The whole built-in pool too: every pick is a stable TLS peer, the
		// IPv4 ones first; in reserve, TLS before the rest.
		all := phonePeerCandidates(publicPeerPool, seed)
		picks := selectAndroidBootstrapPeers(publicPeerPool, phonePeerPoolSize, seed)
		sawName, sawHeavy := false, false
		for i, uri := range all {
			if i < len(picks) {
				if peerScheme(uri) != "tls" || !stable[uri] || peerHostIsIPv6Literal(uri) {
					t.Fatalf("seed %d: pick %s", n, uri)
				}
				if sawName && peerHostIsIPv4(uri) {
					t.Fatalf("seed %d: IPv4 pick %s after a host name", n, uri)
				}
				sawName = sawName || !peerHostIsIPv4(uri)
				continue
			}
			if !lightPeer(uri) {
				sawHeavy = true
			} else if sawHeavy {
				t.Fatalf("seed %d: TLS peer %s after QUIC or WebSocket", n, uri)
			}
		}
	}
}

// One operator gets at most one of a phone's picks (and so one of the few
// peers it dials at once): two links to it would only take a slot.
func TestAPhonePicksOnePeerPerOperator(t *testing.T) {
	for n := 0; n < 50; n++ {
		picks := selectAndroidBootstrapPeers(publicPeerPool, phonePeerPoolSize, peerOrderSeed(testNodePrivateKey(n)))
		if len(picks) != phonePeerPoolSize {
			t.Fatalf("seed %d: %d picks", n, len(picks))
		}
		groups := map[string]string{}
		for _, uri := range picks {
			if other, ok := groups[peerGroup(uri)]; ok {
				t.Fatalf("seed %d: %s and %s are one operator", n, other, uri)
			}
			groups[peerGroup(uri)] = uri
		}
	}
	if peerGroup("tls://78.27.153.163:3784") != peerGroup("tcp://78.27.153.7:1") ||
		peerGroup("tls://78.27.153.163:3784") == peerGroup("tls://78.27.154.163:3784") ||
		peerGroup("tls://Peer.Example:1") != peerGroup("quic://peer.example:2") ||
		peerGroup("tls://[2a01:4f9:2b:2d8f::2]:1") != peerGroup("tls://[2a01:4f9:2b:1::9]:1") {
		t.Fatal("groups: an IPv4 /24, an IPv6 /48, a host name")
	}
}

// Computers dial their whole selection at once: each its own spread.
func TestComputersSpreadOverThePublicPeers(t *testing.T) {
	setUserPublicPeers(nil, false)
	a := builtInDesktopPeers(desktopPublicPeerCount, peerOrderSeed(testNodePrivateKey(1)))
	b := builtInDesktopPeers(desktopPublicPeerCount, peerOrderSeed(testNodePrivateKey(2)))
	if len(a) != desktopPublicPeerCount || len(b) != desktopPublicPeerCount {
		t.Fatalf("%d and %d peers", len(a), len(b))
	}
	if samePeers(a, b) {
		t.Fatal("two computers dial the same peers in the same order")
	}
	for _, peers := range [][]string{a, b} {
		groups := map[string]bool{}
		for _, uri := range peers {
			if groups[peerGroup(uri)] {
				t.Fatalf("%s twice: %v", peerGroup(uri), peers)
			}
			groups[peerGroup(uri)] = true
		}
	}
	again := builtInDesktopPeers(desktopPublicPeerCount, peerOrderSeed(testNodePrivateKey(1)))
	if !samePeers(a, again) {
		t.Fatal("a computer keeps its selection")
	}
}
