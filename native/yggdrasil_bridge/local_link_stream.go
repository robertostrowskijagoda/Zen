package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"sort"
	"sync"
	"time"

	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/address"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// Any stream as a Yggdrasil peer. Yggdrasil dials its peers by URI, so a
// stream that passed the handshake gets a loopback listener of its own; the
// node calls it (tcp://127.0.0.1:port, the other device's key pinned and a
// password only the two ends of this link know) and the adapter pipes
// between that connection and the stream. A process on this device that
// grabbed the loopback connection first would only break the link: it
// cannot pass Yggdrasil's handshake for the pinned key with that password.
//
// Native transports (Bluetooth, Apple's Multipeer Connectivity) hand the
// bridge their stream the same way from the other end: they ask for an
// endpoint (YggOpenLocalLinkJson), connect to 127.0.0.1:port, write the
// 16-byte token first and then pump bytes both ways until either side
// closes. The handshake runs over that stream as over any other.
const (
	localStreamTokenSize  = 16
	localStreamOpenWindow = 60 * time.Second
	localStreamTokenWait  = 5 * time.Second
	// Wrong tokens tolerated on one endpoint before it closes.
	localStreamTokenTries = 4
	localAttachWait       = 10 * time.Second
	// Native endpoints waiting for their stream at once, in all and for one
	// transport (so that streams anyone nearby can open over Bluetooth
	// cannot take the slots of the others).
	localMaxOpenStreams             = 8
	localMaxOpenStreamsPerTransport = 6
)

// The node's side the links need (tests use a real core).
type localLinkCore interface {
	CallPeer(u *url.URL, sintf string) error
	GetPeers() []core.PeerInfo
	PublicKey() ed25519.PublicKey
}

// localLink is one live link.
type localLink struct {
	id        string
	transport string
	address   string
	// The other side's IP for a link over a network (LAN, Wi-Fi Direct);
	// empty over a native stream. The Windows Wi-Fi Direct group owner
	// keeps only clients that made a link (wifi_direct_bridge.cpp).
	remote string
	own    bool
	since  time.Time
	// The node's peering for it (no query), as GetPeers lists it.
	peerURI string
	conn    io.Closer
	once    sync.Once
	closed  chan struct{}
}

func (link *localLink) close() {
	link.once.Do(func() {
		close(link.closed)
		_ = link.conn.Close()
	})
}

// localStreamEndpoint is a native transport's way in, until its stream
// arrives.
type localStreamEndpoint struct {
	id        string
	transport string
	listener  net.Listener
	token     []byte
}

// localLinkManager keeps a node's local links: settings, the LAN, the
// links themselves and native endpoints.
type localLinkManager struct {
	core   localLinkCore
	self   string
	logger *log.Logger

	mu        sync.Mutex
	settings  localLinkSettings
	links     map[string]*localLink
	endpoints map[string]*localStreamEndpoint
	lan       *lanDiscovery
	lanError  string
	stopped   bool
}

func newLocalLinkManager(c localLinkCore, logger *log.Logger) *localLinkManager {
	key := c.PublicKey()
	return &localLinkManager{
		core:      c,
		self:      meshAddressForKey(key),
		logger:    logger,
		links:     make(map[string]*localLink),
		endpoints: make(map[string]*localStreamEndpoint),
	}
}

func (m *localLinkManager) warnf(format string, args ...any) {
	if m.logger != nil {
		m.logger.Warnf(format, args...)
	}
}

func (m *localLinkManager) infof(format string, args ...any) {
	if m.logger != nil {
		m.logger.Infof(format, args...)
	}
}

// peers is a copy of the devices this node may link with now.
func (m *localLinkManager) peers() []localPeer {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]localPeer(nil), m.settings.peers...)
}

// apply takes new settings: links to devices no longer listed close, the
// LAN starts or stops.
func (m *localLinkManager) apply(settings localLinkSettings) {
	m.mu.Lock()
	if m.stopped {
		m.mu.Unlock()
		return
	}
	// The link keys stay in RAM (never swapped out); the old ones are
	// overwritten (handshakes under way work on copies).
	old := m.settings.peers
	if len(old) > 0 && (len(settings.peers) == 0 || &old[0] != &settings.peers[0]) {
		releaseLocalPeers(old)
	}
	lockMemory(sliceBytes(settings.peers))
	m.settings = settings
	allowed := make(map[string]bool, len(settings.peers))
	for _, peer := range settings.peers {
		allowed[peer.address] = true
	}
	var gone []*localLink
	for id, link := range m.links {
		if !allowed[link.address] {
			gone = append(gone, link)
			delete(m.links, id)
		}
	}
	wantLan := settings.lan && len(settings.peers) > 0
	lan := m.lan
	var stopLan *lanDiscovery
	if !wantLan && lan != nil {
		stopLan, m.lan = lan, nil
	}
	startLan := wantLan && lan == nil
	m.mu.Unlock()

	for _, link := range gone {
		link.close()
	}
	if stopLan != nil {
		stopLan.stop()
	}
	if lan != nil && wantLan {
		lan.setInterval(settings.beaconSeconds)
	}
	if startLan {
		started, err := startLanDiscovery(m, settings.beaconSeconds)
		m.mu.Lock()
		defer m.mu.Unlock()
		if err != nil {
			m.lanError = err.Error()
			m.warnf("local links: LAN discovery unavailable: %v", err)
			return
		}
		m.lanError = ""
		if m.stopped || m.lan != nil || !(m.settings.lan && len(m.settings.peers) > 0) {
			go started.stop()
			return
		}
		m.lan = started
	}
}

