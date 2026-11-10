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
		after: func(d time.Duration, f func()) {
			n.timers = append(n.timers, pqTestTimer{at: n.clock.Add(d), f: f})
		},
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
	network.clock = network.clock.Add(pqUnknownReplyInterval + pqResendWindow)
	stale := a.peers[bIP.String()].send

	mustSend(t, a, bIP, "zgubione")
	// The frame opens no session at B; B's answer ends A's session.
	network.deliver(network.queue[0])
	network.queue = network.queue[1:]
	if got := network.take(bIP); len(got) != 0 {
		t.Fatalf("B opened a session without its challenge: %q", got)
	}
	network.pump()
	// It went again under a new session, made with B's new challenge.
	if got := network.take(bIP); len(got) != 1 || got[0] != "zgubione" {
		t.Fatalf("B got %q", got)
	}
	if session := a.peers[bIP.String()].send; session == nil || session == stale {
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

// Strangers asking for keys from addresses made for it, each as often as
// it may, spend a budget of their own: the peers the app names as known
// (its friends, this person's devices) still start their sessions. Data
// frames from addresses nothing is known of leave no trace. On a computer
// and on a phone.
func TestPQStrangersAskingForKeysNeverHoldUpAFriendsSession(t *testing.T) {
	for _, phone := range []bool{false, true} {
		t.Run(fmt.Sprintf("phone %v", phone), func(t *testing.T) {
			network := newPQTestNet(t)
			victim, victimIP := network.add(1)
			victim.phone = phone
			friend, friendIP := network.add(2)
			vouched, vouchedIP := network.add(3)
			victim.importPins(map[string]string{vouchedIP.String(): vouched.ownFingerprint()}, true)
			victim.setKnown([]string{friendIP.String(), vouchedIP.String()})
			rate, burst := pqForeignKEMPerSecond, pqForeignKEMBurst
			if phone {
				rate, burst = pqPhoneForeignKEMPerSecond, pqPhoneForeignKEMBurst
			}
			devicePublic := pqPublicKeyOfEndpoint(t, victim)
			type stranger struct {
				ip    net.IP
				frame []byte
			}
			strangers := make([]stranger, burst)
			for index := range strangers {
				ip, frame := pqStrangerRecord(t, devicePublic)
				frame[len(pqMagic)+1] = pqFlagWant
				strangers[index] = stranger{ip: ip, frame: frame}
			}
			ask := func(n int) {
				for _, s := range strangers[:n] {
					victim.receive(s.ip, s.frame)
				}
				network.queue = nil // the answers go to the strangers
			}

			if !talkBothWays(network, friend, friendIP, victim, victimIP) {
				t.Fatal("the friend and the victim must talk")
			}
			mustSend(t, vouched, victimIP, "first")
			network.pump()
			if got := network.take(victimIP); len(got) != 1 {
				t.Fatalf("victim got %q from the vouched one", got)
			}
			peers := len(victim.peers)

			// An hour later the sessions rotate while strangers ask, each
			// once a second, as many as would use up the whole budget.
			network.advance(time.Hour+time.Second, nil)
			ask(burst)
			fromFriend, fromVouched := 0, 0
			for range 30 {
				network.clock = network.clock.Add(time.Second)
				ask(rate)
				mustSend(t, friend, victimIP, "after")
				network.pump()
				fromFriend += len(network.take(victimIP))
				mustSend(t, vouched, victimIP, "after")
				network.pump()
				fromVouched += len(network.take(victimIP))
			}
			if fromFriend != 30 || fromVouched != 30 {
				t.Fatalf("delivered %d of the friend's and %d of the vouched one's 30 frames", fromFriend, fromVouched)
			}

			// Data frames from addresses with no record: no peer is made for
			// them, so none of the friends' is pushed out.
			junk := make([]byte, pqDataHeaderSize+32)
			copy(junk, pqMagic)
			junk[len(pqMagic)] = pqKindData
			for index := range pqMaxPeers + 100 {
				ip := make(net.IP, net.IPv6len)
				ip[0] = 0x02
				ip[1] = 0x77
				ip[14], ip[15] = byte(index>>8), byte(index)
				victim.receive(ip, junk)
			}
			network.queue = nil
			if len(victim.peers) != peers+len(strangers) ||
				victim.peers[friendIP.String()] == nil || victim.peers[vouchedIP.String()] == nil {
				t.Fatalf("%d peers, want %d", len(victim.peers), peers+len(strangers))
			}
		})
	}
}

func TestPQPinsComeSlowlyAndTheOldestMakesRoom(t *testing.T) {
	network := newPQTestNet(t)
	b, bIP := network.add(2)
	// A burst of strangers' records: only pqNewPinsPerMinute of them are
	// pinned.
	devicePublic := pqPublicKeyOfEndpoint(t, b)
	for range pqNewPinsPerMinute + 20 {
		ip, frame := pqStrangerRecord(t, devicePublic)
		b.receive(ip, frame)
	}
	if len(b.pins) != pqNewPinsPerMinute {
		t.Fatalf("%d pins after a burst, want %d", len(b.pins), pqNewPinsPerMinute)
	}
	// Strangers who go as far as a session each are pinned no faster
	// (and no more of them get one than their KEM budget allows).
	for fill := byte(10); fill < 10+pqNewPinsPerMinute+20; fill++ {
		stranger, _ := network.add(fill)
		_ = stranger.send(bIP, []byte("x"))
	}
	network.pump()
	if sessions := len(network.take(bIP)); len(b.pins) != pqNewPinsPerMinute+min(sessions, pqNewPinsPerMinute) {
		t.Fatalf("%d pins after %d sessions of strangers", len(b.pins), sessions)
	}

	// Full: the pin seen longest ago goes, the others stay.
	b.mu.Lock()
	for address := range b.pins {
		b.removePinLocked(address)
	}
	pqFillPins(b, "200::%x", pqMaxPins, func(index int) time.Time {
		return network.clock.Add(time.Duration(index) * time.Second)
	})
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

// pqStrangerRecord is a key record ('K', nothing asked) of a node key made
// just now: what anyone can send from an address that costs nothing.
func pqStrangerRecord(t *testing.T, devicePublic []byte) (net.IP, []byte) {
	t.Helper()
	_, nodeKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	record, err := pqBuildRecord(nodeKey, devicePublic)
	if err != nil {
		t.Fatal(err)
	}
	ip := net.ParseIP(meshAddressForKey(nodeKey.Public().(ed25519.PublicKey)))
	return ip, append(append([]byte(pqMagic), pqKindKeys, 0), record...)
}

// Strangers' records use up the new pins of the minute; a friend who
// writes for the first time meanwhile is still pinned once its session
// opens.
func TestPQAFirstContactIsPinnedWhenStrangersUsedUpTheNewPins(t *testing.T) {
	network := newPQTestNet(t)
	victim, victimIP := network.add(1)
	friend, friendIP := network.add(2)
	devicePublic := pqPublicKeyOfEndpoint(t, victim)
	for range pqNewPinsPerMinute + 5 {
		ip, frame := pqStrangerRecord(t, devicePublic)
		victim.receive(ip, frame)
	}
	if len(victim.pins) != pqNewPinsPerMinute {
		t.Fatalf("%d pins after the strangers", len(victim.pins))
	}
	mustSend(t, friend, victimIP, "hej")
	network.pump()
	if got := network.take(victimIP); len(got) != 1 {
		t.Fatalf("victim got %q", got)
	}
	if victim.pinsSnapshot()[friendIP.String()] != friend.ownFingerprint() {
		t.Fatal("a first contact whose session opened must be pinned")
	}
	// Nor does it wait for the next minute when this node writes first.
	other, otherIP := network.add(3)
	mustSend(t, victim, otherIP, "hej")
	network.pump()
	if got := network.take(otherIP); len(got) != 1 {
		t.Fatalf("other got %q", got)
	}
	if victim.pinsSnapshot()[otherIP.String()] != other.ownFingerprint() {
		t.Fatal("a contact this node wrote to must be pinned once it took the session")
	}
}

// With the pins full, strangers' records push out only pins of addresses
// that never had a session here: a friend quiet for hours keeps its pin,
// and a holder of its broken node key is still refused.
func TestPQStrangersNeverPushOutThePinOfAPeerThatHadASession(t *testing.T) {
	network := newPQTestNet(t)
	victim, victimIP := network.add(1)
	friend, friendIP := network.add(2)
	mustSend(t, friend, victimIP, "hej")
	network.pump()
	network.take(victimIP)

	// Hours of strangers' records later: the pins are full, the friend's
	// the oldest of them.
	network.clock = network.clock.Add(3 * time.Hour)
	victim.mu.Lock()
	pqFillPins(victim, "201:1::%x", pqMaxPins-len(victim.pins), func(index int) time.Time {
		return network.clock.Add(time.Duration(index) * time.Millisecond)
	})
	victim.mu.Unlock()
	devicePublic := pqPublicKeyOfEndpoint(t, victim)
	for range 2 * pqNewPinsPerMinute {
		network.clock = network.clock.Add(time.Minute / pqNewPinsPerMinute)
		ip, frame := pqStrangerRecord(t, devicePublic)
		victim.receive(ip, frame)
	}
	if len(victim.pins) != pqMaxPins || victim.pins["201:1::1"] != nil {
		t.Fatal("strangers' pins must make room among themselves")
	}
	if victim.pinsSnapshot()[friendIP.String()] != friend.ownFingerprint() {
		t.Fatal("a stranger's record pushed out the pin of a peer that had a session")
	}
	nodeKey, _ := pqTestNode(t, 2)
	impostor := network.pqImpostor(nodeKey, friendIP)
	before := network.sentBy(victimIP)
	if err := impostor.send(victimIP, []byte("ja")); err != nil {
		t.Fatal(err)
	}
	network.pump()
	if network.sentBy(victimIP) != before || len(network.take(victimIP)) != 0 {
		t.Fatal("the impostor must still be refused")
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

// pqFillPins pins n addresses made from format (index+1 in hex) loosely,
// the one at index seen at at(index), as records of nobody would have
// (e.mu held).
func pqFillPins(e *pqEndpoint, format string, n int, at func(int) time.Time) {
	for index := range n {
		e.setPinLocked(fmt.Sprintf(format, index+1), &pqPin{seen: at(index)})
	}
}

// pqJunkPins are n pins of addresses nobody has, with keys nobody holds.
func pqJunkPins(n int, salt string) map[string]string {
	pins := make(map[string]string, n)
	for index := range n {
		fingerprint := sha256.Sum256(fmt.Appendf(nil, "%s-%d", salt, index))
		pins[fmt.Sprintf("201:%x::%x", index>>16, index&0xffff)] = hex.EncodeToString(fingerprint[:])
	}
	return pins
}

// talkBothWays reports whether a text gets from a to b and one back.
func talkBothWays(network *pqTestNet, a *pqEndpoint, aIP net.IP, b *pqEndpoint, bIP net.IP) bool {
	_ = a.send(bIP, []byte("there"))
	network.pump()
	there := network.take(bIP)
	_ = b.send(aIP, []byte("back"))
	network.pump()
	back := network.take(aIP)
	return len(there) == 1 && len(back) == 1
}

// Whatever the app vouches for, and however much of it, the pin of a
// contact this device made itself stays, and so does the session.
func TestPQVouchedKeysNeverPushOutAPinOfThisDevicesOwnContact(t *testing.T) {
	network := newPQTestNet(t)
	friend, friendIP := network.add(1)
	victim, victimIP := network.add(2)
	if !talkBothWays(network, friend, friendIP, victim, victimIP) {
		t.Fatal("the two must talk")
	}
	network.clock = network.clock.Add(time.Hour)
	victim.importPins(pqJunkPins(pqMaxPins, "junk"), true)
	if victim.pinsSnapshot()[friendIP.String()] != friend.ownFingerprint() {
		t.Fatal("vouched keys pushed out the pin of a contact")
	}
	bogus := sha256.Sum256([]byte("chosen by someone else"))
	taken, conflicts := victim.importPins(map[string]string{friendIP.String(): hex.EncodeToString(bogus[:])}, true)
	if taken != 0 || conflicts[friendIP.String()] != friend.ownFingerprint() {
		t.Fatalf("taken %d, conflicts %v", taken, conflicts)
	}
	if victim.pinsSnapshot()[friendIP.String()] != friend.ownFingerprint() {
		t.Fatal("a vouch moved the pin of a contact")
	}
	if !talkBothWays(network, friend, friendIP, victim, victimIP) {
		t.Fatal("after the vouches the two must still talk")
	}
	// The vouched keys that found no room are kept as hints, a bounded few.
	if len(victim.pins) > pqMaxPins || len(victim.hints) > pqMaxHints {
		t.Fatalf("%d pins, %d hints", len(victim.pins), len(victim.hints))
	}
}

// Keys a friend's friend list names are hints: they never move a pin or
// end a session, and the first record the device at that address signs
// decides; a hint that names another key than the pin is reported.
func TestPQAFriendsListOnlyHintsAndTheDeviceItselfDecides(t *testing.T) {
	network := newPQTestNet(t)
	friend, friendIP := network.add(1)
	victim, victimIP := network.add(2)
	stranger, strangerIP := network.add(3)
	if !talkBothWays(network, friend, friendIP, victim, victimIP) {
		t.Fatal("the two must talk")
	}
	network.clock = network.clock.Add(time.Hour)

	// A flood of hints, then hints that lie about a contact and about a
	// device this one has not met yet.
	victim.importHints(pqJunkPins(pqMaxHints+2000, "junk"))
	if len(victim.hints) > pqMaxHints || victim.pinsSnapshot()[friendIP.String()] != friend.ownFingerprint() {
		t.Fatalf("%d hints; the contact's pin must stay", len(victim.hints))
	}
	bogus := sha256.Sum256([]byte("chosen by someone else"))
	lies := map[string]string{
		friendIP.String():   hex.EncodeToString(bogus[:]),
		strangerIP.String(): hex.EncodeToString(bogus[:]),
	}
	_, conflicts := victim.importHints(lies)
	if conflicts[friendIP.String()] != friend.ownFingerprint() || len(conflicts) != 1 {
		t.Fatalf("conflicts %v", conflicts)
	}
	if victim.pinsSnapshot()[friendIP.String()] != friend.ownFingerprint() ||
		victim.peerFingerprint(friendIP) != friend.ownFingerprint() {
		t.Fatal("a hint moved a pin or a session's key")
	}
	if !talkBothWays(network, friend, friendIP, victim, victimIP) {
		t.Fatal("after the hints the two must still talk")
	}
	if !talkBothWays(network, stranger, strangerIP, victim, victimIP) {
		t.Fatal("a hint must not keep the device itself out")
	}
	if victim.pinsSnapshot()[strangerIP.String()] != stranger.ownFingerprint() {
		t.Fatal("the device's own record must be pinned")
	}
	if _, conflicts := victim.importHints(lies); conflicts[strangerIP.String()] != stranger.ownFingerprint() {
		t.Fatalf("the lie must now be reported: %v", conflicts)
	}
	// A hint the device's record confirms is pinned even with no new pins
	// left this minute.
	other, otherIP := network.add(4)
	victim.importHints(map[string]string{otherIP.String(): other.ownFingerprint()})
	victim.mu.Lock()
	victim.newPins = pqBucket{at: network.clock}
	victim.mu.Unlock()
	if !talkBothWays(network, other, otherIP, victim, victimIP) {
		t.Fatal("the hinted device must get through")
	}
	if victim.pinsSnapshot()[otherIP.String()] != other.ownFingerprint() {
		t.Fatal("a confirmed hint must be pinned")
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
