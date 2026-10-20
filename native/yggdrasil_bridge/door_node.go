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
	"net"
	"net/url"
	"strings"
	"sync"
	"time"

	iwt "github.com/Arceliar/ironwood/types"
	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// The flat's door (neighbours, §18.2). The sticker on the door carries the
// address of a second, minimal Yggdrasil node with its own random key, not
// the address of anyone who lives there. It runs inside the bridge next to
// the main node and reaches the mesh only through it (one peering over
// loopback). It never sends anything: it takes knock frames on the signal
// port and hands them to the app through the main node's signal inbox,
// marked as door traffic. Yggdrasil's own queries (getSelf, getPeers,
// getTree, nodeinfo) are dropped unanswered: the door's only peer is the
// resident's main node, and its answer would name it. The app answers a
// knock from its normal identity only once a resident accepts it.
//
// Not closed here (it needs a patched Yggdrasil core): the main node still
// answers getPeers/getTree like every node, and its door is among its
// peers; and the door's mesh path is one hop below the main node's.
const (
	// The only frame the door takes ("flat_hello" in neighbors_service.dart).
	doorKnockType = "flat_hello"
	// Largest knock text, decompressed: a flat profile with its photo
	// (FlatProfile.maxPhotoChars) and room to spare.
	maxDoorKnockBytes = 512 * 1024
	// Where the door listens for the main node's peering.
	doorListenURI = "tcp://127.0.0.1:0"
	// The first byte of a packet out of the core's session layer
	// (yggdrasil core/types.go): traffic, or the core's own protocol
	// (nodeinfo and debug queries), which the door never answers.
	doorSessionTraffic = 1
)

