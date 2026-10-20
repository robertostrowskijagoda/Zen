package main

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"strings"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
	"github.com/yggdrasil-network/yggdrasil-go/src/ipv6rwc"
)

func TestDoorKnockFilter(t *testing.T) {
	knock := `{"type":"flat_hello","f":"k","to":"k","b":{},"s":"x"}`
	if !isDoorKnock(knock) {
		t.Fatal("a plain knock must pass")
	}
	for _, other := range []string{
		`{"type":"flat_msg","b":{}}`,
		`{"type":"friend_request"}`,
		`{"b":{}}`,
		`not json`,
		`["flat_hello"]`,
		`{"type":"flat_hello","_zenEncoding":"zstd","_zenPayload":"AAAA"}`,
		`{"_zenEncoding":"gzip","_zenPayload":"AAAA"}`,
		// The app reads "type" exactly; encoding/json's struct decoding
		// matched these as a knock (Z2-2).
		`{"type":"lg_heads","TYPE":"flat_hello"}`,
		`{"TYPE":"flat_hello"}`,
		`{"Type":"flat_hello","b":{}}`,
		`{"type":"flat_hello","Type":"lg_want"}`,
		`{"type":"lg_hello","type":"flat_hello"}`,
		`{"type":"flat_hello","type":"lg_hello"}`,
		`{"type":"flat_hello","tYpE":"x"}`,
		`{"type":"flat_hello"} {"type":"lg_hello"}`,
		`{"type":"flat_hello"}x`,
		`{"type":["flat_hello"]}`,
		`{"_zenEncoding":7,"type":"flat_hello"}`,
	} {
		if isDoorKnock(other) {
			t.Fatalf("%s must not pass the door", other)
		}
	}
	if isDoorKnock(`{"type":"flat_hello","p":"` + strings.Repeat("x", maxDoorKnockBytes) + `"}`) {
		t.Fatal("an oversized knock must not pass")
	}

	// The app's own zstd wrapper (runtime_signal_codec.dart) is looked into.
	wrap := func(inner string) string {
		encoded, _ := json.Marshal(map[string]string{
			"_zenEncoding": "zstd",
			"_zenPayload":  base64.StdEncoding.EncodeToString(zstdEncoder.EncodeAll([]byte(inner), nil)),
		})
		return string(encoded)
	}
	// A JPEG in base64 hardly compresses; random bytes play it.
	raw := make([]byte, 30*1024)
	rng := rand.New(rand.NewPCG(1, 2))
	for index := range raw {
		raw[index] = byte(rng.UintN(256))
	}
	photo := base64.StdEncoding.EncodeToString(raw)
	if !isDoorKnock(wrap(`{"type":"flat_hello","p":"` + photo + `"}`)) {
		t.Fatal("a compressed knock must pass")
	}
	if isDoorKnock(wrap(`{"type":"flat_msg","p":"` + photo + `"}`)) {
		t.Fatal("a compressed frame of another type must not pass")
	}
	if isDoorKnock(wrap(`{"type":"lg_hello","TYPE":"flat_hello"}`)) {
		t.Fatal("a compressed frame with a case-variant type must not pass")
	}
	if !isDoorKnock(`{"type":"flat_hello","_zenEncoding":""}`) || !isDoorKnock(`{"type":"flat_\u0068ello"}`) {
		t.Fatal("the app reads these as plain knocks")
	}
	caseWrapped, _ := json.Marshal(map[string]string{
		"_ZENENCODING": "zstd",
		"_zenPayload":  base64.StdEncoding.EncodeToString(zstdEncoder.EncodeAll([]byte(`{"type":"flat_hello"}`), nil)),
		"type":         "lg_hello",
	})
	if isDoorKnock(string(caseWrapped)) {
		t.Fatal("a case-variant wrapper key must not pass")
	}
	if isDoorKnock(wrap(`{"type":"flat_hello","p":"` + strings.Repeat("a", maxDoorKnockBytes) + `"}`)) {
		t.Fatal("a knock inflating past the limit must not pass")
	}
}

func TestDoorSeedIsValidated(t *testing.T) {
	if _, err := doorSeed("abcd"); err == nil {
		t.Fatal("a short key must be refused")
	}
	if _, err := doorSeed(strings.Repeat("zz", 32)); err == nil {
		t.Fatal("a key that is not hex must be refused")
	}
	if _, err := doorSeed(strings.Repeat("ab", 32)); err != nil {
		t.Fatalf("a 32-byte hex key must be taken: %v", err)
	}
}

// newTestMeshNode is a main node without peers or listeners.
func newTestMeshNode(t *testing.T) *bridgeNode {
	t.Helper()
	cfg := config.GenerateConfig()
	logger := log.New(io.Discard, "", 0)
	yggCore, err := core.New(cfg.Certificate, logger)
	if err != nil {
		t.Fatalf("core: %v", err)
	}
	iprwc := ipv6rwc.NewReadWriteCloser(yggCore)
	iprwc.SetMTU(iprwc.MaxMTU())
	node := &bridgeNode{
		core:           yggCore,
		iprwc:          iprwc,
		config:         cfg,
		logger:         logger,
		signalPartials: make(map[string]*signalReassembly),
	}
	t.Cleanup(func() {
		node.stopDoor()
		yggCore.Stop()
	})
	return node
}

