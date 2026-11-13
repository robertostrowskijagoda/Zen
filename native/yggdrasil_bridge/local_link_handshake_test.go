package main

import (
	"crypto/mlkem"
	"crypto/rand"
	"errors"
	"fmt"
	"net"
	"testing"
	"time"
)

// testRecordHello opens a stream to a device running the handshake with
// peers, as a stranger nearby can over Bluetooth or the LAN, and keeps the
// hello the device sends it; nonce is the stranger's opening (nil: random).
func testRecordHello(t *testing.T, peers []localPeer, key []byte, nonce []byte) (hello, deviceNonce []byte) {
	t.Helper()
	stranger, device := net.Pipe()
	go func() {
		_, _ = localLinkHandshake(device, peers, key)
		_ = device.Close()
	}()
	defer stranger.Close()
	_ = stranger.SetDeadline(time.Now().Add(5 * time.Second))
	opening := make([]byte, localOpeningSize)
	opening[0] = localHandshakeVersion
	if nonce != nil {
		copy(opening[1:], nonce)
	} else {
		_, _ = rand.Read(opening[1:])
	}
	go func() { _ = writeLocalFrame(stranger, opening) }()
	theirs, err := readLocalFrame(stranger, 1<<16)
	if err != nil {
		t.Fatal(err)
	}
	hello, err = readLocalFrame(stranger, 1<<16)
	if err != nil {
		t.Fatal(err)
	}
	return hello, theirs[1:]
}

// testPlayHello plays hello to a device, after an opening of the stranger's
// own, and tells whether the device went on (sent its ML-KEM ciphertext)
// instead of hanging up on a stranger.
func testPlayHello(t *testing.T, hello []byte, peers []localPeer, key []byte) bool {
	t.Helper()
	stranger, device := net.Pipe()
	result := make(chan error, 1)
	go func() {
		_, err := localLinkHandshake(device, peers, key)
		_ = device.Close()
		result <- err
	}()
	_ = stranger.SetDeadline(time.Now().Add(5 * time.Second))
	testOpenings(t, stranger)
	go func() { _ = writeLocalFrame(stranger, hello) }()
	if _, err := readLocalFrame(stranger, 1<<16); err != nil {
		t.Fatal(err)
	}
	next, err := readLocalFrame(stranger, 1<<16)
	_ = stranger.Close()
	<-result
	return err == nil && len(next) == mlkem.CiphertextSize768
}

// A hello recorded once from a phone, played later (another day, another
// place, the phone's Bluetooth address and adverts all changed), is answered
// neither by the phone nor by its owner's friends: it would follow the phone
// and tell who is friends with whom.
func TestARecordedHelloIsAnsweredByNobody(t *testing.T) {
	keyT, keyF, keyU := testNodeKey(t), testNodeKey(t), testNodeKey(t)
	forT, forF := testPair(t, keyT, keyF)
	peersT := []localPeer{testLocalPeer(t, 1), forT, testLocalPeer(t, 2)}
	peersF := []localPeer{forF, testLocalPeer(t, 3)}
	peersU := []localPeer{testLocalPeer(t, 4), testLocalPeer(t, 5)}

	recorded, _ := testRecordHello(t, peersT, keyT, nil)
	for name, device := range map[string]struct {
		peers []localPeer
		key   []byte
	}{"the phone": {peersT, keyT}, "a friend": {peersF, keyF}, "a stranger": {peersU, keyU}} {
		if testPlayHello(t, recorded, device.peers, device.key) {
			t.Fatalf("%s answered a recorded hello", name)
		}
	}
	// The pair itself still links.
	if _, _, errT, errF := testHandshake(t, []localPeer{forT}, []localPeer{forF}, keyT, keyF); errT != nil || errF != nil {
		t.Fatalf("handshake: %v / %v", errT, errF)
	}
}

