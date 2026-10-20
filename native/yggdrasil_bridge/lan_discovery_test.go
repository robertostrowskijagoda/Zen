package main

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"net"
	"testing"
	"time"
)

func TestLanInterfaceEligible(t *testing.T) {
	wifi := net.FlagUp | net.FlagBroadcast | net.FlagMulticast
	for _, name := range []string{"wlan0", "swlan0", "ap0", "p2p-wlan0-0", "p2p0"} {
		if !lanInterfaceEligible(name, wifi, "android", true) {
			t.Fatalf("%s is Wi-Fi on Android", name)
		}
	}
	for _, name := range []string{"rmnet_data0", "ccmni0", "lo", "dummy0", "tun0", "eth0"} {
		if lanInterfaceEligible(name, wifi, "android", true) {
			t.Fatalf("%s is not Wi-Fi on Android", name)
		}
	}
	if !lanInterfaceEligible("en0", wifi, "ios", true) || lanInterfaceEligible("pdp_ip0", wifi, "ios", true) {
		t.Fatal("iPhone: Wi-Fi (en0) only, never mobile data")
	}
	if !lanInterfaceEligible("bridge100", wifi, "ios", true) {
		t.Fatal("iPhone: its hotspot too")
	}
	for _, name := range []string{"eth0", "enp3s0", "Wi-Fi", "Ethernet", "en0", "wlp2s0"} {
		if !lanInterfaceEligible(name, wifi, "linux", false) {
			t.Fatalf("%s is a local network on a computer", name)
		}
	}
	for _, name := range []string{"docker0", "veth12", "virbr0", "vEthernet (WSL)", "tailscale0", "utun3", "wg0"} {
		if lanInterfaceEligible(name, wifi, "linux", false) {
			t.Fatalf("%s is a virtual network", name)
		}
	}
	if lanInterfaceEligible("wlan0", net.FlagBroadcast, "android", true) {
		t.Fatal("an interface that is down is skipped")
	}
	if lanInterfaceEligible("eth0", net.FlagUp|net.FlagLoopback|net.FlagBroadcast, "linux", false) {
		t.Fatal("loopback is skipped")
	}
	if lanInterfaceEligible("eth0", net.FlagUp|net.FlagPointToPoint, "linux", false) {
		t.Fatal("point-to-point links (VPNs) are skipped")
	}
	if lanTransportFor("p2p-wlan0-0") != "wifi-direct" || lanTransportFor("wlan0") != "lan" {
		t.Fatal("links over a Wi-Fi Direct group are named so")
	}
}

func TestLanBroadcastAndInterfaceLookup(t *testing.T) {
	_, home, _ := net.ParseCIDR("192.168.1.23/24")
	home.IP = net.ParseIP("192.168.1.23").To4()
	if got := lanBroadcast(home); !got.Equal(net.ParseIP("192.168.1.255")) {
		t.Fatalf("broadcast of %v: %v", home, got)
	}
	_, p2p, _ := net.ParseCIDR("192.168.49.1/24")
	interfaces := []lanInterface{{name: "wlan0", nets: []*net.IPNet{home}}, {name: "p2p-wlan0-0", nets: []*net.IPNet{p2p}}}
	if ifi, ok := lanInterfaceFor(interfaces, net.ParseIP("192.168.49.77")); !ok || ifi.name != "p2p-wlan0-0" {
		t.Fatalf("a Wi-Fi Direct neighbour: %v %v", ifi, ok)
	}
	if ifi, ok := lanInterfaceFor(interfaces, net.ParseIP("::ffff:192.168.1.9")); !ok || ifi.name != "wlan0" {
		t.Fatalf("an IPv4-mapped neighbour: %v %v", ifi, ok)
	}
	if _, ok := lanInterfaceFor(interfaces, net.ParseIP("8.8.8.8")); ok {
		t.Fatal("the internet is not the local network")
	}
}

