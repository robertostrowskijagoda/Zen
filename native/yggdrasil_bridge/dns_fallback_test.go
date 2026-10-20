package main

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"net/netip"
	"testing"
	"time"
)

func dnsQueryFor(name string, kind uint16) []byte {
	query := []byte{0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0}
	for _, label := range splitDNSLabels(name) {
		query = append(query, byte(len(label)))
		query = append(query, label...)
	}
	query = append(query, 0, byte(kind>>8), byte(kind), 0, dnsClassIN)
	return query
}

func splitDNSLabels(name string) []string {
	var labels []string
	start := 0
	for i := 0; i < len(name); i++ {
		if name[i] == '.' {
			if i > start {
				labels = append(labels, name[start:i])
			}
			start = i + 1
		}
	}
	if start < len(name) {
		labels = append(labels, name[start:])
	}
	return labels
}

func testDNSResolver(
	system func(ctx context.Context, network, host string) ([]netip.Addr, error),
	exchange func(ctx context.Context, upstream dnsUpstream, query []byte) ([]byte, error),
) *dnsFallbackResolver {
	resolver := newDNSFallbackResolver()
	resolver.systemLookup = system
	resolver.exchange = exchange
	return resolver
}

func TestParseDNSUpstream(t *testing.T) {
	cases := map[string]dnsUpstream{
		"tls://9.9.9.9:853#dns.quad9.net": {network: "tls", address: "9.9.9.9:853", serverName: "dns.quad9.net"},
		"tls://1.1.1.1":                   {network: "tls", address: "1.1.1.1:853"},
		"udp://192.168.1.1":               {network: "udp", address: "192.168.1.1:53"},
		" tcp://[2001:db8::1]:5353 ":      {network: "tcp", address: "[2001:db8::1]:5353"},
	}
	for spec, want := range cases {
		got, err := parseDNSUpstream(spec)
		if err != nil || got != want {
			t.Fatalf("%q: got %+v, %v; want %+v", spec, got, err, want)
		}
	}
	for _, bad := range []string{"8.8.8.8", "https://dns.google/dns-query", "tls://dns.google", "udp://1.1.1.1#name", "tls://1.1.1.1/path"} {
		if _, err := parseDNSUpstream(bad); err == nil {
			t.Fatalf("%q must be refused", bad)
		}
	}
}

func TestDNSDefaultsAreEncrypted(t *testing.T) {
	for _, upstream := range defaultDNSUpstreams {
		if upstream.network != "tls" || upstream.serverName == "" {
			t.Fatalf("default %+v must be DNS over TLS with a checked name", upstream)
		}
	}
}

func TestDNSConfigureJSON(t *testing.T) {
	resolver := newDNSFallbackResolver()
	if err := resolver.configureJSON(`{"servers":["udp://10.0.0.1"],"useSystem":false}`); err != nil {
		t.Fatal(err)
	}
	if resolver.useSystem || len(resolver.upstreams) != 1 || resolver.upstreams[0].address != "10.0.0.1:53" {
		t.Fatalf("got %+v", resolver.upstreams)
	}
	if err := resolver.configureJSON(`[]`); err != nil {
		t.Fatal(err)
	}
	if !resolver.useSystem || len(resolver.upstreams) != len(defaultDNSUpstreams) {
		t.Fatal("an empty list restores the defaults")
	}
	if err := resolver.configureJSON(`["8.8.8.8:53"]`); err == nil {
		t.Fatal("a server without transport must be refused")
	}
}

func TestDNSSystemResolverAnswersFirst(t *testing.T) {
	upstreamAsked := false
	resolver := testDNSResolver(
		func(ctx context.Context, network, host string) ([]netip.Addr, error) {
			if host != "peer.example" || network != "ip4" {
				t.Fatalf("unexpected lookup %s %s", network, host)
			}
			return []netip.Addr{netip.MustParseAddr("192.0.2.7")}, nil
		},
		func(ctx context.Context, upstream dnsUpstream, query []byte) ([]byte, error) {
			upstreamAsked = true
			return nil, errors.New("unused")
		},
	)
	response := resolver.answer(context.Background(), dnsQueryFor("peer.example.", dnsTypeA))
	if upstreamAsked {
		t.Fatal("the upstream must not be asked when the system answers")
	}
	if binary.BigEndian.Uint16(response[6:8]) != 1 {
		t.Fatalf("expected one answer, got %x", response)
	}
	if got := response[len(response)-4:]; !net.IP(got).Equal(net.ParseIP("192.0.2.7")) {
		t.Fatalf("wrong address %v", got)
	}
}

