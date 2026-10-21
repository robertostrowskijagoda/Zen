package main

import (
	"crypto/ed25519"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

func TestDefaultRuntimeConfigTellsNothingAndOpensNoAdminSocket(t *testing.T) {
	cfg := config.GenerateConfig()
	cfg.AdminListen = "tcp://127.0.0.1:9001"
	cfg.IfName = "auto"
	cfg.NodeInfoPrivacy = false
	cfg.NodeInfo = map[string]interface{}{"name": "Ania's phone"}
	cfg.LogLookups = true
	ensureDefaultRuntimeConfig(cfg)
	if cfg.AdminListen != "none" || cfg.IfName != "none" {
		t.Fatalf("admin %q, TUN %q", cfg.AdminListen, cfg.IfName)
	}
	if !cfg.NodeInfoPrivacy || cfg.NodeInfo != nil || cfg.LogLookups {
		t.Fatal("NodeInfo must be private and empty, lookups not logged")
	}
}

// adminHandlers keeps the handlers a core registers for its admin socket,
// so a test can call them without opening one.
type adminHandlers map[string]core.AddHandlerFunc

func (handlers adminHandlers) AddHandler(name, _ string, _ []string, handler core.AddHandlerFunc) error {
	handlers[name] = handler
	return nil
}

func TestNodeInfoAnswersNothingAboutThisDevice(t *testing.T) {
	logger := log.New(io.Discard, "", 0)
	var hubKey ed25519.PrivateKey
	for hubKey == nil || hubKey.Public().(ed25519.PublicKey)[0] != 0 ||
		hubKey.Public().(ed25519.PublicKey)[1] > 0x0f {
		_, hubKey, _ = ed25519.GenerateKey(nil)
	}
	hubConfig := &config.NodeConfig{PrivateKey: config.KeyBytes(hubKey)}
	if err := hubConfig.GenerateSelfSignedCertificate(); err != nil {
		t.Fatal(err)
	}
	hub, err := core.New(hubConfig.Certificate, logger)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(hub.Stop)
	listenURL, _ := url.Parse("tcp://127.0.0.1:0")
	listener, err := hub.Listen(listenURL, "")
	if err != nil {
		t.Fatal(err)
	}
	hubURI := fmt.Sprintf("tcp://127.0.0.1:%d", listener.Addr().(*net.TCPAddr).Port)
	newCore := func(options ...core.SetupOption) *core.Core {
		cfg := config.GenerateConfig()
		c, err := core.New(cfg.Certificate, logger, append(options, core.Peer{URI: hubURI})...)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(c.Stop)
		// NodeInfo requests and answers are handled while the node's
		// packets are read (the app's packet loop does that).
		go func() {
			buffer := make([]byte, 65535)
			for {
				if _, _, err := c.ReadFrom(buffer); err != nil {
					return
				}
			}
		}()
		return c
	}
	private := newCore(nodeInfoPrivacyOptions()...)
	stock := newCore()
	asker := newCore()
	handlers := adminHandlers{}
	if err := asker.SetAdmin(handlers); err != nil {
		t.Fatal(err)
	}
	warmPaths(t, asker, private)
	warmPaths(t, asker, stock)
	ask := func(target *core.Core) string {
		request, _ := json.Marshal(core.GetNodeInfoRequest{Key: hex.EncodeToString(target.PublicKey())})
		var answer string
		waitMesh(t, "no NodeInfo answer", func() bool {
			response, err := handlers["getNodeInfo"](request)
			if err != nil {
				return false
			}
			encoded, _ := json.Marshal(response)
			answer = string(encoded)
			return true
		})
		return answer
	}
	if answer := ask(stock); !strings.Contains(answer, "buildplatform") {
		t.Fatalf("a stock node tells its platform (the check works): %s", answer)
	}
	if answer := ask(private); strings.Contains(answer, "build") || !strings.Contains(answer, "{}") {
		t.Fatalf("a Zen node must answer an empty NodeInfo, got %s", answer)
	}
}

// Yggdrasil leaves TLS's key exchange to Go, whose default since Go 1.24
// is the hybrid X25519MLKEM768: tls://, quic:// and wss:// links between
// current nodes are post-quantum on the line (the mesh's own end-to-end
// layer is not; pq_session.go covers that).
func TestTLSLinksNegotiateHybridPostQuantumKeyExchange(t *testing.T) {
	cfg := config.GenerateConfig()
	// Yggdrasil's own TLS settings (core/tls.go): no curve preferences.
	server := &tls.Config{
		Certificates:       []tls.Certificate{*cfg.Certificate},
		ClientAuth:         tls.NoClientCert,
		InsecureSkipVerify: true,
		MinVersion:         tls.VersionTLS13,
	}
	client := &tls.Config{InsecureSkipVerify: true, MinVersion: tls.VersionTLS12}
	left, right := net.Pipe()
	done := make(chan error, 1)
	go func() {
		conn := tls.Server(left, server)
		done <- conn.Handshake()
	}()
	conn := tls.Client(right, client)
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))
	if err := conn.Handshake(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if state := conn.ConnectionState(); state.CurveID != tls.X25519MLKEM768 {
		t.Fatalf("link key exchange %v, want X25519MLKEM768", state.CurveID)
	}
	if key := peerCertificateKey(conn.ConnectionState()); !key.Equal(ed25519.PrivateKey(cfg.PrivateKey).Public()) {
		t.Fatal("a peer's TLS certificate carries its node key (what ?key= pins)")
	}
}
