package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"crypto/ed25519"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/url"
	"sync"
	"time"

	"github.com/quic-go/quic-go"
)

// The public peers the user edits in the app (public_peers_section.dart):
// the built-in list to start from, the user's own list applied to every
// running node at once (and to nodes started later), and a reachability
// check of any list.

const (
	// One probe; the whole check of a list takes at most publicProbeBudget.
	publicProbeTimeout = 3 * time.Second
	publicProbeBudget  = 5 * time.Second
	// Most URIs checked in one call.
	maxPublicProbePeers = 128
)

// publicPeersOf are the entries of peers that are public (not loopback,
// not on a private network): the ones a new public list replaces.
func publicPeersOf(peers []string) map[string]bool {
	public := make(map[string]bool, len(peers))
	for _, peer := range peers {
		if peer != "" && !isLocalPeerURI(peer) {
			public[peer] = true
		}
	}
	return public
}

func customPublicPeers() bool {
	_, set := currentUserPublicPeers()
	return set
}

// desiredPublicPeers is the public part of a node's peer list now.
func desiredPublicPeers() []string {
	if isPhoneOS() {
		return androidBootstrapPeers()
	}
	return desktopPublicPeers(desktopPublicPeerCount)
}

// applyPublicPeers swaps the node's public peers for desiredPublicPeers,
// leaving every other peer (friends' bridges, devices on the LAN) alone.
// Returns how many were added and removed.
func (node *bridgeNode) applyPublicPeers() (int, int) {
	desired := desiredPublicPeers()
	desiredSet := make(map[string]bool, len(desired))
	for _, peer := range desired {
		desiredSet[peer] = true
	}
	node.configMu.Lock()
	previous := node.publicPeers
	var drop, add []string
	for peer := range previous {
		if !desiredSet[peer] {
			drop = append(drop, peer)
		}
	}
	configured := make(map[string]bool, len(node.config.Peers))
	for _, peer := range node.config.Peers {
		configured[peer] = true
	}
	for _, peer := range desired {
		if !previous[peer] && !configured[peer] {
			add = append(add, peer)
		}
	}
	kept := make([]string, 0, len(node.config.Peers)+len(add))
	dropSet := make(map[string]bool, len(drop))
	for _, peer := range drop {
		dropSet[peer] = true
	}
	for _, peer := range node.config.Peers {
		if !dropSet[peer] {
			kept = append(kept, peer)
		}
	}
	node.config.Peers = append(kept, add...)
	node.publicPeers = desiredSet
	node.configMu.Unlock()

	for _, peer := range drop {
		if parsed, err := url.Parse(peer); err == nil {
			// A peer the core no longer knows is gone already.
			_ = node.core.RemovePeer(parsed, "")
		}
	}
	added := 0
	for _, peer := range add {
		parsed, err := url.Parse(peer)
		if err != nil {
			continue
		}
		if err := node.core.AddPeer(parsed, ""); err != nil {
			node.logger.Warnf("public peer %s not added: %v", peer, err)
			continue
		}
		added++
	}
	node.core.RetryPeersNow()
	if node.peerProbe != nil {
		node.peerProbe.triggerNow()
	}
	return added, len(drop)
}

type publicPeerJSON struct {
	URI       string `json:"uri"`
	Country   string `json:"country,omitempty"`
	Stable    bool   `json:"stable"`
	Encrypted bool   `json:"encrypted"`
	// This device dials it when the user made no list of their own.
	Chosen bool `json:"chosen"`
}

// builtInPeerListing is the built-in pool as the app shows it: what this
// device dials by default first (in that order), then the rest.
func builtInPeerListing() []publicPeerJSON {
	var chosen []string
	if isPhoneOS() {
		chosen = selectAndroidBootstrapPeers(publicPeerPool, androidBootstrapPeerCount)
	} else {
		chosen = builtInDesktopPeers(desktopPublicPeerCount)
	}
	byURI := make(map[string]publicPeer, len(publicPeerPool))
	for _, peer := range builtInPublicPeers() {
		byURI[peer.uri] = peer
	}
	listing := make([]publicPeerJSON, 0, len(byURI))
	seen := make(map[string]bool, len(byURI))
	add := func(peer publicPeer, isChosen bool) {
		if seen[peer.uri] {
			return
		}
		seen[peer.uri] = true
		listing = append(listing, publicPeerJSON{
			URI:       peer.uri,
			Country:   peer.country,
			Stable:    peer.stable,
			Encrypted: isEncryptedPeerURI(peer.uri),
			Chosen:    isChosen,
		})
	}
	for _, uri := range chosen {
		if peer, ok := byURI[uri]; ok {
			add(peer, true)
		}
	}
	for _, peer := range builtInPublicPeers() {
		add(peer, false)
	}
	return listing
}

