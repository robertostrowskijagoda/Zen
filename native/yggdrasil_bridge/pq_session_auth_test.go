package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"testing"
	"time"
)

// pqImpostor is someone who holds the Ed25519 node key of the node at ip
// (broken with a quantum computer) but not its device key: the device
// key's seed comes from the node key's seed, which breaking the public key
// does not give. It signs a record of a KEM key of its own.
func (n *pqTestNet) pqImpostor(nodeKey ed25519.PrivateKey, ip net.IP) *pqEndpoint {
	n.t.Helper()
	key, err := pqPrivateKey(bytes.Repeat([]byte{0xee}, pqSeedSize))
	if err != nil {
		n.t.Fatal(err)
	}
	publicKey := key.PublicKey().Bytes()
	record, err := pqBuildRecord(nodeKey, publicKey)
	if err != nil {
		n.t.Fatal(err)
	}
	return &pqEndpoint{
		local:       bytes.Clone(ip.To16()),
		key:         key,
		record:      record,
		fingerprint: sha256.Sum256(publicKey),
		peers:       make(map[string]*pqPeer),
		pins:        make(map[string]*pqPin),
		write: func(to net.IP, wire []byte) error {
			frame := pqTestFrame{from: ip, to: bytes.Clone(to), wire: bytes.Clone(wire)}
			n.queue = append(n.queue, frame)
			n.sent = append(n.sent, frame)
			return nil
		},
		now: func() time.Time { return n.clock },
	}
}

func (n *pqTestNet) sentBy(from net.IP) int {
	count := 0
	for _, frame := range n.sent {
		if frame.from.Equal(from) {
			count++
		}
	}
	return count
}

func TestPQPinnedKeyRefusesARecordSignedWithABrokenNodeKey(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	mustSend(t, a, bIP, "hej")
	network.pump()
	network.take(bIP)
	pinned := b.peers[aIP.String()].fingerprint
	if pinned != a.fingerprint || b.pinsSnapshot()[aIP.String()] != a.ownFingerprint() {
		t.Fatal("B must have pinned A's device key on first sight")
	}

	nodeKey, _ := pqTestNode(t, 1)
	impostor := network.pqImpostor(nodeKey, aIP)
	before := network.sentBy(bIP)
	if err := impostor.send(bIP, []byte("ja jestem A")); err != nil {
		t.Fatal(err)
	}
	network.pump()
	if network.sentBy(bIP) != before {
		t.Fatal("B answered a record that is not the pinned one")
	}
	if b.peers[aIP.String()].fingerprint != pinned {
		t.Fatal("B swapped A's pinned key")
	}
	if got := network.take(bIP); len(got) != 0 {
		t.Fatalf("B took %q from the impostor", got)
	}
	// A itself still gets through.
	mustSend(t, a, bIP, "nadal ja")
	network.pump()
	if got := network.take(bIP); len(got) != 1 || got[0] != "nadal ja" {
		t.Fatalf("B got %q", got)
	}
}

func TestPQSessionCannotBeStartedWithoutTheChallengeSecret(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	mustSend(t, a, bIP, "hej")
	network.pump()
	network.take(bIP)
	// The challenge id A's sessions are opened with travels in the clear
	// (inside Yggdrasil): the impostor knows it, not its secret.
	first := network.lastData(aIP)
	var challenge pqChallengeID
	copy(challenge[:], first.wire[pqDataHeaderSize:pqDataHeaderSize+pqChallengeIDSize])

	nodeKey, _ := pqTestNode(t, 1)
	impostor := network.pqImpostor(nodeKey, aIP)
	impostor.mu.Lock()
	peer := impostor.peerLocked(bIP, network.clock)
	peer.publicKey = pqPublicKeyOfEndpoint(t, b) // public: anyone has it
	peer.challenge = &pqChallenge{id: challenge, secret: bytes.Repeat([]byte{7}, pqSecretSize), at: network.clock}
	impostor.mu.Unlock()
	if err := impostor.send(bIP, []byte("przelej pieniądze")); err != nil {
		t.Fatal(err)
	}
	sessionsBefore := len(b.peers[aIP.String()].receive)
	network.pump()
	if got := network.take(bIP); len(got) != 0 {
		t.Fatalf("B took %q from someone without A's device key", got)
	}
	if len(b.peers[aIP.String()].receive) != sessionsBefore {
		t.Fatal("B kept a session it could not authenticate")
	}
	// Media fares no better.
	impostor.mu.Lock()
	impostor.peers[bIP.String()].send = nil
	impostor.mu.Unlock()
	media, err := impostor.sealMedia(bIP, []byte{1, 'c', 0x80, 0x60})
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := b.receiveMedia(aIP, media); ok {
		t.Fatal("B took media from someone without A's device key")
	}
	_ = a
}

