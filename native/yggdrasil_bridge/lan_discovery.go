package main

import (
	cryptorand "crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"math/rand/v2"
	"net"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/wlynxg/anet"
)

// LAN discovery: friends and the account's own devices on
// the same Wi-Fi, cable network or Wi-Fi Direct group find each other and
// link directly (local_link.go), with or without internet.
//
// Every few seconds the node broadcasts a beacon on each local network:
// an advert (a Bloom filter of tags only the right devices can test, a new
// random salt every time), the "people nearby" advert while the person is
// visible (lan_nearby.go) and the TCP port it takes links on. A device that
// recognises a beacon and has the lower mesh address of the two connects;
// the other answers with a beacon sent straight back, so the lower one
// hears it even if broadcasts get lost one way. The connection then runs
// the handshake: strangers get nothing but random-looking bytes, and only
// devices the app listed are linked.
//
// Yggdrasil's own multicast discovery stays off (node_probe.go): its
// beacons carry the node key, which is the person's Zen address.
//
// Phones use only Wi-Fi interfaces (Wi-Fi, hotspot, Wi-Fi Direct), never
// mobile data. iPhone: sending broadcasts needs Apple's multicast
// entitlement, so the iPhone only answers links started by others.
const (
	lanBeaconPort = 39319
	// Links go to a TCP port among these (the first one free), and a beacon
	// makes a device dial nothing else: with any port above 1023, a forged
	// beacon had a phone connect to whatever service on the LAN its sender
	// wanted to learn of.
	lanLinkPortFirst = 39320
	lanLinkPorts     = 16
	// Dials beacons lead to, in all, at most per window: each dial goes to
	// the beacon's own source, but anyone on the Wi-Fi can make that up,
	// and a new made-up source each time pulled a dial each time. Devices
	// not linked yet beyond these wait for the next window.
	lanDialWindow        = 15 * time.Second
	lanMaxDialsPerWindow = 4
	// A TCP connection on the LAN is made in milliseconds; a dial to an
	// address where nothing answers gives its handshake slot back soon.
	lanDialTimeout = 2 * time.Second
	// A recognised beacon counts once while its advert is good (its slot,
	// give or take localLinkMaxSlotSkew): the same beacon again, from
	// another source above all, is someone playing back a friend's beacon
	// to be dialled.
	lanHeardSaltMemory = localLinkSlot * (2*localLinkMaxSlotSkew + 1)

	lanDefaultBeaconInterval = 10 * time.Second
	lanMinBeaconInterval     = 5 * time.Second
	lanMaxBeaconInterval     = 5 * time.Minute
	// Beacons handled per sender address at most, and from everyone at
	// most per second: matching costs one HMAC per known device.
	lanSourceInterval   = 2 * time.Second
	lanBeaconsPerSecond = 40
	lanReplyInterval    = 5 * time.Second
	lanDialInterval     = 15 * time.Second
	lanMaxHandshakes    = 8
	// Handshakes with one address at once: a dial and an accept may cross,
	// but one device cannot take every slot.
	lanMaxHandshakesPerSource = 2
	// Handshakes one address may start in lanHandshakeStartWindow. A
	// stranger's handshake ends within localFirstFrameTimeout plus
	// localStageTimeout (4 s), but one that reconnected at once kept its
	// slots for good, and four addresses held all eight. Rationed, one
	// address holds a slot 3 × 4 s in 15 s, 0.8 of one on average, so ten
	// are needed to hold them all. A friend's device starts one every
	// lanDialInterval at most (two when a dial and an accept cross).
	lanHandshakeStartWindow     = 15 * time.Second
	lanHandshakeStartsPerSource = 3
	lanMaxDatagram              = 1472
	// Own beacons come back on some systems; their salts are remembered.
	lanOwnSaltMemory = 2 * time.Minute
	// Senders remembered per rate limit before the old ones are dropped.
	lanMaxRemembered = 1024
)

// Wi-Fi (and the phone's hotspot and Wi-Fi Direct groups): wlan0, swlan0,
// ap0, p2p-wlan0-0 on Android; en0 (Wi-Fi) and bridge100 (hotspot) on
// iPhone.
var (
	androidLanInterfaces = regexp.MustCompile(`^(wlan|swlan|ap|wl|p2p|softap)`)
	iosLanInterfaces     = regexp.MustCompile(`^(en0|bridge[0-9]+)$`)
	// Virtual networks of containers, VMs and VPNs on computers.
	desktopVirtualInterfaces = regexp.MustCompile(`(?i)^(docker|veth|br-|virbr|vmnet|vboxnet|vethernet|zt|tailscale|utun|tun|tap|wg|ygg|lxc|lxd|cni|flannel|podman|awdl|llw|anpi|ham)`)
)

