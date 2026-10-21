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
// random salt every time) and the TCP port it takes links on. A device that
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
	lanBeaconPort            = 39319
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
	lanMaxDatagram            = 1472
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

// lanBeacon is an advert followed by the TCP port links go to.
func lanBeacon(advert []byte, port int) []byte {
	return binary.BigEndian.AppendUint16(append([]byte(nil), advert...), uint16(port))
}

func parseLanBeacon(packet []byte) (advert []byte, port int, ok bool) {
	if len(packet) < localLinkAdvertHeader+localLinkMinBloomBytes+2 || len(packet) > lanMaxDatagram {
		return nil, 0, false
	}
	port = int(binary.BigEndian.Uint16(packet[len(packet)-2:]))
	if port == 0 {
		return nil, 0, false
	}
	return packet[:len(packet)-2], port, true
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
	windowStart time.Time
	windowCount int
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
	listener, err := net.Listen("tcp", ":0")
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
	}
	lan.done.Add(3)
	go lan.beaconLoop()
	go lan.readLoop()
	go lan.acceptLoop()
	return lan, nil
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
		// Jitter, so devices that started together do not stay in step.
		wait := interval + time.Duration(rand.Int64N(int64(interval/4)+1))
		select {
		case <-lan.quit:
			return
		case <-time.After(wait):
		}
	}
}

// beacon makes a beacon with a fresh salt and remembers the salt.
func (lan *lanDiscovery) beacon() []byte {
	advert, err := buildLocalAdvert(lan.m.peers(), time.Now(), 0, cryptorand.Reader)
	if err != nil {
		return nil
	}
	var salt [4]byte
	copy(salt[:], advert[3:7])
	now := time.Now()
	lan.mu.Lock()
	lan.ownSalts[salt] = now
	for s, at := range lan.ownSalts {
		if now.Sub(at) > lanOwnSaltMemory {
			delete(lan.ownSalts, s)
		}
	}
	lan.mu.Unlock()
	return lanBeacon(advert, lan.tcpPort)
}

func (lan *lanDiscovery) broadcast() {
	interfaces := lanInterfaces()
	lan.mu.Lock()
	lan.interfaces = interfaces
	lan.mu.Unlock()
	if len(interfaces) == 0 {
		return
	}
	packet := lan.beacon()
	if packet == nil {
		return
	}
	for _, ifi := range interfaces {
		for _, n := range ifi.nets {
			if target := lanBroadcast(n); target != nil {
				_, _ = lan.udp.WriteToUDP(packet, &net.UDPAddr{IP: target, Port: lanBeaconPort})
			}
		}
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

func (lan *lanDiscovery) handleBeacon(packet []byte, src *net.UDPAddr) {
	advert, port, ok := parseLanBeacon(packet)
	if !ok || src == nil || src.IP.To4() == nil || lan.isOwnSalt(advert) {
		return
	}
	now := time.Now()
	source := src.IP.String()
	if !lan.admit(source, now) {
		return
	}
	var candidates []*localPeer
	for _, peer := range matchLocalAdvert(lan.m.peers(), advert, now) {
		if !lan.m.hasLink(peer.address) {
			candidates = append(candidates, peer)
		}
	}
	if len(candidates) == 0 {
		return
	}
	if lanShouldDial(lan.m.self, candidates) {
		lan.dial(src.IP, port, now)
		return
	}
	lan.reply(src.IP, now)
}

// reply sends a beacon straight back, so the other device can connect.
func (lan *lanDiscovery) reply(ip net.IP, now time.Time) {
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
		_, _ = lan.udp.WriteToUDP(packet, &net.UDPAddr{IP: ip, Port: lanBeaconPort})
	}
}

// takeHandshake takes one of the handshake slots for the address source:
// at most lanMaxHandshakes in all and lanMaxHandshakesPerSource for one
// address.
func (lan *lanDiscovery) takeHandshake(source string) bool {
	lan.mu.Lock()
	defer lan.mu.Unlock()
	if lan.handshakes >= lanMaxHandshakes || lan.perSource[source] >= lanMaxHandshakesPerSource {
		return false
	}
	lan.handshakes++
	lan.perSource[source]++
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

func (lan *lanDiscovery) dial(ip net.IP, port int, now time.Time) {
	key := ip.String()
	lan.mu.Lock()
	if last, ok := lan.lastDial[key]; ok && now.Sub(last) < lanDialInterval {
		lan.mu.Unlock()
		return
	}
	lan.lastDial[key] = now
	pruneLanTimes(lan.lastDial, now, lanDialInterval)
	ifi, onLan := lanInterfaceFor(lan.interfaces, ip)
	lan.mu.Unlock()
	if !onLan || !lan.takeHandshake(key) {
		return
	}
	go func() {
		defer lan.releaseHandshake(key)
		conn, err := net.DialTimeout("tcp", (&net.TCPAddr{IP: ip, Port: port}).String(), 5*time.Second)
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