func pqPublicKeyOfEndpoint(t *testing.T, e *pqEndpoint) []byte {
	t.Helper()
	return e.key.PublicKey().Bytes()
}

func TestPQPinsSurviveARestartThroughTheApp(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	mustSend(t, a, bIP, "hej")
	network.pump()
	network.take(bIP)
	pins := b.pinsSnapshot()
	if len(pins) != 1 || pins[aIP.String()] != a.ownFingerprint() {
		t.Fatalf("pins %v", pins)
	}

	// B starts again with the pins the app kept, plus some junk.
	network.clock = network.clock.Add(time.Minute)
	restarted, _ := network.add(2)
	pins["8.8.8.8"] = a.ownFingerprint()
	pins["fd00::1"] = a.ownFingerprint()
	pins["201:aaaa::1"] = "zz"
	if taken, _ := restarted.importPins(pins, false); taken != 1 {
		t.Fatalf("%d pins taken, want 1", taken)
	}
	nodeKey, _ := pqTestNode(t, 1)
	impostor := network.pqImpostor(nodeKey, aIP)
	before := network.sentBy(bIP)
	if err := impostor.send(bIP, []byte("x")); err != nil {
		t.Fatal(err)
	}
	network.pump()
	if network.sentBy(bIP) != before || network.take(bIP) != nil {
		t.Fatal("a restarted B must refuse the impostor by the imported pin")
	}
	// Imported pins win over a key this run took already.
	other := sha256.Sum256([]byte("another key"))
	restarted.mu.Lock()
	restarted.peerLocked(aIP, network.clock).publicKey = []byte{1}
	restarted.peers[aIP.String()].fingerprint = sha256.Sum256([]byte{1})
	restarted.mu.Unlock()
	restarted.importPins(map[string]string{aIP.String(): hex.EncodeToString(other[:])}, false)
	if restarted.peers[aIP.String()].publicKey != nil {
		t.Fatal("a key that contradicts an imported pin must be forgotten")
	}
}

func TestPQChallengeIsRefreshedBeforeItIsTooOld(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	_, bIP := network.add(2)
	mustSend(t, a, bIP, "hej")
	network.pump()
	network.take(bIP)
	got := a.peers[bIP.String()].challenge
	if got == nil {
		t.Fatal("A holds B's challenge")
	}

	network.clock = network.clock.Add(pqChallengeRefresh + time.Second)
	sentBefore := len(network.sent)
	mustSend(t, a, bIP, "później")
	asked := false
	for _, frame := range network.sent[sentBefore:] {
		if frame.from.Equal(aIP) && frame.wire[len(pqMagic)] == pqKindKeys && frame.wire[len(pqMagic)+1]&pqFlagWant != 0 {
			asked = true
		}
	}
	if !asked {
		t.Fatal("an aging challenge must be renewed")
	}
	network.pump()
	if texts := network.take(bIP); len(texts) != 1 || texts[0] != "później" {
		t.Fatalf("B got %q (the session goes on while the challenge is renewed)", texts)
	}
	renewed := a.peers[bIP.String()].challenge
	if renewed == nil || renewed.id == got.id || renewed.at != network.clock {
		t.Fatal("A must hold a new challenge")
	}

	// Long after: the old session has expired, a new one starts at once
	// with the renewed challenge (nothing waits for the peer).
	network.clock = network.clock.Add(pqSessionLifetime + time.Second)
	old := a.peers[bIP.String()].send
	mustSend(t, a, bIP, "nowa sesja")
	if network.queue[0].wire[len(pqMagic)] != pqKindData {
		t.Fatal("the rotated session must not wait for a key exchange")
	}
	network.pump()
	if texts := network.take(bIP); len(texts) != 1 || texts[0] != "nowa sesja" {
		t.Fatalf("B got %q", texts)
	}
	if a.peers[bIP.String()].send == old {
		t.Fatal("the session must have rotated")
	}
}

