package main

import (
	"bytes"
	"crypto/ed25519"
	"encoding/binary"
	"net"
	"sync/atomic"
	"testing"
	"time"

	iwt "github.com/Arceliar/ironwood/types"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// linkFrame is one ironwood frame as a link carries it: its length, the
// type and the content.
func linkFrame(packetType byte, content []byte) []byte {
	frame := binary.AppendUvarint(nil, uint64(len(content)+1))
	frame = append(frame, packetType)
	return append(frame, content...)
}

// trafficFrame is a traffic frame from source to dest with payload bytes.
func trafficFrame(source, dest ed25519.PublicKey, payload int) []byte {
	var content []byte
	for _, port := range []uint64{3, 200, 1} {
		content = binary.AppendUvarint(content, port)
	}
	content = binary.AppendUvarint(content, 0)
	content = binary.AppendUvarint(content, 7)
	content = binary.AppendUvarint(content, 0)
	content = append(content, source...)
	content = append(content, dest...)
	content = binary.AppendUvarint(content, 42)
	content = append(content, make([]byte, payload)...)
	return linkFrame(linkFrameTraffic, content)
}

// linkMeta is the version metadata a link starts with.
func linkMeta(fields int) []byte {
	meta := append([]byte("meta"), 0, 0)
	binary.BigEndian.PutUint16(meta[4:6], uint16(fields))
	return append(meta, make([]byte, fields)...)
}

func TestTheLinkScannerCountsWhatAFriendSendsThroughThisNode(t *testing.T) {
	self, friend, stranger := testNodeKey(t), testNodeKey(t), testNodeKey(t)
	var forwarded atomic.Uint64
	var talked atomic.Int64
	now := time.Unix(5000, 0)
	fromFriend := newLinkFrameScanner(self, friend, false, &forwarded, &talked)
	fromFriend.now = func() time.Time { return now }

	var stream bytes.Buffer
	stream.Write(linkMeta(120))
	stream.Write(linkFrame(1, nil))                // a keepalive
	stream.Write(linkFrame(4, make([]byte, 300)))  // tree upkeep
	passed := trafficFrame(friend, stranger, 1200) // the friend's own, on to the internet
	stream.Write(passed)
	stream.Write(trafficFrame(stranger, self, 900))   // someone else's, routed by the friend
	stream.Write(trafficFrame(stranger, friend, 900)) // not the friend's to send on
	stream.Write(trafficFrame(friend, self, 100))     // the two talk
	stream.Write(passed)
	// In pieces of every size, as a stream comes.
	data := stream.Bytes()
	for len(data) > 0 {
		n := min(len(data), 1+len(data)%7)
		if _, err := fromFriend.Write(data[:n]); err != nil {
			t.Fatal(err)
		}
		data = data[n:]
	}
	if fromFriend.broken {
		t.Fatal("the scanner lost the frames")
	}
	if got, want := forwarded.Load(), uint64(2*len(passed)); got != want {
		t.Fatalf("counted %d bytes for the friend, want %d", got, want)
	}
	if !talkingSince(talked.Load(), now.Add(time.Minute)) {
		t.Fatal("a frame between the two counts as talking")
	}
	if talkingSince(talked.Load(), now.Add(localLinkTalkWindow)) {
		t.Fatal("talking ends a while after the last frame")
	}

	// The other way: what goes to the friend from elsewhere counts, what
	// this node sends it is its own.
	var out atomic.Uint64
	toFriend := newLinkFrameScanner(self, friend, true, &out, nil)
	toFriend.Write(linkMeta(8))
	forFriend := trafficFrame(stranger, friend, 500)
	toFriend.Write(forFriend)
	toFriend.Write(trafficFrame(self, friend, 500))
	toFriend.Write(trafficFrame(stranger, self, 500))
	if got := out.Load(); got != uint64(len(forFriend)) {
		t.Fatalf("counted %d bytes going to the friend, want %d", got, len(forFriend))
	}
}

func TestAStreamThatIsNotALinkIsNotCounted(t *testing.T) {
	var forwarded atomic.Uint64
	scanner := newLinkFrameScanner(testNodeKey(t), testNodeKey(t), false, &forwarded, nil)
	scanner.Write([]byte("GET / HTTP/1.1\r\n\r\n"))
	if !scanner.broken || forwarded.Load() != 0 {
		t.Fatal("no metadata, nothing counted")
	}
}

func TestAFriendsOwnTrafficIsNoTransit(t *testing.T) {
	before := trafficTotals{}
	after := trafficTotals{peerRx: 3 << 20, peerTx: 3 << 20, friend: 3 << 20}
	if got := estimateTransit(before, after, 2, trafficWindow); got != 0 {
		t.Fatalf("a friend's own 3 MB counted as %d bytes of transit", got)
	}
	after.peerRx += 2 << 20
	after.peerTx += 2 << 20
	if got := estimateTransit(before, after, 2, trafficWindow); got < 1<<20 {
		t.Fatalf("strangers' traffic beside it still counts, got %d", got)
	}
}

// linkedPhone is a phone node with a public peer and a friend's device
// linked nearby, both of whose traffic may pass through it.
func linkedPhone(t *testing.T) (node *bridgeNode, friend *core.Core, publicURI string) {
	t.Helper()
	public, uri := listeningCore(t)
	keeper := newPhonePeerKeeper([]string{uri}, 1)
	node = testNode(t, nil)
	node.phonePeers = keeper
	node.transitGuard = &transitGuard{}
	node.swapPublicPeers(nil, keeper.dialled)
	waitForPeer(t, node.core, public.PublicKey(), true)
	go func() {
		buf := make([]byte, 65535)
		for {
			if _, _, err := public.ReadFrom(buf); err != nil {
				return
			}
		}
	}()

	friend = testCore(t)
	forPhone, forFriend := testPair(t, node.core.PublicKey(), friend.PublicKey())
	phoneManager := node.localLinkManager()
	phoneManager.apply(localLinkSettings{peers: []localPeer{forPhone}})
	friendManager := newLocalLinkManager(friend, nil)
	friendManager.apply(localLinkSettings{peers: []localPeer{forFriend}})
	t.Cleanup(phoneManager.stop)
	t.Cleanup(friendManager.stop)
	left, right := net.Pipe()
	done := make(chan error, 1)
	go func() {
		_, err := friendManager.handshakeAndAttach(right, "test", "")
		done <- err
	}()
	if _, err := phoneManager.handshakeAndAttach(left, "test", ""); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	waitForPeer(t, node.core, friend.PublicKey(), true)
	return node, friend, uri
}

// A friend's phone that reaches the internet through this one (its only
// peering is the link nearby) sends megabytes out through it. That is the
// friend's own traffic, not strangers': no hold, and the friend keeps its
// way out.
func TestAFriendsTrafficThroughThePhoneStartsNoHold(t *testing.T) {
	node, friend, publicURI := linkedPhone(t)
	public := func() ed25519.PublicKey {
		for _, peer := range node.core.GetPeers() {
			if peer.URI == publicURI || peerURIBase(peer.URI) == peerURIBase(publicURI) {
				return peer.Key
			}
		}
		t.Fatal("no public peer")
		return nil
	}()
	payload := make([]byte, 1200)
	to := iwt.Addr(public)
	// The path and the session first.
	deadline := time.Now().Add(20 * time.Second)
	for node.traffic.friendForwarded.Load() == 0 && time.Now().Before(deadline) {
		_, _ = friend.WriteTo(payload, to)
		time.Sleep(100 * time.Millisecond)
	}
	if node.traffic.friendForwarded.Load() == 0 {
		t.Fatal("nothing of the friend's passed through the phone")
	}
	start := time.Now()
	node.sampleTrafficAt(start)
	target := node.traffic.friendForwarded.Load() + 3<<20
	deadline = time.Now().Add(30 * time.Second)
	for node.traffic.friendForwarded.Load() < target && time.Now().Before(deadline) {
		for range 16 {
			_, _ = friend.WriteTo(payload, to)
		}
		time.Sleep(time.Millisecond)
	}
	if node.traffic.friendForwarded.Load() < target {
		t.Fatalf("only %d bytes of the friend's passed", node.traffic.friendForwarded.Load())
	}
	node.sampleTrafficAt(start.Add(trafficWindow))
	if state := node.transitGuardState(start.Add(trafficWindow)); state["holding"] != false {
		t.Fatalf("a friend's own 3 MB started a hold: %v", node.peerTraffic.snapshot())
	}
}

// A hold for strangers' traffic keeps the link to a friend the phone talks
// with: their conversation may have no other way.
func TestAHoldKeepsTheLinkToAFriendThePhoneTalksWith(t *testing.T) {
	node, friend, _ := linkedPhone(t)
	friendKey := friend.PublicKey()
	go func() {
		buf := make([]byte, 65535)
		for {
			if _, _, err := friend.ReadFrom(buf); err != nil {
				return
			}
		}
	}()
	manager := node.existingLocalLinks()
	talking := func() bool {
		for _, link := range manager.links {
			if talkingSince(link.talked.Load(), time.Now()) {
				return true
			}
		}
		return false
	}
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		_, _ = node.core.WriteTo([]byte("hello"), iwt.Addr(friendKey))
		manager.mu.Lock()
		done := talking()
		manager.mu.Unlock()
		if done {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	node.beginTransitHold(transitHoldBase, 1<<20)
	time.Sleep(300 * time.Millisecond)
	waitForPeer(t, node.core, friendKey, true)
	if !manager.mayLink(meshAddressForKey(friendKey)) {
		t.Fatal("the friend the phone talks with may link again during the hold")
	}
	node.endTransitHold()

	// Without talk lately the link goes with the hold, as before.
	manager.mu.Lock()
	for _, link := range manager.links {
		link.talked.Store(0)
	}
	manager.mu.Unlock()
	node.beginTransitHold(transitHoldBase, 1<<20)
	waitForPeer(t, node.core, friendKey, false)
}