// YggDefaultPublicPeersJson: the built-in public peers, as the app shows
// them before the user changes anything: {peers: [{uri, country, stable,
// encrypted, chosen}], custom}.
//
//export YggDefaultPublicPeersJson
func YggDefaultPublicPeersJson() *C.char {
	return responseOK(map[string]any{"peers": builtInPeerListing(), "custom": customPublicPeers()})
}

type setPublicPeersRequest struct {
	// The user's peers in their order; null: back to the built-in list.
	Peers *[]string `json:"peers"`
}

// YggSetPublicPeersJson: {peers: [uri, ...]} makes the user's list the
// public peers of every node (running ones at once), {peers: null} goes
// back to the built-in list. Invalid URIs are left out and named:
// {applied, invalid: [{uri, error}], nodes}.
//
//export YggSetPublicPeersJson
func YggSetPublicPeersJson(payload *C.char) *C.char {
	result, err := setPublicPeersJSON(C.GoString(payload))
	if err != nil {
		return responseError(err)
	}
	return responseOK(result)
}

func setPublicPeersJSON(payload string) (map[string]any, error) {
	var request setPublicPeersRequest
	if err := json.Unmarshal([]byte(payload), &request); err != nil {
		return nil, err
	}
	invalid := make([]map[string]string, 0)
	if request.Peers == nil {
		setUserPublicPeers(nil, false)
	} else {
		valid := make([]string, 0, len(*request.Peers))
		seen := map[string]bool{}
		for _, raw := range *request.Peers {
			uri, err := validatePeerURI(raw)
			if err != nil {
				invalid = append(invalid, map[string]string{"uri": raw, "error": err.Error()})
				continue
			}
			if !seen[uri] {
				seen[uri] = true
				valid = append(valid, uri)
			}
		}
		if len(valid) == 0 {
			// A node with no public peer at all reaches nobody: an empty
			// (or wholly invalid) list is refused rather than applied.
			return nil, errors.New("no valid public peer in the list")
		}
		setUserPublicPeers(valid, true)
	}
	applied := 0
	nodes.Range(func(_, value any) bool {
		node := value.(*bridgeNode)
		if node.core != nil && node.config != nil {
			node.applyPublicPeers()
			applied++
		}
		return true
	})
	uris, _ := currentUserPublicPeers()
	return map[string]any{"applied": len(uris), "invalid": invalid, "nodes": applied}, nil
}

type peerProbeReport struct {
	URI       string  `json:"uri"`
	Reachable bool    `json:"reachable"`
	LatencyMs float64 `json:"latencyMs,omitempty"`
	// The node key the peer showed (tls://, quic://), and whether it is
	// one the URI pins with ?key= (absent without a pin).
	Key        string `json:"key,omitempty"`
	KeyMatches *bool  `json:"keyMatches,omitempty"`
	Error      string `json:"error,omitempty"`
}

// YggProbePeersJson: {peers: [uri, ...]} -> {results: [{uri, reachable,
// latencyMs, key, keyMatches, error}]}, all checked at once within a few
// seconds. Latency is one connection set-up (TCP, or the QUIC handshake).
//
//export YggProbePeersJson
func YggProbePeersJson(payload *C.char) *C.char {
	var request struct {
		Peers []string `json:"peers"`
	}
	if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{"results": probePublicPeers(request.Peers)})
}

func probePublicPeers(uris []string) []peerProbeReport {
	if len(uris) > maxPublicProbePeers {
		uris = uris[:maxPublicProbePeers]
	}
	reports := make([]peerProbeReport, len(uris))
	ctx, cancel := context.WithTimeout(context.Background(), publicProbeBudget)
	defer cancel()
	var wait sync.WaitGroup
	for index, uri := range uris {
		wait.Add(1)
		go func() {
			defer wait.Done()
			reports[index] = probePublicPeer(ctx, uri)
		}()
	}
	wait.Wait()
	return reports
}

