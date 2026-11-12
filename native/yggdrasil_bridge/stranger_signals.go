package main

import (
	"net"
	"sync"
	"time"
)

// A locked phone's node (it only receives: ZenPeerTarget 1) wakes the
// phone for every signal it hands the app. Anyone who knows its address
// can send it signals: a former friend, a member of a shared group, anyone
// with an old invitation. So from senders the app does not name there (its
// friends and own devices, pq_session.go setKnown, and the contacts the
// locked receiver heard from, listen) the node hands over only so many an
// hour, per /64 and from all of them together; the rest is dropped before
// the app is woken. What strangers legitimately send a locked phone (a
// friend request, which is tried again until it is answered; a deposit for
// a friend this phone is a mailbox of, which the sender leaves with the
// friend's other mailboxes too; a knock, tried again) fits in the budget.
const (
	strangerSignalsPerHourPerSource = 30
	strangerSignalBurstPerSource    = 20
	strangerSignalsPerHour          = 240
	strangerSignalBurst             = 60
	// Addresses the app may name as listened to (the contacts the locked
	// receiver heard from): more are not taken.
	maxListenedSignalSources = 4096
	// receiveOnlyPeerTarget is the ZenPeerTarget of a node that only
	// receives (kReceiveOnlyPeerTarget in the app).
	receiveOnlyPeerTarget = 1
)

// strangerSignalBudget is that budget; nil on nodes that have none. Safe
// for concurrent use (the node's packet loop and its doors' loops).
type strangerSignalBudget struct {
	mu       sync.Mutex
	total    signalRateBucket
	sources  map[signalSourceNet]*signalRateBucket
	listened map[string]struct{}
	// The budget's clock (tests set it).
	now func() time.Time
}

func newStrangerSignalBudget() *strangerSignalBudget {
	return &strangerSignalBudget{now: time.Now}
}

// listen adds addresses the app listens to on this node (contacts that are
// not among the known ones: members of its groups); their signals are not
// counted. Malformed ones are skipped; returns how many are listened to.
func (b *strangerSignalBudget) listen(addresses []string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.listened == nil {
		b.listened = make(map[string]struct{})
	}
	for _, address := range addresses {
		if len(b.listened) >= maxListenedSignalSources {
			break
		}
		ip := net.ParseIP(address)
		if ip == nil || ip.To4() != nil || !isYggNodeAddress(ip) {
			continue
		}
		b.listened[ip.String()] = struct{}{}
	}
	return len(b.listened)
}

func (b *strangerSignalBudget) listensTo(address string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	_, ok := b.listened[address]
	return ok
}

// allow takes one signal of a sender nobody named from network's share and
// from the total; false (and nothing taken) when either is used up.
func (b *strangerSignalBudget) allow(network signalSourceNet) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	if b.sources == nil {
		b.sources = make(map[signalSourceNet]*signalRateBucket)
	}
	source := b.sources[network]
	if source == nil {
		if len(b.sources) >= maxSignalRateSources {
			b.forgetLocked(now)
			if len(b.sources) >= maxSignalRateSources {
				// So many strangers at once used their shares up: a new
				// one waits until some refill (the total is spent anyway).
				return false
			}
		}
		source = &signalRateBucket{tokens: strangerSignalBurstPerSource, at: now}
		b.sources[network] = source
	}
	refillStrangerBucket(source, now, strangerSignalsPerHourPerSource, strangerSignalBurstPerSource)
	if b.total.at.IsZero() {
		b.total = signalRateBucket{tokens: strangerSignalBurst, at: now}
	}
	refillStrangerBucket(&b.total, now, strangerSignalsPerHour, strangerSignalBurst)
	if source.tokens < 1 || b.total.tokens < 1 {
		return false
	}
	source.tokens--
	b.total.tokens--
	return true
}

// forgetLocked drops the sources whose share has refilled (they are as good
// as new); a source that used its share up is kept, so many addresses do
// not hand one of them a fresh share.
func (b *strangerSignalBudget) forgetLocked(now time.Time) {
	for network, bucket := range b.sources {
		refillStrangerBucket(bucket, now, strangerSignalsPerHourPerSource, strangerSignalBurstPerSource)
		if bucket.tokens >= strangerSignalBurstPerSource {
			delete(b.sources, network)
		}
	}
}

func refillStrangerBucket(bucket *signalRateBucket, now time.Time, perHour, burst float64) {
	elapsed := now.Sub(bucket.at)
	if elapsed <= 0 {
		return
	}
	bucket.tokens = min(burst, bucket.tokens+elapsed.Hours()*perHour)
	bucket.at = now
}

// admitSignal tells whether a signal from source (in network) may wake the
// app: always, unless the node has a stranger budget and nobody named the
// sender ([strangerSignalBudget]).
func (node *bridgeNode) admitSignal(source net.IP, network signalSourceNet) bool {
	budget := node.strangerSignals
	if budget == nil {
		return true
	}
	address := source.String()
	if budget.listensTo(address) {
		return true
	}
	if !node.pqPlain {
		if endpoint, err := node.pqEndpointOf(); err == nil && endpoint.isKnown(address) {
			return true
		}
	}
	return budget.allow(network)
}