func TestPQUnknownChallengeStartsANewSession(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	mustSend(t, a, bIP, "hej")
	network.pump()
	network.take(bIP)
	// B forgets the challenges it gave A, and A's session is not
	// acknowledged (its frames still open sessions).
	b.mu.Lock()
	b.peers[aIP.String()].issued = nil
	b.peers[aIP.String()].receive = nil
	b.mu.Unlock()
	a.mu.Lock()
	a.peers[bIP.String()].send.acked = false
	a.mu.Unlock()
	network.clock = network.clock.Add(pqUnknownReplyInterval)

	mustSend(t, a, bIP, "zgubione")
	network.pump()
	if got := network.take(bIP); len(got) != 0 {
		t.Fatalf("B opened a session without its challenge: %q", got)
	}
	if a.peers[bIP.String()].send != nil {
		t.Fatal("B's answer must end A's session")
	}
	mustSend(t, a, bIP, "znowu")
	network.pump()
	if got := network.take(bIP); len(got) != 1 || got[0] != "znowu" {
		t.Fatalf("B got %q", got)
	}
}

func TestPQBucketLimitsForeignKEMWork(t *testing.T) {
	var bucket pqBucket
	now := time.Unix(1_800_000_000, 0)
	allowed := 0
	for range pqForeignKEMBurst + 50 {
		if bucket.allow(now, pqForeignKEMPerSecond, pqForeignKEMBurst) {
			allowed++
		}
	}
	if allowed != pqForeignKEMBurst {
		t.Fatalf("%d allowed at once, want %d", allowed, pqForeignKEMBurst)
	}
	if !bucket.allow(now.Add(time.Second/pqForeignKEMPerSecond), pqForeignKEMPerSecond, pqForeignKEMBurst) {
		t.Fatal("the bucket must refill")
	}
	if bucket.allow(now, pqForeignKEMPerSecond, pqForeignKEMBurst) {
		t.Fatal("a clock going back must not refill the bucket")
	}
}

func TestPQPinsComeSlowlyAndTheOldestMakesRoom(t *testing.T) {
	network := newPQTestNet(t)
	b, bIP := network.add(2)
	// A burst of strangers: only pqNewPinsPerMinute of them are pinned.
	for fill := byte(10); fill < 10+pqNewPinsPerMinute+20; fill++ {
		stranger, _ := network.add(fill)
		_ = stranger.send(bIP, []byte("x"))
	}
	network.pump()
	if len(b.pins) != pqNewPinsPerMinute {
		t.Fatalf("%d pins after a burst, want %d", len(b.pins), pqNewPinsPerMinute)
	}

	// Full: the pin seen longest ago goes, the others stay.
	b.mu.Lock()
	b.pins = make(map[string]*pqPin, pqMaxPins)
	for index := range pqMaxPins {
		address := fmt.Sprintf("200::%x", index+1)
		b.pins[address] = &pqPin{seen: network.clock.Add(time.Duration(index) * time.Second)}
	}
	b.mu.Unlock()
	network.clock = network.clock.Add(time.Hour)
	_, friendIP := pqTestNode(t, 250)
	friend, _ := network.add(250)
	mustSend(t, friend, bIP, "hej")
	network.pump()
	if len(b.pins) != pqMaxPins || b.pins["200::1"] != nil || b.pins[friendIP.String()] == nil {
		t.Fatal("the oldest pin must make room for a new one")
	}
}

func TestPQVouchedPinsGuardFirstContactAndReportConflicts(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	// B knows A's device key from a friend's signed record before A and B
	// ever talked: an impostor with A's node key is refused at once.
	taken, conflicts := b.importPins(map[string]string{aIP.String(): a.ownFingerprint()}, true)
	if taken != 1 || len(conflicts) != 0 {
		t.Fatalf("taken %d, conflicts %v", taken, conflicts)
	}
	nodeKey, _ := pqTestNode(t, 1)
	impostor := network.pqImpostor(nodeKey, aIP)
	if err := impostor.send(bIP, []byte("x")); err != nil {
		t.Fatal(err)
	}
	network.pump()
	if network.sentBy(bIP) != 0 || len(network.take(bIP)) != 0 {
		t.Fatal("the vouched key must refuse the impostor on first contact")
	}
	mustSend(t, a, bIP, "hej")
	network.pump()
	if got := network.take(bIP); len(got) != 1 {
		t.Fatalf("B got %q from A", got)
	}
	// Another source vouching another key does not replace the pin.
	other := sha256.Sum256([]byte("other"))
	taken, conflicts = b.importPins(map[string]string{aIP.String(): hex.EncodeToString(other[:])}, true)
	if taken != 0 || conflicts[aIP.String()] != a.ownFingerprint() {
		t.Fatalf("taken %d, conflicts %v", taken, conflicts)
	}
	if b.pinsSnapshot()[aIP.String()] != a.ownFingerprint() {
		t.Fatal("a conflicting vouch must not move the pin")
	}
}

