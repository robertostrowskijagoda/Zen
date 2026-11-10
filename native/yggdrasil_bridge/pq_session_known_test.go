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

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
)

// addStranger is network.add for a node key made just now: what a stranger
// gets for free, as many times as it likes.
func (n *pqTestNet) addStranger() (*pqEndpoint, net.IP) {
	n.t.Helper()
	_, nodeKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		n.t.Fatal(err)
	}
	ip := net.IP(address.AddrForKey(nodeKey.Public().(ed25519.PublicKey))[:])
	endpoint, err := newPQEndpoint(nodeKey, ip, func(to net.IP, wire []byte) error {
		frame := pqTestFrame{from: ip, to: bytes.Clone(to), wire: bytes.Clone(wire)}
		n.queue = append(n.queue, frame)
		n.sent = append(n.sent, frame)
		return nil
	})
	if err != nil {
		n.t.Fatal(err)
	}
	endpoint.now = func() time.Time { return n.clock }
	endpoint.after = func(d time.Duration, f func()) {
		n.timers = append(n.timers, pqTestTimer{at: n.clock.Add(d), f: f})
	}
	n.endpoints[ip.String()] = endpoint
	return endpoint, ip
}

// The app answers every frame that carries a reliable id ('rly_ack'), a
// stranger's too, so this node writes to strangers whenever they like.
// That never makes them known: they keep spending the strangers' budget,
// and a friend's rotated session still opens while each of them asks for
// keys once a second.
func TestPQStrangersThisNodeAnsweredNeverSpendTheKnownBudget(t *testing.T) {
	network := newPQTestNet(t)
	victim, victimIP := network.add(1)
	victim.phone = true
	friend, friendIP := network.add(2)
	victim.setKnown([]string{friendIP.String()})
	if !talkBothWays(network, friend, friendIP, victim, victimIP) {
		t.Fatal("the friend and the victim must talk")
	}
	count := pqPhoneForeignKEMPerSecond * 3 / 2
	strangers := make([]*pqEndpoint, count)
	ips := make([]net.IP, count)
	for index := range count {
		network.clock = network.clock.Add(time.Second)
		strangers[index], ips[index] = network.addStranger()
		mustSend(t, strangers[index], victimIP, `{"type":"friend_request","_rid":"x"}`)
		network.pump()
		if got := network.take(victimIP); len(got) != 1 {
			t.Fatalf("stranger %d: victim got %q", index, got)
		}
		// The app's acknowledgement.
		mustSend(t, victim, ips[index], `{"type":"rly_ack","rid":"x"}`)
		network.pump()
		network.take(ips[index])
	}
	victim.mu.Lock()
	for _, ip := range ips {
		if peer := victim.peers[ip.String()]; peer != nil && victim.knownLocked(peer) {
			victim.mu.Unlock()
			t.Fatalf("a stranger this node answered counts as known: %s", ip)
		}
	}
	victim.mu.Unlock()

	network.advance(time.Hour+time.Second, nil)
	ask := func() {
		for index, s := range strangers {
			victim.receive(ips[index], s.keysFrame(true, nil, nil, false))
		}
		network.queue = nil
	}
	for range 15 {
		network.clock = network.clock.Add(time.Second)
		ask()
	}
	delivered := 0
	for range 30 {
		network.clock = network.clock.Add(time.Second)
		ask()
		mustSend(t, friend, victimIP, "after")
		network.pump()
		delivered += len(network.take(victimIP))
	}
	if delivered != 30 {
		t.Fatalf("%d strangers this node answered held up a friend: %d of 30 frames delivered", count, delivered)
	}
}