func TestLanBeaconRoundTrip(t *testing.T) {
	peers := []localPeer{testLocalPeer(t, 1)}
	advert, err := buildLocalAdvert(peers, time.Now(), 0, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	gotAdvert, port, ok := parseLanBeacon(lanBeacon(advert, 40123))
	if !ok || port != 40123 || !bytes.Equal(gotAdvert, advert) {
		t.Fatalf("beacon round trip: %v %d", ok, port)
	}
	for _, bad := range [][]byte{nil, {1, 2, 3}, lanBeacon(advert, 0), make([]byte, lanMaxDatagram+1)} {
		if _, _, ok := parseLanBeacon(bad); ok {
			t.Fatalf("%d bytes must not parse", len(bad))
		}
	}
}

func TestLanShouldDialOnlyFromTheLowerAddress(t *testing.T) {
	low, high := "200:1::1", "200:2::1"
	if !lanShouldDial(low, []*localPeer{{address: high}}) {
		t.Fatal("the lower address connects")
	}
	if lanShouldDial(high, []*localPeer{{address: low}}) {
		t.Fatal("the higher one answers with a beacon instead")
	}
}

func TestLanBeaconRateLimits(t *testing.T) {
	lan := &lanDiscovery{lastSource: map[string]time.Time{}}
	now := time.Now()
	if !lan.admit("192.168.1.2", now) {
		t.Fatal("the first beacon is looked at")
	}
	if lan.admit("192.168.1.2", now.Add(time.Second)) {
		t.Fatal("one sender is looked at every few seconds at most")
	}
	if !lan.admit("192.168.1.2", now.Add(lanSourceInterval)) {
		t.Fatal("later it is looked at again")
	}
	flood := now.Add(time.Hour)
	admitted := 0
	for i := 0; i < 3*lanBeaconsPerSecond; i++ {
		ip := net.IPv4(10, 0, byte(i/250), byte(i%250)).String()
		if lan.admit(ip, flood) {
			admitted++
		}
	}
	if admitted != lanBeaconsPerSecond {
		t.Fatalf("at most %d beacons a second from everyone, got %d", lanBeaconsPerSecond, admitted)
	}
}

func TestLanIntervalIsBounded(t *testing.T) {
	if lanIntervalFor(0) != lanDefaultBeaconInterval || lanIntervalFor(1) != lanMinBeaconInterval || lanIntervalFor(100000) != lanMaxBeaconInterval {
		t.Fatal("the beacon interval stays within its bounds")
	}
	if lanIntervalFor(30) != 30*time.Second {
		t.Fatal("the app's interval is used when sane")
	}
}

// testLan is the LAN side of a manager without the beacon socket, on
// loopback (as if it were the Wi-Fi).
func testLan(t *testing.T, m *localLinkManager) *lanDiscovery {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, loopback, _ := net.ParseCIDR("127.0.0.0/8")
	lan := &lanDiscovery{
		m:          m,
		listener:   listener,
		tcpPort:    listener.Addr().(*net.TCPAddr).Port,
		quit:       make(chan struct{}),
		interfaces: []lanInterface{{name: "wlan0", nets: []*net.IPNet{loopback}}},
		ownSalts:   map[[4]byte]time.Time{},
		lastSource: map[string]time.Time{},
		lastReply:  map[string]time.Time{},
		lastDial:   map[string]time.Time{},
		perSource:  map[string]int{},
	}
	lan.done.Add(1)
	go lan.acceptLoop()
	t.Cleanup(func() {
		close(lan.quit)
		_ = listener.Close()
		lan.done.Wait()
	})
	return lan
}

func TestLanBeaconLeadsToALink(t *testing.T) {
	coreA, coreB, managerA, managerB := testManagers(t)
	lanA, lanB := testLan(t, managerA), testLan(t, managerB)
	lower, higher, lowerCore, higherCore := lanA, lanB, coreA, coreB
	if managerB.self < managerA.self {
		lower, higher, lowerCore, higherCore = lanB, lanA, coreB, coreA
	}
	// Its own beacon, come back, is ignored.
	own := lower.beacon()
	lower.handleBeacon(own, &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: lanBeaconPort})
	time.Sleep(100 * time.Millisecond)
	if lower.m.hasLink(higher.m.self) {
		t.Fatal("a device does not link with its own beacon")
	}
	// The lower one hears the higher one and connects.
	lower.handleBeacon(higher.beacon(), &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: lanBeaconPort})
	waitForPeer(t, lowerCore, higherCore.PublicKey(), true)
	waitForPeer(t, higherCore, lowerCore.PublicKey(), true)
	links := higher.m.status()["links"].([]map[string]any)
	if len(links) != 1 || links[0]["transport"] != "lan" {
		t.Fatalf("status: %+v", links)
	}
}

