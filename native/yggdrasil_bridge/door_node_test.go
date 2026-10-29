package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

func TestDoorFrameFilter(t *testing.T) {
	knock := `{"type":"flat_hello","f":"k","to":"k","b":{},"s":"x"}`
	if !isDoorTraffic(knock) {
		t.Fatal("a plain knock must pass")
	}
	// Everything between neighbour flats goes from door to door.
	for kind := range doorTrafficTypes {
		if !isDoorTraffic(`{"type":"` + kind + `","b":{}}`) {
			t.Fatalf("%s must pass the door", kind)
		}
	}
	for _, other := range []string{
		// Between housemates: phone to phone, never through a door.
		`{"type":"flat_house","b":{}}`,
		`{"type":"flat_kick","b":{}}`,
		`{"type":"flat_seal","d":"200::1"}`,
		`{"type":"friend_request"}`,
		`{"b":{}}`,
		`not json`,
		`["flat_hello"]`,
		`{"type":"flat_hello","_zenEncoding":"zstd","_zenPayload":"AAAA"}`,
		`{"_zenEncoding":"gzip","_zenPayload":"AAAA"}`,
		// The app reads "type" exactly; encoding/json's struct decoding
		// matched these as a knock.
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
		if isDoorTraffic(other) {
			t.Fatalf("%s must not pass the door", other)
		}
	}
	if isDoorTraffic(`{"type":"flat_hello","p":"` + strings.Repeat("x", maxDoorFrameBytes) + `"}`) {
		t.Fatal("an oversized frame must not pass")
	}
	// The household's card for a flat that knocked ("Co widzi pukający")
	// goes from door to door; the knocks a household shares between its
	// phones (in flat_house) never pass a door.
	card := `{"type":"flat_card","f":"k","to":"k","b":{"p":{}},"s":"x"}`
	if !isDoorTraffic(card) || !isDoorSendable(card) {
		t.Fatal("a door card must pass and be sent")
	}
	if isDoorTraffic(`{"type":"flat_house","b":{"kn":[],"ring":true}}`) {
		t.Fatal("the housemates' shared knocks must not pass a door")
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
	if !isDoorTraffic(wrap(`{"type":"flat_profile","p":"` + photo + `"}`)) {
		t.Fatal("a compressed profile must pass")
	}
	if isDoorTraffic(wrap(`{"type":"flat_house","p":"` + photo + `"}`)) {
		t.Fatal("a compressed frame of another type must not pass")
	}
	if isDoorTraffic(wrap(`{"type":"lg_hello","TYPE":"flat_hello"}`)) {
		t.Fatal("a compressed frame with a case-variant type must not pass")
	}
	if !isDoorTraffic(`{"type":"flat_hello","_zenEncoding":""}`) || !isDoorTraffic(`{"type":"flat_\u0068ello"}`) {
		t.Fatal("the app reads these as plain knocks")
	}
	caseWrapped, _ := json.Marshal(map[string]string{
		"_ZENENCODING": "zstd",
		"_zenPayload":  base64.StdEncoding.EncodeToString(zstdEncoder.EncodeAll([]byte(`{"type":"flat_hello"}`), nil)),
		"type":         "lg_hello",
	})
	if isDoorTraffic(string(caseWrapped)) {
		t.Fatal("a case-variant wrapper key must not pass")
	}
	if isDoorTraffic(wrap(`{"type":"flat_hello","p":"` + strings.Repeat("a", maxDoorFrameBytes) + `"}`)) {
		t.Fatal("a frame inflating past the limit must not pass")
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

// testMesh is a public peer ("hub") on loopback and a main node peered
// with it, as a phone is with its public peers. The door host may dial the
// hub although it is on loopback.
type testMesh struct {
	hub  *core.Core
	node *bridgeNode
}

func newTestMesh(t *testing.T) *testMesh {
	t.Helper()
	logger := log.New(io.Discard, "", 0)
	// The mesh's root is the node with the lowest key, as on the real mesh
	// one long-standing node is: the hub, not one of the keys made below.
	var hubKey ed25519.PrivateKey
	for hubKey == nil || hubKey.Public().(ed25519.PublicKey)[0] != 0 ||
		hubKey.Public().(ed25519.PublicKey)[1] > 0x0f {
		_, hubKey, _ = ed25519.GenerateKey(nil)
	}
	hubConfig := &config.NodeConfig{PrivateKey: config.KeyBytes(hubKey)}
	if err := hubConfig.GenerateSelfSignedCertificate(); err != nil {
		t.Fatalf("hub key: %v", err)
	}
	hub, err := core.New(hubConfig.Certificate, logger)
	if err != nil {
		t.Fatalf("hub: %v", err)
	}
	listenURL, _ := url.Parse("tcp://127.0.0.1:0")
	listener, err := hub.Listen(listenURL, "")
	if err != nil {
		t.Fatalf("hub listen: %v", err)
	}
	hubURI := fmt.Sprintf("tcp://127.0.0.1:%d", listener.Addr().(*net.TCPAddr).Port)

	cfg := config.GenerateConfig()
	cfg.Peers = []string{hubURI}
	yggCore, err := core.New(cfg.Certificate, logger, core.Peer{URI: hubURI})
	if err != nil {
		t.Fatalf("core: %v", err)
	}
	node := &bridgeNode{
		core:           yggCore,
		config:         cfg,
		logger:         logger,
		signalPartials: make(map[string]*signalReassembly),
		// The tests talk to the doors from the main node's own signal
		// path, as another flat's door would: doors speak no session layer.
		pqPlain: true,
	}
	node.startMesh()
	allowed := doorHostPeerAllowed
	doorHostPeerAllowed = func(string) bool { return true }
	t.Cleanup(func() {
		node.stopDoor()
		_, _ = node.setMailboxDoors(nil)
		node.mesh.stop()
		yggCore.Stop()
		hub.Stop()
		doorHostPeerAllowed = allowed
	})
	return &testMesh{hub: hub, node: node}
}

// peerKeys are the keys a core peers with (up or not).
func peerKeys(c *core.Core) map[string]bool {
	keys := make(map[string]bool)
	for _, peer := range c.GetPeers() {
		if peer.Key != nil {
			keys[hex.EncodeToString(peer.Key)] = true
		}
	}
	return keys
}

func waitMesh(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatal(what)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// warmPaths waits until a and b have mesh paths to each other. A session
// begun before a new node's bloom filters have reached the far side stalls
// for a minute: ironwood answers a repeated session init only once, and
// that answer had no path yet.
func warmPaths(t *testing.T, a, b *core.Core) {
	t.Helper()
	hasPath := func(from *core.Core, to ed25519.PublicKey) bool {
		for _, path := range from.GetPaths() {
			if bytes.Equal(path.Key, to) {
				return true
			}
		}
		return false
	}
	waitMesh(t, "no mesh path between the nodes", func() bool {
		a.SendLookup(b.PublicKey())
		b.SendLookup(a.PublicKey())
		time.Sleep(100 * time.Millisecond)
		return hasPath(a, b.PublicKey()) && hasPath(b, a.PublicKey())
	})
}

// drainInbox drops what is waiting in the main node's signal inbox.
func drainInbox(node *bridgeNode) {
	for {
		if _, ok := node.signalInbox.wait(200 * time.Millisecond); !ok {
			return
		}
	}
}

func TestDoorCarriesFlatTrafficAndIsNeverPeeredWithTheMainNode(t *testing.T) {
	mesh := newTestMesh(t)
	node := mesh.node
	// The app's packet loop runs whenever signalling does.
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
	waitMesh(t, "the door never got onto the mesh", func() bool {
		return node.doorState()["linked"].(bool)
	})
	warmPaths(t, node.core, door.core)

	// The main node and the door (and its host) never peer, so no
	// getPeers/getTree answer of either names the other.
	host := node.doorHost
	mainKey := hex.EncodeToString(node.core.PublicKey())
	hostKey := hex.EncodeToString(host.core.PublicKey())
	doorKey := hex.EncodeToString(door.core.PublicKey())
	hubKey := hex.EncodeToString(mesh.hub.PublicKey())
	if keys := peerKeys(node.core); len(keys) != 1 || !keys[hubKey] {
		t.Fatalf("the main node peers with %v, want only its public peer", keys)
	}
	if keys := peerKeys(door.core); len(keys) != 1 || !keys[hostKey] {
		t.Fatalf("the door peers with %v, want only its host", keys)
	}
	if keys := peerKeys(host.core); keys[mainKey] || !keys[hubKey] || !keys[doorKey] {
		t.Fatalf("the door host peers with %v", keys)
	}
	if node.hasUpPeer() != true {
		t.Fatal("the main node is on the mesh through its public peer")
	}

	// The first frames open the session to the door.
	knock := `{"type":"flat_hello","b":{"door":"t"}}`
	waitMesh(t, "no knock came through the door", func() bool {
		if err := sendSignal(node, door.address, knock); err != nil {
			t.Fatalf("send: %v", err)
		}
		message, ok := node.signalInbox.wait(500 * time.Millisecond)
		if !ok {
			return false
		}
		if message.Payload != knock || !message.Door || message.From != node.core.Address().String() {
			t.Fatalf("unexpected door signal: %+v", message)
		}
		return true
	})
	drainInbox(node)

	// Frames between flats pass; frames between housemates, and anything
	// else, stay at the door.
	for _, other := range []string{`{"type":"flat_house","b":{}}`, `{"type":"lg_hello"}`} {
		if err := sendSignal(node, door.address, other); err != nil {
			t.Fatalf("send: %v", err)
		}
	}
	message := `{"type":"flat_msg","b":{"t":"hej"}}`
	if err := sendSignal(node, door.address, message); err != nil {
		t.Fatalf("send: %v", err)
	}
	got, ok := node.signalInbox.wait(5 * time.Second)
	if !ok || got.Payload != message || !got.Door {
		t.Fatalf("expected only the flat message, got %+v (ok=%v)", got, ok)
	}
	if extra, ok := node.signalInbox.wait(300 * time.Millisecond); ok {
		t.Fatalf("the door let another frame in: %+v", extra)
	}
	// A sealed knock naming this door comes in too (a housemate's sticker
	// lists it among the mailbox doors); one naming another door does not.
	sealedHere := `{"type":"flat_seal","d":"` + door.address + `","c":"AAAA"}`
	sealedThere := `{"type":"flat_seal","d":"201:257a:9b7e:ed64:6c2b:bb66:90d6:3167","c":"AAAA"}`
	for _, payload := range []string{sealedThere, sealedHere} {
		if err := sendSignal(node, door.address, payload); err != nil {
			t.Fatalf("send: %v", err)
		}
	}
	got, ok = node.signalInbox.wait(5 * time.Second)
	if !ok || got.Payload != sealedHere || !got.Door {
		t.Fatalf("expected only the sealed knock for this door, got %+v (ok=%v)", got, ok)
	}
	if extra, ok := node.signalInbox.wait(300 * time.Millisecond); ok {
		t.Fatalf("the door let another frame in: %+v", extra)
	}

	// The door sends from its own address, and flat frames only.
	profile := `{"type":"flat_profile","b":{}}`
	waitMesh(t, "nothing the door sent arrived", func() bool {
		if err := node.doorSend(node.core.Address().String(), profile); err != nil {
			t.Fatalf("door send: %v", err)
		}
		got, ok := node.signalInbox.wait(500 * time.Millisecond)
		if !ok {
			return false
		}
		if got.Payload != profile || got.Door || got.From != door.address {
			t.Fatalf("unexpected signal from the door: %+v", got)
		}
		return true
	})
	for _, other := range []string{`{"type":"lg_hello"}`, `{"type":"flat_house","b":{}}`} {
		if err := node.doorSend(node.core.Address().String(), other); err == nil {
			t.Fatalf("the door must not send %s", other)
		}
	}
	// Sealed knocks for mailbox doors go out from the door too.
	if !isDoorSendable(`{"type":"flat_seal","d":"200::1","c":"AAAA"}`) {
		t.Fatal("the door sends sealed knocks")
	}
	if err := node.doorSend("10.0.0.1", profile); err == nil {
		t.Fatal("the door sends to mesh addresses only")
	}

	// Mesh queries to the door or its host (any node's debug_remoteGet*,
	// getNodeInfo) get no answer: their peers would say where they hang.
	admin := capturedAdmin{}
	if err := node.core.SetAdmin(admin); err != nil {
		t.Fatalf("admin: %v", err)
	}
	for _, key := range []string{doorKey, hostKey} {
		query := json.RawMessage(`{"key":"` + key + `"}`)
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
	if node.doorState()["running"] != false {
		t.Fatal("the door is still there after stop")
	}
	if err := node.doorSend(node.core.Address().String(), profile); err == nil {
		t.Fatal("no door, nothing sent")
	}
	// The host goes with the last door.
	if node.doorHost != nil {
		t.Fatal("the door host outlived its doors")
	}
	select {
	case <-host.done:
	case <-time.After(5 * time.Second):
		t.Fatal("the door host kept running")
	}
}

// capturedAdmin keeps the core's admin handlers so a test can call them.
type capturedAdmin map[string]core.AddHandlerFunc

func (admin capturedAdmin) AddHandler(name, _ string, _ []string, handler core.AddHandlerFunc) error {
	admin[name] = handler
	return nil
}

func TestDoorHostPeersAvoidTheMainNodesParent(t *testing.T) {
	pool := []string{"tls://a:443", "tls://b:443?key=00", "tls://c:443", "tls://d:443"}
	got := doorHostPeers(pool, "tls://b:443", 1, 2)
	if len(got) != 2 || got[0] != "tls://c:443" || got[1] != "tls://d:443" {
		t.Fatalf("picked %v", got)
	}
	// Going round the pool, never the parent.
	for offset := 0; offset < 10; offset++ {
		for _, uri := range doorHostPeers(pool, "tls://b:443", offset, 2) {
			if peerURIBase(uri) == "tls://b:443" {
				t.Fatalf("offset %d picked the parent", offset)
			}
		}
	}
	// The parent only when it is the one peer there is.
	if got := doorHostPeers([]string{"tls://b:443"}, "tls://b:443", 0, 2); len(got) != 1 {
		t.Fatalf("picked %v", got)
	}
	if got := doorHostPeers(nil, "", 0, 2); len(got) != 0 {
		t.Fatalf("picked %v", got)
	}
	// Public peers only: a LAN node lists few peers, the main node and the
	// host side by side there would be easy to pair.
	for uri, want := range map[string]bool{
		"tls://1.2.3.4:443":       true,
		"tls://192.168.1.5:12345": false,
		"tcp://127.0.0.1:9000":    false,
		"tls://[fe80::1]:443":     false,
	} {
		if doorHostPeerAllowed(uri) != want {
			t.Fatalf("%s allowed=%v", uri, !want)
		}
	}
}

// The app computes a mailbox door's address from its key itself, to print
// it on the door sticker (yggAddressForKey in flat_door_mail.dart); these
// vectors are checked there too.
func TestDoorAddressVectors(t *testing.T) {
	for seedHex, want := range map[string]string{
		strings.Repeat("42", 32): "202:f568:3973:2437:16dd:d66d:e8f5:68a",
		strings.Repeat("ff", 32): "201:257a:9b7e:ed64:6c2b:bb66:90d6:3167",
		"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f": "206:2f7c:2006:18f7:a0f1:4791:738c:5a1f",
	} {
		private, err := doorSeed(seedHex)
		if err != nil {
			t.Fatal(err)
		}
		got := address.AddrForKey(private.Public().(ed25519.PublicKey))
		if net.IP(got[:]).String() != want {
			t.Fatalf("%s: %s, want %s", seedHex, net.IP(got[:]).String(), want)
		}
	}
}

func TestSealedKnockFilter(t *testing.T) {
	private, _ := doorSeed(strings.Repeat("42", 32))
	ip := *address.AddrForKey(private.Public().(ed25519.PublicKey))
	here := net.IP(ip[:]).String()
	sealed := `{"type":"flat_seal","d":"` + here + `","c":"AAAA"}`
	if !isSealedKnockFor(sealed, ip) {
		t.Fatal("a sealed knock naming the door must pass")
	}
	// The same address written out in full is the same door.
	full := `{"type":"flat_seal","d":"0202:f568:3973:2437:16dd:d66d:e8f5:068a","c":"AAAA"}`
	if !isSealedKnockFor(full, ip) {
		t.Fatal("the address may be written in any IPv6 form")
	}
	for _, other := range []string{
		`{"type":"flat_seal","d":"201:257a:9b7e:ed64:6c2b:bb66:90d6:3167","c":"AAAA"}`,
		`{"type":"flat_seal","c":"AAAA"}`,
		`{"type":"flat_seal","d":7}`,
		`{"type":"flat_seal","d":"10.0.0.1"}`,
		`{"type":"flat_hello","d":"` + here + `"}`,
		`{"type":"flat_seal","D":"` + here + `","d":"` + here + `"}`,
		`{"type":"flat_seal","d":"` + here + `","c":"` + strings.Repeat("x", maxDoorSealBytes) + `"}`,
	} {
		if isSealedKnockFor(other, ip) {
			t.Fatalf("%s must not pass a mailbox door", other)
		}
	}
	compressed, _ := json.Marshal(map[string]string{
		"_zenEncoding": "zstd",
		"_zenPayload":  base64.StdEncoding.EncodeToString(zstdEncoder.EncodeAll([]byte(sealed), nil)),
	})
	if !isSealedKnockFor(string(compressed), ip) {
		t.Fatal("a compressed sealed knock must pass")
	}
	if isDoorTraffic(sealed) {
		t.Fatal("a sealed knock is no traffic between flats")
	}
}

// The sticker lists the other residents' doors among its mailbox doors, so
// the flat's own door takes a sealed knock that names it, besides the
// frames between flats; a mailbox door takes sealed knocks only.
func TestTheFlatsOwnDoorTakesSealedKnocksNamingIt(t *testing.T) {
	private, _ := doorSeed(strings.Repeat("42", 32))
	ip := *address.AddrForKey(private.Public().(ed25519.PublicKey))
	here := net.IP(ip[:]).String()
	own := &doorNode{ip: ip}
	mailbox := &doorNode{ip: ip, mailbox: true}
	sealedHere := `{"type":"flat_seal","d":"` + here + `","c":"AAAA"}`
	sealedThere := `{"type":"flat_seal","d":"201:257a:9b7e:ed64:6c2b:bb66:90d6:3167","c":"AAAA"}`
	knock := `{"type":"flat_hello","b":{"door":"t"}}`
	card := `{"type":"flat_card","b":{}}`
	for _, payload := range []string{sealedHere, knock, card} {
		if !own.takes(payload) {
			t.Fatalf("the flat's own door must take %s", payload)
		}
	}
	for _, payload := range []string{sealedThere, `{"type":"flat_house","b":{}}`, `{"type":"lg_hello"}`} {
		if own.takes(payload) {
			t.Fatalf("the flat's own door must not take %s", payload)
		}
	}
	if !mailbox.takes(sealedHere) {
		t.Fatal("a mailbox door takes a sealed knock naming it")
	}
	for _, payload := range []string{sealedThere, knock, card} {
		if mailbox.takes(payload) {
			t.Fatalf("a mailbox door must not take %s", payload)
		}
	}
}

func TestMailboxDoorsTakeOnlySealedKnocksForThemselves(t *testing.T) {
	mesh := newTestMesh(t)
	node := mesh.node
	startPacketLoop(node)
	seedA := strings.Repeat("51", 32)
	seedB := strings.Repeat("52", 32)
	addresses, err := node.setMailboxDoors([]string{seedA, strings.ToUpper(seedB)})
	if err != nil {
		t.Fatalf("mailbox doors: %v", err)
	}
	if len(addresses) != 2 || addresses[seedA] == addresses[seedB] || addresses[seedA] == node.core.Address().String() {
		t.Fatalf("addresses: %v", addresses)
	}
	doorA := node.mailboxDoors[seedA]
	waitMesh(t, "the mailbox door never got onto the mesh", doorA.linked)
	warmPaths(t, node.core, doorA.core)
	// Below the same host as the flat's own door, never below the main node.
	if node.doorHost == nil || doorA.host != node.doorHost {
		t.Fatal("the mailbox door must hang below the door host")
	}
	if keys := peerKeys(node.core); keys[hex.EncodeToString(doorA.core.PublicKey())] ||
		keys[hex.EncodeToString(node.doorHost.core.PublicKey())] {
		t.Fatalf("the main node peers with a door: %v", keys)
	}
	if err := doorA.send(node.core.Address().String(), `{"type":"flat_profile"}`); err == nil {
		t.Fatal("a mailbox door sends nothing")
	}

	sealed := `{"type":"flat_seal","d":"` + addresses[seedA] + `","c":"AAAA"}`
	waitMesh(t, "no sealed knock came through the mailbox door", func() bool {
		if err := sendSignal(node, addresses[seedA], sealed); err != nil {
			t.Fatalf("send: %v", err)
		}
		message, ok := node.signalInbox.wait(500 * time.Millisecond)
		if !ok {
			return false
		}
		if message.Payload != sealed || !message.Door {
			t.Fatalf("unexpected mailbox door signal: %+v", message)
		}
		return true
	})
	drainInbox(node)
	// A plain knock, and a sealed knock for the other door, stay outside.
	for _, other := range []string{
		`{"type":"flat_hello","b":{}}`,
		`{"type":"flat_seal","d":"` + addresses[seedB] + `","c":"AAAA"}`,
	} {
		if err := sendSignal(node, addresses[seedA], other); err != nil {
			t.Fatalf("send: %v", err)
		}
	}
	if extra, ok := node.signalInbox.wait(800 * time.Millisecond); ok {
		t.Fatalf("the mailbox door let another frame in: %+v", extra)
	}

	// The set is exact: B goes, A stays as it was.
	if _, err := node.setMailboxDoors([]string{seedA}); err != nil {
		t.Fatalf("mailbox doors: %v", err)
	}
	if node.mailboxDoors[seedA] != doorA || len(node.mailboxDoors) != 1 {
		t.Fatal("the running door must stay and the other must go")
	}
	// Never more than the cap, never the flat's own door key.
	many := make([]string, maxHostedDoors+1)
	for index := range many {
		many[index] = fmt.Sprintf("%064x", index+1)
	}
	if _, err := node.setMailboxDoors(many); err == nil {
		t.Fatal("too many mailbox doors must be refused")
	}
	if _, err := node.startDoor(strings.Repeat("53", 32)); err != nil {
		t.Fatalf("door: %v", err)
	}
	host := node.doorHost
	if node.door.host != host {
		t.Fatal("one host carries all doors of a phone")
	}
	if _, err := node.setMailboxDoors([]string{strings.Repeat("53", 32)}); err == nil {
		t.Fatal("a mailbox door with the flat door's key must be refused")
	}
	if _, err := node.setMailboxDoors(nil); err != nil || len(node.mailboxDoors) != 0 {
		t.Fatalf("stop all: %v", err)
	}
	select {
	case <-doorA.done:
	case <-time.After(5 * time.Second):
		t.Fatal("a removed mailbox door kept running")
	}
	if node.doorHost != host {
		t.Fatal("the host stays while the flat's door runs")
	}
}

// doorPairState is one line of what two doors know of each other: their
// own counters, their session layers' view of the other, and ironwood's
// sessions and paths between them.
func doorPairState(a, b *doorNode) string {
	ironwood := func(from *core.Core, to ed25519.PublicKey) string {
		path := false
		for _, p := range from.GetPaths() {
			if bytes.Equal(p.Key, to) {
				path = true
			}
		}
		session := "no session"
		for _, s := range from.GetSessions() {
			if bytes.Equal(s.Key, to) {
				session = fmt.Sprintf("session rx %d tx %d up %v", s.RXBytes, s.TXBytes, s.Uptime.Round(time.Millisecond))
			}
		}
		return fmt.Sprintf("path %v, %s", path, session)
	}
	side := func(name string, from, to *doorNode) string {
		return fmt.Sprintf("%s: [%s] pq of the other: [%s] ironwood: [%s]",
			name, from.stats.String(), from.pq.peerState(net.ParseIP(to.address)),
			ironwood(from.core, to.core.PublicKey()))
	}
	return side("door", a, b) + " | " + side("mailbox", b, a)
}

func TestDoorsSealTheirTrafficPostQuantum(t *testing.T) {
	mesh := newTestMesh(t)
	node := mesh.node
	// The doors run the session layer unless the main node is plain.
	node.pqPlain = false
	startPacketLoop(node)
	door, err := node.startDoor(strings.Repeat("61", 32))
	if err != nil {
		t.Fatalf("door: %v", err)
	}
	seed := strings.Repeat("62", 32)
	addresses, err := node.setMailboxDoors([]string{seed})
	if err != nil {
		t.Fatalf("mailbox doors: %v", err)
	}
	mailbox := node.mailboxDoors[seed]
	if door.pq == nil || mailbox.pq == nil {
		t.Fatal("every door runs the session layer")
	}
	started := time.Now()
	waitMesh(t, "the doors never got onto the mesh", func() bool {
		return door.linked() && mailbox.linked()
	})
	t.Logf("%v: both doors linked: door %s, mailbox %s", time.Since(started).Round(time.Millisecond), door.address, mailbox.address)
	warmPaths(t, door.core, mailbox.core)
	t.Logf("%v: paths both ways: %s", time.Since(started).Round(time.Millisecond), doorPairState(door, mailbox))
	sealed := `{"type":"flat_seal","d":"` + addresses[seed] + `","c":"AAAA"}`
	// The first frames open the session (the mailbox door answers with its
	// key record and a challenge), then the knock crosses sealed. Both doors
	// talk to each other for the first time here, each way: an ironwood
	// session that starts while the far side has no path back yet stalls
	// for up to a minute (see warmPaths), so this step gets longer.
	crossing := time.Now()
	deadline := crossing.Add(90 * time.Second)
	lastLog := time.Time{}
	for {
		if err := door.send(addresses[seed], sealed); err != nil {
			t.Fatalf("door send: %v (%s)", err, doorPairState(door, mailbox))
		}
		message, ok := node.signalInbox.wait(500 * time.Millisecond)
		if ok {
			if message.Payload != sealed || !message.Door || message.From != door.address {
				t.Fatalf("unexpected door signal: %+v", message)
			}
			break
		}
		if time.Since(lastLog) >= 2*time.Second {
			lastLog = time.Now()
			t.Logf("%v: waiting: %s", time.Since(crossing).Round(time.Millisecond), doorPairState(door, mailbox))
		}
		if time.Now().After(deadline) {
			t.Fatalf("no sealed knock crossed between the doors: %s", doorPairState(door, mailbox))
		}
	}
	t.Logf("%v: the sealed knock crossed: %s", time.Since(crossing).Round(time.Millisecond), doorPairState(door, mailbox))
	drainInbox(node)
	// The same frame sent unsealed stays outside.
	destination := net.ParseIP(addresses[seed])
	if err := door.writeWire(destination, []byte(sealed)); err != nil {
		t.Fatalf("plain write: %v", err)
	}
	if extra, ok := node.signalInbox.wait(800 * time.Millisecond); ok {
		t.Fatalf("a door took an unsealed frame: %+v", extra)
	}
	// A mailbox door still sends no flat frame of its own.
	if err := mailbox.send(door.address, `{"type":"flat_profile","b":{}}`); err == nil {
		t.Fatal("a mailbox door sends nothing")
	}
}

// A door host with two or more peers may be picked as the next hop between
// them, so strangers' traffic would cross the phone: it keeps to one, a leaf.
func TestDoorHostIsALeafWithOnePublicPeer(t *testing.T) {
	if doorHostPeerCount != 1 {
		t.Fatalf("the door host dials %d peers at once", doorHostPeerCount)
	}
	pool := []string{"tls://a:443", "tls://b:443", "tls://c:443", "tls://d:443"}
	for offset := 0; offset < 8; offset++ {
		if got := doorHostPeers(pool, "tls://a:443", offset, doorHostPeerCount); len(got) != 1 {
			t.Fatalf("offset %d picked %v", offset, got)
		}
	}
}
