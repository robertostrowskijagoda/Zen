package main

import (
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

func testSignalNet(t *testing.T, address string) signalSourceNet {
	t.Helper()
	ip := net.ParseIP(address)
	if ip == nil {
		t.Fatalf("bad test address %s", address)
	}
	return signalSourceNetOf(ip)
}

func testSignal(from string, payloadBytes int) signalMessage {
	return signalMessage{From: from, Payload: strings.Repeat("x", payloadBytes)}
}

func TestSignalSourcesAreGroupedBy64(t *testing.T) {
	a := testSignalNet(t, "200:1111:2222:3333::1")
	b := testSignalNet(t, "200:1111:2222:3333:4444::2")
	c := testSignalNet(t, "200:1111:2222:4444::1")
	if a != b {
		t.Fatal("addresses in one /64 must share a source")
	}
	if a == c {
		t.Fatal("addresses in different /64s must not share a source")
	}
}

func TestSignalInboxDeliversInOrderAndReleasesBytes(t *testing.T) {
	var inbox signalQueue
	network := testSignalNet(t, "200:1111::1")
	for index := 0; index < 3; index++ {
		message := signalMessage{From: "200:1111::1", Payload: fmt.Sprintf(`{"n":%d}`, index)}
		if dropped, queued := inbox.push(message, network); dropped != 0 || !queued {
			t.Fatalf("push %d: dropped=%d queued=%v", index, dropped, queued)
		}
	}
	for index := 0; index < 3; index++ {
		message, ok := inbox.wait(0)
		if !ok || message.Payload != fmt.Sprintf(`{"n":%d}`, index) {
			t.Fatalf("signal %d out of order: %q", index, message.Payload)
		}
	}
	if _, ok := inbox.wait(0); ok {
		t.Fatal("the inbox should be empty")
	}
	entries, totalBytes, sourceEntries, sourceBytes := inbox.stats(network)
	if entries != 0 || totalBytes != 0 || sourceEntries != 0 || sourceBytes != 0 || len(inbox.sources) != 0 {
		t.Fatalf("leftover accounting: %d entries, %d bytes, source %d/%d", entries, totalBytes, sourceEntries, sourceBytes)
	}
}

func TestSignalInboxKeepsEachSourceWithinItsShare(t *testing.T) {
	var inbox signalQueue
	flooder := testSignalNet(t, "200:6666::6")
	friend := testSignalNet(t, "200:7777::7")
	if _, queued := inbox.push(signalMessage{From: "200:7777::7", Payload: `{"type":"ping"}`}, friend); !queued {
		t.Fatal("the friend's signal should be queued")
	}
	for index := 0; index < 10; index++ {
		message := testSignal("200:6666::6", 700*1024)
		message.Payload = fmt.Sprintf("%02d", index) + message.Payload[2:]
		inbox.push(message, flooder)
	}

	_, _, flooderEntries, flooderBytes := inbox.stats(flooder)
	if flooderBytes > maxSignalInboxBytesPerSource {
		t.Fatalf("one source holds %d bytes, over its %d share", flooderBytes, maxSignalInboxBytesPerSource)
	}
	if flooderEntries != 3 {
		t.Fatalf("expected the source's 3 newest signals to fit its share, got %d", flooderEntries)
	}
	if _, _, friendEntries, _ := inbox.stats(friend); friendEntries != 1 {
		t.Fatal("another source's signal must not be dropped")
	}
	if first, _ := inbox.wait(0); first.From != "200:7777::7" {
		t.Fatalf("expected the friend's signal first, got one from %s", first.From)
	}
	for _, want := range []string{"07", "08", "09"} {
		if message, _ := inbox.wait(0); !strings.HasPrefix(message.Payload, want) {
			t.Fatalf("expected the newest signals to be kept, got %q...", message.Payload[:2])
		}
	}
}

func TestSignalInboxAlwaysFitsOneSignalOfTheLargestSize(t *testing.T) {
	var inbox signalQueue
	network := testSignalNet(t, "200:1111::1")
	// About 110 KB of small signals: more than the room left beside one
	// signal of the largest size.
	for index := 0; index < 300; index++ {
		inbox.push(testSignal("200:1111::1", 100), network)
	}
	dropped, queued := inbox.push(testSignal("200:1111::1", maxSignalPayloadBytes), network)
	if !queued {
		t.Fatal("a signal of the largest size must be queued")
	}
	if dropped == 0 {
		t.Fatal("expected older signals of the same source to make room")
	}
	_, _, _, sourceBytes := inbox.stats(network)
	if sourceBytes > maxSignalInboxBytesPerSource {
		t.Fatalf("source holds %d bytes, over its %d share", sourceBytes, maxSignalInboxBytesPerSource)
	}
}

func TestSignalInboxDropsFromTheHeaviestSourceWhenFull(t *testing.T) {
	var inbox signalQueue
	friend := testSignalNet(t, "200:ffff::1")
	inbox.push(signalMessage{From: "200:ffff::1", Payload: `{"type":"message"}`}, friend)
	inbox.push(signalMessage{From: "200:ffff::1", Payload: `{"type":"message"}`}, friend)

	sources := maxSignalInboxBytes/maxSignalPayloadBytes + 4
	totalDropped := 0
	for index := 0; index < sources; index++ {
		address := fmt.Sprintf("200:%x::1", index+1)
		dropped, queued := inbox.push(testSignal(address, maxSignalPayloadBytes), testSignalNet(t, address))
		if !queued {
			t.Fatalf("signal from %s was not queued", address)
		}
		totalDropped += dropped
	}

	entries, totalBytes, _, _ := inbox.stats(friend)
	if totalBytes > maxSignalInboxBytes {
		t.Fatalf("inbox holds %d bytes, over the %d budget", totalBytes, maxSignalInboxBytes)
	}
	if totalDropped == 0 {
		t.Fatal("expected the budget to drop signals")
	}
	if _, _, friendEntries, _ := inbox.stats(friend); friendEntries != 2 {
		t.Fatalf("the lightest source lost signals: %d left", friendEntries)
	}
	if entries+totalDropped != sources+2 {
		t.Fatalf("accounting mismatch: %d queued + %d dropped != %d pushed", entries, totalDropped, sources+2)
	}
}

func TestSignalInboxDropsFromTheBusiestSourceWhenOutOfSlots(t *testing.T) {
	var inbox signalQueue
	flooder := testSignalNet(t, "200:6666::6")
	friend := testSignalNet(t, "200:7777::7")
	for index := 0; index < signalInboxCapacity+100; index++ {
		inbox.push(signalMessage{From: "200:6666::6", Payload: "{}"}, flooder)
	}
	if entries, _, _, _ := inbox.stats(flooder); entries != signalInboxCapacity {
		t.Fatalf("expected the inbox to stop at %d signals, got %d", signalInboxCapacity, entries)
	}
	if dropped, queued := inbox.push(signalMessage{From: "200:7777::7", Payload: `{"type":"ping"}`}, friend); !queued || dropped != 1 {
		t.Fatalf("the friend's signal should replace one flood signal: dropped=%d queued=%v", dropped, queued)
	}
	entries, _, flooderEntries, _ := inbox.stats(flooder)
	if entries != signalInboxCapacity || flooderEntries != signalInboxCapacity-1 {
		t.Fatalf("unexpected counts: %d total, %d from the flooder", entries, flooderEntries)
	}
}

func TestSignalInboxWaitTimesOutAndWakesOnPush(t *testing.T) {
	var inbox signalQueue
	start := time.Now()
	if _, ok := inbox.wait(20 * time.Millisecond); ok {
		t.Fatal("nothing was queued")
	}
	if waited := time.Since(start); waited < 15*time.Millisecond {
		t.Fatalf("wait returned after %v, before its timeout", waited)
	}

	network := testSignalNet(t, "200:1111::1")
	go func() {
		time.Sleep(20 * time.Millisecond)
		inbox.push(signalMessage{From: "200:1111::1", Payload: `{"type":"pong"}`}, network)
	}()
	message, ok := inbox.wait(5 * time.Second)
	if !ok || message.Payload != `{"type":"pong"}` {
		t.Fatal("wait should return a signal pushed while waiting")
	}
}

func TestSignalInboxServesConcurrentWaiters(t *testing.T) {
	var inbox signalQueue
	network := testSignalNet(t, "200:1111::1")
	const waiters = 4
	results := make(chan bool, waiters)
	for index := 0; index < waiters; index++ {
		go func() {
			_, ok := inbox.wait(5 * time.Second)
			results <- ok
		}()
	}
	time.Sleep(10 * time.Millisecond)
	for index := 0; index < waiters; index++ {
		inbox.push(signalMessage{From: "200:1111::1", Payload: "{}"}, network)
	}
	for index := 0; index < waiters; index++ {
		if !<-results {
			t.Fatal("every waiter should get one of the signals")
		}
	}
}

func TestSignalRateLimiterAllowsBurstThenRate(t *testing.T) {
	var limiter signalRateLimiter
	flooder := testSignalNet(t, "200:6666::6")
	other := testSignalNet(t, "200:7777::7")
	now := time.Unix(1_700_000_000, 0)

	for index := 0; index < signalSourcePacketBurst; index++ {
		if !limiter.allow(flooder, now) {
			t.Fatalf("datagram %d of the burst was refused", index)
		}
	}
	if limiter.allow(flooder, now) {
		t.Fatal("expected the source to be limited after its burst")
	}
	if !limiter.allow(other, now) {
		t.Fatal("other sources must not be limited")
	}

	now = now.Add(time.Second)
	for index := 0; index < signalSourcePacketsPerSecond; index++ {
		if !limiter.allow(flooder, now) {
			t.Fatalf("datagram %d of the refill was refused", index)
		}
	}
	if limiter.allow(flooder, now) {
		t.Fatal("expected the source to be limited to its rate")
	}

	now = now.Add(time.Hour)
	allowed := 0
	for limiter.allow(flooder, now) {
		allowed++
	}
	if allowed != signalSourcePacketBurst {
		t.Fatalf("an idle source should get back exactly its burst, got %d", allowed)
	}
}

func TestSignalRateLimiterStaysBoundedAndRemembersFlooders(t *testing.T) {
	var limiter signalRateLimiter
	flooder := testSignalNet(t, "200:6666::6")
	now := time.Unix(1_700_000_000, 0)
	for limiter.allow(flooder, now) {
	}

	for index := 0; index < 3*maxSignalRateSources; index++ {
		address := fmt.Sprintf("2%02x:%x:%x::1", index%256, index/256, index)
		limiter.allow(testSignalNet(t, address), now)
		if len(limiter.buckets) > maxSignalRateSources {
			t.Fatalf("limiter tracks %d sources, over %d", len(limiter.buckets), maxSignalRateSources)
		}
	}
	if limiter.allow(flooder, now) {
		t.Fatal("a source that used up its budget must not be forgotten for idler ones")
	}
}

func TestSignalInboxCloseWakesEveryWaiter(t *testing.T) {
	var inbox signalQueue
	results := make(chan bool, 2)
	for index := 0; index < 2; index++ {
		go func() {
			_, ok := inbox.wait(time.Minute)
			results <- ok
		}()
	}
	time.Sleep(20 * time.Millisecond)
	if inbox.isClosed() {
		t.Fatal("a new inbox must not be closed")
	}
	inbox.close()
	inbox.close() // a second stop is harmless
	for index := 0; index < 2; index++ {
		select {
		case ok := <-results:
			if ok {
				t.Fatal("a closed inbox has no signal to give")
			}
		case <-time.After(2 * time.Second):
			t.Fatal("close did not wake a waiter")
		}
	}
	if !inbox.isClosed() {
		t.Fatal("the inbox should report it is closed")
	}
	started := time.Now()
	if _, ok := inbox.wait(time.Minute); ok || time.Since(started) > time.Second {
		t.Fatal("waiting on a closed inbox must return at once")
	}
}
