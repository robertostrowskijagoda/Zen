package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

// Random input for everything the bridge reads from the network or a
// nearby device: no parser may panic, read past its input or accept what
// its builder would not make; where there is a builder, what it builds is
// read back the same. `go test` runs the seeds below on every run; CI also
// fuzzes each target for a few seconds (go test -fuzz=FuzzX -fuzztime=…).

func FuzzParseRelayFrame(f *testing.F) {
	frame, _ := buildRelayFrame("call-1", []byte("media"))
	f.Add(frame)
	f.Add([]byte{})
	f.Add([]byte{0})
	f.Add([]byte{255, 'a'})
	f.Fuzz(func(t *testing.T, data []byte) {
		callID, payload, ok := parseRelayFrame(data)
		if !ok {
			return
		}
		if len(callID) == 0 || len(callID) > 255 {
			t.Fatalf("accepted a call id of %d bytes", len(callID))
		}
		again, err := buildRelayFrame(callID, payload)
		if err != nil || !bytes.Equal(again, data) {
			t.Fatalf("read back differently: %v", err)
		}
	})
}

func FuzzParseYggPacket(f *testing.F) {
	source := net.ParseIP("200::1")
	packet, _ := buildYggPacket(source, net.ParseIP("200::2"), 9999, []byte(`{"type":"ping"}`))
	f.Add(packet)
	f.Add(make([]byte, 48))
	f.Add([]byte{0x60})
	f.Fuzz(func(t *testing.T, data []byte) {
		from, _, payload, ok := parseYggPacket(data)
		if !ok {
			return
		}
		if len(from) != net.IPv6len {
			t.Fatalf("a source of %d bytes", len(from))
		}
		if len(payload) > len(data) {
			t.Fatal("a payload longer than the packet")
		}
	})
}

func FuzzParseLanBeacon(f *testing.F) {
	f.Add(lanBeacon(lanBeaconFields{
		advert: make([]byte, localLinkAdvertHeader+localLinkMinBloomBytes),
		port:   4242,
	}))
	f.Add(lanBeacon(lanBeaconFields{
		advert:  make([]byte, localLinkAdvertHeader+localLinkMinBloomBytes+4),
		nearby:  make([]byte, lanNearbyAdvertBytes),
		looking: true,
		port:    1,
	}))
	f.Add([]byte{1, 2, 3})
	f.Fuzz(func(t *testing.T, data []byte) {
		fields, ok := parseLanBeacon(data)
		if !ok {
			return
		}
		if fields.port <= 0 || fields.port > 0xffff {
			t.Fatalf("port %d", fields.port)
		}
		if !bytes.Equal(lanBeacon(fields), data) {
			t.Fatal("read back differently")
		}
	})
}

func FuzzParseLocalHello(f *testing.F) {
	f.Add([]byte{localHandshakeVersion})
	f.Add(append([]byte{localHandshakeVersion}, make([]byte, localEphemeralSize+2)...))
	whole := append([]byte{localHandshakeVersion}, make([]byte, localEphemeralSize+2+64*localSelectorSize)...)
	whole[1+localEphemeralSize+1] = 64
	f.Add(whole)
	f.Fuzz(func(t *testing.T, data []byte) {
		ephemeral, selectors, err := parseLocalHello(data)
		if err != nil {
			return
		}
		if len(ephemeral) != localEphemeralSize || len(selectors) > localMaxSelectors || !localHelloSizeAllowed(len(data)) {
			t.Fatalf("ephemeral %d bytes, %d selectors, hello of %d bytes", len(ephemeral), len(selectors), len(data))
		}
	})
}

// Whatever a stranger nearby sends, the handshake ends with an error well
// within its time and never panics.
func FuzzLocalLinkHandshake(f *testing.F) {
	keyA, _, _ := ed25519.GenerateKey(nil)
	keyB, _, _ := ed25519.GenerateKey(nil)
	peer, err := newLocalPeer(meshAddressForKey(keyB), "0000000000000000000000000000000000000000000000000000000000000001", false)
	if err != nil {
		f.Fatal(err)
	}
	peers := []localPeer{peer}
	opening := append([]byte{0, localOpeningSize, localHandshakeVersion}, make([]byte, localNonceSize)...)
	f.Add([]byte{0, 5, 2, 1, 2, 3, 4})
	f.Add(opening)
	f.Add(append(append([]byte(nil), opening...), 0x06, 0xC3, localHandshakeVersion))
	f.Add([]byte{0xFF, 0xFF})
	f.Fuzz(func(t *testing.T, data []byte) {
		stranger, device := net.Pipe()
		go func() {
			buf := make([]byte, 4096)
			for {
				if _, err := stranger.Read(buf); err != nil {
					return
				}
			}
		}()
		done := make(chan error, 1)
		go func() {
			_, err := localLinkHandshakeWithin(device, peers, keyA, localFirstFrameTimeout)
			_ = device.Close()
			done <- err
		}()
		_, _ = stranger.Write(data)
		_ = stranger.Close()
		select {
		case err := <-done:
			if err == nil {
				t.Fatal("a stranger's bytes passed the handshake")
			}
		case <-time.After(localHandshakeTimeout + 2*time.Second):
			t.Fatal("the handshake did not end")
		}
	})
}

func FuzzReadLocalFrame(f *testing.F) {
	var buffer bytes.Buffer
	_ = writeLocalFrame(&buffer, []byte("hello"))
	f.Add(buffer.Bytes(), 64)
	f.Add([]byte{0xff, 0xff}, 16)
	f.Fuzz(func(t *testing.T, data []byte, limit int) {
		if limit < 0 || limit > 1<<16 {
			return
		}
		body, err := readLocalFrame(bytes.NewReader(data), limit)
		if err == nil && len(body) > limit {
			t.Fatalf("a frame of %d bytes past the limit %d", len(body), limit)
		}
	})
}

