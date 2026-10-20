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
	"github.com/yggdrasil-network/yggdrasil-go/src/ipv6rwc"
	"github.com/yggdrasil-network/yggdrasil-go/src/multicast"
)

type bridgeResponse struct {
	OK    bool   `json:"ok"`
	Data  any    `json:"data,omitempty"`
	Error string `json:"error,omitempty"`
}

type bridgeNode struct {
	core      *core.Core
	iprwc     *ipv6rwc.ReadWriteCloser
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
	// Source IP -> whether it is this device's own (see acceptLocalSource).
	sourceVerdicts map[string]bool
	mu             sync.Mutex
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
	// the bridges of §5.1). "[::]" listens on IPv6 and IPv4 together; Go
	// falls back to IPv4 alone where the computer has no IPv6.
	defaultDesktopPeerListen = "tls://[::]:32913"
	// LAN discovery, when the app turns it on with a password (it is off by
	// default, see ensureDefaultRuntimeConfig), runs on every interface.
	defaultMulticastInterfaceRegex = ".*"
	// Android interface names for Wi-Fi / ethernet / hotspot. Matching every
	// interface (rmnet, dummy, lo) makes multicast noisy and can stall startup.
	androidMulticastInterfaceRegex = "^(wlan|ap|swlan|eth|en|wl).*"
	androidBootstrapPeerLimit      = 8
	androidBootstrapPeerCount      = 16
	desktopPublicPeerCount         = 20
	desktopPeerProbeCandidateLimit = 40
	androidPeerProbeCandidateLimit = 16
	leafProbeTimeout               = 2 * time.Second
	leafProbeCycleBudget           = 3 * time.Second
	leafConnectGracePeriod         = 8 * time.Second
	leafHealthCheckInterval        = 20 * time.Second
	peerProbeRefreshInterval       = 10 * time.Minute
	signalChunkSize                = 1300
	// Most signals queued for the app at once (see signal_inbox.go).
	signalInboxCapacity = 2048
	signalTTL           = 90 * time.Second
	maxRelayBacklog     = 256
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
// The Dart friend gate authorizes which authenticated peers may drive
// application features (friendship, messages, calls); see
// social_hub_controller_lifecycle_signal.dart. It is an authorization layer
// on top of the mesh-level E2E encryption, not a replacement for it.
// Call media (WebRTC) rides the local UDP relay and keeps its own DTLS-SRTP.

// Peer lists derived from publicPeerPool (public_peers.go):
//
//   - defaultPublicPeers: every listed peer, the pool that probing and the
//     runtime fall back on;
//   - androidPublicPeers: the phone's starting set — TLS only, stable, IPv4
//     literals first so Go does not need DNS (a long stale list of dead IPs
//     used to occupy every outbound slot and left the phone on "Łączę...");
//   - desktopPublicPeers(): a desktop connects to every configured peer, so
//     it gets a spread-out subset instead of the whole pool.
var defaultPublicPeers = publicPeerURIs(publicPeerPool)

var androidPublicPeers = selectAndroidBootstrapPeers(publicPeerPool, androidBootstrapPeerCount)
