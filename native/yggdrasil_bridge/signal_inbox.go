package main

import (
	"bytes"
	"cmp"
	"container/list"
	"net"
	"slices"
	"sync"
	"time"
)

// Signals reach the bridge from anyone on the mesh, before the app can tell
// whether the sender is a friend, so what one sender can make the bridge hold
// and do is bounded per /64 (one node address and the subnet around it).
const (
	// Every queued signal is charged its text plus this much, so a flood of
	// tiny signals is bounded by bytes as well as by signalInboxCapacity.
	signalInboxEntryCost = 256
	// Bytes of decoded signals waiting for the app, from everyone together
	// and from one /64. A source over its share loses its own oldest
	// signals; when the total is over, whoever holds the most bytes loses
	// its oldest, and when every slot is taken, whoever holds the most
	// signals does. One source always has room for a signal of the largest
	// size (2 MiB) with a few small ones next to it.
	maxSignalInboxBytes          = 32 * 1024 * 1024
	maxSignalInboxBytesPerSource = maxSignalPayloadBytes + 64*1024
	// Signal datagrams one /64 may send: a token bucket refilled at this
	// rate and holding up to the burst. The burst covers the ~2150 fragments
	// of a signal of the largest size; the rate (~2.6 MB/s of fragments) is
	// more than the app digests from one peer. Datagrams over it are dropped
	// before any parsing or decompression.
	signalSourcePacketsPerSecond = 2000
	signalSourcePacketBurst      = 4000
	// Sources the rate limiter tracks at once. When full, sources whose
	// bucket has refilled are forgotten first (they are as good as new),
	// then the least busy ones.
	maxSignalRateSources = 4096
)

// signalSourceNet is the /64 a signal came from: the unit the inbox budget
// and the rate limit are kept per.
type signalSourceNet [8]byte

func signalSourceNetOf(ip net.IP) signalSourceNet {
	var network signalSourceNet
	copy(network[:], ip.To16())
	return network
}

type queuedSignal struct {
	message signalMessage
	network signalSourceNet
	cost    int
}

type signalSourceUsage struct {
	bytes   int
	entries int
}

// signalQueue holds reassembled signals until the app polls them, oldest
// first, within the byte budgets above. It never blocks the packet loop.
// The zero value is ready to use; it is safe for concurrent use.
type signalQueue struct {
	mu      sync.Mutex
	entries list.List // of *queuedSignal
	bytes   int
	sources map[signalSourceNet]*signalSourceUsage
	// Holds a token while signals may be waiting; wakes one waiter.
	ready chan struct{}
}

// push queues message from network, first dropping older signals as
// described at maxSignalInboxBytes. It returns how many were dropped, and
// queued=false when message alone exceeds a source's share (never for a
// signal within maxSignalPayloadBytes).
func (q *signalQueue) push(message signalMessage, network signalSourceNet) (dropped int, queued bool) {
	cost := len(message.Payload) + len(message.From) + signalInboxEntryCost
	if cost > maxSignalInboxBytesPerSource {
		return 0, false
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.sources == nil {
		q.sources = make(map[signalSourceNet]*signalSourceUsage)
	}
	for usage := q.sources[network]; usage != nil && usage.bytes+cost > maxSignalInboxBytesPerSource; usage = q.sources[network] {
		if !q.dropOldestLocked(network) {
			break
		}
		dropped++
	}
	for q.bytes+cost > maxSignalInboxBytes && q.entries.Len() > 0 {
		if !q.dropOldestLocked(q.heaviestLocked(false)) {
			break
		}
		dropped++
	}
	for q.entries.Len() >= signalInboxCapacity {
		if !q.dropOldestLocked(q.heaviestLocked(true)) {
			break
		}
		dropped++
	}

	q.entries.PushBack(&queuedSignal{message: message, network: network, cost: cost})
	q.bytes += cost
	usage := q.sources[network]
	if usage == nil {
		usage = &signalSourceUsage{}
		q.sources[network] = usage
	}
	usage.bytes += cost
	usage.entries++
	q.notifyLocked()
	return dropped, true
}

// tryPop takes the oldest queued signal, if any, releasing its bytes.
func (q *signalQueue) tryPop() (signalMessage, bool) {
	q.mu.Lock()
	defer q.mu.Unlock()
	front := q.entries.Front()
	if front == nil {
		return signalMessage{}, false
	}
	item := q.removeLocked(front)
	if q.entries.Len() > 0 {
		// Let another waiter in for the rest.
		q.notifyLocked()
	}
	return item.message, true
}

// wait takes the oldest queued signal, waiting up to timeout for one to
// arrive (not at all when timeout <= 0).
func (q *signalQueue) wait(timeout time.Duration) (signalMessage, bool) {
	if message, ok := q.tryPop(); ok || timeout <= 0 {
		return message, ok
	}
	q.mu.Lock()
	ready := q.readyLocked()
	q.mu.Unlock()

	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case <-ready:
			// The token may be stale (another caller took the signal);
			// then keep waiting.
			if message, ok := q.tryPop(); ok {
				return message, true
			}
		case <-timer.C:
			return q.tryPop()
		}
	}
}

