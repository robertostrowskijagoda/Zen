package main

import (
	"context"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Name resolution for the Go side where the platform gives Go no resolver
// configuration (Android: no /etc/resolv.conf, STAN S38).
//
// Every query first goes to the system resolver (getaddrinfo, which also
// honours Android's "Private DNS" setting). Only when that does not work
// does it go to a list of upstream servers, by default public resolvers
// over DNS-over-TLS (port 853, certificate checked), so a network that
// blocks or watches plain DNS sees neither the names nor fake answers. The
// list can be replaced through YggSetDnsServersJson.
//
// Go's resolver (PreferGo) is pointed at dnsBridgeConn, an in-memory
// "DNS server" that answers each query this way.

type dnsUpstream struct {
	// "tls" (DNS over TLS), "tcp" or "udp".
	network string
	// IP literal and port.
	address string
	// Name the TLS certificate must carry (the IP itself when empty).
	serverName string
}

var defaultDNSUpstreams = []dnsUpstream{
	{network: "tls", address: "9.9.9.9:853", serverName: "dns.quad9.net"},
	{network: "tls", address: "1.1.1.1:853", serverName: "one.one.one.one"},
	{network: "tls", address: "8.8.8.8:853", serverName: "dns.google"},
	{network: "tls", address: "[2620:fe::fe]:853", serverName: "dns.quad9.net"},
	{network: "tls", address: "[2606:4700:4700::1111]:853", serverName: "one.one.one.one"},
	{network: "tls", address: "149.112.112.112:853", serverName: "dns.quad9.net"},
	{network: "tls", address: "1.0.0.1:853", serverName: "one.one.one.one"},
	{network: "tls", address: "8.8.4.4:853", serverName: "dns.google"},
}

const (
	dnsSystemTimeout   = 2 * time.Second
	dnsUpstreamTimeout = 4 * time.Second
	// After the system resolver fails, queries skip it for this long.
	dnsSystemCooldown = 30 * time.Second
	dnsAnswerTTL      = 60
	maxDNSUpstreams   = 16

	dnsTypeA    = 1
	dnsTypeAAAA = 28
	dnsClassIN  = 1

	dnsRCodeSuccess  = 0
	dnsRCodeFormErr  = 1
	dnsRCodeServFail = 2
)

// parseDNSUpstream reads "tls://9.9.9.9:853#dns.quad9.net",
// "tls://1.1.1.1" (port 853, certificate for the IP), "udp://192.168.1.1"
// (port 53) or "tcp://[2001:db8::1]:53". The host must be an IP address:
// a resolver cannot be found by name.
func parseDNSUpstream(spec string) (dnsUpstream, error) {
	spec = strings.TrimSpace(spec)
	serverName := ""
	if hash := strings.IndexByte(spec, '#'); hash >= 0 {
		serverName = strings.TrimSpace(spec[hash+1:])
		spec = spec[:hash]
	}
	parsed, err := url.Parse(spec)
	if err != nil {
		return dnsUpstream{}, err
	}
	network := strings.ToLower(parsed.Scheme)
	defaultPort := "53"
	switch network {
	case "tls":
		defaultPort = "853"
	case "udp", "tcp":
		if serverName != "" {
			return dnsUpstream{}, fmt.Errorf("dns server %q: a name is only used with tls://", spec)
		}
	default:
		return dnsUpstream{}, fmt.Errorf("dns server %q: use tls://, tcp:// or udp://", spec)
	}
	host := parsed.Hostname()
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return dnsUpstream{}, fmt.Errorf("dns server %q: the host must be an IP address", spec)
	}
	port := parsed.Port()
	if port == "" {
		port = defaultPort
	}
	if parsed.Path != "" && parsed.Path != "/" {
		return dnsUpstream{}, fmt.Errorf("dns server %q: unexpected path", spec)
	}
	return dnsUpstream{
		network:    network,
		address:    net.JoinHostPort(ip.String(), port),
		serverName: serverName,
	}, nil
}

type dnsFallbackResolver struct {
	mu                sync.Mutex
	upstreams         []dnsUpstream
	useSystem         bool
	systemFailedUntil time.Time

	// Replaceable in tests.
	now          func() time.Time
	systemLookup func(ctx context.Context, network, host string) ([]netip.Addr, error)
	exchange     func(ctx context.Context, upstream dnsUpstream, query []byte) ([]byte, error)
}

func newDNSFallbackResolver() *dnsFallbackResolver {
	system := &net.Resolver{PreferGo: false}
	return &dnsFallbackResolver{
		upstreams:    append([]dnsUpstream(nil), defaultDNSUpstreams...),
		useSystem:    true,
		now:          time.Now,
		systemLookup: system.LookupNetIP,
		exchange:     exchangeDNSUpstream,
	}
}