// Nothing a stranger does makes it known, on a computer either: not being
// written to, not frames held for it, not a vouched pin. Only the app's
// word does, and the app takes it back.
func TestPQOnlyTheAppMakesAPeerKnown(t *testing.T) {
	network := newPQTestNet(t)
	victim, victimIP := network.add(1)
	stranger, strangerIP := network.add(2)
	if !talkBothWays(network, stranger, strangerIP, victim, victimIP) {
		t.Fatal("the two must talk")
	}
	victim.importPins(map[string]string{strangerIP.String(): stranger.ownFingerprint()}, true)
	_ = victim.send(net.ParseIP("200::77"), []byte("held"))
	network.queue = nil
	known := func(ip net.IP) bool {
		victim.mu.Lock()
		defer victim.mu.Unlock()
		return victim.knownLocked(victim.peerLocked(ip, network.clock))
	}
	if known(strangerIP) || known(net.ParseIP("200::77")) {
		t.Fatal("being written to or vouched for made a stranger known")
	}
	if victim.setKnown([]string{strangerIP.String(), "8.8.8.8", "fd00::1"}) != 1 || !known(strangerIP) {
		t.Fatal("the app's word must make the peer known")
	}
	victim.setKnown(nil)
	if known(strangerIP) {
		t.Fatal("the app took its word back")
	}
}

// However many key records strangers send (no KEM cost, no rate limit), a
// known peer's entry stays, with its sessions and challenges; strangers'
// entries make room among themselves. A peer the app no longer knows goes
// back among them.
func TestPQStrangersRecordsNeverPushOutAKnownPeer(t *testing.T) {
	network := newPQTestNet(t)
	victim, victimIP := network.add(1)
	friend, friendIP := network.add(2)
	victim.setKnown([]string{friendIP.String()})
	if !talkBothWays(network, friend, friendIP, victim, victimIP) {
		t.Fatal("the two must talk")
	}
	network.clock = network.clock.Add(time.Minute)
	devicePublic := pqPublicKeyOfEndpoint(t, victim)
	for range pqMaxPeers + 50 {
		ip, frame := pqStrangerRecord(t, devicePublic)
		victim.receive(ip, frame)
	}
	network.queue = nil
	victim.mu.Lock()
	kept := victim.peers[friendIP.String()] != nil
	peers, strangers := len(victim.peers), victim.strangerPeers.Len()
	victim.mu.Unlock()
	if !kept || strangers != pqMaxPeers || peers != pqMaxPeers+1 {
		t.Fatalf("friend kept %v, %d peers, %d strangers", kept, peers, strangers)
	}

	// Strangers ask for keys once a second, as many as use up their
	// budget; the friend's frames still go.
	askers := make([]pqTestFrame, pqStrangerKEMPerSecond)
	for index := range askers {
		ip, frame := pqStrangerRecord(t, devicePublic)
		frame[len(pqMagic)+1] = pqFlagWant
		askers[index] = pqTestFrame{from: ip, wire: frame}
	}
	delivered := 0
	for range 30 {
		network.clock = network.clock.Add(time.Second)
		for _, a := range askers {
			victim.receive(a.from, a.wire)
		}
		network.queue = nil
		mustSend(t, friend, victimIP, "after")
		network.pump()
		delivered += len(network.take(victimIP))
	}
	if delivered != 30 {
		t.Fatalf("the friend delivered %d of 30", delivered)
	}

	victim.setKnown(nil)
	for range 10 {
		ip, frame := pqStrangerRecord(t, devicePublic)
		victim.receive(ip, frame)
	}
	victim.mu.Lock()
	gone := victim.peers[friendIP.String()] == nil
	strangers = victim.strangerPeers.Len()
	victim.mu.Unlock()
	if gone || strangers != pqMaxPeers {
		t.Fatalf("a peer no longer known goes back among the strangers, newest: gone %v, %d", gone, strangers)
	}
}

