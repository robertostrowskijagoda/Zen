package main

import (
	"crypto/rand"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// testForgedAdvert is an advert of bloomBytes for the slot of now with the
// first ones bits of its filter set.
func testForgedAdvert(now time.Time, bloomBytes, ones int) []byte {
	advert := make([]byte, localLinkAdvertHeader+bloomBytes)
	advert[0] = localLinkAdvertVersion
	binary.BigEndian.PutUint16(advert[1:3], uint16(localLinkSlotAt(now)))
	for i := 0; i < ones; i++ {
		advert[localLinkAdvertHeader+i/8] |= 1 << (i % 8)
	}
	return advert
}

// A filter with more bits set than an honest one ever has matches nothing,
// whatever the transport: with every bit set it matched every phone nearby.
func TestAFilterTooFullMatchesNothing(t *testing.T) {
	now := time.Now()
	victim := []localPeer{testLocalPeer(t, 9001)}
	for _, size := range []int{13, 16, 32, 64, 256} {
		bits := size * 8
		if got := matchLocalAdvert(victim, testForgedAdvert(now, size, bits), now); len(got) != 0 {
			t.Fatalf("%d bytes, every bit set: matched", size)
		}
		over := bits*localLinkMaxBloomFill/100 + 1
		if !localAdvertTooFull(testForgedAdvert(now, size, over)[localLinkAdvertHeader:]) {
			t.Fatalf("%d bytes, %d of %d bits set: taken", size, over, bits)
		}
		if localAdvertTooFull(testForgedAdvert(now, size, bits*localLinkMaxBloomFill/100)[localLinkAdvertHeader:]) {
			t.Fatalf("%d bytes: the limit itself is refused", size)
		}
	}
	// The manager's test (Bluetooth, Multipeer, Wi-Fi Direct) goes the
	// same way.
	_, _, managerA, _ := testManagers(t)
	if managerA.matches(testForgedAdvert(now, 16, 128)) {
		t.Fatal("the manager took a full filter")
	}
}

// However many devices the sender links with, the 16 bytes of a Bluetooth
// advert hold only as many as keep it selective: with 20 or more, 70-100%
// of unrelated phones took it for a friend's and dialled.
func TestABluetoothAdvertStaysSelective(t *testing.T) {
	now := time.Now()
	if localAdvertCapacity(16) != 8 {
		t.Fatalf("a 16-byte filter holds %d devices", localAdvertCapacity(16))
	}
	for _, n := range []int{5, 20, 80} {
		sender := make([]localPeer, n)
		receiver := make([]localPeer, 40)
		for i := range sender {
			sender[i] = testLocalPeer(t, 1000+i)
		}
		for i := range receiver {
			receiver[i] = testLocalPeer(t, 5000+i)
		}
		const tries = 300
		hits := 0
		for i := 0; i < tries; i++ {
			advert, err := buildLocalAdvert(sender, now, 16, rand.Reader)
			if err != nil {
				t.Fatal(err)
			}
			if localAdvertTooFull(advert[localLinkAdvertHeader:]) {
				t.Fatalf("%d devices: an advert fuller than receivers take", n)
			}
			if len(matchLocalAdvert(receiver, advert, now)) > 0 {
				hits++
			}
		}
		t.Logf("16-byte filter, sender with %d devices: a stranger with 40 matched %d of %d adverts", n, hits, tries)
		if hits > tries/10 {
			t.Fatalf("sender with %d devices: a stranger with 40 matched %d of %d adverts", n, hits, tries)
		}
		// The first ones of the list are in it.
		advert, _ := buildLocalAdvert(sender, now, 16, rand.Reader)
		if len(matchLocalAdvert(sender[:1], advert, now)) != 1 {
			t.Fatalf("%d devices: the first is not in the advert", n)
		}
	}
	// A LAN beacon is sized to the devices: all of them fit, below the limit.
	many := make([]localPeer, 100)
	for i := range many {
		many[i] = testLocalPeer(t, 7000+i)
	}
	advert, err := buildLocalAdvert(many, now, 0, rand.Reader)
	if err != nil || localAdvertTooFull(advert[localLinkAdvertHeader:]) {
		t.Fatalf("LAN advert: %v", err)
	}
	if got := matchLocalAdvert(many, advert, now); len(got) != len(many) {
		t.Fatalf("LAN advert holds %d of %d devices", len(got), len(many))
	}
}

// An advert with room for fewer devices than there are takes the account's
// own devices first, then the ones linked lately, then the others by turns.
func TestAnAdvertTakesOwnDevicesThenRecentThenByTurns(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	peers := make([]localPeer, 20)
	for i := range peers {
		peers[i] = testLocalPeer(t, 100+i)
	}
	peers[7].own, peers[15].own = true, true
	linked := map[string]time.Time{
		peers[3].address:  now.Add(-time.Hour),
		peers[11].address: now.Add(-time.Minute),
		peers[12].address: now.Add(-60 * 24 * time.Hour), // long ago
	}
	got := localAdvertOrder(peers, linked, now, 8)
	if len(got) != len(peers) {
		t.Fatalf("%d of %d", len(got), len(peers))
	}
	want := []string{peers[7].address, peers[15].address, peers[11].address, peers[3].address}
	for i, address := range want {
		if got[i].address != address {
			t.Fatalf("place %d: %s, want %s", i, got[i].address, address)
		}
	}
	// Every other device is in now and then.
	seen := map[string]bool{}
	for slot := 0; slot < 10; slot++ {
		for _, peer := range localAdvertOrder(peers, linked, now.Add(time.Duration(slot)*localLinkSlot), 8)[:8] {
			seen[peer.address] = true
		}
	}
	if len(seen) != len(peers) {
		t.Fatalf("in 10 slots %d of %d devices were in the advert", len(seen), len(peers))
	}
	// Room for all: as they are.
	if got := localAdvertOrder(peers, linked, now, 20); &got[0] != &peers[0] {
		t.Fatal("reordered with room for every device")
	}
}

// One forged beacon (a full filter, any port, a spoofed source on the
// Wi-Fi) made a device open TCP to that address and port and write its
// hello there. Now: a full filter is refused, a beacon must come from the
// beacon port and name no well-known port, and a friend's real beacon still
// leads to a dial of its own source only.
func TestAForgedLanBeaconDialsNothing(t *testing.T) {
	_, _, managerA, _ := testManagers(t)
	lan := testLan(t, managerA)
	managerA.mu.Lock()
	managerA.self = "000"
	managerA.mu.Unlock()
	target, err := net.Listen("tcp", "127.0.0.2:0")
	if err != nil {
		t.Skip(err)
	}
	defer target.Close()
	// Any connection at all is what the forger wants (a write to a port of
	// its choosing): it is told at once.
	got := make(chan string, 4)
	go func() {
		for {
			conn, err := target.Accept()
			if err != nil {
				return
			}
			got <- conn.RemoteAddr().String()
			_ = conn.Close()
		}
	}()
	port := target.Addr().(*net.TCPAddr).Port
	now := time.Now()
	full := testForgedAdvert(now, 16, 128)
	lan.handleBeacon(lanBeacon(lanBeaconFields{advert: full, port: port}), &net.UDPAddr{IP: net.IPv4(127, 0, 0, 2), Port: lanBeaconPort})
	select {
	case from := <-got:
		t.Fatalf("a forged full beacon made the device connect (from %s)", from)
	case <-time.After(1500 * time.Millisecond):
	}

	// A beacon the device recognises (its friend's tag), but from another
	// source port, or naming a well-known port: no dial either.
	friend, err := buildLocalAdvert(managerA.peers(), now, 0, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if !lan.lanBeaconFromNearby(&net.UDPAddr{IP: net.IPv4(127, 0, 0, 3), Port: lanBeaconPort}, port) {
		t.Fatal("a beacon from the beacon port of a device on the network is taken")
	}
	for _, bad := range []struct {
		src  *net.UDPAddr
		port int
	}{
		{&net.UDPAddr{IP: net.IPv4(127, 0, 0, 4), Port: 5353}, port},
		{&net.UDPAddr{IP: net.IPv4(127, 0, 0, 5), Port: lanBeaconPort}, 631},
		{&net.UDPAddr{IP: net.IPv4(203, 0, 113, 5), Port: lanBeaconPort}, port},
	} {
		if lan.lanBeaconFromNearby(bad.src, bad.port) {
			t.Fatalf("a beacon from %v naming port %d is taken", bad.src, bad.port)
		}
		lan.handleBeacon(lanBeacon(lanBeaconFields{advert: friend, port: bad.port}), bad.src)
	}
	select {
	case from := <-got:
		t.Fatalf("the device connected (from %s)", from)
	case <-time.After(500 * time.Millisecond):
	}
}

// A beacon is answered only on the local networks: the socket listens on
// every interface, and a computer with a public address answered anyone on
// the internet who asked.
func TestLanRepliesOnlyOnTheLocalNetwork(t *testing.T) {
	now := time.Now()
	looker, _, _ := testNearbyLan(lanNearby{looking: true})
	asks := looker.beacon()
	visible, to, _ := testNearbyLan(lanNearby{start: lanNearbySlotAt(now), adverts: testNearbyAdverts(1)})
	visible.handleBeacon(asks, &net.UDPAddr{IP: net.IPv4(203, 0, 113, 7), Port: lanBeaconPort})
	visible.reply(net.IPv4(198, 51, 100, 7), now)
	if len(*to) != 0 {
		t.Fatalf("answered %v", *to)
	}
	visible.handleBeacon(asks, &net.UDPAddr{IP: net.IPv4(192, 168, 1, 40), Port: lanBeaconPort})
	if len(*to) != 1 {
		t.Fatalf("a device on the Wi-Fi is answered: %v", *to)
	}
}
