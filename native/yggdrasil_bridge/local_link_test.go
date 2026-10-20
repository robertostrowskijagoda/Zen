package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

func testSecretHex(t *testing.T) string {
	t.Helper()
	secret := make([]byte, localLinkSecretSize)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(secret)
}

// testLocalPeer is a device with an arbitrary address and a fresh secret.
func testLocalPeer(t *testing.T, n int) localPeer {
	t.Helper()
	peer, err := newLocalPeer(fmt.Sprintf("200:%x::1", n), testSecretHex(t), false)
	if err != nil {
		t.Fatal(err)
	}
	return peer
}

func testNodeKey(t *testing.T) ed25519.PublicKey {
	t.Helper()
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return public
}

// testPair is what the two apps give their bridges for each other: the same
// secret, each with the other's address.
func testPair(t *testing.T, a, b ed25519.PublicKey) (forA, forB localPeer) {
	t.Helper()
	secret := testSecretHex(t)
	forA, err := newLocalPeer(meshAddressForKey(b), secret, false)
	if err != nil {
		t.Fatal(err)
	}
	forB, err = newLocalPeer(meshAddressForKey(a), secret, false)
	if err != nil {
		t.Fatal(err)
	}
	return forA, forB
}

func TestParseLocalLinkSettings(t *testing.T) {
	secret := testSecretHex(t)
	settings, err := parseLocalLinkSettings(`{"Lan":true,"BeaconSeconds":30,"Peers":[` +
		`{"Address":"200:abcd::1","Secret":"` + secret + `","Own":true},` +
		`{"Address":"200:ABCD:0::1","Secret":"` + strings.ToUpper(secret) + `"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	if !settings.lan || settings.beaconSeconds != 30 || len(settings.peers) != 1 {
		t.Fatalf("got %+v", settings)
	}
	if settings.peers[0].address != "200:abcd::1" || !settings.peers[0].own {
		t.Fatalf("one device, normalised: %+v", settings.peers[0])
	}
	for _, bad := range []string{
		`not json`,
		`{"Peers":[{"Address":"10.0.0.1","Secret":"` + secret + `"}]}`,
		`{"Peers":[{"Address":"fe80::1","Secret":"` + secret + `"}]}`,
		`{"Peers":[{"Address":"200::1","Secret":"0011"}]}`,
		`{"Peers":[{"Address":"200::1","Secret":"zz` + secret[2:] + `"}]}`,
	} {
		if _, err := parseLocalLinkSettings(bad); err == nil {
			t.Fatalf("%s must be refused", bad)
		}
	}
	off, err := parseLocalLinkSettings(`{}`)
	if err != nil || off.lan || len(off.peers) != 0 {
		t.Fatalf("empty settings are off: %+v %v", off, err)
	}
}

func TestLocalPeerKeysDependOnTheSecretOnly(t *testing.T) {
	secret := testSecretHex(t)
	a, _ := newLocalPeer("200::1", secret, false)
	b, _ := newLocalPeer("200::2", secret, true)
	if a.tagKey != b.tagKey || a.selKey != b.selKey || a.linkKey != b.linkKey {
		t.Fatal("both sides of a pair derive the same keys")
	}
	if a.tagKey == a.selKey || a.selKey == a.linkKey {
		t.Fatal("each use has its own key")
	}
	other, _ := newLocalPeer("200::1", testSecretHex(t), false)
	if other.tagKey == a.tagKey {
		t.Fatal("another secret, other keys")
	}
}

func TestLocalAdvertRecognisedOnlyByTheOtherSide(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	friends := []localPeer{testLocalPeer(t, 1), testLocalPeer(t, 2), testLocalPeer(t, 3)}
	advert, err := buildLocalAdvert(friends, now, 0, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if len(advert) != localLinkAdvertHeader+16 {
		t.Fatalf("three devices fit the smallest filter, got %d bytes", len(advert))
	}
	// A friend holds one of the secrets, under the sender's address.
	friend := friends[1]
	friend.address = "200:ffff::1"
	if got := matchLocalAdvert([]localPeer{friend}, advert, now); len(got) != 1 || got[0].address != friend.address {
		t.Fatalf("the friend recognises the advert: %v", got)
	}
	// Strangers hold other secrets.
	strangers := make([]localPeer, 0, 200)
	for i := 0; i < 200; i++ {
		strangers = append(strangers, testLocalPeer(t, 100+i))
	}
	matched := 0
	for i := 0; i < 50; i++ {
		fresh, _ := buildLocalAdvert(friends, now, 0, rand.Reader)
		matched += len(matchLocalAdvert(strangers, fresh, now))
	}
	// 10 000 tries of a filter with 3 of ~128 bits set: well under 1%.
	if matched > 20 {
		t.Fatalf("strangers matched %d times", matched)
	}
}

func TestLocalAdvertsRotate(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	friends := []localPeer{testLocalPeer(t, 1)}
	first, _ := buildLocalAdvert(friends, now, 0, rand.Reader)
	second, _ := buildLocalAdvert(friends, now, 0, rand.Reader)
	if bytes.Equal(first, second) {
		t.Fatal("every advert has a new salt")
	}
	if bytes.Equal(first[localLinkAdvertHeader:], second[localLinkAdvertHeader:]) {
		t.Fatal("and so other bits set: two adverts cannot be linked")
	}
	later, _ := buildLocalAdvert(friends, now.Add(localLinkSlot), 0, rand.Reader)
	if bytes.Equal(first[1:3], later[1:3]) {
		t.Fatal("the next slot is named in the advert")
	}
	// A device whose clock is a little off still recognises it; a recording
	// played back much later is refused.
	if len(matchLocalAdvert(friends, first, now.Add(localLinkMaxSlotSkew*localLinkSlot))) != 1 {
		t.Fatal("a few slots of clock drift are fine")
	}
	if len(matchLocalAdvert(friends, first, now.Add((localLinkMaxSlotSkew+1)*localLinkSlot))) != 0 {
		t.Fatal("an advert from long ago is refused")
	}
	if len(matchLocalAdvert(friends, first, now.Add(-(localLinkMaxSlotSkew+1)*localLinkSlot))) != 0 {
		t.Fatal("an advert from the future is refused")
	}
	// A slot is named by its low 16 bits: one 65536 slots away is not it.
	if len(matchLocalAdvert(friends, first, now.Add(65536*localLinkSlot))) != 0 {
		t.Fatal("a wrapped slot is not the same slot")
	}
}

func TestLocalAdvertSizes(t *testing.T) {
	if localLinkBloomBytes(0) != 16 || localLinkBloomBytes(13) != 32 || localLinkBloomBytes(5000) != localLinkMaxBloomBytes {
		t.Fatal("filters grow with the devices in steps of 16 bytes")
	}
	small, err := buildLocalAdvert([]localPeer{testLocalPeer(t, 1)}, time.Now(), 20, rand.Reader)
	if err != nil || len(small) != localLinkAdvertHeader+20 {
		t.Fatalf("a native transport asks for the size it can carry: %d %v", len(small), err)
	}
	for _, bad := range []int{1, localLinkMinBloomBytes - 1, localLinkMaxBloomBytes + 1} {
		if _, err := buildLocalAdvert(nil, time.Now(), bad, rand.Reader); err == nil {
			t.Fatalf("a %d-byte filter is refused", bad)
		}
	}
	if matchLocalAdvert([]localPeer{testLocalPeer(t, 1)}, []byte{9, 9, 9}, time.Now()) != nil {
		t.Fatal("garbage matches nothing")
	}
}

// testHandshake runs both sides over a pipe.
func testHandshake(t *testing.T, peersA, peersB []localPeer, keyA, keyB ed25519.PublicKey) (*localLinkSession, *localLinkSession, error, error) {
	t.Helper()
	left, right := net.Pipe()
	type result struct {
		session *localLinkSession
		err     error
	}
	done := make(chan result, 1)
	go func() {
		session, err := localLinkHandshake(right, peersB, keyB)
		if err != nil {
			_ = right.Close()
		}
		done <- result{session, err}
	}()
	sessionA, errA := localLinkHandshake(left, peersA, keyA)
	if errA != nil {
		_ = left.Close()
	}
	b := <-done
	return sessionA, b.session, errA, b.err
}

func TestLocalHandshakeLinksAPair(t *testing.T) {
	keyA, keyB := testNodeKey(t), testNodeKey(t)
	forA, forB := testPair(t, keyA, keyB)
	// Each side also knows other devices.
	peersA := []localPeer{testLocalPeer(t, 1), forA, testLocalPeer(t, 2)}
	peersB := []localPeer{testLocalPeer(t, 3), forB}
	a, b, errA, errB := testHandshake(t, peersA, peersB, keyA, keyB)
	if errA != nil || errB != nil {
		t.Fatalf("handshake: %v / %v", errA, errB)
	}
	if !bytes.Equal(a.remoteKey, keyB) || !bytes.Equal(b.remoteKey, keyA) {
		t.Fatal("each side learns the other's Yggdrasil key")
	}
	if a.peer.address != forA.address || b.peer.address != forB.address {
		t.Fatal("each side knows which device it linked with")
	}
	if a.password == "" || a.password != b.password {
		t.Fatal("both sides derive the same link password")
	}
	// The stream is encrypted both ways and carries data intact.
	payload := bytes.Repeat([]byte("zen"), 20000)
	go func() {
		_, _ = a.conn.Write(payload)
		_ = a.conn.Close()
	}()
	got, err := io.ReadAll(b.conn)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrClosedPipe) {
		t.Fatal(err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("got %d bytes, sent %d", len(got), len(payload))
	}
}

func TestLocalHandshakeRefusesStrangers(t *testing.T) {
	keyA, keyB, keyC := testNodeKey(t), testNodeKey(t), testNodeKey(t)
	forA, _ := testPair(t, keyA, keyB)
	// C holds a secret, but not one A has.
	_, forC := testPair(t, keyB, keyC)
	_, _, errA, errC := testHandshake(t, []localPeer{forA}, []localPeer{forC}, keyA, keyC)
	if !errors.Is(errA, errLocalLinkStranger) || errC == nil {
		t.Fatalf("strangers must not link: %v / %v", errA, errC)
	}
	// C holds nothing at all.
	_, _, errA, errC = testHandshake(t, []localPeer{forA}, nil, keyA, keyC)
	if !errors.Is(errA, errLocalLinkStranger) || errC == nil {
		t.Fatalf("strangers must not link: %v / %v", errA, errC)
	}
}

func TestLocalHandshakeRefusesAnotherDevicesKey(t *testing.T) {
	keyA, keyB, keyC := testNodeKey(t), testNodeKey(t), testNodeKey(t)
	forA, forB := testPair(t, keyA, keyB)
	// The device with B's secret claims to be C.
	_, _, errA, _ := testHandshake(t, []localPeer{forA}, []localPeer{forB}, keyA, keyC)
	if errA == nil || errors.Is(errA, errLocalLinkStranger) {
		t.Fatalf("a key that is not the device's must be refused, got %v", errA)
	}
}

func TestLocalHelloSaysNothingAboutTheDevices(t *testing.T) {
	peers := []localPeer{testLocalPeer(t, 1), testLocalPeer(t, 2)}
	ephemeral := make([]byte, 32)
	_, _ = rand.Read(ephemeral)
	one, _ := buildLocalHello(peers, ephemeral, rand.Reader)
	_, selectors, err := parseLocalHello(one)
	if err != nil {
		t.Fatal(err)
	}
	if len(selectors) != 16 {
		t.Fatalf("padded to 16 selectors, got %d", len(selectors))
	}
	other := make([]byte, 32)
	_, _ = rand.Read(other)
	two, _ := buildLocalHello(peers, other, rand.Reader)
	_, again, _ := parseLocalHello(two)
	for s := range selectors {
		if again[s] {
			t.Fatal("selectors are bound to the ephemeral key: hellos cannot be linked")
		}
	}
	if _, _, err := parseLocalHello(append(one, 0)); err == nil {
		t.Fatal("a hello with trailing bytes is refused")
	}
}

// testCore is a Yggdrasil node with no peers.
func testCore(t *testing.T) *core.Core {
	t.Helper()
	cfg := config.GenerateConfig()
	logger := log.New(os.Stderr, "", 0)
	c, err := core.New(cfg.Certificate, logger, core.NodeInfoPrivacy(true))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Stop)
	return c
}

func waitForPeer(t *testing.T, c *core.Core, key ed25519.PublicKey, want bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		found := false
		for _, peer := range c.GetPeers() {
			if peer.Up && bytes.Equal(peer.Key, key) {
				found = true
			}
		}
		if found == want {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("peer %x up: want %v", key[:4], want)
}

func testManagers(t *testing.T) (*core.Core, *core.Core, *localLinkManager, *localLinkManager) {
	t.Helper()
	coreA, coreB := testCore(t), testCore(t)
	forA, forB := testPair(t, coreA.PublicKey(), coreB.PublicKey())
	managerA := newLocalLinkManager(coreA, nil)
	managerB := newLocalLinkManager(coreB, nil)
	managerA.apply(localLinkSettings{peers: []localPeer{forA}})
	managerB.apply(localLinkSettings{peers: []localPeer{forB}})
	t.Cleanup(managerA.stop)
	t.Cleanup(managerB.stop)
	return coreA, coreB, managerA, managerB
}

func TestLocalStreamBecomesAYggdrasilPeer(t *testing.T) {
	coreA, coreB, managerA, managerB := testManagers(t)
	left, right := net.Pipe()
	done := make(chan error, 1)
	go func() {
		_, err := managerB.handshakeAndAttach(right, "test")
		done <- err
	}()
	if _, err := managerA.handshakeAndAttach(left, "test"); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	waitForPeer(t, coreA, coreB.PublicKey(), true)
	waitForPeer(t, coreB, coreA.PublicKey(), true)

	status := managerA.status()
	links := status["links"].([]map[string]any)
	if len(links) != 1 || links[0]["transport"] != "test" || links[0]["address"] != coreB.Address().String() {
		t.Fatalf("status: %+v", status)
	}
	if !managerA.hasLink(coreB.Address().String()) {
		t.Fatal("the link is known by the device's address")
	}

	// A second stream to the same device is not linked again.
	again, other := net.Pipe()
	go func() { _, _ = managerB.handshakeAndAttach(other, "test") }()
	if _, err := managerA.handshakeAndAttach(again, "test"); err == nil {
		t.Fatal("one link per device")
	}

	// The friend is removed: the link closes, and so does the peering.
	managerA.apply(localLinkSettings{})
	waitForPeer(t, coreB, coreA.PublicKey(), false)
	if managerB.hasLink(coreA.Address().String()) {
		t.Fatal("the other side sees the link go")
	}
}

func TestNativeStreamEndpoints(t *testing.T) {
	coreA, coreB, managerA, managerB := testManagers(t)
	endpointA, portA, err := managerA.openStream("bluetooth")
	if err != nil {
		t.Fatal(err)
	}
	endpointB, portB, err := managerB.openStream("bluetooth")
	if err != nil {
		t.Fatal(err)
	}
	// What the native transports do: connect, write the token, then pump
	// (here the "radio" is a pipe between the two).
	connect := func(port int, token []byte) net.Conn {
		conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		if err != nil {
			t.Fatal(err)
		}
		if _, err := conn.Write(token); err != nil {
			t.Fatal(err)
		}
		return conn
	}
	// Something else on this device tries first, with a wrong token.
	intruder, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", portA))
	if err != nil {
		t.Fatal(err)
	}
	_, _ = intruder.Write(make([]byte, localStreamTokenSize))
	_ = intruder.Close()

	radioA := connect(portA, endpointA.token)
	radioB := connect(portB, endpointB.token)
	go func() { _, _ = io.Copy(radioA, radioB) }()
	go func() { _, _ = io.Copy(radioB, radioA) }()
	waitForPeer(t, coreA, coreB.PublicKey(), true)
	waitForPeer(t, coreB, coreA.PublicKey(), true)

	// The radio goes away: the link ends.
	_ = radioA.Close()
	waitForPeer(t, coreB, coreA.PublicKey(), false)
}

func TestLocalLinkAdvertsBetweenManagers(t *testing.T) {
	_, coreB, managerA, managerB := testManagers(t)
	advert, err := managerB.advert(24)
	if err != nil {
		t.Fatal(err)
	}
	if !managerA.matches(advert) {
		t.Fatal("A recognises B's advert")
	}
	stranger := newLocalLinkManager(testCore(t), nil)
	stranger.apply(localLinkSettings{peers: []localPeer{testLocalPeer(t, 9)}})
	if stranger.matches(advert) {
		t.Fatal("a stranger does not")
	}
	if managerA.hasLink(coreB.Address().String()) {
		t.Fatal("no link yet")
	}
}

func TestNativeStreamEndpointsAreLimitedPerTransport(t *testing.T) {
	_, _, manager, _ := testManagers(t)
	for i := 0; i < localMaxOpenStreamsPerTransport; i++ {
		if _, _, err := manager.openStream("bluetooth"); err != nil {
			t.Fatalf("endpoint %d: %v", i, err)
		}
	}
	if _, _, err := manager.openStream("bluetooth"); err == nil {
		t.Fatal("one transport took more than its share of the endpoints")
	}
	if _, _, err := manager.openStream("multipeer"); err != nil {
		t.Fatalf("another transport got no endpoint: %v", err)
	}
}