// lanInterfaceEligible tells whether discovery runs on an interface.
func lanInterfaceEligible(name string, flags net.Flags, goos string, phone bool) bool {
	if flags&net.FlagUp == 0 || flags&net.FlagLoopback != 0 ||
		flags&net.FlagPointToPoint != 0 || flags&net.FlagBroadcast == 0 {
		return false
	}
	if !phone {
		return !desktopVirtualInterfaces.MatchString(name)
	}
	switch goos {
	case "android":
		return androidLanInterfaces.MatchString(name)
	case "ios":
		return iosLanInterfaces.MatchString(name)
	default:
		return false
	}
}

// lanTransportFor names the link by the interface it came over (Android's
// p2p-…, Windows' Wi-Fi Direct virtual adapters).
func lanTransportFor(name string) string {
	if strings.HasPrefix(name, "p2p") || lanWifiDirectAdapter(name) {
		return "wifi-direct"
	}
	return "lan"
}

type lanInterface struct {
	name string
	nets []*net.IPNet
}

// lanInterfaces are this device's eligible interfaces with their IPv4
// networks (anet: Go's own listing fails on Android 11+).
func lanInterfaces() []lanInterface {
	all, err := anet.Interfaces()
	if err != nil {
		return nil
	}
	phone := isPhoneOS()
	var out []lanInterface
	for i := range all {
		ifi := all[i]
		if !lanInterfaceEligible(ifi.Name, ifi.Flags, runtime.GOOS, phone) {
			continue
		}
		addrs, err := anet.InterfaceAddrsByInterface(&ifi)
		if err != nil {
			continue
		}
		entry := lanInterface{name: ifi.Name}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet.IP.To4() == nil || ipNet.IP.IsLinkLocalUnicast() {
				continue
			}
			entry.nets = append(entry.nets, &net.IPNet{IP: ipNet.IP.To4(), Mask: ipNet.Mask})
		}
		if len(entry.nets) > 0 {
			out = append(out, entry)
		}
	}
	return out
}

// lanBroadcast is the directed broadcast address of an IPv4 network.
func lanBroadcast(n *net.IPNet) net.IP {
	ip := n.IP.To4()
	mask := n.Mask
	if len(mask) == net.IPv6len {
		mask = mask[12:]
	}
	if ip == nil || len(mask) != net.IPv4len {
		return nil
	}
	out := make(net.IP, net.IPv4len)
	for i := range out {
		out[i] = ip[i] | ^mask[i]
	}
	return out
}

// lanInterfaceFor is the interface whose network holds ip.
func lanInterfaceFor(interfaces []lanInterface, ip net.IP) (lanInterface, bool) {
	ip4 := ip.To4()
	if ip4 == nil {
		return lanInterface{}, false
	}
	for _, ifi := range interfaces {
		for _, n := range ifi.nets {
			if n.Contains(ip4) {
				return ifi, true
			}
		}
	}
	return lanInterface{}, false
}

// lanBeaconFields is what one beacon says: the link advert, the "people
// nearby" advert (nil: not visible), whether its sender looks around, and
// the TCP port links go to.
type lanBeaconFields struct {
	advert  []byte
	nearby  []byte
	looking bool
	port    int
}

// lanBeacon is the link advert, the nearby advert (empty or
// lanNearbyAdvertBytes), an info byte (the nearby advert's length, and
// lanNearbyLookingBit) and the TCP port links go to.
func lanBeacon(fields lanBeaconFields) []byte {
	info := byte(len(fields.nearby))
	if fields.looking {
		info |= lanNearbyLookingBit
	}
	out := make([]byte, 0, len(fields.advert)+len(fields.nearby)+3)
	out = append(out, fields.advert...)
	out = append(out, fields.nearby...)
	out = append(out, info)
	return binary.BigEndian.AppendUint16(out, uint16(fields.port))
}

