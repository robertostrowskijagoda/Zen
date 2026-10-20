package main

import (
	"bufio"
	"io"
	"net"
	"testing"
	"time"
)

func TestPeerGuardSourceKey(t *testing.T) {
	cases := map[string]string{
		"203.0.113.9":          "203.0.113.9",
		"::ffff:203.0.113.9":   "203.0.113.9",
		"2001:db8:1:2:3:4:5:6": "2001:db8:1:2::/64",
		"2001:db8:1:2:ffff::1": "2001:db8:1:2::/64",
		"2001:db8:1:3:3:4:5:6": "2001:db8:1:3::/64",
	}
	for input, want := range cases {
		if got := peerGuardSourceKey(net.ParseIP(input)); got != want {
			t.Fatalf("%s: got %s, want %s", input, got, want)
		}
	}
}

func TestGuardedListenAddress(t *testing.T) {
	public, scheme, ok := guardedListenAddress(defaultDesktopPeerListenForTest)
	if !ok || public != "[::]:32913" || scheme != "tls" {
		t.Fatalf("got %q %q %v", public, scheme, ok)
	}
	for _, other := range []string{"quic://[::]:32913", "tls://[::]:32913?password=x", "tls://[::]", "ws://0.0.0.0:80", "%%"} {
		if _, _, ok := guardedListenAddress(other); ok {
			t.Fatalf("%q must be left to Yggdrasil", other)
		}
	}
}

// The desktop default, spelled out so this file needs no Yggdrasil import.
const defaultDesktopPeerListenForTest = "tls://[::]:32913"

func testGuard(limits peerGuardLimits, now *time.Time) *peerListenGuard {
	guard := newPeerListenGuard(nil, "", limits)
	guard.now = func() time.Time { return *now }
	return guard
}

func TestPeerGuardConnectionLimits(t *testing.T) {
	now := time.Unix(10000, 0)
	limits := defaultPeerGuardLimits
	limits.maxConnsPerSource = 2
	limits.maxConnsTotal = 3
	guard := testGuard(limits, &now)

	if !guard.admit("a") || !guard.admit("a") {
		t.Fatal("two connections from one source are allowed")
	}
	if guard.admit("a") {
		t.Fatal("a third connection from the same source must be refused")
	}
	if !guard.admit("b") {
		t.Fatal("another source still gets in")
	}
	if guard.admit("c") {
		t.Fatal("the total limit must hold")
	}
	guard.release("a")
	if !guard.admit("c") {
		t.Fatal("a released slot is free again")
	}
	if guard.refusedConn != 2 {
		t.Fatalf("expected 2 refusals counted, got %d", guard.refusedConn)
	}
}

func TestPeerGuardRateLimit(t *testing.T) {
	now := time.Unix(10000, 0)
	limits := defaultPeerGuardLimits
	limits.bytesPerSecondPerSource = 1000
	limits.burstBytesPerSource = 2000
	guard := testGuard(limits, &now)
	if !guard.admit("a") {
		t.Fatal("admit failed")
	}
	if wait, err := guard.charge("a", 2000); err != nil || wait != 0 {
		t.Fatalf("the burst passes without waiting, got %v %v", wait, err)
	}
	wait, err := guard.charge("a", 500)
	if err != nil || wait != 500*time.Millisecond {
		t.Fatalf("over the burst the sender waits, got %v %v", wait, err)
	}
	now = now.Add(10 * time.Second)
	if wait, err := guard.charge("a", 1500); err != nil || wait != 0 {
		t.Fatalf("tokens refill with time, got %v %v", wait, err)
	}
}

func TestPeerGuardDailyBudgets(t *testing.T) {
	now := time.Unix(10000, 0)
	limits := defaultPeerGuardLimits
	limits.dailyBytesPerSource = 10000
	limits.dailyBytesTotal = 15000
	limits.burstBytesPerSource = 1e9
	guard := testGuard(limits, &now)
	if !guard.admit("a") || !guard.admit("b") {
		t.Fatal("admit failed")
	}
	if _, err := guard.charge("a", 10000); err != nil {
		t.Fatalf("within the budget: %v", err)
	}
	if _, err := guard.charge("a", 1); err != errPeerGuardBudget {
		t.Fatalf("over the source's day budget the link ends, got %v", err)
	}
	guard.release("a")
	if guard.admit("a") {
		t.Fatal("a source that used its day budget is refused until the day is over")
	}
	if _, err := guard.charge("b", 5000); err != errPeerGuardBudget {
		t.Fatalf("over the total day budget the link ends, got %v", err)
	}
	if guard.admit("c") {
		t.Fatal("with the total budget used up nobody new gets in")
	}
	now = now.Add(peerGuardDay)
	if !guard.admit("a") || !guard.admit("c") {
		t.Fatal("a new day brings new budgets")
	}
}

func TestPeerGuardForgetsIdleSources(t *testing.T) {
	now := time.Unix(10000, 0)
	limits := defaultPeerGuardLimits
	limits.maxTrackedSources = 2
	guard := testGuard(limits, &now)
	if !guard.admit("a") || !guard.admit("b") {
		t.Fatal("admit failed")
	}
	guard.release("a")
	if guard.admit("c") {
		t.Fatal("while sources are remembered for their day, new ones wait")
	}
	now = now.Add(peerGuardDay)
	if !guard.admit("c") {
		t.Fatal("an idle source whose day is over is forgotten")
	}
}

func TestPeerGuardProxiesAndLimits(t *testing.T) {
	backend, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	go func() {
		for {
			conn, err := backend.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.Copy(conn, conn)
			}()
		}
	}()

	limits := defaultPeerGuardLimits
	limits.maxConnsPerSource = 1
	public, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	guard := newPeerListenGuard(public, backend.Addr().String(), limits)
	go guard.serve()
	defer guard.close()

	first, err := net.Dial("tcp", guard.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	if _, err := first.Write([]byte("hello\n")); err != nil {
		t.Fatal(err)
	}
	_ = first.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := bufio.NewReader(first).ReadString('\n')
	if err != nil || line != "hello\n" {
		t.Fatalf("expected the echo through the guard, got %q %v", line, err)
	}

	second, err := net.Dial("tcp", guard.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	_ = second.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := second.Read(make([]byte, 1)); err == nil {
		t.Fatal("a second connection from the same address must be closed")
	}

	guard.close()
	_ = first.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := first.Read(make([]byte, 1)); err == nil {
		t.Fatal("closing the guard drops proxied links")
	}
}

func TestPeerGuardRefusesFilteredAddresses(t *testing.T) {
	guard, nodeURI, err := startPeerListenGuard("tcp://127.0.0.1:0", defaultPeerGuardLimits, func(net.IP) bool { return false })
	if err != nil {
		t.Fatal(err)
	}
	defer guard.close()
	if host, _, err := net.SplitHostPort(nodeURI[len("tcp://"):]); err != nil || host != "127.0.0.1" {
		t.Fatalf("the node must listen on loopback, got %q", nodeURI)
	}
	conn, err := net.Dial("tcp", guard.listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("a filtered address must be closed at once")
	}
}
