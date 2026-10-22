package main

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"encoding/hex"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/quic-go/quic-go"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

const testPinnedKey = "000000086278b5f3ba1eb63acb5b7f6e406f04ce83990dee9c07f49011e375ae"

func TestValidatePeerURI(t *testing.T) {
	for _, good := range []string{
		"tls://203.0.113.10:443",
		" TLS://ygg.example.org:993?key=" + testPinnedKey + " ",
		"quic://[2001:db8::1]:4443?priority=3",
		"wss://ygg.example.org/socket?maxbackoff=30s",
		"ws://203.0.113.5",
		"tcp://203.0.113.5:1514?password=sekret",
		"tls://203.0.113.10:443?sni=ygg.example.org",
	} {
		if _, err := validatePeerURI(good); err != nil {
			t.Fatalf("%q refused: %v", good, err)
		}
	}
	if got, _ := validatePeerURI("TLS://ygg.example.org:993"); got != "tls://ygg.example.org:993" {
		t.Fatalf("not normalised: %q", got)
	}
	for _, bad := range []string{
		"",
		"ygg.example.org:443",
		"http://203.0.113.10:443",
		"socks://127.0.0.1:9050/203.0.113.10:443",
		"unix:///run/ygg.sock",
		"tls://203.0.113.10",
		"tls://203.0.113.10:0",
		"tls://203.0.113.10:70000",
		"tls://:443",
		"tls://user@203.0.113.10:443",
		"tls://203.0.113.10:443#x",
		"tls://203.0.113.10:443/path",
		"tls://[200:1111::1]:443",
		"tls://[0:0:0:0:0:0:0:0]:443",
		"tls://203.0.113.10:443?key=abcd",
		"tls://203.0.113.10:443?key=" + strings.Repeat("zz", 32),
		"tls://203.0.113.10:443?priority=300",
		"tls://203.0.113.10:443?maxbackoff=1s",
		"tls://203.0.113.10:443?password=" + strings.Repeat("p", 65),
		"tls://203.0.113.10:443?sni=203.0.113.10",
		"tls://203.0.113.10:443?pirority=1",
		"tls://203.0.113.10:443?priority=1&priority=2",
		"tls://" + strings.Repeat("a", 600) + ":443",
	} {
		if _, err := validatePeerURI(bad); err == nil {
			t.Fatalf("%q must be refused", bad)
		}
	}
}

func TestEveryBuiltInPeerIsValid(t *testing.T) {
	for _, peer := range publicPeerPool {
		if _, err := validatePeerURI(peer.uri); err != nil {
			t.Fatalf("built-in %q: %v", peer.uri, err)
		}
	}
}

func TestAppPicksOnlyEncryptedTransportsAndOneURIPerHost(t *testing.T) {
	desktop := desktopPublicPeers(desktopPublicPeerCount)
	hosts := map[string]bool{}
	for _, peer := range desktop {
		if !isEncryptedPeerURI(peer) {
			t.Fatalf("desktop picked %q (unencrypted link)", peer)
		}
		if hosts[peerHost(peer)] {
			t.Fatalf("two links to %s: %v", peerHost(peer), desktop)
		}
		hosts[peerHost(peer)] = true
	}
	for _, peer := range append(androidBootstrapPeers(), defaultPublicPeerURIs()...) {
		if !isEncryptedPeerURI(peer) {
			t.Fatalf("%q would carry the node's traffic in clear", peer)
		}
	}
}

func withUserPublicPeers(t *testing.T, uris []string) {
	t.Helper()
	previous, set := currentUserPublicPeers()
	setUserPublicPeers(uris, true)
	t.Cleanup(func() { setUserPublicPeers(previous, set) })
}

func TestUserPublicPeersReplaceTheBuiltInPool(t *testing.T) {
	mine := []string{"tcp://203.0.113.7:1514", "tls://203.0.113.8:443", "quic://203.0.113.9:443"}
	withUserPublicPeers(t, mine)
	if got := androidBootstrapPeers(); strings.Join(got, " ") != strings.Join(mine, " ") {
		t.Fatalf("phone peers %v", got)
	}
	if got := desktopPublicPeers(desktopPublicPeerCount); strings.Join(got, " ") != strings.Join(mine, " ") {
		t.Fatalf("desktop peers %v", got)
	}
	if got := defaultPublicPeerURIs(); len(got) != 3 {
		t.Fatalf("pool %v", got)
	}
	if !customPublicPeers() {
		t.Fatal("the node info tells the list is the user's")
	}
}

func TestSetPublicPeersJSON(t *testing.T) {
	previous, set := currentUserPublicPeers()
	t.Cleanup(func() { setUserPublicPeers(previous, set) })

	if _, err := setPublicPeersJSON(`{"peers":[]}`); err == nil {
		t.Fatal("an empty list leaves the node with nobody: refused")
	}
	if _, err := setPublicPeersJSON(`{"peers":["http://x"]}`); err == nil {
		t.Fatal("a list with no valid peer is refused")
	}
	result, err := setPublicPeersJSON(`{"peers":["tls://203.0.113.8:443","bad","TLS://203.0.113.8:443"]}`)
	if err != nil {
		t.Fatal(err)
	}
	if result["applied"] != 1 || len(result["invalid"].([]map[string]string)) != 1 {
		t.Fatalf("result %v", result)
	}
	if uris, set := currentUserPublicPeers(); !set || len(uris) != 1 {
		t.Fatalf("list %v %v", uris, set)
	}
	if _, err := setPublicPeersJSON(`{"peers":null}`); err != nil {
		t.Fatal(err)
	}
	if customPublicPeers() {
		t.Fatal("null goes back to the built-in list")
	}
}

