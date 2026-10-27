package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"sync/atomic"
	"time"
)

// What goes over a local link on behalf of the device at its other end.
// Links nearby are with friends' and the account's own devices, and a
// friend's phone that reaches the internet through this one (its own
// peerings down, or slower than the Wi-Fi to here) sends its own traffic
// in over the link and out over this node's public peers. To the transit
// meter (traffic_meter.go) that is traffic passing through, and enough of
// it started a hold (transit_guard.go) that cut the friend off, or cut the
// link both phones talked over. It is not strangers' traffic: the scanner
// below reads the ironwood frames the link carries and counts the ones the
// friend sent or that go to the friend, which the meter then takes out of
// its estimate. Frames between this node and the friend tell that the two
// talk now: a hold keeps such a link.
//
// The frames are Yggdrasil's link protocol in clear (the loopback side of
// the adapter, local_link_stream.go): the version metadata ("meta", its
// length, the fields), then frames of a uvarint length, a type byte and
// the content. Traffic frames start with two zero-terminated paths of
// uvarints, then the source and the destination key.
const (
	// The ironwood packet type of traffic (network/wire.go).
	linkFrameTraffic = 9
	// The most of a frame looked at to classify it; a traffic frame's
	// header (two paths and two keys) is far shorter.
	linkFrameHeadMax = 1024
	// How long after the last frame between this node and the device at
	// the other end the two count as talking (a hold keeps their link).
	localLinkTalkWindow = 2 * time.Minute
)

// linkFrameScanner reads one direction of a local link and counts what
// it carries for the device at the other end. Write never fails; a stream
// it cannot read stops being counted.
type linkFrameScanner struct {
	self, other [ed25519.PublicKeySize]byte
	// The direction: towards the other device (else from it).
	outbound bool
	// Bytes of traffic frames the other device sent through this node or
	// that this node passes on to it.
	forwarded *atomic.Uint64
	// When this node and the other device last exchanged a frame (unix
	// nanoseconds).
	talked *atomic.Int64
	now    func() time.Time

	state    int
	header   []byte
	skip     int
	length   uint64
	shift    uint
	frameLen int
	head     []byte
	broken   bool
}

const (
	scanMeta = iota
	scanMetaBody
	scanLength
	scanFrame
	scanSkip
)

func newLinkFrameScanner(self, other ed25519.PublicKey, outbound bool, forwarded *atomic.Uint64, talked *atomic.Int64) *linkFrameScanner {
	scanner := &linkFrameScanner{outbound: outbound, forwarded: forwarded, talked: talked, now: time.Now}
	copy(scanner.self[:], self)
	copy(scanner.other[:], other)
	return scanner
}

func (s *linkFrameScanner) Write(p []byte) (int, error) {
	n := len(p)
	for len(p) > 0 && !s.broken {
		switch s.state {
		case scanMeta:
			take := min(6-len(s.header), len(p))
			s.header = append(s.header, p[:take]...)
			p = p[take:]
			if len(s.header) < 6 {
				continue
			}
			if !bytes.Equal(s.header[:4], []byte("meta")) {
				s.broken = true
				continue
			}
			s.skip = int(binary.BigEndian.Uint16(s.header[4:6]))
			s.header = s.header[:0]
			s.state = scanMetaBody
		case scanMetaBody:
			take := min(s.skip, len(p))
			s.skip -= take
			p = p[take:]
			if s.skip == 0 {
				s.state = scanLength
			}
		case scanLength:
			b := p[0]
			p = p[1:]
			s.length |= uint64(b&0x7f) << s.shift
			s.shift += 7
			if b&0x80 != 0 {
				if s.shift >= 64 {
					s.broken = true
				}
				continue
			}
			s.frameLen = int(s.length) + int(s.shift/7)
			s.skip = int(s.length)
			s.length, s.shift = 0, 0
			s.head = s.head[:0]
			if s.skip == 0 {
				continue
			}
			s.state = scanFrame
		case scanFrame:
			want := min(s.skip, linkFrameHeadMax) - len(s.head)
			take := min(want, len(p))
			s.head = append(s.head, p[:take]...)
			p = p[take:]
			if len(s.head) < min(s.skip, linkFrameHeadMax) {
				continue
			}
			s.classify(s.head, s.frameLen)
			s.skip -= len(s.head)
			s.state = scanSkip
			if s.skip == 0 {
				s.state = scanLength
			}
		case scanSkip:
			take := min(s.skip, len(p))
			s.skip -= take
			p = p[take:]
			if s.skip == 0 {
				s.state = scanLength
			}
		}
	}
	return n, nil
}

// classify counts one frame of size bytes (length included) whose start
// is head.
func (s *linkFrameScanner) classify(head []byte, size int) {
	if len(head) == 0 || head[0] != linkFrameTraffic {
		return
	}
	data := head[1:]
	for range 2 {
		for {
			port, used := binary.Uvarint(data)
			if used <= 0 {
				return
			}
			data = data[used:]
			if port == 0 {
				break
			}
		}
	}
	if len(data) < 2*ed25519.PublicKeySize {
		return
	}
	source := data[:ed25519.PublicKeySize]
	dest := data[ed25519.PublicKeySize : 2*ed25519.PublicKeySize]
	from, to := s.other[:], s.self[:]
	if s.outbound {
		from, to = s.self[:], s.other[:]
	}
	fromMatches := bytes.Equal(source, from)
	toMatches := bytes.Equal(dest, to)
	switch {
	case fromMatches && toMatches:
		// This node and the other device: they talk.
		if s.talked != nil {
			s.talked.Store(s.now().UnixNano())
		}
	case !s.outbound && fromMatches, s.outbound && toMatches:
		// The other device's own traffic, passed on by this node.
		if s.forwarded != nil {
			s.forwarded.Add(uint64(size))
		}
	}
}

// talkingSince reports whether a link whose last frame between the two
// ends was at talked (unix nanoseconds, 0 never) counts as talking at now.
func talkingSince(talked int64, now time.Time) bool {
	return talked != 0 && now.Sub(time.Unix(0, talked)) < localLinkTalkWindow
}
