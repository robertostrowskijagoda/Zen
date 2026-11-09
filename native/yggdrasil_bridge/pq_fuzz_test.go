package main

import (
	"bytes"
	"encoding/base64"
	"net"
	"testing"
)

// FuzzPQReceive gives an endpoint that holds a session with a peer frames
// made from the real ones of that session (key requests and records,
// session openings, data, acknowledgements) with any bytes changed, cut or
// added, as anyone on the mesh may send them. Nothing may panic, and no
// frame that is not one the peer really sent may open into a message.
func FuzzPQReceive(f *testing.F) {
	type seeded struct {
		wire []byte
	}
	var corpus []seeded
	{
		t := &testing.T{}
		network := newPQTestNet(t)
		a, _ := network.add(1)
		_, bIP := network.add(2)
		_ = a.send(bIP, []byte(`{"type":"message","text":"hej"}`))
		network.pump()
		_ = a.send(bIP, []byte(`{"type":"message","text":"druga"}`))
		network.pump()
		for _, frame := range network.sent {
			corpus = append(corpus, seeded{wire: frame.wire})
		}
	}
	for _, c := range corpus {
		f.Add(c.wire)
	}
	f.Add([]byte{})
	f.Add([]byte(pqMagic))
	f.Fuzz(func(t *testing.T, wire []byte) {
		network := newPQTestNet(t)
		a, aIP := network.add(1)
		b, bIP := network.add(2)
		if err := a.send(bIP, []byte(`{"type":"message","text":"hej"}`)); err != nil {
			t.Fatal(err)
		}
		network.pump()
		network.take(bIP)
		real := false
		for _, frame := range network.sent {
			if bytes.Equal(frame.wire, wire) {
				real = true
			}
		}
		plain, ok := b.receive(aIP, wire)
		if ok && !real {
			// Every frame the session carried was taken already: a replay
			// is refused by its counter, and anything else is a forgery.
			t.Fatalf("a frame the peer never sent opened into %q", plain)
		}
		// And from a stranger's address nothing of the session opens.
		if plain, ok := b.receive(pqTestStranger(), wire); ok && len(plain) > 0 && !real {
			t.Fatalf("a stranger's frame opened into %q", plain)
		}
	})
}

// pqTestStranger is an address no endpoint of the test network has.
func pqTestStranger() net.IP {
	return net.IP{0x02, 0x00, 0xde, 0xad, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x99}
}

// FuzzDecodeSignalWire gives the decoder of joined signal fragments any
// text: base64 or not, zstd frames that claim or inflate to any size. It
// never panics, never returns more than maxSignalPayloadBytes, and never
// returns anything for text over maxSignalEncodedBytes.
func FuzzDecodeSignalWire(f *testing.F) {
	f.Add(base64.StdEncoding.EncodeToString([]byte(`{"type":"ping"}`)))
	f.Add(buildSignalWirePayload(`{"type":"message","text":"` +
		string(bytes.Repeat([]byte("ab"), 10000)) + `"}`))
	f.Add("not base64 at all")
	f.Add("")
	f.Fuzz(func(t *testing.T, encoded string) {
		text, ok := decodeSignalWire("200:1111::1", encoded)
		if !ok {
			return
		}
		if len(encoded) > maxSignalEncodedBytes {
			t.Fatalf("decoded %d encoded bytes, over the limit", len(encoded))
		}
		if len(text) > maxSignalPayloadBytes {
			t.Fatalf("a signal of %d bytes", len(text))
		}
	})
}