func parseLanBeacon(packet []byte) (lanBeaconFields, bool) {
	if len(packet) < localLinkAdvertHeader+localLinkMinBloomBytes+3 || len(packet) > lanMaxDatagram {
		return lanBeaconFields{}, false
	}
	port := int(binary.BigEndian.Uint16(packet[len(packet)-2:]))
	info := packet[len(packet)-3]
	nearbyBytes := int(info & lanNearbyLengthMask)
	if port == 0 || (nearbyBytes != 0 && nearbyBytes != lanNearbyAdvertBytes) {
		return lanBeaconFields{}, false
	}
	advertEnd := len(packet) - 3 - nearbyBytes
	if advertEnd < localLinkAdvertHeader+localLinkMinBloomBytes {
		return lanBeaconFields{}, false
	}
	fields := lanBeaconFields{
		advert:  packet[:advertEnd],
		looking: info&lanNearbyLookingBit != 0,
		port:    port,
	}
	if nearbyBytes > 0 {
		fields.nearby = packet[advertEnd : advertEnd+nearbyBytes]
	}
	return fields, true
}

// lanDiscovery runs the beacons, the listener and the dialling for one
// node.
type lanDiscovery struct {
	m        *localLinkManager
	udp      *net.UDPConn
	listener net.Listener
	tcpPort  int
	quit     chan struct{}
	done     sync.WaitGroup
	stopOnce sync.Once

	mu          sync.Mutex
	interval    time.Duration
	interfaces  []lanInterface
	ownSalts    map[[4]byte]time.Time
	lastSource  map[string]time.Time
	lastReply   map[string]time.Time
	lastDial    map[string]time.Time
	handshakes  int
	perSource   map[string]int
	starts      map[string]lanStarts
	windowStart time.Time
	windowCount int
	// Dials in the window that began at dialWindowStart.
	dialWindowStart time.Time
	dialWindowCount int
	// Salts of the recognised beacons heard lately.
	heardSalts map[[4]byte]time.Time
	// Nearby adverts heard while the app looks around (lan_nearby.go).
	nearby map[[lanNearbyAdvertBytes]byte]lanNearbyHeard

	// A beacon goes out at once (the app started looking around).
	poke chan struct{}
	// Set by tests to see the datagrams that go out.
	sent func(packet []byte, to *net.UDPAddr)
}

func lanIntervalFor(seconds int) time.Duration {
	interval := time.Duration(seconds) * time.Second
	if seconds <= 0 {
		interval = lanDefaultBeaconInterval
	}
	if interval < lanMinBeaconInterval {
		interval = lanMinBeaconInterval
	}
	if interval > lanMaxBeaconInterval {
		interval = lanMaxBeaconInterval
	}
	return interval
}

func startLanDiscovery(m *localLinkManager, beaconSeconds int) (*lanDiscovery, error) {
	udp, err := net.ListenUDP("udp4", &net.UDPAddr{Port: lanBeaconPort})
	if err != nil {
		return nil, fmt.Errorf("beacon port %d: %w", lanBeaconPort, err)
	}
	listener, err := listenLanLinks("")
	if err != nil {
		_ = udp.Close()
		return nil, err
	}
	lan := &lanDiscovery{
		m:          m,
		udp:        udp,
		listener:   listener,
		tcpPort:    listener.Addr().(*net.TCPAddr).Port,
		quit:       make(chan struct{}),
		interval:   lanIntervalFor(beaconSeconds),
		ownSalts:   map[[4]byte]time.Time{},
		lastSource: map[string]time.Time{},
		lastReply:  map[string]time.Time{},
		lastDial:   map[string]time.Time{},
		perSource:  map[string]int{},
		poke:       make(chan struct{}, 1),
	}
	lan.done.Add(3)
	go lan.beaconLoop()
	go lan.readLoop()
	go lan.acceptLoop()
	return lan, nil
}

// listenLanLinks listens for links on host ("": every interface), on the
// first free one of the link ports.
func listenLanLinks(host string) (net.Listener, error) {
	var last error
	for port := lanLinkPortFirst; port < lanLinkPortFirst+lanLinkPorts; port++ {
		listener, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
		if err == nil {
			return listener, nil
		}
		last = err
	}
	return nil, fmt.Errorf("link ports %d-%d: %w", lanLinkPortFirst, lanLinkPortFirst+lanLinkPorts-1, last)
}

// lanLinkPort tells whether a beacon may make this device dial port.
func lanLinkPort(port int) bool {
	return port >= lanLinkPortFirst && port < lanLinkPortFirst+lanLinkPorts
}

func (lan *lanDiscovery) stop() {
	lan.stopOnce.Do(func() {
		close(lan.quit)
		_ = lan.udp.Close()
		_ = lan.listener.Close()
		lan.done.Wait()
	})
}