// stats reports the signals and bytes queued, in total and from network.
func (q *signalQueue) stats(network signalSourceNet) (entries, totalBytes, sourceEntries, sourceBytes int) {
	q.mu.Lock()
	defer q.mu.Unlock()
	if source := q.sources[network]; source != nil {
		sourceEntries, sourceBytes = source.entries, source.bytes
	}
	return q.entries.Len(), q.bytes, sourceEntries, sourceBytes
}

func (q *signalQueue) readyLocked() chan struct{} {
	if q.ready == nil {
		q.ready = make(chan struct{}, 1)
	}
	return q.ready
}

func (q *signalQueue) notifyLocked() {
	select {
	case q.readyLocked() <- struct{}{}:
	default:
	}
}

func (q *signalQueue) removeLocked(element *list.Element) *queuedSignal {
	item := q.entries.Remove(element).(*queuedSignal)
	q.bytes -= item.cost
	if usage := q.sources[item.network]; usage != nil {
		usage.bytes -= item.cost
		usage.entries--
		if usage.entries <= 0 {
			delete(q.sources, item.network)
		}
	}
	return item
}

// dropOldestLocked removes the oldest signal from network; false when it
// has none queued.
func (q *signalQueue) dropOldestLocked(network signalSourceNet) bool {
	for element := q.entries.Front(); element != nil; element = element.Next() {
		if element.Value.(*queuedSignal).network == network {
			q.removeLocked(element)
			return true
		}
	}
	return false
}

// heaviestLocked is the source holding the most bytes, or the most signals
// when byEntries is set (ties go to the lowest address, deterministically).
func (q *signalQueue) heaviestLocked(byEntries bool) signalSourceNet {
	var heaviest signalSourceNet
	most := -1
	for network, usage := range q.sources {
		weight := usage.bytes
		if byEntries {
			weight = usage.entries
		}
		if weight > most || (weight == most && bytes.Compare(network[:], heaviest[:]) < 0) {
			heaviest = network
			most = weight
		}
	}
	return heaviest
}

type signalRateBucket struct {
	tokens float64
	at     time.Time
}

func (bucket *signalRateBucket) refill(now time.Time) {
	elapsed := now.Sub(bucket.at)
	if elapsed <= 0 {
		return
	}
	bucket.tokens = min(signalSourcePacketBurst, bucket.tokens+elapsed.Seconds()*signalSourcePacketsPerSecond)
	bucket.at = now
}

// signalRateLimiter keeps a token bucket per /64 for the packet loop. The
// zero value is ready to use; it is not safe for concurrent use (the loop is
// one goroutine).
type signalRateLimiter struct {
	buckets map[signalSourceNet]*signalRateBucket
}

// allow reports whether network may send one more signal datagram now.
func (limiter *signalRateLimiter) allow(network signalSourceNet, now time.Time) bool {
	if limiter.buckets == nil {
		limiter.buckets = make(map[signalSourceNet]*signalRateBucket)
	}
	bucket := limiter.buckets[network]
	if bucket == nil {
		if len(limiter.buckets) >= maxSignalRateSources {
			limiter.forget(now)
		}
		bucket = &signalRateBucket{tokens: signalSourcePacketBurst, at: now}
		limiter.buckets[network] = bucket
	} else {
		bucket.refill(now)
	}
	if bucket.tokens < 1 {
		return false
	}
	bucket.tokens--
	return true
}

// forget makes room for new sources: it drops every source whose bucket has
// refilled, and if that is not enough, the least busy quarter of the rest
// (never everyone at once: that would hand every flooding source a fresh
// burst). Sources that used up their budget are the last to go.
func (limiter *signalRateLimiter) forget(now time.Time) {
	type tracked struct {
		network signalSourceNet
		tokens  float64
	}
	busy := make([]tracked, 0, len(limiter.buckets))
	for network, bucket := range limiter.buckets {
		bucket.refill(now)
		if bucket.tokens >= signalSourcePacketBurst {
			delete(limiter.buckets, network)
			continue
		}
		busy = append(busy, tracked{network: network, tokens: bucket.tokens})
	}
	if len(limiter.buckets) < maxSignalRateSources {
		return
	}
	keep := maxSignalRateSources * 3 / 4
	slices.SortFunc(busy, func(a, b tracked) int {
		if order := cmp.Compare(b.tokens, a.tokens); order != 0 {
			return order
		}
		return bytes.Compare(a.network[:], b.network[:])
	})
	for _, source := range busy[:len(busy)-keep] {
		delete(limiter.buckets, source.network)
	}
}
