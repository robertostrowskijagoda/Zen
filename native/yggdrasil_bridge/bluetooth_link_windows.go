//go:build windows

package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"
	"sync/atomic"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Classic Bluetooth (RFCOMM) on Windows through Winsock, with phones and
// computers paired in the system's Bluetooth settings (BLE links are GATT
// streams in the runner, bluetooth_le_bridge.cpp, as Windows offers apps no
// BLE L2CAP channels): the listener's channel is
// published over SDP under the Zen RFCOMM service class, and paired devices
// are reached by that class (Winsock looks the channel up). Android does
// the same (ZenBluetoothLinkBridge.kt). The structures below are the 64-bit
// layouts (Zen ships x64 and ARM64 only).
const (
	btHasL2cap  = false
	btHasRfcomm = true

	btPortAny          = ^uint32(0)
	btRnrRegister      = 0
	btRnrDelete        = 2
	btFionbio          = 0x8004667e
	btPollRdNorm       = 0x0100
	btPollWrNorm       = 0x0010
	btPollErr          = 0x0001
	btPollHup          = 0x0002
	btPollNval         = 0x0004
	btPollMillis       = 250
	btMajorComputer    = 1
	btMajorPhone       = 2
	btMaxNameLength    = 248
	btSocketError      = -1
	btClassOfDeviceBit = 8
)

// 5a454e00-6c69-6e6b-0000-000000000004
var btRfcommServiceClass = windows.GUID{
	Data1: 0x5a454e00,
	Data2: 0x6c69,
	Data3: 0x6e6b,
	Data4: [8]byte{0, 0, 0, 0, 0, 0, 0, 0x04},
}

var (
	btWs2             = windows.NewLazySystemDLL("ws2_32.dll")
	btProcAccept      = btWs2.NewProc("accept")
	btProcGetsockname = btWs2.NewProc("getsockname")
	btProcRecv        = btWs2.NewProc("recv")
	btProcSend        = btWs2.NewProc("send")
	btProcIoctl       = btWs2.NewProc("ioctlsocket")
	btProcPoll        = btWs2.NewProc("WSAPoll")
	btProcSetService  = btWs2.NewProc("WSASetServiceW")

	btApis                = windows.NewLazySystemDLL("BluetoothApis.dll")
	btProcFindFirst       = btApis.NewProc("BluetoothFindFirstDevice")
	btProcFindNext        = btApis.NewProc("BluetoothFindNextDevice")
	btProcFindDeviceClose = btApis.NewProc("BluetoothFindDeviceClose")
)

func btSupported() bool {
	s, err := windows.Socket(windows.AF_BTH, windows.SOCK_STREAM, windows.BTHPROTO_RFCOMM)
	if err != nil {
		return false
	}
	_ = windows.Closesocket(s)
	return true
}

// WSAPOLLFD
type btPollFd struct {
	fd      windows.Handle
	events  int16
	revents int16
}

// btWait waits up to btPollMillis for events on s; false: nothing yet.
func btWait(s windows.Handle, events int16) (bool, error) {
	fds := [1]btPollFd{{fd: s, events: events}}
	r, _, e := btProcPoll.Call(uintptr(unsafe.Pointer(&fds[0])), 1, btPollMillis)
	if int32(r) == btSocketError {
		return false, e
	}
	if fds[0].revents&(btPollErr|btPollHup|btPollNval) != 0 && fds[0].revents&events == 0 {
		return false, io.EOF
	}
	return int32(r) > 0, nil
}

func btSetNonblocking(s windows.Handle) error {
	on := uint32(1)
	r, _, e := btProcIoctl.Call(uintptr(s), btFionbio, uintptr(unsafe.Pointer(&on)))
	if int32(r) != 0 {
		return e
	}
	return nil
}

// btSockaddr writes a SOCKADDR_BTH into a SOCKADDR buffer (Winsock reads
// only the first 30 bytes).
func btSockaddr(addr uint64, port uint32) *syscall.RawSockaddrAny {
	var raw syscall.RawSockaddrAny
	bth := (*windows.RawSockaddrBth)(unsafe.Pointer(&raw))
	binary.LittleEndian.PutUint16(bth.AddressFamily[:], windows.AF_BTH)
	binary.LittleEndian.PutUint64(bth.BtAddr[:], addr)
	binary.LittleEndian.PutUint32(bth.Port[:], port)
	return &raw
}