func (lan *lanDiscovery) setInterval(seconds int) {
	lan.mu.Lock()
	lan.interval = lanIntervalFor(seconds)
	lan.mu.Unlock()
}

func (lan *lanDiscovery) interfaceNames() []string {
	lan.mu.Lock()
	defer lan.mu.Unlock()
	names := make([]string, 0, len(lan.interfaces))
	for _, ifi := range lan.interfaces {
		names = append(names, ifi.name)
	}
	return names
}

func (lan *lanDiscovery) beaconLoop() {
	defer lan.done.Done()
	for {
		lan.broadcast()
		lan.mu.Lock()
		interval := lan.interval
		lan.mu.Unlock()
		if lan.m.nearbySettings().looking && interval > lanNearbyLookInterval {
			interval = lanNearbyLookInterval
		}
		// Jitter, so devices that started together do not stay in step.
		wait := interval + time.Duration(rand.Int64N(int64(interval/4)+1))
		select {
		case <-lan.quit:
			return
		case <-lan.poke:
		case <-time.After(wait):
		}
	}
}

// wake sends a beacon now instead of at the next turn.
func (lan *lanDiscovery) wake() {
	if lan.poke == nil {
		return
	}
	select {
	case lan.poke <- struct{}{}:
	default:
	}
}

// beacon makes a beacon with a fresh salt and remembers the salt.
func (lan *lanDiscovery) beacon() []byte {
	now := time.Now()
	advert, err := buildLocalAdvert(lan.m.advertPeers(0, now), now, 0, cryptorand.Reader)
	if err != nil {
		return nil
	}
	nearby := lan.m.nearbySettings()
	var salt [4]byte
	copy(salt[:], advert[3:7])
	lan.mu.Lock()
	lan.ownSalts[salt] = now
	for s, at := range lan.ownSalts {
		if now.Sub(at) > lanOwnSaltMemory {
			delete(lan.ownSalts, s)
		}
	}
	lan.mu.Unlock()
	return lanBeacon(lanBeaconFields{
		advert:  advert,
		nearby:  nearby.shown(now),
		looking: nearby.looking,
		port:    lan.tcpPort,
	})
}

func (lan *lanDiscovery) broadcast() {
	interfaces := lanInterfaces()
	lan.mu.Lock()
	lan.interfaces = interfaces
	lan.mu.Unlock()
	// Shown only to people nearby, with no devices to link with: it answers
	// those who look around, but sends nothing by itself.
	if len(interfaces) == 0 || !lan.m.beaconsWanted() {
		return
	}
	packet := lan.beacon()
	if packet == nil {
		return
	}
	for _, ifi := range interfaces {
		for _, n := range ifi.nets {
			if target := lanBroadcast(n); target != nil {
				lan.send(packet, &net.UDPAddr{IP: target, Port: lanBeaconPort})
			}
		}
	}
}

// send writes one datagram.
func (lan *lanDiscovery) send(packet []byte, to *net.UDPAddr) {
	if lan.sent != nil {
		lan.sent(packet, to)
		return
	}
	if lan.udp != nil {
		_, _ = lan.udp.WriteToUDP(packet, to)
	}
}

func (lan *lanDiscovery) readLoop() {
	defer lan.done.Done()
	buf := make([]byte, lanMaxDatagram+1)
	for {
		n, src, err := lan.udp.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-lan.quit:
				return
			default:
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		lan.handleBeacon(append([]byte(nil), buf[:n]...), src)
	}
}

// admit applies the beacon rate limits; it tells whether to look at one
// from source.
func (lan *lanDiscovery) admit(source string, now time.Time) bool {
	lan.mu.Lock()
	defer lan.mu.Unlock()
	if now.Sub(lan.windowStart) >= time.Second {
		lan.windowStart = now
		lan.windowCount = 0
	}
	if lan.windowCount >= lanBeaconsPerSecond {
		return false
	}
	if last, ok := lan.lastSource[source]; ok && now.Sub(last) < lanSourceInterval {
		return false
	}
	lan.windowCount++
	lan.lastSource[source] = now
	pruneLanTimes(lan.lastSource, now, lanSourceInterval)
	return true
}

// pruneLanTimes drops the entries older than keep once times holds more
// than lanMaxRemembered: senders are UDP source addresses, which anyone on
// the network can make up, so the maps must not grow with them.
func pruneLanTimes(times map[string]time.Time, now time.Time, keep time.Duration) {
	if len(times) <= lanMaxRemembered {
		return
	}
	for key, at := range times {
		if now.Sub(at) >= keep {
			delete(times, key)
		}
	}
}