func TestDoorTakesOnlyKnocksAndHandsThemToTheApp(t *testing.T) {
	node := newTestMeshNode(t)
	// The app's packet loop runs whenever signalling does; sessions to the
	// door need it.
	startPacketLoop(node)
	seed := strings.Repeat("42", 32)
	door, err := node.startDoor(seed)
	if err != nil {
		t.Fatalf("start door: %v", err)
	}
	if door.address == node.core.Address().String() {
		t.Fatal("the door must have its own address")
	}
	if again, _ := node.startDoor(strings.ToUpper(seed)); again != door {
		t.Fatal("the same key keeps the running door")
	}
	state := node.doorState()
	if state["running"] != true || state["address"] != door.address {
		t.Fatalf("door state: %v", state)
	}
	if _, leaked := state["seed"]; leaked {
		t.Fatal("the door key never leaves the bridge")
	}
	if pub := state["publicKey"]; pub != hex.EncodeToString(door.core.PublicKey()) {
		t.Fatalf("door public key: %v", pub)
	}

	deadline := time.Now().Add(20 * time.Second)
	for !node.doorState()["linked"].(bool) {
		if time.Now().After(deadline) {
			t.Fatal("the main node never linked to the door")
		}
		time.Sleep(50 * time.Millisecond)
	}
	for _, peer := range node.meshPeers() {
		if peer.URI == door.linkURI {
			t.Fatal("the door must not count as a mesh peer")
		}
	}
	if node.hasUpPeer() {
		t.Fatal("a node linked only to its door is not on the mesh")
	}

	// The first knocks open the session to the door.
	knock := `{"type":"flat_hello","b":{"door":"t"}}`
	for {
		if time.Now().After(deadline) {
			t.Fatal("no knock came through the door")
		}
		if err := sendSignal(node, door.address, knock); err != nil {
			t.Fatalf("send: %v", err)
		}
		if message, ok := node.signalInbox.wait(500 * time.Millisecond); ok {
			if message.Payload != knock || !message.Door || message.From != node.core.Address().String() {
				t.Fatalf("unexpected door signal: %+v", message)
			}
			break
		}
	}
	for {
		if _, ok := node.signalInbox.wait(200 * time.Millisecond); !ok {
			break
		}
	}

	// Any other frame stays at the door; the knock after it comes through.
	if err := sendSignal(node, door.address, `{"type":"flat_msg","b":{}}`); err != nil {
		t.Fatalf("send: %v", err)
	}
	second := `{"type":"flat_hello","b":{"door":"u"}}`
	if err := sendSignal(node, door.address, second); err != nil {
		t.Fatalf("send: %v", err)
	}
	message, ok := node.signalInbox.wait(5 * time.Second)
	if !ok || message.Payload != second || !message.Door {
		t.Fatalf("expected only the knock, got %+v (ok=%v)", message, ok)
	}
	if extra, ok := node.signalInbox.wait(300 * time.Millisecond); ok {
		t.Fatalf("the door let another frame in: %+v", extra)
	}

	// Mesh queries to the door (any node's debug_remoteGet*, getNodeInfo)
	// get no answer: its peers would name the resident's main node.
	admin := capturedAdmin{}
	if err := node.core.SetAdmin(admin); err != nil {
		t.Fatalf("admin: %v", err)
	}
	query := json.RawMessage(`{"key":"` + hex.EncodeToString(door.core.PublicKey()) + `"}`)
	answers := make(chan string, len(admin))
	for name, handler := range admin {
		go func() {
			if reply, err := handler(query); err == nil {
				answers <- fmt.Sprintf("%s answered: %v", name, reply)
				return
			}
			answers <- ""
		}()
	}
	for range admin {
		if answer := <-answers; answer != "" {
			t.Fatal(answer)
		}
	}

	// A new key ("Nowy kod") is a new door; the old address is gone.
	rotated, err := node.startDoor(strings.Repeat("43", 32))
	if err != nil {
		t.Fatalf("rotate door: %v", err)
	}
	if rotated.address == door.address {
		t.Fatal("a new key must give a new door address")
	}
	select {
	case <-door.done:
	case <-time.After(5 * time.Second):
		t.Fatal("the old door kept running")
	}
	node.stopDoor()
	if node.doorState()["running"] != false || node.doorLinkURI() != "" {
		t.Fatal("the door is still there after stop")
	}
	gone := time.Now().Add(5 * time.Second)
	for stillPeered(node, rotated.linkURI) {
		if time.Now().After(gone) {
			t.Fatal("the main node still peers with a stopped door")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// capturedAdmin keeps the core's admin handlers so a test can call them.
type capturedAdmin map[string]core.AddHandlerFunc

func (admin capturedAdmin) AddHandler(name, _ string, _ []string, handler core.AddHandlerFunc) error {
	admin[name] = handler
	return nil
}

func stillPeered(node *bridgeNode, uri string) bool {
	for _, peer := range node.core.GetPeers() {
		if peer.URI == uri {
			return true
		}
	}
	return false
}