// A peer asking for keys over and over gets a challenge (a KEM operation)
// at most pqChallengesPerMinute times a minute.
func TestPQChallengesPerPeerAreCounted(t *testing.T) {
	network := newPQTestNet(t)
	victim, _ := network.add(1)
	asker, askerIP := network.add(2)
	given := 0
	for range 60 {
		network.clock = network.clock.Add(time.Second)
		victim.receive(askerIP, asker.keysFrame(true, nil, nil, false))
		for _, frame := range network.queue {
			if frame.wire[len(pqMagic)] == pqKindKeys && frame.wire[len(pqMagic)+1]&pqFlagChallenge != 0 {
				given++
			}
		}
		network.queue = nil
	}
	if given != pqChallengesPerMinute {
		t.Fatalf("%d challenges in a minute, want %d", given, pqChallengesPerMinute)
	}
}

// Strangers' records pin loose keys, a share of the table at most, and a
// restart keeps them loose: a first contact after it is still pinned, and
// a key the app vouches for is a pin that refuses an impostor holding the
// device's node key.
func TestPQStrangersPinsStayLooseAcrossARestart(t *testing.T) {
	network := newPQTestNet(t)
	victim, victimIP := network.add(1)
	devicePublic := pqPublicKeyOfEndpoint(t, victim)
	for range pqMaxLoosePins + 200 {
		network.clock = network.clock.Add(time.Minute / pqNewPinsPerMinute)
		ip, frame := pqStrangerRecord(t, devicePublic)
		victim.receive(ip, frame)
	}
	network.queue = nil
	if len(victim.pins) != pqMaxLoosePins {
		t.Fatalf("%d strangers' pins, want their share %d", len(victim.pins), pqMaxLoosePins)
	}

	kept := victim.pinsState()
	if len(kept.Firm) != 0 || len(kept.Vouched) != 0 || len(kept.Seen) != len(kept.Pins) {
		t.Fatalf("firm %d, vouched %d, seen %d of %d", len(kept.Firm), len(kept.Vouched), len(kept.Seen), len(kept.Pins))
	}
	restarted, _ := network.add(1)
	if taken := restarted.restorePins(kept); taken != len(kept.Pins) {
		t.Fatalf("%d of %d restored", taken, len(kept.Pins))
	}
	for address, pin := range restarted.pins {
		if !pin.loose() {
			t.Fatalf("%s came back firm", address)
		}
	}
	contact, contactIP := network.add(8)
	if !talkBothWays(network, contact, contactIP, restarted, victimIP) {
		t.Fatal("the contact must talk")
	}
	if restarted.pinsSnapshot()[contactIP.String()] != contact.ownFingerprint() {
		t.Fatal("a first contact whose session opened must be pinned")
	}

	device, deviceIP := network.add(7)
	taken, conflicts := restarted.importPins(map[string]string{deviceIP.String(): device.ownFingerprint()}, true)
	if taken != 1 || len(conflicts) != 0 || restarted.pinsSnapshot()[deviceIP.String()] != device.ownFingerprint() {
		t.Fatalf("the vouch must be a pin: taken %d, conflicts %v", taken, conflicts)
	}
	nodeKey, _ := pqTestNode(t, 7)
	impostor := network.pqImpostor(nodeKey, deviceIP)
	network.endpoints[deviceIP.String()] = impostor
	if err := impostor.send(victimIP, []byte("ja jestem tym urzadzeniem")); err != nil {
		t.Fatal(err)
	}
	network.pump()
	if got := network.take(victimIP); len(got) != 0 {
		t.Fatalf("the impostor's %q was taken", got)
	}
}

