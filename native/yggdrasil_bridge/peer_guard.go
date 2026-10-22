package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Limits for a computer that is a bridge ("przeciążenie mostu"):
// strangers peer with it, so one of them (or a botnet) must not take every
// connection slot, saturate the home uplink or burn a metered plan.
//
// Yggdrasil has no such limits, so the public peering port is a small
// proxy (peerListenGuard): it accepts the connection, applies the limits by
// the peer's address and pipes the bytes, still TLS end to end, to the
// node's real listener on loopback.
type peerGuardLimits struct {
	// Open connections from one address (IPv4) or one /64 (IPv6).
	maxConnsPerSource int
	// Open inbound connections in all.
	maxConnsTotal int
	// Sustained transfer per source, both directions together, and the
	// burst allowed above it.
	bytesPerSecondPerSource float64
	burstBytesPerSource     float64
	// Transfer per source and in all within a rolling day.
	dailyBytesPerSource int64
	dailyBytesTotal     int64
	// Sources remembered (for their daily budget) at once.
	maxTrackedSources int
}

var defaultPeerGuardLimits = peerGuardLimits{
	maxConnsPerSource:       4,
	maxConnsTotal:           128,
	bytesPerSecondPerSource: 1 << 20, // 1 MiB/s: plenty for a video call
	burstBytesPerSource:     4 << 20,
	dailyBytesPerSource:     2 << 30,
	dailyBytesTotal:         32 << 30,
	maxTrackedSources:       4096,
}

const (
	peerGuardDialTimeout = 5 * time.Second
	peerGuardDay         = 24 * time.Hour
	peerGuardCopyBuffer  = 32 * 1024
)

var errPeerGuardBudget = errors.New("bridge transfer budget used up")

type peerGuardSource struct {
	conns      int
	tokens     float64
	refilledAt time.Time
	dayStart   time.Time
	dayBytes   int64
}

type peerListenGuard struct {
	listener net.Listener
	backend  string
	limits   peerGuardLimits

	mu         sync.Mutex
	sources    map[string]*peerGuardSource
	totalConns int
	dayStart   time.Time
	dayBytes   int64
	open       map[net.Conn]struct{}
	closed     bool
	// Takes no peers for now (the computer runs on battery).
	paused bool
	// Connections refused by a limit so far.
	refusedConn int

	// Replaceable in tests.
	now   func() time.Time
	sleep func(time.Duration)
	dial  func(ctx context.Context, network, address string) (net.Conn, error)
	// Whether a peer at this address may connect at all.
	allowIP func(ip net.IP) bool
}

func newPeerListenGuard(listener net.Listener, backend string, limits peerGuardLimits) *peerListenGuard {
	dialer := &net.Dialer{Timeout: peerGuardDialTimeout}
	return &peerListenGuard{
		listener: listener,
		backend:  backend,
		limits:   limits,
		sources:  make(map[string]*peerGuardSource),
		open:     make(map[net.Conn]struct{}),
		now:      time.Now,
		sleep:    time.Sleep,
		dial:     dialer.DialContext,
		allowIP:  func(net.IP) bool { return true },
	}
}

// peerGuardSourceKey groups addresses one party is likely to control: an
// IPv4 address, or an IPv6 /64 (what one home or one server gets).
func peerGuardSourceKey(ip net.IP) string {
	if v4 := ip.To4(); v4 != nil {
		return v4.String()
	}
	masked := ip.Mask(net.CIDRMask(64, 128))
	if masked == nil {
		return ip.String()
	}
	return masked.String() + "/64"
}

func (guard *peerListenGuard) serve() {
	for {
		conn, err := guard.listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			guard.mu.Lock()
			closed := guard.closed
			guard.mu.Unlock()
			if closed {
				return
			}
			// Out of file descriptors and the like: do not spin.
			guard.sleep(50 * time.Millisecond)
			continue
		}
		go guard.handle(conn)
	}
}

func remoteIPOf(conn net.Conn) net.IP {
	switch address := conn.RemoteAddr().(type) {
	case *net.TCPAddr:
		return address.IP
	default:
		host, _, err := net.SplitHostPort(conn.RemoteAddr().String())
		if err != nil {
			return nil
		}
		return net.ParseIP(host)
	}
}