var bridgeDNS = newDNSFallbackResolver()

// configure replaces the upstream list (empty: the defaults) and whether
// the system resolver is asked first.
func (resolver *dnsFallbackResolver) configure(specs []string, useSystem bool) error {
	if len(specs) > maxDNSUpstreams {
		return fmt.Errorf("at most %d dns servers", maxDNSUpstreams)
	}
	upstreams := make([]dnsUpstream, 0, len(specs))
	for _, spec := range specs {
		upstream, err := parseDNSUpstream(spec)
		if err != nil {
			return err
		}
		upstreams = append(upstreams, upstream)
	}
	if len(upstreams) == 0 {
		upstreams = append(upstreams, defaultDNSUpstreams...)
	}
	resolver.mu.Lock()
	defer resolver.mu.Unlock()
	resolver.upstreams = upstreams
	resolver.useSystem = useSystem
	resolver.systemFailedUntil = time.Time{}
	return nil
}

// configureJSON takes either a list of server specs or
// {"servers": [...], "useSystem": true}.
func (resolver *dnsFallbackResolver) configureJSON(payload string) error {
	trimmed := strings.TrimSpace(payload)
	if trimmed == "" || trimmed == "null" {
		return resolver.configure(nil, true)
	}
	if strings.HasPrefix(trimmed, "[") {
		var specs []string
		if err := json.Unmarshal([]byte(trimmed), &specs); err != nil {
			return err
		}
		return resolver.configure(specs, true)
	}
	var request struct {
		Servers   []string `json:"servers"`
		UseSystem *bool    `json:"useSystem"`
	}
	if err := json.Unmarshal([]byte(trimmed), &request); err != nil {
		return err
	}
	useSystem := true
	if request.UseSystem != nil {
		useSystem = *request.UseSystem
	}
	return resolver.configure(request.Servers, useSystem)
}

// install makes Go's default resolver (used by Yggdrasil to reach peers
// given by name) answer through this resolver.
func (resolver *dnsFallbackResolver) install() {
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return &dnsBridgeConn{resolver: resolver}, nil
		},
	}
}

// answer resolves one DNS query (a whole message) into a response.
func (resolver *dnsFallbackResolver) answer(ctx context.Context, query []byte) []byte {
	question, ok := parseDNSQuestion(query)
	if !ok {
		return dnsErrorResponse(query, dnsRCodeFormErr)
	}
	if question.class == dnsClassIN && (question.kind == dnsTypeA || question.kind == dnsTypeAAAA) {
		if response, ok := resolver.answerFromSystem(ctx, query, question); ok {
			return response
		}
	}
	resolver.mu.Lock()
	upstreams := append([]dnsUpstream(nil), resolver.upstreams...)
	resolver.mu.Unlock()
	for _, upstream := range upstreams {
		if ctx.Err() != nil {
			break
		}
		response, err := resolver.exchange(ctx, upstream, query)
		if err == nil && len(response) >= 12 && response[0] == query[0] && response[1] == query[1] {
			return response
		}
	}
	return dnsErrorResponse(query, dnsRCodeServFail)
}

func (resolver *dnsFallbackResolver) answerFromSystem(ctx context.Context, query []byte, question dnsQuestion) ([]byte, bool) {
	resolver.mu.Lock()
	skip := !resolver.useSystem || resolver.now().Before(resolver.systemFailedUntil)
	resolver.mu.Unlock()
	if skip {
		return nil, false
	}
	network := "ip4"
	if question.kind == dnsTypeAAAA {
		network = "ip6"
	}
	lookupCtx, cancel := context.WithTimeout(ctx, dnsSystemTimeout)
	defer cancel()
	addrs, err := resolver.systemLookup(lookupCtx, network, strings.TrimSuffix(question.name, "."))
	if err != nil {
		var dnsErr *net.DNSError
		if errors.As(err, &dnsErr) && dnsErr.IsNotFound {
			// The system resolver works and says there is no such
			// record: answer that, without asking anyone else.
			return dnsAddressResponse(query, question, nil), true
		}
		resolver.mu.Lock()
		resolver.systemFailedUntil = resolver.now().Add(dnsSystemCooldown)
		resolver.mu.Unlock()
		return nil, false
	}
	return dnsAddressResponse(query, question, addrs), true
}

type dnsQuestion struct {
	name  string
	kind  uint16
	class uint16
	// End offset of the question in the query.
	end int
}