// With the pins full of loose ones, a vouch pushes one out. With the pins
// full of pins sessions proved, it is kept as a vouched hint: a record
// that contradicts it is refused and reported, and the device's own record
// makes it a pin.
func TestPQAVouchIntoFullPinsStillRefusesTheImpostor(t *testing.T) {
	for _, firm := range []bool{false, true} {
		t.Run(fmt.Sprintf("firm %v", firm), func(t *testing.T) {
			network := newPQTestNet(t)
			victim, victimIP := network.add(1)
			victim.mu.Lock()
			pqFillPins(victim, "201:1::%x", pqMaxPins, func(index int) time.Time {
				return network.clock.Add(time.Duration(index) * time.Millisecond)
			})
			if firm {
				for _, pin := range victim.pins {
					pin.firm = true
				}
				for address, pin := range victim.pins {
					victim.placePinLocked(address, pin)
				}
			}
			victim.mu.Unlock()
			network.clock = network.clock.Add(time.Minute)
			device, deviceIP := network.add(7)
			taken, conflicts := victim.importPins(map[string]string{deviceIP.String(): device.ownFingerprint()}, true)
			victim.mu.Lock()
			_, pinned := victim.pins[deviceIP.String()]
			hint := victim.hints[deviceIP.String()]
			victim.mu.Unlock()
			if taken != 1 || len(conflicts) != 0 || pinned == firm || (firm && (hint == nil || !hint.vouched)) {
				t.Fatalf("taken %d, conflicts %v, pinned %v, hint %+v", taken, conflicts, pinned, hint)
			}

			nodeKey, _ := pqTestNode(t, 7)
			impostor := network.pqImpostor(nodeKey, deviceIP)
			network.endpoints[deviceIP.String()] = impostor
			if err := impostor.send(victimIP, []byte("ja")); err != nil {
				t.Fatal(err)
			}
			network.pump()
			if got := network.take(victimIP); len(got) != 0 {
				t.Fatalf("the impostor's %q was taken", got)
			}
			if reported := victim.takeConflicts(); firm != (reported[deviceIP.String()] == device.ownFingerprint()) {
				t.Fatalf("reported %v", reported)
			}
			if victim.pinsSnapshot()[deviceIP.String()] == impostor.ownFingerprint() {
				t.Fatal("the impostor's key was pinned")
			}

			network.endpoints[deviceIP.String()] = device
			if !talkBothWays(network, device, deviceIP, victim, victimIP) {
				t.Fatal("the device itself must get through")
			}
			if victim.pinsSnapshot()[deviceIP.String()] != device.ownFingerprint() {
				t.Fatal("the device's own record must pin the vouched key")
			}
		})
	}
}

// A hint (what a friend's list or device record says about an address)
// is never a pin: a made-up key keeps nobody out, the device's own record
// decides, and once the friend who gave it is gone the hint goes.
func TestPQAMadeUpKeyAFriendNamesKeepsNobodyOut(t *testing.T) {
	network := newPQTestNet(t)
	real, realIP := network.add(1)
	victim, victimIP := network.add(2)
	bogus := sha256.Sum256([]byte("a key a friend made up"))
	other, otherIP := network.add(3)
	hints := map[string]string{
		realIP.String():  hex.EncodeToString(bogus[:]),
		otherIP.String(): hex.EncodeToString(bogus[:]),
	}
	if taken, conflicts := victim.importHints(hints); taken != 2 || len(conflicts) != 0 {
		t.Fatalf("taken %d, conflicts %v", taken, conflicts)
	}
	if !talkBothWays(network, real, realIP, victim, victimIP) || !talkBothWays(network, victim, victimIP, real, realIP) {
		t.Fatal("the real device must get through both ways")
	}
	if victim.pinsSnapshot()[realIP.String()] != real.ownFingerprint() {
		t.Fatal("the device's own record must be pinned")
	}
	if taken, conflicts := victim.importPins(map[string]string{realIP.String(): real.ownFingerprint()}, true); taken != 1 || len(conflicts) != 0 {
		t.Fatalf("an honest vouch afterwards: taken %d, conflicts %v", taken, conflicts)
	}
	// The friend is removed: what only it named goes.
	if dropped := victim.dropHints(hints); dropped != 1 {
		t.Fatalf("%d hints dropped, want the one not confirmed", dropped)
	}
	victim.mu.Lock()
	left := len(victim.hints)
	victim.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d hints left", left)
	}
	_ = other
}

