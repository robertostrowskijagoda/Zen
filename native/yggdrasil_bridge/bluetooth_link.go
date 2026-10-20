package main

import (
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"sort"
	"sync"
	"time"
)

// Bluetooth streams the bridge opens itself, where no platform bridge does
// (Linux: BLE L2CAP channels, bluetooth_link_linux.go; Windows: classic
// RFCOMM with paired devices, bluetooth_link_windows.go). Each stream is
// handed to the node exactly as a native transport hands one
// (local_link_stream.go): the app asks the node for an endpoint, and the
// stream is connected to 127.0.0.1:port, gets the token first and is then
// pumped both ways until either side closes. Nothing here knows any node:
// the app (bluetooth_local_links.dart) decides whom to connect to and which
// incoming stream goes where.
//
// The wire format the other platforms share (ZenBluetoothLinkBridge.kt,
// ZenLocalLinksBridge.swift):
//   - BLE: GATT service 5a454e00-6c69-6e6b-0000-000000000001 (advertised),
//     characteristics …0002 (the advert) and …0003 (the L2CAP PSM, uint16
//     little-endian); manufacturer data of company 0xFFFF: "ZL", the PSM
//     (uint16 little-endian), the advert.
//   - RFCOMM: the service class 5a454e00-6c69-6e6b-0000-000000000004.
const (
	// Incoming streams wait this long for the app's endpoint.
	btIncomingWait = 15 * time.Second
	btMaxIncoming  = 8
	// Incoming streams waiting from one device at once, so that one device
	// cannot take every slot.
	btMaxIncomingPerDevice = 2
	btMaxDials             = 4
	btMaxStreams           = 16
	btLoopbackWait         = 5 * time.Second
)

var (
	errBtUnsupported    = errors.New("bluetooth: not on this platform")
	errBtListenerClosed = errors.New("bluetooth: listener closed")
)

// btConn is one Bluetooth stream.
type btConn interface {
	io.ReadWriteCloser
}

// btListener takes incoming streams; accept returns the other device too.
type btListener interface {
	accept() (btConn, string, error)
	close() error
}

type btIncoming struct {
	conn     btConn
	device   string
	reported bool
	timer    *time.Timer
}

type btStream struct {
	device string
	conn   btConn
	loop   net.Conn
	once   sync.Once
}

func (s *btStream) close() {
	s.once.Do(func() {
		_ = s.conn.Close()
		_ = s.loop.Close()
	})
}

// btLinks is the process's Bluetooth streams (one radio, whichever node
// asks).
type btLinks struct {
	listen func() (btListener, map[string]any, error)
	dial   func(device string, psm int, classic bool) (btConn, error)

	mu       sync.Mutex
	listener btListener
	info     map[string]any
	incoming map[string]*btIncoming
	// Dials: "pending" until done, then "ok" or "failed" until polled.
	dials   map[string]string
	streams map[string]*btStream
}

func newBtLinks(
	listen func() (btListener, map[string]any, error),
	dial func(device string, psm int, classic bool) (btConn, error),
) *btLinks {
	return &btLinks{
		listen:   listen,
		dial:     dial,
		incoming: map[string]*btIncoming{},
		dials:    map[string]string{},
		streams:  map[string]*btStream{},
	}
}

// start listens for incoming streams (again a no-op while it does).
func (b *btLinks) start() (map[string]any, error) {
	b.mu.Lock()
	if b.listener != nil {
		info := b.info
		b.mu.Unlock()
		return info, nil
	}
	b.mu.Unlock()
	listener, info, err := b.listen()
	if err != nil {
		return nil, err
	}
	b.mu.Lock()
	if b.listener != nil {
		// Started meanwhile.
		info = b.info
		b.mu.Unlock()
		_ = listener.close()
		return info, nil
	}
	b.listener = listener
	b.info = info
	b.mu.Unlock()
	go b.acceptLoop(listener)
	return info, nil
}

func (b *btLinks) acceptLoop(listener btListener) {
	for {
		conn, device, err := listener.accept()
		if err != nil {
			b.mu.Lock()
			if b.listener == listener {
				// The radio went away: the next start listens again.
				b.listener = nil
				b.info = nil
			}
			b.mu.Unlock()
			_ = listener.close()
			return
		}
		b.addIncoming(conn, device)
	}
}

func (b *btLinks) addIncoming(conn btConn, device string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.listener == nil || len(b.incoming) >= btMaxIncoming || len(b.streams) >= btMaxStreams {
		_ = conn.Close()
		return
	}
	fromDevice := 0
	for _, entry := range b.incoming {
		if entry.device == device {
			fromDevice++
		}
	}
	if fromDevice >= btMaxIncomingPerDevice {
		_ = conn.Close()
		return
	}
	id := randomLocalID()
	entry := &btIncoming{conn: conn, device: device}
	entry.timer = time.AfterFunc(btIncomingWait, func() { b.reject(id) })
	b.incoming[id] = entry
}

// stop closes the listener and every stream.
func (b *btLinks) stop() {
	b.mu.Lock()
	listener := b.listener
	b.listener = nil
	b.info = nil
	incoming := b.incoming
	b.incoming = map[string]*btIncoming{}
	streams := b.streams
	b.streams = map[string]*btStream{}
	b.dials = map[string]string{}
	b.mu.Unlock()
	if listener != nil {
		_ = listener.close()
	}
	for _, entry := range incoming {
		entry.timer.Stop()
		_ = entry.conn.Close()
	}
	for _, stream := range streams {
		stream.close()
	}
}