func probePublicPeer(parent context.Context, raw string) peerProbeReport {
	report := peerProbeReport{URI: raw}
	uri, err := validatePeerURI(raw)
	if err != nil {
		report.Error = err.Error()
		return report
	}
	parsed, _ := url.Parse(uri)
	ctx, cancel := context.WithTimeout(parent, publicProbeTimeout)
	defer cancel()
	var key ed25519.PublicKey
	var latency time.Duration
	switch parsed.Scheme {
	case "quic":
		latency, key, err = probeQUICPeer(ctx, parsed)
	case "tls":
		latency, key, err = probeTLSPeer(ctx, parsed)
	default:
		latency, err = probeTCPPeer(ctx, parsed)
	}
	if err != nil {
		report.Error = err.Error()
		return report
	}
	report.Reachable = true
	// A loopback connect can finish inside one tick of a coarse clock;
	// report at least 1 µs so "reachable" never reads as zero latency.
	report.LatencyMs = max(float64(latency.Microseconds())/1000, 0.001)
	if key != nil {
		report.Key = hex.EncodeToString(key)
		if pinned := peerPinnedKeys(uri); len(pinned) > 0 {
			matches := false
			for _, want := range pinned {
				matches = matches || want == report.Key
			}
			report.KeyMatches = &matches
		}
	}
	return report
}

func peerDialAddress(parsed *url.URL) string {
	port := parsed.Port()
	if port == "" {
		port = "80"
		if parsed.Scheme == "wss" {
			port = "443"
		}
	}
	return net.JoinHostPort(parsed.Hostname(), port)
}

func probeTCPPeer(ctx context.Context, parsed *url.URL) (time.Duration, error) {
	var dialer net.Dialer
	started := time.Now()
	conn, err := dialer.DialContext(ctx, "tcp", peerDialAddress(parsed))
	if err != nil {
		return 0, err
	}
	latency := time.Since(started)
	_ = conn.Close()
	return latency, nil
}

// peerProbeTLSConfig speaks TLS as Yggdrasil does (a self-signed
// certificate of the node key, checked by key, not by a CA).
func peerProbeTLSConfig(parsed *url.URL) *tls.Config {
	config := &tls.Config{
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS12,
	}
	if sni := parsed.Query().Get("sni"); sni != "" {
		config.ServerName = sni
	} else if net.ParseIP(parsed.Hostname()) == nil {
		config.ServerName = parsed.Hostname()
	}
	return config
}

func peerCertificateKey(state tls.ConnectionState) ed25519.PublicKey {
	if len(state.PeerCertificates) == 0 {
		return nil
	}
	key, _ := state.PeerCertificates[0].PublicKey.(ed25519.PublicKey)
	return key
}

func probeTLSPeer(ctx context.Context, parsed *url.URL) (time.Duration, ed25519.PublicKey, error) {
	var dialer net.Dialer
	started := time.Now()
	raw, err := dialer.DialContext(ctx, "tcp", peerDialAddress(parsed))
	if err != nil {
		return 0, nil, err
	}
	latency := time.Since(started)
	conn := tls.Client(raw, peerProbeTLSConfig(parsed))
	defer conn.Close()
	if err := conn.HandshakeContext(ctx); err != nil {
		// Reachable, but not speaking TLS as a Yggdrasil peer would.
		return 0, nil, fmt.Errorf("tls: %w", err)
	}
	return latency, peerCertificateKey(conn.ConnectionState()), nil
}

func probeQUICPeer(ctx context.Context, parsed *url.URL) (time.Duration, ed25519.PublicKey, error) {
	started := time.Now()
	conn, err := quic.DialAddr(ctx, peerDialAddress(parsed), peerProbeTLSConfig(parsed), &quic.Config{
		HandshakeIdleTimeout: publicProbeTimeout,
	})
	if err != nil {
		return 0, nil, err
	}
	latency := time.Since(started)
	defer func() { _ = conn.CloseWithError(0, "") }()
	return latency, peerCertificateKey(conn.ConnectionState().TLS), nil
}