// An impostor with A's node key spoke to B first, so its key was pinned on
// first sight. When the app pins A's real key over it (a hello signed by
// A's hybrid device key named another key), the impostor's open session
// must stop working at once, and frames are always labelled with the key
// of the session that carried them.
func TestPQRepinDropsSessionsMadeWithTheOldKey(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	nodeKey, _ := pqTestNode(t, 1)
	impostor := network.pqImpostor(nodeKey, aIP)
	// B's answers to A's address reach the impostor.
	network.endpoints[aIP.String()] = impostor
	mustSend(t, impostor, bIP, "pierwszy")
	network.pump()
	if got := network.take(bIP); len(got) != 1 {
		t.Fatalf("B got %q", got)
	}
	if b.pinsSnapshot()[aIP.String()] != impostor.ownFingerprint() {
		t.Fatal("the first key seen must have been pinned")
	}
	// A frame of the impostor's session is labelled with its key.
	queued := len(network.queue)
	mustSend(t, impostor, bIP, "drugi")
	frame := network.queue[queued]
	network.queue = network.queue[:queued]
	if plain, key, ok := b.receiveKeyed(aIP, frame.wire); !ok || string(plain) != "drugi" || key != impostor.ownFingerprint() {
		t.Fatalf("got %q, %q, %v", plain, key, ok)
	}

	taken, _ := b.importPins(map[string]string{aIP.String(): a.ownFingerprint()}, false)
	if taken != 1 {
		t.Fatal("the app's pin must replace the first-sight one")
	}
	if len(b.peers[aIP.String()].receive) != 0 {
		t.Fatal("sessions made with the old key must be gone")
	}
	queued = len(network.queue)
	mustSend(t, impostor, bIP, "nadal ja")
	if len(network.queue) == queued {
		t.Fatal("the impostor's session must still send")
	}
	stale := network.queue[queued]
	network.queue = network.queue[:queued]
	if _, _, ok := b.receiveKeyed(aIP, stale.wire); ok {
		t.Fatal("a frame of the impostor's old session opened after the repin")
	}

	// The real A gets through, labelled with its own key.
	network.endpoints[aIP.String()] = a
	mustSend(t, a, bIP, "to ja")
	for len(network.queue) > 0 {
		next := network.queue[0]
		network.queue = network.queue[1:]
		if next.to.Equal(bIP) && next.wire[len(pqMagic)] == pqKindData {
			plain, key, ok := b.receiveKeyed(next.from, next.wire)
			if !ok || string(plain) != "to ja" || key != a.ownFingerprint() {
				t.Fatalf("got %q, %q, %v", plain, key, ok)
			}
			continue
		}
		network.deliver(next)
	}
}

// A receive session opens nothing past its maximum age, however busy it
// is kept.
func TestPQReceiveSessionHasAMaximumAge(t *testing.T) {
	network := newPQTestNet(t)
	a, aIP := network.add(1)
	b, bIP := network.add(2)
	mustSend(t, a, bIP, "hej")
	network.pump()
	network.take(bIP)
	sealAt := func(text string) []byte {
		t.Helper()
		a.mu.Lock()
		defer a.mu.Unlock()
		peer := a.peers[bIP.String()]
		// The sender keeps its session alive past its lifetime (only a
		// changed sender would).
		peer.send.created = network.clock
		sealed, err := a.sealLocked(peer, []byte(text), network.clock)
		if err != nil {
			t.Fatal(err)
		}
		return sealed
	}
	network.clock = network.clock.Add(pqReceiveSessionMaxAge - time.Minute)
	if plain, ok := b.receive(aIP, sealAt("jeszcze")); !ok || string(plain) != "jeszcze" {
		t.Fatal("a session younger than its maximum age must open")
	}
	network.clock = network.clock.Add(2 * time.Minute)
	if _, ok := b.receive(aIP, sealAt("za stary")); ok {
		t.Fatal("a session older than its maximum age opened")
	}
}