func (lan *lanDiscovery) isOwnSalt(advert []byte) bool {
	var salt [4]byte
	copy(salt[:], advert[3:7])
	lan.mu.Lock()
	defer lan.mu.Unlock()
	_, own := lan.ownSalts[salt]
	return own
}

// lanShouldDial: of two devices that recognise each other, the one with
// the lower mesh address connects.
func lanShouldDial(self string, candidates []*localPeer) bool {
	for _, peer := range candidates {
		if self < peer.address {
			return true
		}
	}
	return false
}

// lanBeaconFromNearby tells whether a beacon from src naming port may come
// from a Zen device on one of this device's local networks: every beacon
// goes out from the beacon port, and names no well-known port (a dial goes
// only to a link port, lanLinkPort; a device of an older version names a
// port the system gave it, and is still answered). Anything else would
// have this device answer hosts far away (a computer with a public
// address), or connect to a printer's or a router's port and write there.
func (lan *lanDiscovery) lanBeaconFromNearby(src *net.UDPAddr, port int) bool {
	return src != nil && src.IP.To4() != nil && src.Port == lanBeaconPort && port >= 1024 && lan.onLan(src.IP)
}

// onLan tells whether ip is on one of this device's local networks.
func (lan *lanDiscovery) onLan(ip net.IP) bool {
	lan.mu.Lock()
	defer lan.mu.Unlock()
	_, ok := lanInterfaceFor(lan.interfaces, ip)
	return ok
}

func (lan *lanDiscovery) handleBeacon(packet []byte, src *net.UDPAddr) {
	beacon, ok := parseLanBeacon(packet)
	if !ok || !lan.lanBeaconFromNearby(src, beacon.port) || lan.isOwnSalt(beacon.advert) {
		return
	}
	now := time.Now()
	source := src.IP.String()
	if !lan.admit(source, now) {
		return
	}
	nearby := lan.m.nearbySettings()
	if nearby.looking && beacon.nearby != nil {
		lan.rememberNearby(beacon.nearby, now)
	}
	if beacon.looking && nearby.shown(now) != nil {
		// Someone looks around: this device answers at once.
		lan.reply(src.IP, now)
	}
	matched := matchLocalAdvert(lan.m.peers(), beacon.advert, now)
	if len(matched) == 0 || !lan.firstHearing(beacon.advert, now) {
		return
	}
	var candidates []*localPeer
	for _, peer := range matched {
		if !lan.m.hasLink(peer.address) && lan.m.mayLink(peer.address) {
			candidates = append(candidates, peer)
		}
	}
	if len(candidates) == 0 {
		return
	}
	if lanShouldDial(lan.m.self, candidates) {
		lan.dial(src.IP, beacon.port, now)
		return
	}
	lan.reply(src.IP, now)
}

// firstHearing tells whether a recognised beacon's advert is heard for the
// first time, and remembers its salt (lanHeardSaltMemory). A beacon proves
// no key (it has no field to answer a challenge with), but a friend's real
// one reaches this device as its broadcast goes out: a copy played back
// from a made-up source comes after it and is dropped.
func (lan *lanDiscovery) firstHearing(advert []byte, now time.Time) bool {
	var salt [4]byte
	copy(salt[:], advert[3:7])
	lan.mu.Lock()
	defer lan.mu.Unlock()
	if lan.heardSalts == nil {
		lan.heardSalts = map[[4]byte]time.Time{}
	}
	if at, ok := lan.heardSalts[salt]; ok && now.Sub(at) < lanHeardSaltMemory {
		return false
	}
	lan.heardSalts[salt] = now
	if len(lan.heardSalts) > lanMaxRemembered {
		for s, at := range lan.heardSalts {
			if now.Sub(at) >= lanHeardSaltMemory {
				delete(lan.heardSalts, s)
			}
		}
	}
	return true
}

// reply sends a beacon straight back, so the other device can connect;
// only to an address on one of this device's local networks (the socket
// listens on every interface).
func (lan *lanDiscovery) reply(ip net.IP, now time.Time) {
	if !lan.onLan(ip) {
		return
	}
	key := ip.String()
	lan.mu.Lock()
	if last, ok := lan.lastReply[key]; ok && now.Sub(last) < lanReplyInterval {
		lan.mu.Unlock()
		return
	}
	lan.lastReply[key] = now
	pruneLanTimes(lan.lastReply, now, lanReplyInterval)
	lan.mu.Unlock()
	if packet := lan.beacon(); packet != nil {
		lan.send(packet, &net.UDPAddr{IP: ip, Port: lanBeaconPort})
	}
}