// A hello sent back to the phone that made it, for the very nonce the phone
// sent on another stream, names the phone's own address, not its friend's:
// the phone does not take it for the friend.
func TestAHelloSentBackToItsSenderIsRefused(t *testing.T) {
	keyT, keyF := testNodeKey(t), testNodeKey(t)
	forT, _ := testPair(t, keyT, keyF)
	peersT := []localPeer{forT}
	// Stream 2: the phone's nonce. Stream 1: the stranger hands that nonce
	// to the phone and keeps the hello made for it.
	stranger, device := net.Pipe()
	result := make(chan error, 1)
	go func() {
		_, err := localLinkHandshake(device, peersT, keyT)
		_ = device.Close()
		result <- err
	}()
	defer stranger.Close()
	_ = stranger.SetDeadline(time.Now().Add(5 * time.Second))
	opening := make([]byte, localOpeningSize)
	opening[0] = localHandshakeVersion
	_, _ = rand.Read(opening[1:])
	go func() { _ = writeLocalFrame(stranger, opening) }()
	theirs, err := readLocalFrame(stranger, 1<<16)
	if err != nil {
		t.Fatal(err)
	}
	reflected, _ := testRecordHello(t, peersT, keyT, theirs[1:])
	go func() { _ = writeLocalFrame(stranger, reflected) }()
	if _, err := readLocalFrame(stranger, 1<<16); err != nil {
		t.Fatal(err)
	}
	if next, err := readLocalFrame(stranger, 1<<16); err == nil {
		t.Fatalf("the phone took its own hello for its friend's and sent %d bytes", len(next))
	}
	if err := <-result; !errors.Is(err, errLocalLinkStranger) {
		t.Fatalf("want a stranger, got %v", err)
	}
	// Its own opening sent back: refused at once.
	stranger2, device2 := net.Pipe()
	defer stranger2.Close()
	go func() { result <- func() error { _, err := localLinkHandshake(device2, peersT, keyT); return err }() }()
	theirs2, err := readLocalFrame(stranger2, 1<<16)
	if err != nil {
		t.Fatal(err)
	}
	_ = writeLocalFrame(stranger2, theirs2)
	if err := <-result; err == nil {
		t.Fatal("an opening sent back must be refused")
	}
}

// Every hello of someone who links with fewer than 64 devices has the same
// size: the count is no trait to follow a phone by.
func TestHelloSizeSaysNothingOfTheNumberOfDevices(t *testing.T) {
	sizes := map[int]bool{}
	for _, n := range []int{0, 1, 17, 40, 63} {
		peers := make([]localPeer, n)
		for i := range peers {
			peers[i] = testLocalPeer(t, 10+i)
		}
		hello, _ := testRecordHello(t, peers, testNodeKey(t), nil)
		sizes[len(hello)] = true
	}
	if len(sizes) != 1 {
		t.Fatalf("hello sizes: %v", sizes)
	}
	many := make([]localPeer, 200)
	for i := range many {
		many[i] = testLocalPeer(t, 100+i)
	}
	hello, _ := testRecordHello(t, many, testNodeKey(t), nil)
	if len(hello) != localHelloSize(256) {
		t.Fatalf("200 devices: %d bytes", len(hello))
	}
}

// A device of the version before (its hello where the opening belongs) is
// refused at once, its frame unread: the two link over the internet.
func TestAnOlderHandshakeIsRefusedAtOnce(t *testing.T) {
	keyA := testNodeKey(t)
	forA, _ := testPair(t, keyA, testNodeKey(t))
	older, device := net.Pipe()
	defer older.Close()
	result := make(chan error, 1)
	go func() {
		_, err := localLinkHandshake(device, []localPeer{forA}, keyA)
		_ = device.Close()
		result <- err
	}()
	// A version 2 hello: version, one-time keys, 16 selectors.
	hello := append([]byte{2}, make([]byte, localEphemeralSize+2+16*localSelectorSize)...)
	go func() { _ = writeLocalFrame(older, hello) }()
	go func() { _, _ = readLocalFrame(older, 1<<16) }()
	select {
	case err := <-result:
		if !errors.Is(err, errLocalLinkBadInput) {
			t.Fatalf("got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the older hello was waited for")
	}
}

// Connections that open and say nothing give their LAN handshake slots back
// within the first frame's time, not the whole handshake's: they held every
// slot for eight seconds, and a friend's link was refused meanwhile.
func TestSilentConnectionsLeaveTheLanSlotsSoon(t *testing.T) {
	_, _, managerA, _ := testManagers(t)
	lan := testLan(t, managerA)
	var conns []net.Conn
	for i := 0; i < 4; i++ {
		for j := 0; j < 2; j++ {
			d := net.Dialer{LocalAddr: &net.TCPAddr{IP: net.IPv4(127, 0, 0, byte(10+i))}}
			c, err := d.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", lan.tcpPort))
			if err != nil {
				t.Skip(err)
			}
			conns = append(conns, c)
		}
	}
	defer func() {
		for _, c := range conns {
			_ = c.Close()
		}
	}()
	time.Sleep(300 * time.Millisecond)
	if lan.takeHandshake("127.0.0.99") {
		t.Fatal("the silent connections took no slot")
	}
	start := time.Now()
	for lan.handshakesHeld() > 0 && time.Since(start) < 10*time.Second {
		time.Sleep(50 * time.Millisecond)
	}
	held := time.Since(start) + 300*time.Millisecond
	if held > localFirstFrameTimeout+time.Second {
		t.Fatalf("silent connections held the slots for %v", held)
	}
}

func (lan *lanDiscovery) handshakesHeld() int {
	lan.mu.Lock()
	defer lan.mu.Unlock()
	return lan.handshakes
}
