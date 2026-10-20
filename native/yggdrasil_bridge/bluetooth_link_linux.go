//go:build linux && !android

package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/unix"
)

// BLE L2CAP connection-oriented channels on Linux (the kernel's Bluetooth
// sockets; no extra permission). The app advertises and scans through
// BlueZ over D-Bus (bluetooth_local_links.dart); classic RFCOMM is not
// offered here (finding the channel needs BlueZ's SDP over D-Bus).
const (
	btHasL2cap  = true
	btHasRfcomm = false

	// The LE dynamic PSM range; the listener takes the first one free.
	btLePsmFirst = 0x80
	btLePsmLast  = 0xff
	// <bluetooth/bluetooth.h>
	btSndMtu = 12
	// The smallest LE channel MTU: writes are cut to it when the channel's
	// is unknown.
	btLeMinMtu = 23
	// A connect gives up after this long.
	btConnectTimeout = 20 * time.Second
	// Reads take whole packets; one is never bigger than this.
	btReadBuffer = 65535
)

func btSupported() bool {
	fd, err := unix.Socket(unix.AF_BLUETOOTH, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, unix.BTPROTO_L2CAP)
	if err != nil {
		return false
	}
	_ = unix.Close(fd)
	return true
}

func btPaired() ([]string, error) {
	return nil, errBtUnsupported
}

type linuxL2capListener struct {
	fd     int
	mu     sync.Mutex
	closed bool
}

func btListen() (btListener, map[string]any, error) {
	fd, err := unix.Socket(unix.AF_BLUETOOTH, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, unix.BTPROTO_L2CAP)
	if err != nil {
		return nil, nil, err
	}
	psm := 0
	for p := btLePsmFirst; p <= btLePsmLast; p++ {
		err = unix.Bind(fd, &unix.SockaddrL2{PSM: uint16(p), AddrType: unix.BDADDR_LE_PUBLIC})
		if err == nil {
			psm = p
			break
		}
		if !errors.Is(err, unix.EADDRINUSE) {
			break
		}
	}
	if psm == 0 {
		_ = unix.Close(fd)
		if err == nil {
			err = errors.New("bluetooth: no free L2CAP channel")
		}
		return nil, nil, err
	}
	if err := unix.Listen(fd, 4); err != nil {
		_ = unix.Close(fd)
		return nil, nil, err
	}
	if err := unix.SetNonblock(fd, true); err != nil {
		_ = unix.Close(fd)
		return nil, nil, err
	}
	return &linuxL2capListener{fd: fd}, map[string]any{"psm": psm}, nil
}

// accept waits for a connection, looking every half second whether the
// listener was closed (a blocked accept would not notice).
func (l *linuxL2capListener) accept() (btConn, string, error) {
	for {
		l.mu.Lock()
		if l.closed {
			l.mu.Unlock()
			return nil, "", errBtListenerClosed
		}
		fd := l.fd
		l.mu.Unlock()
		fds := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
		if _, err := unix.Poll(fds, 500); err != nil && !errors.Is(err, unix.EINTR) {
			return nil, "", err
		}
		if fds[0].Revents&(unix.POLLERR|unix.POLLHUP|unix.POLLNVAL) != 0 {
			return nil, "", errors.New("bluetooth: listener failed")
		}
		if fds[0].Revents&unix.POLLIN == 0 {
			continue
		}
		l.mu.Lock()
		if l.closed {
			l.mu.Unlock()
			return nil, "", errBtListenerClosed
		}
		nfd, sa, err := unix.Accept4(fd, unix.SOCK_CLOEXEC)
		l.mu.Unlock()
		if err != nil {
			if errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.EINTR) || errors.Is(err, unix.ECONNABORTED) {
				continue
			}
			return nil, "", err
		}
		device := ""
		if addr, ok := sa.(*unix.SockaddrL2); ok {
			// Accept gives the address least significant byte first.
			var display [6]byte
			for i := range display {
				display[i] = addr.Addr[5-i]
			}
			device = linuxBtDevice(display, addr.AddrType)
		}
		conn, err := newLinuxL2capConn(nfd)
		if err != nil {
			_ = unix.Close(nfd)
			continue
		}
		return conn, device, nil
	}
}

