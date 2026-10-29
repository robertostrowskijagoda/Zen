package main

import (
	"crypto/ed25519"
	"errors"
	"net/url"
	"sync"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// What the app asks of a node never waits for the node's mesh core. The app
// calls the bridge on its UI thread (the node info, the peers, the states of
// the public peers, a door's link), and the core answers every such
// question inside one of its actors (phony.Block): one that did not answer
// froze the screen for good, the start included (R5-F4, "the logo that
// never goes away"). So the core is asked by a goroutine of its own, one
// question of a kind at a time, and the caller gets the answer when it
// comes within a short wait, else the last one. Changes of the core's
// peerings (a friend's bridge, a new list of public peers) run the same way:
// past a short wait they go on by themselves and the caller hears so. A
// node's stop waits for its core only so long.
const (
	// An answer this young is given again without asking the core (callers
	// in a burst share one question; the app still sees a peering that just
	// came up at once).
	nodeViewFresh = 100 * time.Millisecond
	// How long a caller waits for a fresh answer before it takes the last
	// one (a healthy core answers within a millisecond). A question under
	// way for longer is not waited for again.
	nodeViewWait = 300 * time.Millisecond
	// How long a change of the core's peerings is waited for.
	nodeActionWait = 2 * time.Second
	// Changes of one node's peerings under way at once; past that its core
	// is taken to be stuck and new ones are refused.
	nodeActionsAtOnce = 8
	// How long stopping a node (or a door) waits for its core.
	nodeStopWait = 10 * time.Second
)

var errNodeBusy = errors.New("the node's mesh core did not answer in time; the change goes on by itself")

// coreQuery is one kind of question to a core, asked off the caller's
// thread: one at a time, its last answer kept. The zero value is ready; it
// is safe for concurrent use.
type coreQuery[T any] struct {
	mu    sync.Mutex
	value T
	// When value was taken (zero: never, or marked stale).
	at time.Time
	// Closed once the question under way is answered (nil: none is), and
	// when it was asked.
	running chan struct{}
	started time.Time
}

// get is the answer of ask: asked again when the last one is older than
// fresh, and waited for at most wait from when it was asked; else the last
// answer (the zero value before the first).
func (q *coreQuery[T]) get(fresh, wait time.Duration, ask func() T) T {
	q.mu.Lock()
	if q.running == nil && (q.at.IsZero() || time.Since(q.at) >= fresh) {
		running := make(chan struct{})
		q.running = running
		q.started = time.Now()
		go func() {
			value := ask()
			q.mu.Lock()
			q.value = value
			q.at = time.Now()
			q.running = nil
			q.mu.Unlock()
			close(running)
		}()
	}
	running, started := q.running, q.started
	q.mu.Unlock()
	if running != nil {
		if left := wait - time.Since(started); left > 0 {
			timer := time.NewTimer(left)
			select {
			case <-running:
			case <-timer.C:
			}
			timer.Stop()
		}
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	return q.value
}

// stale has the next get ask again.
func (q *coreQuery[T]) stale() {
	q.mu.Lock()
	q.at = time.Time{}
	q.mu.Unlock()
}

// nodeSample is what the app reads of a node's core at once.
type nodeSample struct {
	self     core.SelfInfo
	peers    []core.PeerInfo
	sessions []core.SessionInfo
	// trafficState of that moment.
	traffic map[string]any
}

// view is the node's core as last sampled (see the top of this file).
func (node *bridgeNode) view() nodeSample {
	return node.sample.get(nodeViewFresh, nodeViewWait, node.takeSample)
}

// takeSample asks the core what view gives, and feeds the traffic meter
// with it (a phone's transit guard included).
func (node *bridgeNode) takeSample() nodeSample {
	peers := node.core.GetPeers()
	sessions := node.core.GetSessions()
	node.sampleTrafficWith(peers, sessions, time.Now())
	return nodeSample{
		self:     node.core.GetSelf(),
		peers:    peers,
		sessions: sessions,
		traffic:  node.trafficStateWith(peers),
	}
}

// viewPaths and viewTree are the core's paths and its spanning tree, as
// view gives the rest.
func (node *bridgeNode) viewPaths() []core.PathEntryInfo {
	return node.paths.get(nodeViewFresh, nodeViewWait, node.core.GetPaths)
}

func (node *bridgeNode) viewTree() []core.TreeEntryInfo {
	return node.tree.get(nodeViewFresh, nodeViewWait, node.core.GetTree)
}

// coreAction runs change (a change of the core's peerings) off the caller's
// thread and waits for it at most nodeActionWait; past that it goes on by
// itself and the caller hears errNodeBusy. With nodeActionsAtOnce of them
// under way (a core that stopped answering), new ones are refused. The
// node's view is asked again afterwards.
func (node *bridgeNode) coreAction(change func() error) error {
	if node.actions.Add(1) > nodeActionsAtOnce {
		node.actions.Add(-1)
		return errNodeBusy
	}
	done := make(chan error, 1)
	go func() {
		defer node.actions.Add(-1)
		done <- change()
		node.sample.stale()
	}()
	timer := time.NewTimer(nodeActionWait)
	defer timer.Stop()
	select {
	case err := <-done:
		node.sample.stale()
		return err
	case <-timer.C:
		return errNodeBusy
	}
}

// stopCore stops a core and waits at most wait for it to close its links;
// a core that does not answer is left to finish by itself (false).
func stopCore(c *core.Core, wait time.Duration) bool {
	return within(wait, c.Stop)
}

// within runs call and reports whether it returned within wait; one that
// did not goes on by itself.
func within(wait time.Duration, call func()) bool {
	done := make(chan struct{})
	go func() {
		call()
		close(done)
	}()
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-done:
		return true
	case <-timer.C:
		return false
	}
}

// nodeLinkCore is the node's core as its local links see it
// (local_link_stream.go): the peers their status shows come from the
// node's view, so the app's thread never waits for the core. Links are
// made on goroutines of their own, which call the core itself.
type nodeLinkCore struct {
	node *bridgeNode
}

func (c nodeLinkCore) CallPeer(u *url.URL, sintf string) error {
	return c.node.core.CallPeer(u, sintf)
}

func (c nodeLinkCore) GetPeers() []core.PeerInfo {
	return c.node.view().peers
}

func (c nodeLinkCore) PublicKey() ed25519.PublicKey {
	return c.node.core.PublicKey()
}