// stop closes everything (the node stops).
func (m *localLinkManager) stop() {
	m.mu.Lock()
	m.stopped = true
	lan := m.lan
	m.lan = nil
	links := m.links
	m.links = map[string]*localLink{}
	endpoints := m.endpoints
	m.endpoints = map[string]*localStreamEndpoint{}
	m.mu.Unlock()
	if lan != nil {
		lan.stop()
	}
	for _, link := range links {
		link.close()
	}
	for _, endpoint := range endpoints {
		_ = endpoint.listener.Close()
	}
}

// hasLink tells whether a link to address is up.
func (m *localLinkManager) hasLink(address string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, link := range m.links {
		if link.address == address {
			return true
		}
	}
	return false
}

// handshakeAndAttach runs the handshake on conn and makes it a peering; it
// owns conn (closed on failure). remote is the other side's IP over a
// network ("" over a native stream).
func (m *localLinkManager) handshakeAndAttach(conn net.Conn, transport, remote string) (*localLink, error) {
	session, err := localLinkHandshake(conn, m.peers(), m.core.PublicKey())
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	link, err := m.attach(session, transport, remote)
	if err != nil {
		_ = session.conn.Close()
		return nil, err
	}
	return link, nil
}

// attach makes a session a Yggdrasil peering (see the top of this file).
func (m *localLinkManager) attach(session *localLinkSession, transport, remote string) (*localLink, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	port := listener.Addr().(*net.TCPAddr).Port
	link := &localLink{
		id:        randomLocalID(),
		transport: transport,
		address:   session.peer.address,
		remote:    remote,
		own:       session.peer.own,
		since:     time.Now(),
		peerURI:   fmt.Sprintf("tcp://127.0.0.1:%d", port),
		conn:      session.conn,
		closed:    make(chan struct{}),
	}
	m.mu.Lock()
	switch {
	case m.stopped:
		err = errors.New("local links stopped")
	case len(m.links) >= localLinkMaxLinks:
		err = errors.New("local links: too many links")
	default:
		for _, other := range m.links {
			if other.address == link.address {
				err = errors.New("local links: already linked with this device")
				break
			}
		}
	}
	if err == nil {
		m.links[link.id] = link
	}
	m.mu.Unlock()
	if err != nil {
		_ = listener.Close()
		return nil, err
	}

	go m.serveLink(link, listener, session.conn)
	uri, _ := url.Parse(fmt.Sprintf("%s?key=%s&password=%s", link.peerURI, hex.EncodeToString(session.remoteKey), session.password))
	if err := m.core.CallPeer(uri, ""); err != nil {
		m.remove(link)
		_ = listener.Close()
		return nil, err
	}
	m.infof("local link %s up over %s", link.id, transport)
	return link, nil
}

// serveLink pipes between the node's loopback connection and the stream
// until either ends.
func (m *localLinkManager) serveLink(link *localLink, listener net.Listener, stream net.Conn) {
	defer m.remove(link)
	accepted := make(chan net.Conn, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			close(accepted)
			return
		}
		accepted <- conn
	}()
	var node net.Conn
	select {
	case conn, ok := <-accepted:
		_ = listener.Close()
		if !ok {
			return
		}
		node = conn
	case <-time.After(localAttachWait):
		_ = listener.Close()
		return
	case <-link.closed:
		_ = listener.Close()
		return
	}
	done := make(chan struct{}, 2)
	go func() {
		_, _ = io.Copy(node, stream)
		done <- struct{}{}
	}()
	go func() {
		_, _ = io.Copy(stream, node)
		done <- struct{}{}
	}()
	select {
	case <-done:
	case <-link.closed:
	}
	_ = node.Close()
	link.close()
}

func (m *localLinkManager) remove(link *localLink) {
	link.close()
	m.mu.Lock()
	if m.links[link.id] == link {
		delete(m.links, link.id)
		m.infof("local link %s down", link.id)
	}
	m.mu.Unlock()
}

