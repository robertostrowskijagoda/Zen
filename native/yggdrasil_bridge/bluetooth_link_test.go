package main

import (
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"testing"
	"time"
)

// fakeBtListener hands out the streams pushed into it.
type fakeBtListener struct {
	conns  chan net.Conn
	closed chan struct{}
}

func newFakeBtListener() *fakeBtListener {
	return &fakeBtListener{conns: make(chan net.Conn, 4), closed: make(chan struct{})}
}

func (l *fakeBtListener) accept() (btConn, string, error) {
	select {
	case conn := <-l.conns:
		return conn, "AA:BB:CC:DD:EE:FF/random", nil
	case <-l.closed:
		return nil, "", errBtListenerClosed
	}
}

func (l *fakeBtListener) close() error {
	select {
	case <-l.closed:
	default:
		close(l.closed)
	}
	return nil
}

// fakeEndpoint is the node's side: it checks the token and echoes.
func fakeEndpoint(t *testing.T, token []byte) (int, <-chan error) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	result := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			result <- err
			return
		}
		defer conn.Close()
		got := make([]byte, len(token))
		if _, err := io.ReadFull(conn, got); err != nil {
			result <- err
			return
		}
		if !bytes.Equal(got, token) {
			result <- errors.New("wrong token")
			return
		}
		result <- nil
		_, _ = io.Copy(conn, conn)
	}()
	return listener.Addr().(*net.TCPAddr).Port, result
}

func waitFor(t *testing.T, what string, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !check() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestBtIncomingStreamIsPumpedIntoTheEndpoint(t *testing.T) {
	listener := newFakeBtListener()
	links := newBtLinks(
		func() (btListener, map[string]any, error) {
			return listener, map[string]any{"psm": 0x80}, nil
		},
		nil,
	)
	defer links.stop()
	info, err := links.start()
	if err != nil || info["psm"] != 0x80 {
		t.Fatalf("start: %v %v", info, err)
	}
	// Started again: the same listener.
	if again, _ := links.start(); again["psm"] != 0x80 {
		t.Fatalf("restart: %v", again)
	}

	remote, local := net.Pipe()
	defer remote.Close()
	listener.conns <- local
	var id string
	waitFor(t, "the incoming stream", func() bool {
		incoming := links.poll()["incoming"].([]string)
		if len(incoming) == 1 {
			id = incoming[0]
		}
		return id != ""
	})
	if again := links.poll()["incoming"].([]string); len(again) != 0 {
		t.Fatalf("reported twice: %v", again)
	}

	token := bytes.Repeat([]byte{7}, localStreamTokenSize)
	port, endpoint := fakeEndpoint(t, token)
	if err := links.accept(id, port, token); err != nil {
		t.Fatal(err)
	}
	if err := <-endpoint; err != nil {
		t.Fatal(err)
	}
	if _, err := remote.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	echo := make([]byte, 5)
	if _, err := io.ReadFull(remote, echo); err != nil || string(echo) != "hello" {
		t.Fatalf("echo %q %v", echo, err)
	}
	devices := links.poll()["devices"].([]string)
	if len(devices) != 1 || devices[0] != "AA:BB:CC:DD:EE:FF/random" {
		t.Fatalf("devices %v", devices)
	}
	if !links.openDevices()["AA:BB:CC:DD:EE:FF/random"] {
		t.Fatal("the device has no open stream")
	}

	// Closing the Bluetooth side ends the stream.
	_ = remote.Close()
	waitFor(t, "the stream to end", func() bool {
		return len(links.poll()["devices"].([]string)) == 0
	})
	if err := links.accept(id, port, token); err == nil {
		t.Fatal("a stream accepted twice")
	}
}

func TestBtRejectedStreamIsClosed(t *testing.T) {
	listener := newFakeBtListener()
	links := newBtLinks(
		func() (btListener, map[string]any, error) { return listener, map[string]any{}, nil },
		nil,
	)
	defer links.stop()
	if _, err := links.start(); err != nil {
		t.Fatal(err)
	}
	remote, local := net.Pipe()
	listener.conns <- local
	var id string
	waitFor(t, "the incoming stream", func() bool {
		incoming := links.poll()["incoming"].([]string)
		if len(incoming) == 1 {
			id = incoming[0]
		}
		return id != ""
	})
	links.reject(id)
	_ = remote.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := remote.Read(make([]byte, 1)); err == nil {
		t.Fatal("the rejected stream is still open")
	}
}

func TestBtIncomingStreamsAreLimitedPerDevice(t *testing.T) {
	listener := newFakeBtListener()
	links := newBtLinks(
		func() (btListener, map[string]any, error) { return listener, map[string]any{}, nil },
		nil,
	)
	defer links.stop()
	if _, err := links.start(); err != nil {
		t.Fatal(err)
	}
	// The fake listener says every stream comes from the same device.
	remotes := []net.Conn{}
	for i := 0; i < btMaxIncomingPerDevice; i++ {
		remote, local := net.Pipe()
		remotes = append(remotes, remote)
		listener.conns <- local
	}
	waitFor(t, "the incoming streams", func() bool {
		links.mu.Lock()
		defer links.mu.Unlock()
		return len(links.incoming) == btMaxIncomingPerDevice
	})
	extra, local := net.Pipe()
	listener.conns <- local
	_ = extra.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := extra.Read(make([]byte, 1)); err == nil || errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatalf("a stream over the device's share was not closed: %v", err)
	}
	links.mu.Lock()
	waiting := len(links.incoming)
	links.mu.Unlock()
	if waiting != btMaxIncomingPerDevice {
		t.Fatalf("%d streams waiting", waiting)
	}
	for _, remote := range remotes {
		_ = remote.Close()
	}
}