// parseDNSQuestion reads the single question of a standard query.
func parseDNSQuestion(query []byte) (dnsQuestion, bool) {
	if len(query) < 12 {
		return dnsQuestion{}, false
	}
	flags := binary.BigEndian.Uint16(query[2:4])
	if flags&0x8000 != 0 || (flags>>11)&0xF != 0 || binary.BigEndian.Uint16(query[4:6]) != 1 {
		return dnsQuestion{}, false
	}
	offset := 12
	var name strings.Builder
	for {
		if offset >= len(query) {
			return dnsQuestion{}, false
		}
		length := int(query[offset])
		offset++
		if length == 0 {
			break
		}
		if length > 63 || offset+length > len(query) || name.Len()+length+1 > 254 {
			return dnsQuestion{}, false
		}
		name.Write(query[offset : offset+length])
		name.WriteByte('.')
		offset += length
	}
	if offset+4 > len(query) {
		return dnsQuestion{}, false
	}
	text := name.String()
	if text == "" {
		text = "."
	}
	return dnsQuestion{
		name:  text,
		kind:  binary.BigEndian.Uint16(query[offset : offset+2]),
		class: binary.BigEndian.Uint16(query[offset+2 : offset+4]),
		end:   offset + 4,
	}, true
}

func dnsResponseHeader(query []byte, rcode int, answers int) []byte {
	header := make([]byte, 12)
	copy(header[0:2], query[0:2])
	flags := uint16(0x8000) | uint16(0x0080) | uint16(rcode&0xF)
	if len(query) >= 4 {
		flags |= binary.BigEndian.Uint16(query[2:4]) & 0x0100 // RD
	}
	binary.BigEndian.PutUint16(header[2:4], flags)
	binary.BigEndian.PutUint16(header[6:8], uint16(answers))
	return header
}

// dnsAddressResponse answers question with addrs of its type (none: an
// empty, successful answer).
func dnsAddressResponse(query []byte, question dnsQuestion, addrs []netip.Addr) []byte {
	var records [][]byte
	for _, addr := range addrs {
		addr = addr.Unmap()
		var data []byte
		switch {
		case question.kind == dnsTypeA && addr.Is4():
			raw := addr.As4()
			data = raw[:]
		case question.kind == dnsTypeAAAA && addr.Is6():
			raw := addr.As16()
			data = raw[:]
		default:
			continue
		}
		record := make([]byte, 12, 12+len(data))
		binary.BigEndian.PutUint16(record[0:2], 0xC00C) // the question's name
		binary.BigEndian.PutUint16(record[2:4], question.kind)
		binary.BigEndian.PutUint16(record[4:6], dnsClassIN)
		binary.BigEndian.PutUint32(record[6:10], dnsAnswerTTL)
		binary.BigEndian.PutUint16(record[10:12], uint16(len(data)))
		records = append(records, append(record, data...))
	}
	response := dnsResponseHeader(query, dnsRCodeSuccess, len(records))
	binary.BigEndian.PutUint16(response[4:6], 1)
	response = append(response, query[12:question.end]...)
	for _, record := range records {
		response = append(response, record...)
	}
	return response
}

func dnsErrorResponse(query []byte, rcode int) []byte {
	if len(query) < 12 {
		return dnsResponseHeader(append(query, make([]byte, 12)...), rcode, 0)
	}
	if question, ok := parseDNSQuestion(query); ok {
		response := dnsResponseHeader(query, rcode, 0)
		binary.BigEndian.PutUint16(response[4:6], 1)
		return append(response, query[12:question.end]...)
	}
	return dnsResponseHeader(query, rcode, 0)
}

// exchangeDNSUpstream sends query to upstream and returns its response.
func exchangeDNSUpstream(ctx context.Context, upstream dnsUpstream, query []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, dnsUpstreamTimeout)
	defer cancel()
	dialer := &net.Dialer{}
	switch upstream.network {
	case "udp":
		conn, err := dialer.DialContext(ctx, "udp", upstream.address)
		if err != nil {
			return nil, err
		}
		defer conn.Close()
		if deadline, ok := ctx.Deadline(); ok {
			_ = conn.SetDeadline(deadline)
		}
		if _, err := conn.Write(query); err != nil {
			return nil, err
		}
		buffer := make([]byte, 65535)
		for {
			count, err := conn.Read(buffer)
			if err != nil {
				return nil, err
			}
			if count >= 12 && buffer[0] == query[0] && buffer[1] == query[1] {
				return append([]byte(nil), buffer[:count]...), nil
			}
		}
	case "tcp", "tls":
		raw, err := dialer.DialContext(ctx, "tcp", upstream.address)
		if err != nil {
			return nil, err
		}
		conn := raw
		if upstream.network == "tls" {
			serverName := upstream.serverName
			if serverName == "" {
				serverName, _, _ = net.SplitHostPort(upstream.address)
			}
			tlsConn := tls.Client(raw, &tls.Config{
				ServerName: serverName,
				MinVersion: tls.VersionTLS12,
			})
			if err := tlsConn.HandshakeContext(ctx); err != nil {
				_ = raw.Close()
				return nil, err
			}
			conn = tlsConn
		}
		defer conn.Close()
		if deadline, ok := ctx.Deadline(); ok {
			_ = conn.SetDeadline(deadline)
		}
		return dnsStreamExchange(conn, query)
	default:
		return nil, fmt.Errorf("unknown dns transport %q", upstream.network)
	}
}