// openStream gives a native transport an endpoint for one stream.
func (m *localLinkManager) openStream(transport string) (*localStreamEndpoint, int, error) {
	if transport == "" || len(transport) > 32 {
		return nil, 0, fmt.Errorf("%w: transport", errLocalLinkBadInput)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, 0, err
	}
	token := make([]byte, localStreamTokenSize)
	if _, err := rand.Read(token); err != nil {
		_ = listener.Close()
		return nil, 0, err
	}
	endpoint := &localStreamEndpoint{
		id:        randomLocalID(),
		transport: transport,
		listener:  listener,
		token:     token,
	}
	m.mu.Lock()
	sameTransport := 0
	for _, other := range m.endpoints {
		if other.transport == transport {
			sameTransport++
		}
	}
	if m.stopped || len(m.endpoints) >= localMaxOpenStreams || sameTransport >= localMaxOpenStreamsPerTransport {
		m.mu.Unlock()
		_ = listener.Close()
		return nil, 0, errors.New("local links: no more stream endpoints")
	}
	m.endpoints[endpoint.id] = endpoint
	m.mu.Unlock()
	go m.serveEndpoint(endpoint)
	return endpoint, listener.Addr().(*net.TCPAddr).Port, nil
}

// serveEndpoint waits for the native transport's connection, checks its
// token and runs the handshake on it.
func (m *localLinkManager) serveEndpoint(endpoint *localStreamEndpoint) {
	defer func() {
		_ = endpoint.listener.Close()
		m.mu.Lock()
		delete(m.endpoints, endpoint.id)
		m.mu.Unlock()
	}()
	timer := time.AfterFunc(localStreamOpenWindow, func() { _ = endpoint.listener.Close() })
	defer timer.Stop()
	for try := 0; try < localStreamTokenTries; try++ {
		conn, err := endpoint.listener.Accept()
		if err != nil {
			return
		}
		got := make([]byte, localStreamTokenSize)
		_ = conn.SetReadDeadline(time.Now().Add(localStreamTokenWait))
		if _, err := io.ReadFull(conn, got); err != nil || subtle.ConstantTimeCompare(got, endpoint.token) != 1 {
			_ = conn.Close()
			continue
		}
		_ = conn.SetReadDeadline(time.Time{})
		_ = endpoint.listener.Close()
		if _, err := m.handshakeAndAttach(conn, endpoint.transport, ""); err != nil {
			m.infof("local link over %s not made: %v", endpoint.transport, err)
		}
		return
	}
}

// closeLink ends a link, or a native endpoint still waiting, by id.
func (m *localLinkManager) closeLink(id string) bool {
	m.mu.Lock()
	link := m.links[id]
	endpoint := m.endpoints[id]
	m.mu.Unlock()
	if link != nil {
		m.remove(link)
	}
	if endpoint != nil {
		_ = endpoint.listener.Close()
	}
	return link != nil || endpoint != nil
}

// status is what the app shows: the LAN and the live links.
func (m *localLinkManager) status() map[string]any {
	up := map[string]bool{}
	for _, peer := range m.core.GetPeers() {
		if peer.Up {
			up[peer.URI] = true
		}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	links := make([]map[string]any, 0, len(m.links))
	for _, link := range m.links {
		links = append(links, map[string]any{
			"id":        link.id,
			"transport": link.transport,
			"address":   link.address,
			"remote":    link.remote,
			"own":       link.own,
			"since":     link.since.UnixMilli(),
			"up":        up[link.peerURI],
		})
	}
	sort.Slice(links, func(i, j int) bool {
		return links[i]["since"].(int64) < links[j]["since"].(int64)
	})
	lan := map[string]any{
		"on":         m.settings.lan,
		"running":    m.lan != nil,
		"interfaces": []string{},
	}
	if m.lan != nil {
		lan["interfaces"] = m.lan.interfaceNames()
	}
	if m.lanError != "" {
		lan["error"] = m.lanError
	}
	return map[string]any{
		"lan":   lan,
		"peers": len(m.settings.peers),
		"links": links,
	}
}

// advert is an advert of this node's devices for a native transport, with
// a filter of bloomBytes bytes (0: sized to them).
func (m *localLinkManager) advert(bloomBytes int) ([]byte, error) {
	return buildLocalAdvert(m.peers(), time.Now(), bloomBytes, rand.Reader)
}

// matches tells whether an advert may come from a device this node links
// with, and not one linked already.
func (m *localLinkManager) matches(advert []byte) bool {
	for _, peer := range matchLocalAdvert(m.peers(), advert, time.Now()) {
		if !m.hasLink(peer.address) {
			return true
		}
	}
	return false
}

func meshAddressForKey(key ed25519.PublicKey) string {
	addr := address.AddrForKey(key)
	if addr == nil {
		return ""
	}
	return net.IP(addr[:]).String()
}