// poll: incoming streams not reported yet, dials that ended, and the
// devices with a stream open.
func (b *btLinks) poll() map[string]any {
	b.mu.Lock()
	defer b.mu.Unlock()
	incoming := []string{}
	for id, entry := range b.incoming {
		if !entry.reported {
			entry.reported = true
			incoming = append(incoming, id)
		}
	}
	sort.Strings(incoming)
	dials := map[string]string{}
	for id, state := range b.dials {
		if state != "pending" {
			dials[id] = state
			delete(b.dials, id)
		}
	}
	devices := []string{}
	seen := map[string]bool{}
	for _, stream := range b.streams {
		if !seen[stream.device] {
			seen[stream.device] = true
			devices = append(devices, stream.device)
		}
	}
	sort.Strings(devices)
	return map[string]any{
		"listening": b.listener != nil,
		"incoming":  incoming,
		"dials":     dials,
		"devices":   devices,
	}
}

func (b *btLinks) take(id string) *btIncoming {
	b.mu.Lock()
	defer b.mu.Unlock()
	entry := b.incoming[id]
	if entry != nil {
		delete(b.incoming, id)
		entry.timer.Stop()
	}
	return entry
}

// accept pumps the incoming stream id into the endpoint port/token.
func (b *btLinks) accept(id string, port int, token []byte) error {
	entry := b.take(id)
	if entry == nil {
		return fmt.Errorf("bluetooth: no incoming stream %q", id)
	}
	if err := b.pump(entry.conn, entry.device, port, token); err != nil {
		_ = entry.conn.Close()
		return err
	}
	return nil
}

func (b *btLinks) reject(id string) {
	if entry := b.take(id); entry != nil {
		_ = entry.conn.Close()
	}
}

// dialAsync opens a stream to device and pumps it into the endpoint; the
// outcome comes with a later poll under the returned id.
func (b *btLinks) dialAsync(device string, psm int, classic bool, port int, token []byte) (string, error) {
	if device == "" || len(device) > 64 {
		return "", fmt.Errorf("%w: device", errLocalLinkBadInput)
	}
	if err := checkBtEndpoint(port, token); err != nil {
		return "", err
	}
	b.mu.Lock()
	pending := 0
	for _, state := range b.dials {
		if state == "pending" {
			pending++
		}
	}
	if pending >= btMaxDials || len(b.streams) >= btMaxStreams {
		b.mu.Unlock()
		return "", errors.New("bluetooth: too many streams")
	}
	id := randomLocalID()
	b.dials[id] = "pending"
	b.mu.Unlock()
	go func() {
		state := "ok"
		conn, err := b.dial(device, psm, classic)
		if err == nil {
			if err = b.pump(conn, device, port, token); err != nil {
				_ = conn.Close()
			}
		}
		if err != nil {
			state = "failed"
		}
		b.mu.Lock()
		if _, ok := b.dials[id]; ok {
			b.dials[id] = state
		}
		b.mu.Unlock()
	}()
	return id, nil
}

func checkBtEndpoint(port int, token []byte) error {
	if port <= 0 || port > 65535 || len(token) != localStreamTokenSize {
		return fmt.Errorf("%w: endpoint", errLocalLinkBadInput)
	}
	return nil
}

// pump connects conn to the node's endpoint and copies both ways until
// either side ends; it owns conn once it returns nil.
func (b *btLinks) pump(conn btConn, device string, port int, token []byte) error {
	if err := checkBtEndpoint(port, token); err != nil {
		return err
	}
	loop, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), btLoopbackWait)
	if err != nil {
		return err
	}
	if _, err := loop.Write(token); err != nil {
		_ = loop.Close()
		return err
	}
	stream := &btStream{device: device, conn: conn, loop: loop}
	id := randomLocalID()
	b.mu.Lock()
	b.streams[id] = stream
	b.mu.Unlock()
	go func() {
		done := make(chan struct{}, 2)
		go func() {
			_, _ = io.Copy(loop, conn)
			done <- struct{}{}
		}()
		go func() {
			_, _ = io.Copy(conn, loop)
			done <- struct{}{}
		}()
		<-done
		stream.close()
		<-done
		b.mu.Lock()
		delete(b.streams, id)
		b.mu.Unlock()
	}()
	return nil
}

// openDevices are the devices a stream is open with.
func (b *btLinks) openDevices() map[string]bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	out := map[string]bool{}
	for _, stream := range b.streams {
		out[stream.device] = true
	}
	return out
}

func parseBtToken(tokenHex string) ([]byte, error) {
	token, err := hex.DecodeString(tokenHex)
	if err != nil || len(token) != localStreamTokenSize {
		return nil, fmt.Errorf("%w: token", errLocalLinkBadInput)
	}
	return token, nil
}

// formatBtAddress writes a Bluetooth address (most significant byte
// first) as AA:BB:CC:DD:EE:FF.
func formatBtAddress(addr [6]byte) string {
	return fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X", addr[0], addr[1], addr[2], addr[3], addr[4], addr[5])
}

// parseBtAddress reads AA:BB:CC:DD:EE:FF (most significant byte first).
func parseBtAddress(text string) ([6]byte, error) {
	var addr [6]byte
	if len(text) != 17 {
		return addr, fmt.Errorf("%w: address %q", errLocalLinkBadInput, text)
	}
	for i := range addr {
		if i > 0 && text[i*3-1] != ':' {
			return addr, fmt.Errorf("%w: address %q", errLocalLinkBadInput, text)
		}
		b, err := hex.DecodeString(text[i*3 : i*3+2])
		if err != nil {
			return addr, fmt.Errorf("%w: address %q", errLocalLinkBadInput, text)
		}
		addr[i] = b[0]
	}
	return addr, nil
}