// admit takes a connection slot for key, or refuses it.
func (guard *peerListenGuard) admit(key string) bool {
	guard.mu.Lock()
	defer guard.mu.Unlock()
	if guard.closed || guard.paused {
		return false
	}
	now := guard.now()
	guard.rollDayLocked(now)
	if guard.totalConns >= guard.limits.maxConnsTotal || guard.dayBytes >= guard.limits.dailyBytesTotal {
		guard.refusedConn++
		return false
	}
	source := guard.sources[key]
	if source == nil {
		if len(guard.sources) >= guard.limits.maxTrackedSources {
			guard.forgetIdleSourcesLocked(now)
		}
		if len(guard.sources) >= guard.limits.maxTrackedSources {
			guard.refusedConn++
			return false
		}
		source = &peerGuardSource{
			tokens:     guard.limits.burstBytesPerSource,
			refilledAt: now,
			dayStart:   now,
		}
		guard.sources[key] = source
	}
	if now.Sub(source.dayStart) >= peerGuardDay {
		source.dayStart = now
		source.dayBytes = 0
	}
	if source.conns >= guard.limits.maxConnsPerSource || source.dayBytes >= guard.limits.dailyBytesPerSource {
		guard.refusedConn++
		return false
	}
	source.conns++
	guard.totalConns++
	return true
}

func (guard *peerListenGuard) release(key string) {
	guard.mu.Lock()
	defer guard.mu.Unlock()
	guard.totalConns--
	if source := guard.sources[key]; source != nil {
		source.conns--
	}
}

func (guard *peerListenGuard) rollDayLocked(now time.Time) {
	if guard.dayStart.IsZero() || now.Sub(guard.dayStart) >= peerGuardDay {
		guard.dayStart = now
		guard.dayBytes = 0
	}
}

// forgetIdleSourcesLocked drops sources with no connection whose day is
// over: there is nothing left to remember about them.
func (guard *peerListenGuard) forgetIdleSourcesLocked(now time.Time) {
	for key, source := range guard.sources {
		if source.conns == 0 && now.Sub(source.dayStart) >= peerGuardDay {
			delete(guard.sources, key)
		}
	}
}

// charge counts count bytes of key's traffic. It returns how long to wait
// to stay within the source's rate, or errPeerGuardBudget when a daily
// budget is used up (the connection is then closed).
func (guard *peerListenGuard) charge(key string, count int) (time.Duration, error) {
	guard.mu.Lock()
	defer guard.mu.Unlock()
	now := guard.now()
	guard.rollDayLocked(now)
	guard.dayBytes += int64(count)
	source := guard.sources[key]
	if source == nil {
		return 0, nil
	}
	if now.Sub(source.dayStart) >= peerGuardDay {
		source.dayStart = now
		source.dayBytes = 0
	}
	source.dayBytes += int64(count)
	if source.dayBytes > guard.limits.dailyBytesPerSource || guard.dayBytes > guard.limits.dailyBytesTotal {
		return 0, errPeerGuardBudget
	}
	elapsed := now.Sub(source.refilledAt).Seconds()
	if elapsed > 0 {
		source.tokens += elapsed * guard.limits.bytesPerSecondPerSource
		if source.tokens > guard.limits.burstBytesPerSource {
			source.tokens = guard.limits.burstBytesPerSource
		}
	}
	source.refilledAt = now
	source.tokens -= float64(count)
	if source.tokens >= 0 {
		return 0, nil
	}
	return time.Duration(-source.tokens / guard.limits.bytesPerSecondPerSource * float64(time.Second)), nil
}

func (guard *peerListenGuard) track(conn net.Conn) bool {
	guard.mu.Lock()
	defer guard.mu.Unlock()
	if guard.closed {
		return false
	}
	guard.open[conn] = struct{}{}
	return true
}

func (guard *peerListenGuard) untrack(conn net.Conn) {
	guard.mu.Lock()
	defer guard.mu.Unlock()
	delete(guard.open, conn)
}