func TestLanRefusesConnectionsFromOutsideTheLocalNetwork(t *testing.T) {
	_, _, managerA, _ := testManagers(t)
	lan := testLan(t, managerA)
	lan.mu.Lock()
	lan.interfaces = nil
	lan.mu.Unlock()
	conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", lan.tcpPort))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("a connection from outside the local networks is closed at once")
	}
}

func TestLanDiscoveryFollowsTheSetting(t *testing.T) {
	_, _, managerA, _ := testManagers(t)
	peers := managerA.peers()
	managerA.apply(localLinkSettings{lan: true, peers: peers})
	lan := managerA.status()["lan"].(map[string]any)
	if lan["error"] != nil {
		t.Skipf("beacon port unavailable here: %v", lan["error"])
	}
	if lan["running"] != true || lan["on"] != true {
		t.Fatalf("LAN discovery runs when on: %+v", lan)
	}
	managerA.apply(localLinkSettings{lan: true})
	if managerA.status()["lan"].(map[string]any)["running"] != false {
		t.Fatal("with nobody to find there is nothing to send")
	}
	managerA.apply(localLinkSettings{lan: true, peers: peers})
	managerA.apply(localLinkSettings{peers: peers})
	if managerA.status()["lan"].(map[string]any)["running"] != false {
		t.Fatal("LAN discovery stops when turned off")
	}
}

func TestLanSenderMapsStayBounded(t *testing.T) {
	lan := &lanDiscovery{lastDial: map[string]time.Time{}}
	replies := map[string]time.Time{}
	start := time.Now()
	// Beacons from made-up source addresses, ten a second for hours.
	for i := 0; i < 20*lanMaxRemembered; i++ {
		now := start.Add(time.Duration(i) * 100 * time.Millisecond)
		ip := net.IPv4(10, byte(i>>16), byte(i>>8), byte(i))
		// Not on a local network of this device: remembered, never dialled.
		lan.dial(ip, 1, now)
		replies[ip.String()] = now
		pruneLanTimes(replies, now, lanReplyInterval)
	}
	if len(lan.lastDial) > lanMaxRemembered+1 || len(replies) > lanMaxRemembered+1 {
		t.Fatalf("remembered %d dials and %d replies", len(lan.lastDial), len(replies))
	}
}

func TestLanHandshakeSlotsArePerSource(t *testing.T) {
	lan := &lanDiscovery{perSource: map[string]int{}}
	for i := 0; i < lanMaxHandshakesPerSource; i++ {
		if !lan.takeHandshake("192.168.1.7") {
			t.Fatalf("slot %d refused", i)
		}
	}
	if lan.takeHandshake("192.168.1.7") {
		t.Fatal("one address took more than its share of the slots")
	}
	// Others still get theirs, up to the total.
	taken := lanMaxHandshakesPerSource
	for i := 0; taken < lanMaxHandshakes; i++ {
		if !lan.takeHandshake(net.IPv4(192, 168, 1, byte(10+i)).String()) {
			t.Fatalf("slot %d refused", taken)
		}
		taken++
	}
	if lan.takeHandshake("192.168.1.200") {
		t.Fatal("more than lanMaxHandshakes at once")
	}
	lan.releaseHandshake("192.168.1.7")
	if !lan.takeHandshake("192.168.1.7") {
		t.Fatal("a released slot is not given again")
	}
	lan.releaseHandshake("192.168.1.7")
	lan.releaseHandshake("192.168.1.7")
	if _, ok := lan.perSource["192.168.1.7"]; ok {
		t.Fatal("a source with no handshake is still remembered")
	}
}