func (l *linuxL2capListener) close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	return unix.Close(l.fd)
}

func linuxBtDevice(addr [6]byte, addrType uint8) string {
	kind := "public"
	if addrType == unix.BDADDR_LE_RANDOM {
		kind = "random"
	}
	return formatBtAddress(addr) + "/" + kind
}

// parseLinuxBtDevice reads "AA:BB:CC:DD:EE:FF/public|random".
func parseLinuxBtDevice(device string) ([6]byte, uint8, error) {
	text, kind, _ := strings.Cut(device, "/")
	addr, err := parseBtAddress(text)
	if err != nil {
		return addr, 0, err
	}
	switch kind {
	case "", "public":
		return addr, unix.BDADDR_LE_PUBLIC, nil
	case "random":
		return addr, unix.BDADDR_LE_RANDOM, nil
	}
	return addr, 0, fmt.Errorf("%w: address type %q", errLocalLinkBadInput, kind)
}

func btDial(device string, psm int, classic bool) (btConn, error) {
	if classic {
		return nil, errBtUnsupported
	}
	if psm < btLePsmFirst || psm > 0xffff {
		return nil, fmt.Errorf("%w: psm %d", errLocalLinkBadInput, psm)
	}
	addr, addrType, err := parseLinuxBtDevice(device)
	if err != nil {
		return nil, err
	}
	fd, err := unix.Socket(unix.AF_BLUETOOTH, unix.SOCK_SEQPACKET|unix.SOCK_CLOEXEC, unix.BTPROTO_L2CAP)
	if err != nil {
		return nil, err
	}
	// An LE source, so the channel is an LE one.
	if err := unix.Bind(fd, &unix.SockaddrL2{AddrType: unix.BDADDR_LE_PUBLIC}); err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	timeout := unix.NsecToTimeval(btConnectTimeout.Nanoseconds())
	_ = unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_SNDTIMEO, &timeout)
	if err := unix.Connect(fd, &unix.SockaddrL2{PSM: uint16(psm), Addr: addr, AddrType: addrType}); err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	conn, err := newLinuxL2capConn(fd)
	if err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	return conn, nil
}

// linuxL2capConn is a connected channel on Go's poller (closing it ends
// blocked reads). Reads come in whole packets, writes go out in packets of
// at most the channel's MTU.
type linuxL2capConn struct {
	file *os.File
	mtu  int

	readMu  sync.Mutex
	buf     []byte
	pending []byte
}

func newLinuxL2capConn(fd int) (*linuxL2capConn, error) {
	mtu, err := unix.GetsockoptInt(fd, unix.SOL_BLUETOOTH, btSndMtu)
	// The option is 16 bits wide: only the low ones are the MTU.
	mtu &= 0xffff
	if err != nil || mtu < btLeMinMtu {
		mtu = btLeMinMtu
	}
	if err := unix.SetNonblock(fd, true); err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), "l2cap")
	if file == nil {
		return nil, errors.New("bluetooth: bad socket")
	}
	return &linuxL2capConn{file: file, mtu: mtu, buf: make([]byte, btReadBuffer)}, nil
}

func (c *linuxL2capConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	if len(c.pending) == 0 {
		n, err := c.file.Read(c.buf)
		if n <= 0 {
			if err == nil {
				err = errors.New("bluetooth: empty read")
			}
			return 0, err
		}
		c.pending = c.buf[:n]
	}
	n := copy(p, c.pending)
	c.pending = c.pending[n:]
	return n, nil
}

func (c *linuxL2capConn) Write(p []byte) (int, error) {
	written := 0
	for written < len(p) {
		end := min(written+c.mtu, len(p))
		n, err := c.file.Write(p[written:end])
		written += n
		if err != nil {
			return written, err
		}
	}
	return written, nil
}

func (c *linuxL2capConn) Close() error {
	return c.file.Close()
}
