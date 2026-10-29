package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gologme/log"
	"github.com/klauspost/compress/zstd"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/multicast"
)

type bridgeResponse struct {
	OK    bool   `json:"ok"`
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

type bridgeNode struct {
	core *core.Core
	// The node's own packets on the mesh: the packet loop reads, a writer
	// of its own writes (mesh_io.go).
	mesh      *meshIO
	config    *config.NodeConfig
	configMu  sync.RWMutex
	multicast *multicast.Multicast
	logger    *log.Logger
	// Decoded signals waiting for the app, within a byte budget
	// (signal_inbox.go); the zero value is ready to use.
	signalInbox    signalQueue
	signalPartials map[string]*signalReassembly
	// Bytes buffered in signalPartials; guarded by signalMu.
	signalPartialBytes int
	signalMu           sync.Mutex
	relays             map[string]*relayState
	relayMu            sync.Mutex
	packetStarted      atomic.Bool
	leafMonitor        *leafPeerMonitor
	peerProbe          *peerProbeState
	nudgeStop          chan struct{}
	nudgeStopOnce      sync.Once
	// Limits on the public peering port of a desktop bridge (peer_guard.go).
	peerGuards []*peerListenGuard
	// Which configured peers came from the public pool (the user's list or
	// the built-in one), so a new list replaces exactly those; guarded by
	// configMu.
	publicPeers map[string]bool
	// The flat's door, when the app runs one, the mailbox doors it runs
	// for friends, by key, and the node carrying them (door_node.go).
	door         *doorNode
	mailboxDoors map[string]*doorNode
	doorHost     *doorHost
	doorMu       sync.Mutex
	// Direct links with friends' and own devices nearby
	// (local_link.go), made on first use.
	localLinks   *localLinkManager
	localLinksMu sync.Mutex
	// Which public peers a phone dials now and the rest of its pool
	// (phone_peers.go); nil on computers.
	phonePeers *phonePeerKeeper
	// A computer's bridge and peer count on battery (power_source.go); nil
	// on phones.
	power *desktopPowerSaver
	// The post-quantum session layer of the signal port (pq_session.go),
	// made on first use.
	pq     *pqEndpoint
	pqErr  error
	pqOnce sync.Once
	// Signals go unsealed: only tests that drive doors (which speak no
	// session layer) from the main node's signal path set it.
	pqPlain bool
	// Bounds of signalPartials (a door's are tighter, door_node.go).
	partialLimits signalPartialLimits
	// The node's own packets and what its peerings carried, for the
	// transit estimate (traffic_meter.go).
	traffic     ownTraffic
	peerTraffic peerTrafficMeter
	// A phone's limit on strangers' traffic passing through it and the
	// peerings it set aside while it holds (transit_guard.go); nil guard on
	// computers.
	transitGuard    *transitGuard
	transitHold     *transitHold
	transitHoldMu   sync.Mutex
	transitStop     chan struct{}
	transitStopOnce sync.Once
	// The node's key, held while it runs, and when the app last called on
	// the node (node_identity.go); nil in tests that build a node by hand.
	identity *nodeIdentityClaim
	lastCall atomic.Int64
}

type configSummary struct {
	PublicKey   string `json:"publicKey"`
	IPv6Address string `json:"ipv6Address"`
	IPv6Subnet  string `json:"ipv6Subnet"`
}

type peerJSON struct {
	URI       string `json:"uri"`
	Up        bool   `json:"up"`
	Inbound   bool   `json:"inbound"`
	IP        string `json:"ip,omitempty"`
	Latency   string `json:"latency,omitempty"`
	LastError string `json:"lastError,omitempty"`
}

type signalMessage struct {
	From    string `json:"from"`
	Payload string `json:"payload"`
	// It came to the flat's door, not to this node (door_node.go).
	Door bool `json:"door,omitempty"`
	// Fingerprint (SHA-256, hex) of the sender's device key, which sealed
	// and authenticated the signal (pq_session.go); the app binds it to
	// the sender's hybrid identity.
	Key string `json:"key,omitempty"`
}

type signalEnvelope struct {
	ID      string `json:"id"`
	Index   int    `json:"index"`
	Total   int    `json:"total"`
	Payload string `json:"payload"`
}

type relayState struct {
	callID          string
	remoteIP        net.IP
	conn            *net.UDPConn
	activeTarget    *net.UDPAddr
	localTargets    map[string]*net.UDPAddr
	pendingPackets  [][]byte
	outboundPackets int
	// Source IP -> whether it is this device's own (see isLocalSourceLocked).
	sourceVerdicts map[string]bool
	// Which local sockets may use the relay (relay_admission.go).
	admission relayAdmission
	// Bytes in pendingPackets.
	pendingBytes int
	mu           sync.Mutex
}

type leafPeerMonitor struct {
	activePeer  string
	activeSince time.Time
	failures    int
	trigger     chan struct{}
	stop        chan struct{}
	stopOnce    sync.Once
	mu          sync.RWMutex
}

type leafPeerProbeResult struct {
	uri     string
	latency time.Duration
	err     error
}

type peerProbeState struct {
	bestPeer       string
	bestLatency    time.Duration
	availableCount int
	candidateCount int
	lastCheckedAt  time.Time
	trigger        chan struct{}
	stop           chan struct{}
	stopOnce       sync.Once
	mu             sync.RWMutex
}

const (
	yggSignalPort = 54321
	yggRelayPort  = 54322
	// Desktops help the wider mesh by accepting inbound peering (they are
	// the bridges). "[::]" listens on IPv6 and IPv4 together; Go
	// falls back to IPv4 alone where the computer has no IPv6.
	defaultDesktopPeerListen = "tls://[::]:32913"
	// A phone's first picks from the built-in pool; the rest of the pool
	// waits behind them in reserve (phonePeerCandidates), and the phone
	// dials only phonePeerCount at once (phone_peers.go).
	phonePeerPoolSize              = 16
	desktopPublicPeerCount         = 20
	desktopPeerProbeCandidateLimit = 40
	androidPeerProbeCandidateLimit = 16
	leafProbeTimeout               = 2 * time.Second
	leafProbeCycleBudget           = 3 * time.Second
	leafConnectGracePeriod         = 8 * time.Second
	leafHealthCheckInterval        = 20 * time.Second
	// The desktop's latency probe of the pool only feeds the diagnostics
	// ("selectedPeer"): rarely, never on battery (power_source.go).
	peerProbeRefreshInterval = 6 * time.Hour
	// Base64 text in one signal fragment as senders up to 1.14 cut them:
	// what the number of fragments a signal may have is reckoned with
	// (maxSignalChunks).
	signalChunkSize = 1300
	// Base64 text in one fragment as this bridge cuts them (doors too): a
	// whole session-layer key record, challenge or opening frame fits one
	// packet, so none of them is split across packets of which the mesh may
	// keep only the last (mesh_io.go). Receivers since 1.13 take fragments
	// of up to maxSignalEncodedBytes.
	signalSendChunkSize = 8 * 1024
	// Most signals queued for the app at once (see signal_inbox.go).
	signalInboxCapacity = 2048
	signalTTL           = 90 * time.Second
	maxRelayBacklog     = 256
	// Most bytes a relay holds in pendingPackets (a datagram may be up to
	// 64 KiB).
	maxRelayBacklogBytes = 512 * 1024
	// Largest signal text, after base64 and zstd. It is kRuntimeSignalMaxBytes
	// in lib/src/features/runtime/runtime_signal_codec.dart, the most a Zen
	// sender ever puts in one signal (the bridge compresses only when that
	// makes the text shorter). Signals arrive from anyone on the mesh before
	// the app knows whether the sender is a friend, so nothing larger is
	// decoded or queued.
	maxSignalPayloadBytes = 2 * 1024 * 1024
	// A zstd signal may inflate to at most this many times its compressed
	// size, or to minSignalDecompressionLimit if that is more (short,
	// repetitive signals compress far better than 64:1 and are harmless).
	// zstd turns a few bytes into megabytes otherwise.
	maxSignalCompressionRatio   = 64
	minSignalDecompressionLimit = 64 * 1024
	zstdMagicPrefix             = "ZSTD:"
)

var (
	nodes            sync.Map
	nextHandle       atomic.Int32
	nextSignalPacket atomic.Int64
	zstdEncoder      *zstd.Encoder
	leafRetryBackoff = []time.Duration{
		10 * time.Second,
		30 * time.Second,
		2 * time.Minute,
		5 * time.Minute,
		15 * time.Minute,
	}
)

const enableVerboseRuntimeLogs = false

func init() {
	var err error
	zstdEncoder, err = zstd.NewWriter(nil, zstd.WithEncoderLevel(zstd.SpeedDefault))
	if err != nil {
		panic("zstd encoder init: " + err.Error())
	}
	// Incoming signals are decompressed by decompressSignal, which bounds the
	// output of each one (signal_reassembly.go).
}

func main() {}

func debugf(format string, args ...any) {
	if enableVerboseRuntimeLogs {
		fmt.Printf(format, args...)
	}
}

// SECURITY / ENCRYPTION AUDIT (2025, re-verified 2026 against v0.5.12):
// Yggdrasil's core embeds ironwood's encrypted.PacketConn (iwe). Every packet
// written through ipv6rwc/Core is sealed with a NaCl-box session key
// (X25519 derived from the nodes' ed25519 identity keys plus ephemeral
// ratcheted keys; the session handshake is ed25519-signed). Traffic is
// therefore end-to-end encrypted and the sender address is authenticated:
// ReadFrom only yields packets whose source key matches the session peer,
// and the IPv6 source address is bound to that key by ipv6rwc.
// Peer links additionally use TLS (or link keys) hop by hop.
// All of this is classical (X25519, Ed25519): the signals the app sends are
// therefore sealed once more by Zen's hybrid post-quantum session layer
// (ML-KEM-768 + X25519, pq_session.go) before they enter the mesh.
// The Dart friend gate authorizes which authenticated peers may drive
// application features (friendship, messages, calls); see
// social_hub_controller_lifecycle_signal.dart. It is an authorization layer
// on top of the mesh-level E2E encryption, not a replacement for it.
// Call media (WebRTC) rides the local UDP relay: every relay packet is
// sealed by the same post-quantum session layer (a media frame, 256-bit
// ChaCha20-Poly1305 per packet), around WebRTC's own DTLS-SRTP and the
// app's AES-GCM frame encryption (call_media_e2ee.dart).

// Peer lists come from activePublicPeerPool (public_peers.go): the user's
// own list when they made one in the app, else the built-in pool on
// encrypted transports:
//
//   - defaultPublicPeerURIs(): the pool that probing and the runtime fall
//     back on;
//   - androidBootstrapPeers(): the phone's starting set — TLS only, stable,
//     IPv4 literals first so Go does not need DNS (a long stale list of dead
//     IPs used to occupy every outbound slot and left the phone on
//     "Łączę...");
//   - desktopPublicPeers(): a desktop connects to every configured peer, so
//     it gets a spread-out subset instead of the whole pool.