// btRegisterService publishes (or withdraws) the SDP record of the
// listener's channel.
func btRegisterService(channel uint32, op uintptr) error {
	local := btSockaddr(0, channel)
	csa := windows.CSAddrInfo{
		LocalAddr: windows.SocketAddress{
			Sockaddr:       local,
			SockaddrLength: int32(unsafe.Sizeof(windows.RawSockaddrBth{})),
		},
		SocketType: windows.SOCK_STREAM,
		Protocol:   windows.BTHPROTO_RFCOMM,
	}
	name, err := windows.UTF16PtrFromString("Zen")
	if err != nil {
		return err
	}
	class := btRfcommServiceClass
	query := windows.WSAQUERYSET{
		ServiceInstanceName: name,
		ServiceClassId:      &class,
		NameSpace:           windows.NS_BTH,
		NumberOfCsAddrs:     1,
		SaBuffer:            &csa,
	}
	query.Size = uint32(unsafe.Sizeof(query))
	r, _, e := btProcSetService.Call(uintptr(unsafe.Pointer(&query)), op, 0)
	if int32(r) != 0 {
		return fmt.Errorf("bluetooth: SDP record: %w", e)
	}
	return nil
}

type winRfcommListener struct {
	s       windows.Handle
	channel uint32
	closing atomic.Bool
	mu      sync.RWMutex
	closed  bool
}

func btListen() (btListener, map[string]any, error) {
	s, err := windows.Socket(windows.AF_BTH, windows.SOCK_STREAM, windows.BTHPROTO_RFCOMM)
	if err != nil {
		return nil, nil, err
	}
	fail := func(err error) (btListener, map[string]any, error) {
		_ = windows.Closesocket(s)
		return nil, nil, err
	}
	if err := windows.Bind(s, &windows.SockaddrBth{Port: btPortAny}); err != nil {
		return fail(err)
	}
	if err := windows.Listen(s, 4); err != nil {
		return fail(err)
	}
	var raw syscall.RawSockaddrAny
	size := int32(unsafe.Sizeof(raw))
	r, _, e := btProcGetsockname.Call(uintptr(s), uintptr(unsafe.Pointer(&raw)), uintptr(unsafe.Pointer(&size)))
	if int32(r) != 0 {
		return fail(e)
	}
	channel := binary.LittleEndian.Uint32((*windows.RawSockaddrBth)(unsafe.Pointer(&raw)).Port[:])
	if err := btSetNonblocking(s); err != nil {
		return fail(err)
	}
	if err := btRegisterService(channel, btRnrRegister); err != nil {
		return fail(err)
	}
	return &winRfcommListener{s: s, channel: channel}, map[string]any{"channel": int(channel)}, nil
}

func (l *winRfcommListener) accept() (btConn, string, error) {
	l.mu.RLock()
	defer l.mu.RUnlock()
	for {
		if l.closing.Load() || l.closed {
			return nil, "", errBtListenerClosed
		}
		ready, err := btWait(l.s, btPollRdNorm)
		if err != nil {
			return nil, "", err
		}
		if !ready {
			continue
		}
		var raw syscall.RawSockaddrAny
		size := int32(unsafe.Sizeof(raw))
		r, _, e := btProcAccept.Call(uintptr(l.s), uintptr(unsafe.Pointer(&raw)), uintptr(unsafe.Pointer(&size)))
		s := windows.Handle(r)
		if s == windows.InvalidHandle {
			if errors.Is(e, windows.WSAEWOULDBLOCK) {
				continue
			}
			return nil, "", e
		}
		addr := binary.LittleEndian.Uint64((*windows.RawSockaddrBth)(unsafe.Pointer(&raw)).BtAddr[:])
		if err := btSetNonblocking(s); err != nil {
			_ = windows.Closesocket(s)
			continue
		}
		return &winRfcommConn{s: s}, btAddressText(addr), nil
	}
}

func (l *winRfcommListener) close() error {
	l.closing.Store(true)
	// Waits for accept to notice (it looks every btPollMillis).
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed {
		return nil
	}
	l.closed = true
	_ = btRegisterService(l.channel, btRnrDelete)
	return windows.Closesocket(l.s)
}

// winRfcommConn is a connected non-blocking socket. Reads and writes wait
// in short polls, so Close can wait for them to return before the socket
// is closed (its handle is never used once it could belong to another).
type winRfcommConn struct {
	s       windows.Handle
	closing atomic.Bool
	mu      sync.RWMutex
	closed  bool
}

func (c *winRfcommConn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	for {
		if c.closing.Load() || c.closed {
			return 0, io.EOF
		}
		r, _, e := btProcRecv.Call(uintptr(c.s), uintptr(unsafe.Pointer(&p[0])), uintptr(len(p)), 0)
		n := int32(r)
		if n > 0 {
			return int(n), nil
		}
		if n == 0 {
			return 0, io.EOF
		}
		if !errors.Is(e, windows.WSAEWOULDBLOCK) {
			return 0, e
		}
		if _, err := btWait(c.s, btPollRdNorm); err != nil {
			return 0, err
		}
	}
}