func FuzzDoorObject(f *testing.F) {
	f.Add([]byte(`{"type":"pebble_get","id":"x"}`))
	f.Add([]byte(`{"type":"a","TYPE":"b"}`))
	f.Add([]byte(`{"a":1}{"b":2}`))
	f.Add([]byte(`[`))
	f.Fuzz(func(t *testing.T, data []byte) {
		fields, ok := doorObject(data)
		if !ok {
			return
		}
		// What the door accepts, encoding/json reads the same way.
		var plain map[string]json.RawMessage
		if err := json.Unmarshal(data, &plain); err != nil {
			t.Fatalf("accepted what encoding/json refuses: %v", err)
		}
		if len(plain) != len(fields) {
			t.Fatalf("%d fields, encoding/json sees %d", len(fields), len(plain))
		}
	})
}

func FuzzParseDNSQuestion(f *testing.F) {
	f.Add([]byte{0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 3, 'z', 'e', 'n', 0, 0, 1, 0, 1})
	f.Add(make([]byte, 12))
	f.Fuzz(func(t *testing.T, data []byte) {
		question, ok := parseDNSQuestion(data)
		if !ok {
			return
		}
		if question.end > len(data) || len(question.name) > 255 {
			t.Fatalf("end %d of %d, name of %d", question.end, len(data), len(question.name))
		}
	})
}

// What a linked device sends over the link, in pieces of any size: the
// scanner takes it all and never stops the stream; a frame counts once its
// head came, and no frame is longer than a node takes.
func FuzzLinkFrameScanner(f *testing.F) {
	self := make(ed25519.PublicKey, ed25519.PublicKeySize)
	other := make(ed25519.PublicKey, ed25519.PublicKeySize)
	other[0] = 1
	stream := append([]byte("meta\x00\x00"), 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01, 0x09)
	f.Add(stream, byte(3))
	traffic := append([]byte("meta\x00\x00"), 0x4a, linkFrameTraffic, 3, 0, 7, 0)
	traffic = append(traffic, other...)
	traffic = append(traffic, self...)
	f.Add(traffic, byte(7))
	f.Fuzz(func(t *testing.T, data []byte, piece byte) {
		var forwarded atomic.Uint64
		var talked atomic.Int64
		for _, outbound := range []bool{false, true} {
			scanner := newLinkFrameScanner(self, other, outbound, &forwarded, &talked)
			rest := data
			for len(rest) > 0 {
				n := min(len(rest), 1+int(piece)%64)
				if written, err := scanner.Write(rest[:n]); written != n || err != nil {
					t.Fatalf("wrote %d of %d: %v", written, n, err)
				}
				rest = rest[n:]
			}
		}
		if frames := uint64(len(data)/2 + 1); forwarded.Load() > 2*frames*(linkFrameMax+10) {
			t.Fatalf("counted %d bytes of %d", forwarded.Load(), len(data))
		}
	})
}

// A call's first datagrams from a local socket and from the peer, and
// adverts anyone nearby sends.
func FuzzRelayAdmissionAndLocalAdverts(f *testing.F) {
	f.Add([]byte{0x00, 0x01, 0x00, 0x08, 0x21, 0x12, 0xA4, 0x42, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0x00, 0x06, 0x00, 0x03, 'a', ':', 'b', 0})
	f.Add(make([]byte, 40))
	f.Add(lanBeacon(lanBeaconFields{
		advert: make([]byte, localLinkAdvertHeader+localLinkMinBloomBytes),
		port:   4242,
	}))
	peer, err := newLocalPeer("200::1", "0000000000000000000000000000000000000000000000000000000000000001", false)
	if err != nil {
		f.Fatal(err)
	}
	peers := []localPeer{peer}
	now := time.Unix(1_800_000_000, 0)
	f.Fuzz(func(t *testing.T, data []byte) {
		if name, ok := stunBindingRequestUsername(data); ok {
			if len(name) == 0 || len(name) > stunMaxUsernameBytes {
				t.Fatalf("a username of %d bytes", len(name))
			}
			if swapped, ok := swappedICEUsername(name); ok {
				if back, ok := swappedICEUsername(swapped); !ok || back != name {
					t.Fatalf("%q swapped twice is %q", name, back)
				}
			}
		}
		var admission relayAdmission
		admission.learnFromPeer(data)
		admission.judgeFirstDatagram(data)
		if len(matchLocalAdvert(peers, data, now)) > len(peers) {
			t.Fatal("more matches than peers")
		}
		if fields, ok := parseLanBeacon(data); ok {
			matchLocalAdvert(peers, fields.advert, now)
		}
	})
}

func FuzzReassembleSignal(f *testing.F) {
	one, _ := json.Marshal(signalEnvelope{
		ID:      "s1",
		Index:   0,
		Total:   1,
		Payload: base64.StdEncoding.EncodeToString([]byte(`{"type":"ping"}`)),
	})
	f.Add(one)
	f.Add([]byte(`{"id":"x","index":0,"total":2,"payload":"QQ=="}`))
	f.Add([]byte(`{"total":-1}`))
	f.Fuzz(func(t *testing.T, data []byte) {
		node := newTestBridgeNode()
		text, ok := node.reassembleSignal("200:1111::1", data)
		if ok && len(text) > maxSignalPayloadBytes && !isPQWire(text) {
			t.Fatalf("a signal of %d bytes", len(text))
		}
	})
}
