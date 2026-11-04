package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net"
	"testing"
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
	f.Fuzz(func(t *testing.T, data []byte) {
		ephemeral, selectors, err := parseLocalHello(data)
		if err != nil {
			return
		}
		if len(ephemeral) != localEphemeralSize || len(selectors) > localMaxSelectors {
			t.Fatalf("ephemeral %d bytes, %d selectors", len(ephemeral), len(selectors))
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