func TestApplyPublicPeersSwapsOnlyThePublicOnes(t *testing.T) {
	cfg := config.GenerateConfig()
	yggCore, err := core.New(cfg.Certificate, log.New(io.Discard, "", 0))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(yggCore.Stop)
	old := "tls://192.0.2.1:443"
	bridge := "tls://198.51.100.20:32913"
	local := "tls://127.0.0.1:9001"
	cfg.Peers = []string{local, old}
	node := &bridgeNode{
		core:        yggCore,
		config:      cfg,
		logger:      log.New(io.Discard, "", 0),
		publicPeers: publicPeersOf(cfg.Peers),
	}
	// A bridge learnt from friends later, through YggAddPeer.
	node.updateConfiguredPeer(bridge, true)

	fresh := "tls://192.0.2.2:443"
	withUserPublicPeers(t, []string{fresh})
	added, removed := node.applyPublicPeers()
	if added != 1 || removed != 1 {
		t.Fatalf("added %d, removed %d", added, removed)
	}
	got := strings.Join(node.configSnapshot().Peers, " ")
	if got != strings.Join([]string{local, bridge, fresh}, " ") {
		t.Fatalf("peers after the swap: %s", got)
	}
	// Again: nothing changes.
	if added, removed := node.applyPublicPeers(); added != 0 || removed != 0 {
		t.Fatalf("a second apply changed %d/%d", added, removed)
	}
}

func testTLSServerConfig(t *testing.T) (*tls.Config, string) {
	t.Helper()
	cfg := config.GenerateConfig()
	key := hex.EncodeToString(ed25519.PrivateKey(cfg.PrivateKey).Public().(ed25519.PublicKey))
	return &tls.Config{Certificates: []tls.Certificate{*cfg.Certificate}, MinVersion: tls.VersionTLS13}, key
}

func TestProbePublicPeers(t *testing.T) {
	plain, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer plain.Close()
	go func() {
		for {
			conn, err := plain.Accept()
			if err != nil {
				return
			}
			_ = conn.Close()
		}
	}()
	serverConfig, key := testTLSServerConfig(t)
	secure, err := tls.Listen("tcp", "127.0.0.1:0", serverConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer secure.Close()
	go func() {
		for {
			conn, err := secure.Accept()
			if err != nil {
				return
			}
			go func() {
				_ = conn.(*tls.Conn).Handshake()
				time.Sleep(100 * time.Millisecond)
				_ = conn.Close()
			}()
		}
	}()
	quicListener, err := quic.ListenAddr("127.0.0.1:0", serverConfig, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer quicListener.Close()
	go func() {
		for {
			conn, err := quicListener.Accept(context.Background())
			if err != nil {
				return
			}
			go func() {
				time.Sleep(200 * time.Millisecond)
				_ = conn.CloseWithError(0, "")
			}()
		}
	}()
	closed, _ := net.Listen("tcp", "127.0.0.1:0")
	closedAddress := closed.Addr().String()
	closed.Close()

	other := strings.Repeat("ab", 32)
	uris := []string{
		"tcp://" + plain.Addr().String(),
		"tls://" + secure.Addr().String() + "?key=" + key,
		"tls://" + secure.Addr().String() + "?key=" + other,
		"quic://" + quicListener.Addr().String() + "?key=" + key,
		"tcp://" + closedAddress,
		"not a peer",
	}
	reports := probePublicPeers(uris)
	if len(reports) != len(uris) {
		t.Fatalf("%d reports", len(reports))
	}
	if !reports[0].Reachable || reports[0].LatencyMs <= 0 || reports[0].KeyMatches != nil {
		t.Fatalf("tcp: %+v", reports[0])
	}
	if !reports[1].Reachable || reports[1].Key != key || reports[1].KeyMatches == nil || !*reports[1].KeyMatches {
		t.Fatalf("tls with the right key: %+v", reports[1])
	}
	if !reports[2].Reachable || reports[2].KeyMatches == nil || *reports[2].KeyMatches {
		t.Fatalf("tls with another key: %+v", reports[2])
	}
	if !reports[3].Reachable || reports[3].Key != key || !*reports[3].KeyMatches {
		t.Fatalf("quic: %+v", reports[3])
	}
	if reports[4].Reachable || reports[4].Error == "" {
		t.Fatalf("closed port: %+v", reports[4])
	}
	if reports[5].Reachable || reports[5].Error == "" {
		t.Fatalf("invalid: %+v", reports[5])
	}
}

func TestBuiltInListingPutsWhatThisDeviceDialsFirst(t *testing.T) {
	withUserPublicPeers(t, []string{"tls://203.0.113.8:443"})
	listing := builtInPeerListing()
	chosen := builtInDesktopPeers(desktopPublicPeerCount)
	if isPhoneOS() {
		chosen = selectAndroidBootstrapPeers(publicPeerPool, phonePeerPoolSize)
	}
	if len(listing) != len(builtInPublicPeers()) {
		t.Fatalf("%d listed, %d built in", len(listing), len(builtInPublicPeers()))
	}
	for index, uri := range chosen {
		if listing[index].URI != uri || !listing[index].Chosen {
			t.Fatalf("entry %d is %+v, want chosen %s", index, listing[index], uri)
		}
	}
	for _, entry := range listing[len(chosen):] {
		if entry.Chosen || !entry.Encrypted {
			t.Fatalf("entry %+v", entry)
		}
	}
}