func TestDNSFallsBackToUpstreamWhenSystemFails(t *testing.T) {
	now := time.Unix(5000, 0)
	systemCalls := 0
	var asked []string
	resolver := testDNSResolver(
		func(ctx context.Context, network, host string) ([]netip.Addr, error) {
			systemCalls++
			return nil, &net.DNSError{Err: "connection refused", Name: host, IsTemporary: true}
		},
		func(ctx context.Context, upstream dnsUpstream, query []byte) ([]byte, error) {
			asked = append(asked, upstream.address)
			if len(asked) == 1 {
				return nil, errors.New("blocked")
			}
			question, _ := parseDNSQuestion(query)
			return dnsAddressResponse(query, question, []netip.Addr{netip.MustParseAddr("2001:db8::5")}), nil
		},
	)
	resolver.now = func() time.Time { return now }
	response := resolver.answer(context.Background(), dnsQueryFor("peer.example", dnsTypeAAAA))
	if len(asked) != 2 || asked[0] != defaultDNSUpstreams[0].address || asked[1] != defaultDNSUpstreams[1].address {
		t.Fatalf("upstreams asked in order until one answers, got %v", asked)
	}
	if binary.BigEndian.Uint16(response[6:8]) != 1 {
		t.Fatalf("expected the upstream's answer, got %x", response)
	}
	// The broken system resolver is skipped for a while...
	resolver.answer(context.Background(), dnsQueryFor("peer.example", dnsTypeA))
	if systemCalls != 1 {
		t.Fatalf("expected the system resolver skipped during its cooldown, got %d calls", systemCalls)
	}
	// ...and tried again afterwards.
	now = now.Add(dnsSystemCooldown + time.Second)
	resolver.answer(context.Background(), dnsQueryFor("peer.example", dnsTypeA))
	if systemCalls != 2 {
		t.Fatalf("expected the system resolver retried, got %d calls", systemCalls)
	}
}

func TestDNSSystemNotFoundIsAnAnswer(t *testing.T) {
	resolver := testDNSResolver(
		func(ctx context.Context, network, host string) ([]netip.Addr, error) {
			return nil, &net.DNSError{Err: "no such host", Name: host, IsNotFound: true}
		},
		func(ctx context.Context, upstream dnsUpstream, query []byte) ([]byte, error) {
			t.Fatal("a name the system knows not to exist is not asked elsewhere")
			return nil, nil
		},
	)
	response := resolver.answer(context.Background(), dnsQueryFor("nothing.example", dnsTypeA))
	if response[3]&0xF != dnsRCodeSuccess || binary.BigEndian.Uint16(response[6:8]) != 0 {
		t.Fatalf("expected an empty answer, got %x", response)
	}
}

func TestDNSAllUpstreamsFailingIsServFail(t *testing.T) {
	resolver := testDNSResolver(
		func(ctx context.Context, network, host string) ([]netip.Addr, error) {
			return nil, errors.New("down")
		},
		func(ctx context.Context, upstream dnsUpstream, query []byte) ([]byte, error) {
			return nil, errors.New("down")
		},
	)
	response := resolver.answer(context.Background(), dnsQueryFor("peer.example", dnsTypeA))
	if response[3]&0xF != dnsRCodeServFail || response[0] != 0x12 || response[1] != 0x34 {
		t.Fatalf("expected SERVFAIL with the query's id, got %x", response)
	}
}

// Go's own resolver, pointed at dnsBridgeConn, gets the system's answers.
func TestDNSBridgeConnServesGoResolver(t *testing.T) {
	resolver := testDNSResolver(
		func(ctx context.Context, network, host string) ([]netip.Addr, error) {
			if network == "ip6" {
				return []netip.Addr{netip.MustParseAddr("2001:db8::9")}, nil
			}
			return []netip.Addr{netip.MustParseAddr("192.0.2.9")}, nil
		},
		func(ctx context.Context, upstream dnsUpstream, query []byte) ([]byte, error) {
			return nil, errors.New("unused")
		},
	)
	goResolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return &dnsBridgeConn{resolver: resolver}, nil
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	addrs, err := goResolver.LookupNetIP(ctx, "ip", "peer.zen-test.example")
	if err != nil {
		t.Fatalf("lookup failed: %v", err)
	}
	found := map[string]bool{}
	for _, addr := range addrs {
		found[addr.Unmap().String()] = true
	}
	if !found["192.0.2.9"] || !found["2001:db8::9"] {
		t.Fatalf("got %v", addrs)
	}
}