func dnsStreamExchange(conn io.ReadWriter, query []byte) ([]byte, error) {
	if len(query) > 65535 {
		return nil, errors.New("dns query too long")
	}
	framed := make([]byte, 2, 2+len(query))
	binary.BigEndian.PutUint16(framed, uint16(len(query)))
	if _, err := conn.Write(append(framed, query...)); err != nil {
		return nil, err
	}
	var length [2]byte
	if _, err := io.ReadFull(conn, length[:]); err != nil {
		return nil, err
	}
	response := make([]byte, binary.BigEndian.Uint16(length[:]))
	if _, err := io.ReadFull(conn, response); err != nil {
		return nil, err
	}
	return response, nil
}

// dnsBridgeConn is what Go's resolver "dials": a stream connection (two
// byte length before each message, as DNS over TCP) answered in memory by
// the fallback resolver. It is not a net.PacketConn, so Go frames its
// queries for a stream and never sees a truncated answer.
type dnsBridgeConn struct {
	resolver *dnsFallbackResolver
	mu       sync.Mutex
	pending  []byte
	output   []byte
	deadline time.Time
	closed   bool
}

func (conn *dnsBridgeConn) Write(data []byte) (int, error) {
	conn.mu.Lock()
	if conn.closed {
		conn.mu.Unlock()
		return 0, net.ErrClosed
	}
	conn.pending = append(conn.pending, data...)
	deadline := conn.deadline
	conn.mu.Unlock()
	for {
		conn.mu.Lock()
		if len(conn.pending) < 2 {
			conn.mu.Unlock()
			return len(data), nil
		}
		size := int(binary.BigEndian.Uint16(conn.pending[0:2]))
		if len(conn.pending) < 2+size {
			conn.mu.Unlock()
			return len(data), nil
		}
		query := append([]byte(nil), conn.pending[2:2+size]...)
		conn.pending = conn.pending[2+size:]
		conn.mu.Unlock()

		ctx := context.Background()
		cancel := context.CancelFunc(func() {})
		if !deadline.IsZero() {
			ctx, cancel = context.WithDeadline(ctx, deadline)
		}
		response := conn.resolver.answer(ctx, query)
		cancel()
		if len(response) > 65535 {
			response = dnsErrorResponse(query, dnsRCodeServFail)
		}
		framed := make([]byte, 2, 2+len(response))
		binary.BigEndian.PutUint16(framed, uint16(len(response)))
		conn.mu.Lock()
		conn.output = append(conn.output, append(framed, response...)...)
		conn.mu.Unlock()
	}
}

func (conn *dnsBridgeConn) Read(buffer []byte) (int, error) {
	conn.mu.Lock()
	defer conn.mu.Unlock()
	if len(conn.output) == 0 {
		if conn.closed {
			return 0, net.ErrClosed
		}
		// Every answer is ready by the time Write returns.
		return 0, io.EOF
	}
	count := copy(buffer, conn.output)
	conn.output = conn.output[count:]
	return count, nil
}

func (conn *dnsBridgeConn) Close() error {
	conn.mu.Lock()
	defer conn.mu.Unlock()
	conn.closed = true
	return nil
}

func (conn *dnsBridgeConn) LocalAddr() net.Addr  { return dnsBridgeAddr{} }
func (conn *dnsBridgeConn) RemoteAddr() net.Addr { return dnsBridgeAddr{} }

func (conn *dnsBridgeConn) SetDeadline(deadline time.Time) error {
	conn.mu.Lock()
	defer conn.mu.Unlock()
	conn.deadline = deadline
	return nil
}

func (conn *dnsBridgeConn) SetReadDeadline(deadline time.Time) error { return nil }

func (conn *dnsBridgeConn) SetWriteDeadline(deadline time.Time) error {
	return conn.SetDeadline(deadline)
}

type dnsBridgeAddr struct{}

func (dnsBridgeAddr) Network() string { return "zen-dns" }
func (dnsBridgeAddr) String() string  { return "zen-dns" }