func TestBtDialReportsItsOutcome(t *testing.T) {
	remote, local := net.Pipe()
	defer remote.Close()
	links := newBtLinks(nil, func(device string, psm int, classic bool) (btConn, error) {
		if device == "AA:BB:CC:DD:EE:01" && classic {
			return local, nil
		}
		return nil, errors.New("not there")
	})
	defer links.stop()
	token := bytes.Repeat([]byte{9}, localStreamTokenSize)
	port, endpoint := fakeEndpoint(t, token)

	if _, err := links.dialAsync("AA:BB:CC:DD:EE:01", 0, true, port, token[:3]); err == nil {
		t.Fatal("a short token was taken")
	}
	ok, err := links.dialAsync("AA:BB:CC:DD:EE:01", 0, true, port, token)
	if err != nil {
		t.Fatal(err)
	}
	failed, err := links.dialAsync("AA:BB:CC:DD:EE:02", 0, true, port, token)
	if err != nil {
		t.Fatal(err)
	}
	outcomes := map[string]string{}
	waitFor(t, "both dials", func() bool {
		for id, state := range links.poll()["dials"].(map[string]string) {
			outcomes[id] = state
		}
		return len(outcomes) == 2
	})
	if outcomes[ok] != "ok" || outcomes[failed] != "failed" {
		t.Fatalf("outcomes %v", outcomes)
	}
	if err := <-endpoint; err != nil {
		t.Fatal(err)
	}
	links.stop()
	_ = remote.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := remote.Read(make([]byte, 1)); err == nil {
		t.Fatal("stop left the stream open")
	}
}

func TestBtAddressesRoundTrip(t *testing.T) {
	addr, err := parseBtAddress("01:23:45:67:89:AB")
	if err != nil || addr != [6]byte{0x01, 0x23, 0x45, 0x67, 0x89, 0xab} {
		t.Fatalf("%v %v", addr, err)
	}
	if formatBtAddress(addr) != "01:23:45:67:89:AB" {
		t.Fatal(formatBtAddress(addr))
	}
	for _, bad := range []string{"", "01:23:45:67:89", "01-23-45-67-89-AB", "0x:23:45:67:89:AB"} {
		if _, err := parseBtAddress(bad); err == nil {
			t.Fatalf("%q was taken", bad)
		}
	}
}
