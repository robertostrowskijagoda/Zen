package main

import (
	"encoding/binary"
	"testing"
	"time"
)

// stunBindingRequestFor builds an ICE connectivity check with USERNAME
// username (plus a PRIORITY attribute before it, as WebRTC sends).
func stunBindingRequestFor(username string) []byte {
	attribute := func(kind uint16, value []byte) []byte {
		out := make([]byte, 4, 4+len(value)+3)
		binary.BigEndian.PutUint16(out[0:2], kind)
		binary.BigEndian.PutUint16(out[2:4], uint16(len(value)))
		out = append(out, value...)
		for len(out)%4 != 0 {
			out = append(out, 0)
		}
		return out
	}
	body := attribute(0x0024, []byte{0x6e, 0x7f, 0x1e, 0xff})
	body = append(body, attribute(stunAttributeUser, []byte(username))...)
	packet := make([]byte, stunHeaderSize, stunHeaderSize+len(body))
	binary.BigEndian.PutUint16(packet[0:2], stunBindingRequest)
	binary.BigEndian.PutUint16(packet[2:4], uint16(len(body)))
	binary.BigEndian.PutUint32(packet[4:8], stunMagicCookie)
	copy(packet[8:20], []byte("transaction1"))
	return append(packet, body...)
}

func TestStunBindingRequestUsername(t *testing.T) {
	username, ok := stunBindingRequestUsername(stunBindingRequestFor("abcd:wxyz"))
	if !ok || username != "abcd:wxyz" {
		t.Fatalf("got %q, %v", username, ok)
	}
	// An odd-length username is padded on the wire.
	username, ok = stunBindingRequestUsername(stunBindingRequestFor("ab+/:x"))
	if !ok || username != "ab+/:x" {
		t.Fatalf("got %q, %v", username, ok)
	}

	notStun := [][]byte{
		nil,
		[]byte("hello"),
		// DTLS / RTP start with other first bits.
		append([]byte{0x16, 0xfe, 0xfd}, make([]byte, 40)...),
		append([]byte{0x80, 0x00}, make([]byte, 40)...),
	}
	for _, packet := range notStun {
		if _, ok := stunBindingRequestUsername(packet); ok {
			t.Fatalf("%x is not a STUN Binding request", packet)
		}
	}

	response := stunBindingRequestFor("a:b")
	binary.BigEndian.PutUint16(response[0:2], 0x0101)
	if _, ok := stunBindingRequestUsername(response); ok {
		t.Fatal("a Binding success response carries no check to admit")
	}
	badCookie := stunBindingRequestFor("a:b")
	badCookie[4] ^= 0xff
	if _, ok := stunBindingRequestUsername(badCookie); ok {
		t.Fatal("a wrong magic cookie must be refused")
	}
	truncated := stunBindingRequestFor("abcd:wxyz")
	if _, ok := stunBindingRequestUsername(truncated[:len(truncated)-4]); ok {
		t.Fatal("a length past the datagram must be refused")
	}
	noUser := stunBindingRequestFor("a:b")[:stunHeaderSize+8]
	binary.BigEndian.PutUint16(noUser[2:4], 8)
	if _, ok := stunBindingRequestUsername(noUser); ok {
		t.Fatal("a check without USERNAME must be refused")
	}
}

func TestSwappedICEUsername(t *testing.T) {
	if swapped, ok := swappedICEUsername("abcd:wxyz"); !ok || swapped != "wxyz:abcd" {
		t.Fatalf("got %q, %v", swapped, ok)
	}
	for _, bad := range []string{"", "abcd", ":abcd", "abcd:", "a:b:c"} {
		if _, ok := swappedICEUsername(bad); ok {
			t.Fatalf("%q is not an ICE username", bad)
		}
	}
}

func TestRelayAdmissionNeedsTheCallsCredentials(t *testing.T) {
	var admission relayAdmission
	// The peer (ufrag "peer") checks us (ufrag "mine").
	admission.learnFromPeer(stunBindingRequestFor("mine:peer"))

	if verdict := admission.judgeFirstDatagram(stunBindingRequestFor("peer:mine")); verdict != relayAdmit {
		t.Fatalf("our WebRTC's own check must be admitted, got %v", verdict)
	}
	if verdict := admission.judgeFirstDatagram([]byte("first!")); verdict != relayDrop {
		t.Fatalf("a datagram that is not an ICE check must be dropped, got %v", verdict)
	}
	if verdict := admission.judgeFirstDatagram(stunBindingRequestFor("evil:app")); verdict != relayForwardOnly {
		t.Fatalf("an unknown check is only passed on, got %v", verdict)
	}
}

func TestRelayAdmissionLearnsOnlyFromChecks(t *testing.T) {
	var admission relayAdmission
	admission.learnFromPeer([]byte("rtp or dtls"))
	admission.learnFromPeer(stunBindingRequestFor("no-colon"))
	if len(admission.expected) != 0 {
		t.Fatalf("learned %v from datagrams that are not checks", admission.expected)
	}
	for i := 0; i < maxRelayExpectedUsernames+5; i++ {
		admission.learnFromPeer(stunBindingRequestFor(string(rune('a'+i)) + ":peer"))
	}
	if len(admission.expected) != maxRelayExpectedUsernames {
		t.Fatalf("expected the set capped at %d, got %d", maxRelayExpectedUsernames, len(admission.expected))
	}
	newest := "peer:" + string(rune('a'+maxRelayExpectedUsernames+4))
	if _, ok := admission.expected[newest]; !ok {
		t.Fatal("the newest credentials must be kept")
	}
}

func TestRelayAdmissionRateLimitsUnverifiedChecks(t *testing.T) {
	now := time.Unix(1000, 0)
	admission := relayAdmission{now: func() time.Time { return now }}
	check := stunBindingRequestFor("x:y")
	for i := 0; i < relayUnadmittedForwardsPerSecond; i++ {
		if verdict := admission.judgeFirstDatagram(check); verdict != relayForwardOnly {
			t.Fatalf("check %d: got %v", i, verdict)
		}
	}
	if verdict := admission.judgeFirstDatagram(check); verdict != relayDrop {
		t.Fatalf("over the budget a check must be dropped, got %v", verdict)
	}
	now = now.Add(time.Second)
	if verdict := admission.judgeFirstDatagram(check); verdict != relayForwardOnly {
		t.Fatalf("a new second brings a new budget, got %v", verdict)
	}
	big := append(stunBindingRequestFor("x:y"), make([]byte, relayUnadmittedMaxBytes)...)
	if verdict := admission.judgeFirstDatagram(big); verdict != relayDrop {
		t.Fatalf("an oversized unverified datagram must be dropped, got %v", verdict)
	}
}