func (guard *peerListenGuard) handle(conn net.Conn) {
	ip := remoteIPOf(conn)
	if ip == nil || !guard.allowIP(ip) {
		_ = conn.Close()
		return
	}
	key := peerGuardSourceKey(ip)
	if !guard.admit(key) {
		_ = conn.Close()
		return
	}
	defer guard.release(key)

	ctx, cancel := context.WithTimeout(context.Background(), peerGuardDialTimeout)
	backend, err := guard.dial(ctx, "tcp", guard.backend)
	cancel()
	if err != nil {
		_ = conn.Close()
		return
	}
	if !guard.track(conn) {
		_ = conn.Close()
		_ = backend.Close()
		return
	}
	defer guard.untrack(conn)
	if !guard.track(backend) {
		_ = conn.Close()
		_ = backend.Close()
		return
	}
	defer guard.untrack(backend)

	done := make(chan struct{}, 2)
	pipe := func(dst, src net.Conn) {
		guard.copyMetered(dst, src, key)
		// Either side ending ends the link.
		_ = dst.Close()
		_ = src.Close()
		done <- struct{}{}
	}
	go pipe(backend, conn)
	go pipe(conn, backend)
	<-done
	<-done
}

func (guard *peerListenGuard) copyMetered(dst io.Writer, src io.Reader, key string) {
	buffer := make([]byte, peerGuardCopyBuffer)
	for {
		count, err := src.Read(buffer)
		if count > 0 {
			wait, budgetErr := guard.charge(key, count)
			if budgetErr != nil {
				return
			}
			if wait > 0 {
				guard.sleep(wait)
			}
			if _, writeErr := dst.Write(buffer[:count]); writeErr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

// setPaused stops taking peers and drops the ones it carries (paused), or
// takes them again. The port stays open, so nothing has to be bound again.
func (guard *peerListenGuard) setPaused(paused bool) {
	guard.mu.Lock()
	if guard.closed || guard.paused == paused {
		guard.mu.Unlock()
		return
	}
	guard.paused = paused
	var open []net.Conn
	if paused {
		open = make([]net.Conn, 0, len(guard.open))
		for conn := range guard.open {
			open = append(open, conn)
		}
	}
	guard.mu.Unlock()
	for _, conn := range open {
		_ = conn.Close()
	}
}

// close stops accepting and drops every proxied connection.
func (guard *peerListenGuard) close() {
	guard.mu.Lock()
	if guard.closed {
		guard.mu.Unlock()
		return
	}
	guard.closed = true
	open := make([]net.Conn, 0, len(guard.open))
	for conn := range guard.open {
		open = append(open, conn)
	}
	guard.mu.Unlock()
	_ = guard.listener.Close()
	for _, conn := range open {
		_ = conn.Close()
	}
}

// guardedListenAddress turns a stream listen URI ("tls://[::]:32913")
// into the address to listen on publicly and the loopback URI the node
// itself should listen on instead. ok=false for transports the guard does
// not proxy (they are passed to the node unchanged).
func guardedListenAddress(listenURI string) (public string, scheme string, ok bool) {
	parsed, err := url.Parse(strings.TrimSpace(listenURI))
	if err != nil {
		return "", "", false
	}
	switch strings.ToLower(parsed.Scheme) {
	case "tls", "tcp":
	default:
		return "", "", false
	}
	if parsed.Port() == "" || parsed.RawQuery != "" {
		// Options in the query (passwords, SNI) are left to Yggdrasil as
		// they are; the default desktop listener has none.
		return "", "", false
	}
	if _, err := strconv.Atoi(parsed.Port()); err != nil {
		return "", "", false
	}
	return parsed.Host, strings.ToLower(parsed.Scheme), true
}

// startPeerListenGuard listens on listenURI's address and returns the
// guard, already serving, plus the loopback URI the node must listen on.
func startPeerListenGuard(listenURI string, limits peerGuardLimits, allowIP func(net.IP) bool) (*peerListenGuard, string, error) {
	public, scheme, ok := guardedListenAddress(listenURI)
	if !ok {
		return nil, "", errors.New("listen address not guarded")
	}
	listener, err := net.Listen("tcp", public)
	if err != nil {
		return nil, "", err
	}
	// A free loopback port for the node's own listener.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		_ = listener.Close()
		return nil, "", err
	}
	backend := probe.Addr().String()
	_ = probe.Close()
	guard := newPeerListenGuard(listener, backend, limits)
	if allowIP != nil {
		guard.allowIP = allowIP
	}
	go guard.serve()
	return guard, scheme + "://" + backend, nil
}
