package main

import (
	"encoding/binary"
	"strings"
	"sync"
	"time"
)

// Admission of local sockets to a call relay (STAN S38).
//
// The relay is a UDP port on this device that the local WebRTC stack sends
// call media to. Any other app on the device can send to that port too, so
// "the first local process that speaks owns the relay" let a local app take
// a call's media path. A local socket is now admitted only when its first
// datagram proves it belongs to this call: WebRTC always opens with an ICE
// connectivity check, a STUN Binding request whose USERNAME is
// "<remote ufrag>:<local ufrag>". Both ufrags are random per call and travel
// only inside the end-to-end encrypted call signaling and over loopback, so
// no other app on the device knows them.
//
// The relay learns the expected USERNAME from the peer's own checks, which
// arrive over the mesh from the peer's (authenticated) address carrying
// "<local ufrag>:<remote ufrag>". Until it has learned it, a local Binding
// request is passed to the peer (rate limited) without admitting its
// sender, so the peer can learn ours the same way and neither side waits
// for the other. Relays of older versions forward everything, which also
// works.

const (
	stunHeaderSize       = 20
	stunMagicCookie      = 0x2112A442
	stunBindingRequest   = 0x0001
	stunAttributeUser    = 0x0006
	stunMaxUsernameBytes = 513

	// Usernames remembered per relay (an ICE restart adds a pair).
	maxRelayExpectedUsernames = 16
	// Local Binding requests passed to the peer per second before the
	// sender is admitted; ICE paces its checks far below this.
	relayUnadmittedForwardsPerSecond = 40
	// Largest unadmitted datagram passed on (a STUN check is ~100-200 B).
	relayUnadmittedMaxBytes = 1200
)

// stunBindingRequestUsername returns the USERNAME attribute of a STUN
// Binding request (RFC 8489), or ok=false when packet is anything else.
func stunBindingRequestUsername(packet []byte) (string, bool) {
	if len(packet) < stunHeaderSize || packet[0]&0xC0 != 0 {
		return "", false
	}
	if binary.BigEndian.Uint16(packet[0:2]) != stunBindingRequest {
		return "", false
	}
	if binary.BigEndian.Uint32(packet[4:8]) != stunMagicCookie {
		return "", false
	}
	length := int(binary.BigEndian.Uint16(packet[2:4]))
	if length%4 != 0 || stunHeaderSize+length > len(packet) {
		return "", false
	}
	attributes := packet[stunHeaderSize : stunHeaderSize+length]
	for len(attributes) >= 4 {
		kind := binary.BigEndian.Uint16(attributes[0:2])
		size := int(binary.BigEndian.Uint16(attributes[2:4]))
		if 4+size > len(attributes) {
			return "", false
		}
		if kind == stunAttributeUser {
			if size == 0 || size > stunMaxUsernameBytes {
				return "", false
			}
			return string(attributes[4 : 4+size]), true
		}
		padded := (size + 3) &^ 3
		if 4+padded > len(attributes) {
			return "", false
		}
		attributes = attributes[4+padded:]
	}
	return "", false
}

// swappedICEUsername turns the "<receiver>:<sender>" USERNAME of a check
// seen in one direction into the one expected in the other direction.
func swappedICEUsername(username string) (string, bool) {
	separator := strings.IndexByte(username, ':')
	if separator <= 0 || separator == len(username)-1 ||
		strings.IndexByte(username[separator+1:], ':') >= 0 {
		return "", false
	}
	return username[separator+1:] + ":" + username[:separator], true
}

// relayAdmission decides which local sockets may use one call relay.
// The zero value is ready to use.
type relayAdmission struct {
	mu       sync.Mutex
	expected map[string]struct{}
	// Unadmitted forwards in the current one-second window.
	windowStart time.Time
	windowCount int
	now         func() time.Time
}

func (admission *relayAdmission) clock() time.Time {
	if admission.now != nil {
		return admission.now()
	}
	return time.Now()
}

// learnFromPeer records the USERNAME a local check must carry, from a
// datagram the peer sent over the mesh (already checked to come from the
// call's remote address).
func (admission *relayAdmission) learnFromPeer(payload []byte) {
	username, ok := stunBindingRequestUsername(payload)
	if !ok {
		return
	}
	expected, ok := swappedICEUsername(username)
	if !ok {
		return
	}
	admission.mu.Lock()
	defer admission.mu.Unlock()
	if admission.expected == nil {
		admission.expected = make(map[string]struct{})
	}
	if _, known := admission.expected[expected]; known {
		return
	}
	if len(admission.expected) >= maxRelayExpectedUsernames {
		// Make room for the newest (an ICE restart brings new credentials).
		for key := range admission.expected {
			delete(admission.expected, key)
			break
		}
	}
	admission.expected[expected] = struct{}{}
}

// relayAdmissionVerdict is what to do with a datagram from a local socket
// that is not admitted yet.
type relayAdmissionVerdict int

const (
	// Drop it.
	relayDrop relayAdmissionVerdict = iota
	// Admit the sender (it proved the call's ICE credentials) and relay it.
	relayAdmit
	// Pass it to the peer without admitting the sender: a check whose
	// credentials the relay cannot verify yet.
	relayForwardOnly
)

// judgeFirstDatagram decides about a datagram from a not yet admitted
// local socket.
func (admission *relayAdmission) judgeFirstDatagram(payload []byte) relayAdmissionVerdict {
	username, ok := stunBindingRequestUsername(payload)
	if !ok {
		return relayDrop
	}
	admission.mu.Lock()
	defer admission.mu.Unlock()
	if _, known := admission.expected[username]; known {
		return relayAdmit
	}
	if len(payload) > relayUnadmittedMaxBytes {
		return relayDrop
	}
	now := admission.clock()
	if admission.windowStart.IsZero() || now.Sub(admission.windowStart) >= time.Second {
		admission.windowStart = now
		admission.windowCount = 0
	}
	if admission.windowCount >= relayUnadmittedForwardsPerSecond {
		return relayDrop
	}
	admission.windowCount++
	return relayForwardOnly
}