// The pins of an app that kept no kinds (1.16.4 and earlier: every pin
// came back firm, made-up keys from friends' device records among them)
// come back loose. A made-up key keeps the real device out for
// pqLegacyPinGrace at most; a key the device confirms in that time stays,
// and a session makes it firm.
func TestPQPinsKeptByAnOlderAppComeBackLoose(t *testing.T) {
	network := newPQTestNet(t)
	real, realIP := network.add(1)
	friend, friendIP := network.add(3)
	victim, victimIP := network.add(2)
	bogus := sha256.Sum256([]byte("a key a friend made up"))
	taken := victim.restorePins(pqPinsState{Pins: map[string]string{
		realIP.String():   hex.EncodeToString(bogus[:]),
		friendIP.String(): friend.ownFingerprint(),
	}})
	if taken != 2 {
		t.Fatalf("%d restored", taken)
	}
	for address, pin := range victim.pins {
		if !pin.loose() {
			t.Fatalf("%s came back firm", address)
		}
	}
	// The friend's device confirms its key: firm from now on.
	if !talkBothWays(network, friend, friendIP, victim, victimIP) {
		t.Fatal("the friend must talk")
	}
	if victim.pins[friendIP.String()].loose() {
		t.Fatal("a session must make the kept pin firm")
	}
	// The real device is kept out while the made-up pin lasts ...
	if talkBothWays(network, real, realIP, victim, victimIP) {
		t.Fatal("the made-up pin still holds within its grace")
	}
	// ... and no longer.
	network.advance(pqLegacyPinGrace+time.Second, nil)
	network.queue = nil
	if !talkBothWays(network, real, realIP, victim, victimIP) {
		t.Fatal("after the grace the real device must get through")
	}
	if victim.pinsSnapshot()[realIP.String()] != real.ownFingerprint() ||
		victim.pinsSnapshot()[friendIP.String()] != friend.ownFingerprint() {
		t.Fatal("the real keys must be pinned")
	}

	// What this app keeps comes back as it was.
	kept := victim.pinsState()
	restarted, _ := network.add(2)
	restarted.restorePins(kept)
	if restarted.pins[friendIP.String()].loose() || restarted.pins[realIP.String()].loose() {
		t.Fatal("firm pins must come back firm")
	}
}

// Hints and pins into full tables cost a few steps each, never a scan of
// the table, so a friend's list of 2000 does not hold up signals and call
// media for a second.
func TestPQHintsAndPinsIntoFullTablesTakeNoScan(t *testing.T) {
	network := newPQTestNet(t)
	victim, _ := network.add(1)
	junk := func(n, from int) map[string]string {
		pins := make(map[string]string, n)
		for index := from; index < from+n; index++ {
			pins[fmt.Sprintf("202:%x::%x", index>>16, index&0xffff)] = victim.ownFingerprint()
		}
		return pins
	}
	timed := func(f func()) time.Duration {
		started := time.Now()
		f()
		return time.Since(started)
	}
	empty := timed(func() { victim.importHints(junk(2000, 0)) })
	victim.importHints(junk(pqMaxHints, 10_000))
	full := timed(func() { victim.importHints(junk(2000, 30_000)) })
	if full > 20*empty+50*time.Millisecond {
		t.Fatalf("2000 hints: %v into a full table, %v into an empty one", full, empty)
	}
	victim.mu.Lock()
	pqFillPins(victim, "201:2::%x", pqMaxPins, func(int) time.Time { return network.clock })
	victim.mu.Unlock()
	fullPins := timed(func() { victim.importPins(junk(2000, 60_000), true) })
	if fullPins > 20*empty+50*time.Millisecond {
		t.Fatalf("2000 vouches into full pins: %v (hints into an empty table %v)", fullPins, empty)
	}
	if len(victim.pins) > pqMaxPins || len(victim.hints) > pqMaxHints+pqMaxVouchedHints {
		t.Fatalf("%d pins, %d hints", len(victim.pins), len(victim.hints))
	}
}