type doorNode struct {
	core     *core.Core
	listener *core.Listener
	// The main node's peering to the door (no query, as GetPeers lists it).
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
	stopOnce  sync.Once
	// Closed by stop; done is closed when run has returned.
	quit chan struct{}
	done chan struct{}
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

// newDoorNode starts a door with the key from seedHex, peered to main.
func newDoorNode(main *bridgeNode, seedHex string) (*doorNode, error) {
	private, err := doorSeed(seedHex)
	if err != nil {
		return nil, err
	}
	cfg := &config.NodeConfig{PrivateKey: config.KeyBytes(private)}
	if err := cfg.GenerateSelfSignedCertificate(); err != nil {
		return nil, err
	}
	logger := log.New(io.Discard, "", 0)
	if main.logger != nil {
		logger = main.logger
	}
	doorCore, err := core.New(
		cfg.Certificate,
		logger,
		// Only the main node of this app may peer with the door.
		core.AllowedPublicKey(main.core.PublicKey()),
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
	door := &doorNode{
		core:      doorCore,
		listener:  listener,
		linkURI:   linkURI,
		peerURI:   peerURI,
		seed:      strings.ToLower(strings.TrimSpace(seedHex)),
		address:   doorCore.Address().String(),
		ip:        *address.AddrForKey(doorCore.PublicKey()),
		assembler: &bridgeNode{signalPartials: make(map[string]*signalReassembly)},
		quit:      make(chan struct{}),
		done:      make(chan struct{}),
	}
	// The main node calls the door (a phone's main node has no listener).
	if err := main.core.AddPeer(peerURI, ""); err != nil {
		doorCore.Stop()
		return nil, err
	}
	go door.run(main)
	return door, nil
}

// run takes knocks until the door stops.
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
		if !ok || !isDoorKnock(message) {
			continue
		}
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
// getPeers, getTree, nodeinfo) itself; here they are dropped. As in
// ipv6rwc, the packet must be addressed to the door and come from the
// sender key's own address.
func (door *doorNode) trafficPacket(session []byte, from net.Addr) ([]byte, bool) {
	if len(session) < 1+40 || session[0] != doorSessionTraffic {
		return nil, false
	}
	key, ok := from.(iwt.Addr)
	if !ok || len(key) != ed25519.PublicKeySize {
		return nil, false
	}
	packet := session[1:]
	if packet[0]>>4 != 6 || !bytes.Equal(packet[24:40], door.ip[:]) {
		return nil, false
	}
	if !bytes.Equal(packet[8:24], address.AddrForKey(ed25519.PublicKey(key))[:]) {
		return nil, false
	}
	return packet, true
}

// stop shuts the door and drops the main node's peering to it.
func (door *doorNode) stop(main *bridgeNode) {
	door.stopOnce.Do(func() {
		close(door.quit)
		if main != nil && main.core != nil {
			_ = main.core.RemovePeer(door.peerURI, "")
		}
		door.listener.Cancel()
		// Stopping the core ends run's reads.
		door.core.Stop()
	})
}

// isDoorKnock reports whether a signal text is a knock: a JSON object of
// type doorKnockType, as the app sends it (plain, or wrapped by the app's
// zstd encoding, runtime_signal_codec.dart), within maxDoorKnockBytes.
// It reads the text exactly as the app's jsonDecode does (doorObject), so
// what passes here is a knock for the app too.
func isDoorKnock(message string) bool {
	if len(message) > maxDoorKnockBytes {
		return false
	}
	head, ok := doorObject([]byte(message))
	if !ok {
		return false
	}
	encoding, ok := doorString(head, "_zenEncoding")
	if !ok {
		return false
	}
	if encoding == "" {
		kind, ok := doorString(head, "type")
		return ok && kind == doorKnockType
	}
	payload, ok := doorString(head, "_zenPayload")
	if _, typed := head["type"]; encoding != "zstd" || typed || !ok || payload == "" {
		return false
	}
	compressed, err := base64.StdEncoding.DecodeString(payload)
	if err != nil {
		return false
	}
	inner, err := decompressSignal(compressed)
	if err != nil || len(inner) > maxDoorKnockBytes {
		return false
	}
	body, ok := doorObject(inner)
	if !ok {
		return false
	}
	kind, ok := doorString(body, "type")
	return ok && kind == doorKnockType
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

// startDoor runs the door with the key from seedHex, replacing a door with
// another key. The same key keeps the running door.
func (node *bridgeNode) startDoor(seedHex string) (*doorNode, error) {
	node.doorMu.Lock()
	defer node.doorMu.Unlock()
	if current := node.door; current != nil {
		if current.seed == strings.ToLower(strings.TrimSpace(seedHex)) {
			return current, nil
		}
		current.stop(node)
		node.door = nil
	}
	door, err := newDoorNode(node, seedHex)
	if err != nil {
		return nil, err
	}
	node.door = door
	// The door is reachable once the main node's link to it is up.
	node.core.RetryPeersNow()
	return door, nil
}

// stopDoor shuts the door, if one runs.
func (node *bridgeNode) stopDoor() {
	node.doorMu.Lock()
	defer node.doorMu.Unlock()
	if node.door != nil {
		node.door.stop(node)
		node.door = nil
	}
}

// doorState is what the app learns about the door: never its key.
func (node *bridgeNode) doorState() map[string]any {
	node.doorMu.Lock()
	defer node.doorMu.Unlock()
	door := node.door
	if door == nil {
		return map[string]any{"running": false}
	}
	up := false
	for _, peer := range node.core.GetPeers() {
		if peer.URI == door.linkURI && peer.Up {
			up = true
		}
	}
	return map[string]any{
		"running":   true,
		"address":   door.address,
		"publicKey": hex.EncodeToString(door.core.PublicKey()),
		"linked":    up,
	}
}

// doorLinkURI is the main node's peering to the door ("" without a door).
func (node *bridgeNode) doorLinkURI() string {
	node.doorMu.Lock()
	defer node.doorMu.Unlock()
	if node.door == nil {
		return ""
	}
	return node.door.linkURI
}

// meshPeers are the main node's peers without the door: the door is not a
// way into the mesh, and must not count as one.
func (node *bridgeNode) meshPeers() []core.PeerInfo {
	peers := node.core.GetPeers()
	link := node.doorLinkURI()
	if link == "" {
		return peers
	}
	filtered := peers[:0]
	for _, peer := range peers {
		if peer.URI != link {
			filtered = append(filtered, peer)
		}
	}
	return filtered
}