func (c *winRfcommConn) Write(p []byte) (int, error) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	written := 0
	for written < len(p) {
		if c.closing.Load() || c.closed {
			return written, io.ErrClosedPipe
		}
		r, _, e := btProcSend.Call(uintptr(c.s), uintptr(unsafe.Pointer(&p[written])), uintptr(len(p)-written), 0)
		n := int32(r)
		if n > 0 {
			written += int(n)
			continue
		}
		if n == btSocketError && !errors.Is(e, windows.WSAEWOULDBLOCK) {
			return written, e
		}
		if _, err := btWait(c.s, btPollWrNorm); err != nil {
			return written, err
		}
	}
	return written, nil
}

func (c *winRfcommConn) Close() error {
	c.closing.Store(true)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	return windows.Closesocket(c.s)
}

func btDial(device string, psm int, classic bool) (btConn, error) {
	if !classic {
		return nil, errBtUnsupported
	}
	addr, err := btAddressValue(device)
	if err != nil {
		return nil, err
	}
	s, err := windows.Socket(windows.AF_BTH, windows.SOCK_STREAM, windows.BTHPROTO_RFCOMM)
	if err != nil {
		return nil, err
	}
	// Port 0: Winsock finds the channel of the service class over SDP.
	if err := windows.Connect(s, &windows.SockaddrBth{BtAddr: addr, ServiceClassId: btRfcommServiceClass}); err != nil {
		_ = windows.Closesocket(s)
		return nil, err
	}
	if err := btSetNonblocking(s); err != nil {
		_ = windows.Closesocket(s)
		return nil, err
	}
	return &winRfcommConn{s: s}, nil
}

// BLUETOOTH_DEVICE_SEARCH_PARAMS
type btDeviceSearchParams struct {
	size                uint32
	returnAuthenticated int32
	returnRemembered    int32
	returnUnknown       int32
	returnConnected     int32
	issueInquiry        int32
	timeoutMultiplier   uint8
	radio               windows.Handle
}

// BLUETOOTH_DEVICE_INFO
type btDeviceInfo struct {
	size          uint32
	address       uint64
	classOfDevice uint32
	connected     int32
	remembered    int32
	authenticated int32
	lastSeen      [8]uint16
	lastUsed      [8]uint16
	name          [btMaxNameLength]uint16
}

// The layouts must be the 64-bit C ones: the build fails otherwise.
var (
	_ [560 - unsafe.Sizeof(btDeviceInfo{})]byte
	_ [unsafe.Sizeof(btDeviceInfo{}) - 560]byte
	_ [40 - unsafe.Sizeof(btDeviceSearchParams{})]byte
	_ [unsafe.Sizeof(btDeviceSearchParams{}) - 40]byte
	_ [16 - unsafe.Sizeof(btPollFd{})]byte
	_ [unsafe.Sizeof(btPollFd{}) - 16]byte
	_ [30 - unsafe.Sizeof(windows.RawSockaddrBth{})]byte
	_ [unsafe.Sizeof(windows.RawSockaddrBth{}) - 30]byte
)

// btPaired lists the phones and computers paired with this one (no
// inquiry: nothing is sent over the air).
func btPaired() ([]string, error) {
	if err := btProcFindFirst.Find(); err != nil {
		return nil, errBtUnsupported
	}
	params := btDeviceSearchParams{returnAuthenticated: 1}
	params.size = uint32(unsafe.Sizeof(params))
	info := btDeviceInfo{}
	info.size = uint32(unsafe.Sizeof(info))
	find, _, e := btProcFindFirst.Call(uintptr(unsafe.Pointer(&params)), uintptr(unsafe.Pointer(&info)))
	if find == 0 {
		if errors.Is(e, windows.ERROR_NO_MORE_ITEMS) {
			return nil, nil
		}
		return nil, e
	}
	defer btProcFindDeviceClose.Call(find)
	var out []string
	for {
		major := (info.classOfDevice >> btClassOfDeviceBit) & 0x1f
		if info.authenticated != 0 && (major == btMajorComputer || major == btMajorPhone) {
			out = append(out, btAddressText(info.address))
		}
		info = btDeviceInfo{}
		info.size = uint32(unsafe.Sizeof(info))
		ok, _, _ := btProcFindNext.Call(find, uintptr(unsafe.Pointer(&info)))
		if ok == 0 {
			return out, nil
		}
	}
}

// btAddressText writes a BTH_ADDR (least significant byte first in memory,
// a number here) as AA:BB:CC:DD:EE:FF.
func btAddressText(addr uint64) string {
	var bytes [6]byte
	for i := range bytes {
		bytes[i] = byte(addr >> (8 * (5 - i)))
	}
	return formatBtAddress(bytes)
}

func btAddressValue(text string) (uint64, error) {
	bytes, err := parseBtAddress(text)
	if err != nil {
		return 0, err
	}
	var addr uint64
	for _, b := range bytes {
		addr = addr<<8 | uint64(b)
	}
	return addr, nil
}
