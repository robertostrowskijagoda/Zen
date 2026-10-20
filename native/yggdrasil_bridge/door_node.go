package main

import (
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

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/ipv6rwc"
)

// The flat's door (neighbours, §18.2). The sticker on the door carries the
// address of a second, minimal Yggdrasil node with its own random key, not
// the address of anyone who lives there. It runs inside the bridge next to
// the main node and reaches the mesh only through it (one peering over
// loopback). It never sends anything: it takes knock frames on the signal
// port and hands them to the app through the main node's signal inbox,
// marked as door traffic. The app answers from its normal identity.
const (
	// The only frame the door takes ("flat_hello" in neighbors_service.dart).
	doorKnockType = "flat_hello"
	// Largest knock text, decompressed: a flat profile with its photo
	// (FlatProfile.maxPhotoChars) and room to spare.
	maxDoorKnockBytes = 512 * 1024
	// Where the door listens for the main node's peering.
	doorListenURI = "tcp://127.0.0.1:0"
)

type doorNode struct {
	core     *core.Core
	iprwc    *ipv6rwc.ReadWriteCloser
	listener *core.Listener
	// The main node's peering to the door (no query, as GetPeers lists it).
	linkURI string
	// The full peering URI, with the door's key pinned.
	peerURI *url.URL
	seed    string
	address string
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
	iprwc := ipv6rwc.NewReadWriteCloser(doorCore)
	// Signal fragments are larger than ipv6rwc's default of 1280 bytes.
	iprwc.SetMTU(iprwc.MaxMTU())
	door := &doorNode{
		core:      doorCore,
		iprwc:     iprwc,
		listener:  listener,
		linkURI:   linkURI,
		peerURI:   peerURI,
		seed:      strings.ToLower(strings.TrimSpace(seedHex)),
		address:   doorCore.Address().String(),
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
	buffer := make([]byte, 64*1024)
	var limiter signalRateLimiter
	for {
		count, err := door.iprwc.Read(buffer)
		if err != nil {
			select {
			case <-door.quit:
				return
			case <-time.After(50 * time.Millisecond):
			}
			continue
		}
		source, port, payload, ok := parseYggPacket(buffer[:count])
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
func isDoorKnock(message string) bool {
	if len(message) > maxDoorKnockBytes {
		return false
	}
	var head struct {
		Type     string `json:"type"`
		Encoding string `json:"_zenEncoding"`
		Payload  string `json:"_zenPayload"`
	}
	if err := json.Unmarshal([]byte(message), &head); err != nil {
		return false
	}
	if head.Encoding == "" {
		return head.Type == doorKnockType
	}
	if head.Encoding != "zstd" || head.Type != "" || head.Payload == "" {
		return false
	}
	compressed, err := base64.StdEncoding.DecodeString(head.Payload)
	if err != nil {
		return false
	}
	inner, err := decompressSignal(compressed)
	if err != nil || len(inner) > maxDoorKnockBytes {
		return false
	}
	var body struct {
		Type string `json:"type"`
	}
	return json.Unmarshal(inner, &body) == nil && body.Type == doorKnockType
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