// lanStarts counts the handshakes one address started in the window that
// began at since.
type lanStarts struct {
	since time.Time
	count int
}

// takeHandshake takes one of the handshake slots for the address source:
// at most lanMaxHandshakes in all and lanMaxHandshakesPerSource for one
// address at once, and lanHandshakeStartsPerSource for one address in a
// window.
func (lan *lanDiscovery) takeHandshake(source string) bool {
	return lan.takeHandshakeAt(source, time.Now())
}

func (lan *lanDiscovery) takeHandshakeAt(source string, now time.Time) bool {
	lan.mu.Lock()
	defer lan.mu.Unlock()
	if lan.starts == nil {
		lan.starts = map[string]lanStarts{}
	}
	started := lan.starts[source]
	if now.Sub(started.since) >= lanHandshakeStartWindow {
		started = lanStarts{since: now}
	}
	if lan.handshakes >= lanMaxHandshakes || lan.perSource[source] >= lanMaxHandshakesPerSource ||
		started.count >= lanHandshakeStartsPerSource {
		return false
	}
	lan.handshakes++
	lan.perSource[source]++
	started.count++
	lan.starts[source] = started
	if len(lan.starts) > lanMaxRemembered {
		for key, entry := range lan.starts {
			if now.Sub(entry.since) >= lanHandshakeStartWindow {
				delete(lan.starts, key)
			}
		}
	}
	return true
}

func (lan *lanDiscovery) releaseHandshake(source string) {
	lan.mu.Lock()
	lan.handshakes--
	if lan.perSource[source] <= 1 {
		delete(lan.perSource, source)
	} else {
		lan.perSource[source]--
	}
	lan.mu.Unlock()
}

// dial connects to a device whose beacon this one recognised, at the
// beacon's source: only on a link port, on a local network, once per
// address per lanDialInterval and lanMaxDialsPerWindow in all.
func (lan *lanDiscovery) dial(ip net.IP, port int, now time.Time) {
	if !lanLinkPort(port) {
		return
	}
	key := ip.String()
	lan.mu.Lock()
	if last, ok := lan.lastDial[key]; ok && now.Sub(last) < lanDialInterval {
		lan.mu.Unlock()
		return
	}
	lan.lastDial[key] = now
	pruneLanTimes(lan.lastDial, now, lanDialInterval)
	ifi, onLan := lanInterfaceFor(lan.interfaces, ip)
	if onLan {
		if now.Sub(lan.dialWindowStart) >= lanDialWindow {
			lan.dialWindowStart, lan.dialWindowCount = now, 0
		}
		if lan.dialWindowCount >= lanMaxDialsPerWindow {
			onLan = false
		} else {
			lan.dialWindowCount++
		}
	}
	lan.mu.Unlock()
	if !onLan || !lan.takeHandshake(key) {
		return
	}
	go func() {
		defer lan.releaseHandshake(key)
		conn, err := net.DialTimeout("tcp", (&net.TCPAddr{IP: ip, Port: port}).String(), lanDialTimeout)
		if err != nil {
			return
		}
		if _, err := lan.m.handshakeAndAttach(conn, lanTransportFor(ifi.name), key); err != nil {
			lan.m.infof("local link to a LAN device not made: %v", err)
		}
	}()
}

func (lan *lanDiscovery) acceptLoop() {
	defer lan.done.Done()
	for {
		conn, err := lan.listener.Accept()
		if err != nil {
			select {
			case <-lan.quit:
				return
			default:
			}
			if errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(100 * time.Millisecond)
			continue
		}
		remote, _ := conn.RemoteAddr().(*net.TCPAddr)
		lan.mu.Lock()
		var ifi lanInterface
		onLan := false
		source := ""
		if remote != nil {
			ifi, onLan = lanInterfaceFor(lan.interfaces, remote.IP)
			source = remote.IP.String()
		}
		lan.mu.Unlock()
		// Only devices on the same local network, and only a few at once
		// (and from each of them).
		if !onLan || !lan.takeHandshake(source) {
			_ = conn.Close()
			continue
		}
		go func(conn net.Conn, transport string) {
			defer lan.releaseHandshake(source)
			if _, err := lan.m.handshakeAndAttach(conn, transport, source); err != nil {
				lan.m.infof("local link from a LAN device not made: %v", err)
			}
		}(conn, lanTransportFor(ifi.name))
	}
}
