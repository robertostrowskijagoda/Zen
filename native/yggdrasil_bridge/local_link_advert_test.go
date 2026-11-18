package main

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"strings"
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

// One device's Bluetooth adverts from different slots share no byte that
// another device sends differently: what stays the same (the version) is
// the same on every Zen device, so nobody nearby can tie the adverts of one
// phone together across its address changes. The platforms add nothing of
// the phone's own around it any more (BluetoothLinkAdvert.kt: until 1.18.0
// the L2CAP PSM went with it).
func TestABluetoothAdvertHasNoFieldOfItsOwnAcrossSlots(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	phone := []localPeer{testLocalPeer(t, 1), testLocalPeer(t, 2), testLocalPeer(t, 3)}
	other := []localPeer{testLocalPeer(t, 4)}
	var mine, theirs [][]byte
	for i := 0; i < 288; i++ {
		now := start.Add(time.Duration(i) * localLinkSlot)
		a, err := buildLocalAdvert(phone, now, 16, rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		b, err := buildLocalAdvert(other, now, 16, rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		mine = append(mine, a)
		theirs = append(theirs, b)
	}
	for i := range mine[0] {
		same := true
		for _, a := range mine {
			same = same && a[i] == mine[0][i]
		}
		if !same {
			continue
		}
		for _, b := range theirs {
			if b[i] != mine[0][i] {
				t.Fatalf("byte %d stays %#x in one phone's adverts and differs in another's", i, mine[0][i])
			}
		}
		if i != 0 {
			t.Fatalf("byte %d stays the same in every advert", i)
		}
	}
	// Its friends still find it in every slot.
	for i, a := range mine {
		now := start.Add(time.Duration(i) * localLinkSlot)
		if len(matchLocalAdvert(phone[:1], a, now)) != 1 {
			t.Fatalf("slot %d: the friend does not find the advert", i)
		}
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

// testLinkTargets listens on the same link port at each of ips (loopback
// addresses standing for hosts on the Wi-Fi) and reports every connection
// made to any of them.
func testLinkTargets(t *testing.T, ips ...net.IP) (int, chan string) {
	t.Helper()
	first, err := listenLanLinks(ips[0].String())
	if err != nil {
		t.Skip(err)
	}
	port := first.Addr().(*net.TCPAddr).Port
	listeners := []net.Listener{first}
	for _, ip := range ips[1:] {
		listener, err := net.Listen("tcp", net.JoinHostPort(ip.String(), fmt.Sprint(port)))
		if err != nil {
			t.Skip(err)
		}
		listeners = append(listeners, listener)
	}
	got := make(chan string, 64)
	for _, listener := range listeners {
		t.Cleanup(func() { _ = listener.Close() })
		go func(listener net.Listener) {
			for {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				got <- conn.LocalAddr().String()
				_ = conn.Close()
			}
		}(listener)
	}
	return port, got
}

// testDials counts the connections that come within wait.
func testDials(got chan string, wait time.Duration) []string {
	var dialled []string
	deadline := time.After(wait)
	for {
		select {
		case to := <-got:
			dialled = append(dialled, to)
		case <-deadline:
			return dialled
		}
	}
}

// A spoofed beacon pulled a dial to any host on the LAN and any port above
// 1023 the forger chose, as often as it sent new source addresses: the
// phone probed the LAN for it. Now a beacon makes the device dial only the
// link ports, a beacon it recognises counts once (a copy from another
// address is a replay), and few dials go out in a window.
func TestASpoofedLanBeaconCannotMakeTheDeviceProbeTheLan(t *testing.T) {
	_, _, managerA, _ := testManagers(t)
	lan := testLan(t, managerA)
	managerA.mu.Lock()
	managerA.self = "000"
	managerA.mu.Unlock()
	now := time.Now()
	friendBeacon := func(port int) []byte {
		advert, err := buildLocalAdvert(managerA.peers(), now, 0, rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		return lanBeacon(lanBeaconFields{advert: advert, port: port})
	}

	// Any other port: a printer's, a router's admin page, a service the
	// forger wants to know of.
	other, err := net.Listen("tcp", "127.0.0.2:0")
	if err != nil {
		t.Skip(err)
	}
	defer other.Close()
	otherDialled := make(chan struct{}, 1)
	go func() {
		if conn, err := other.Accept(); err == nil {
			otherDialled <- struct{}{}
			_ = conn.Close()
		}
	}()
	lan.handleBeacon(friendBeacon(other.Addr().(*net.TCPAddr).Port), &net.UDPAddr{IP: net.IPv4(127, 0, 0, 2), Port: lanBeaconPort})
	select {
	case <-otherDialled:
		t.Fatal("a beacon made the device dial a port outside the link ports")
	case <-time.After(time.Second):
	}

	// The friend's beacon from its address leads to one dial; the same
	// beacon from another address is a replay and leads to none.
	port, got := testLinkTargets(t, net.IPv4(127, 0, 0, 3), net.IPv4(127, 0, 0, 4))
	beacon := friendBeacon(port)
	lan.handleBeacon(beacon, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 3), Port: lanBeaconPort})
	lan.handleBeacon(beacon, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 4), Port: lanBeaconPort})
	if dialled := testDials(got, time.Second); len(dialled) != 1 || !strings.HasPrefix(dialled[0], "127.0.0.3:") {
		t.Fatalf("dialled %v", dialled)
	}

	// Fresh beacons from many addresses: few dials in a window.
	var ips []net.IP
	for i := 0; i < 2*lanMaxDialsPerWindow; i++ {
		ips = append(ips, net.IPv4(127, 0, 1, byte(10+i)))
	}
	port, got = testLinkTargets(t, ips...)
	lan.mu.Lock()
	lan.dialWindowStart, lan.dialWindowCount = time.Time{}, 0
	lan.mu.Unlock()
	for _, ip := range ips {
		lan.dial(ip, port, now)
	}
	if dialled := testDials(got, time.Second); len(dialled) != lanMaxDialsPerWindow {
		t.Fatalf("%d dials in a window", len(dialled))
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
