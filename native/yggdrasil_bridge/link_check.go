package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"time"

	iwt "github.com/Arceliar/ironwood/types"
)

// A phone that only receives dials one public peer (phone_peers.go). When
// that peer's link ends with a word (a FIN, an RST) the packet wakes the
// phone and stand-ins are dialled at once. A link that dies without one (a
// mobile network or a NAT that forgot the connection, a server gone off the
// network) stays "up" for as long as nothing is sent over it: the core
// sends nothing over an idle link, and it only expects an answer, within
// its peer timeout (3 s, ironwood's peerTimeout), after it sent something.
// A locked phone sends on its mailbox polls only, up to half an hour apart:
// that long nobody could reach it.
//
// checkLinks sends that something on the wakes the phone has anyway (the
// app's beat, ZenWake in the app): an empty packet to each peer's own key,
// so the core sends it over that peer's link. A peer that is there answers
// within a second or so (the lookup's answer, or its keepalive), and the
// link counts as answered as soon as anything comes back over it. One that
// is gone does not, the core ends the link after its peer timeout, and the
// keeper dials stand-ins (peerEventLogger): the check then waits, while the
// phone is still held awake, until a link is up again. A packet of a few
// dozen bytes to each peer, on wakes that come anyway: nothing the battery
// notices.
const (
	// How long a probed link has to answer: the core's peer timeout and a
	// little more, so a link that does not answer is down by then.
	linkCheckAnswerWait = 3500 * time.Millisecond
	// How long the check waits, after a link it probed went down, for one
	// to be up again (a stand-in is up in a second or two; a dead candidate
	// costs phonePeerDialGrace).
	linkCheckRedialWait = 12 * time.Second
	linkCheckStep       = 50 * time.Millisecond
)

// linkCheck is what one check found.
type linkCheck struct {
	// Links that were up and got a packet.
	Probed int `json:"probed"`
	// Of those, the ones something came back over.
	Answered int `json:"answered"`
	// Of those, the ones that went down instead.
	Dropped int `json:"dropped"`
	// Links up when the check ended.
	Up int `json:"up"`
	// How long the check took.
	Ms int64 `json:"ms"`
}

// checkLinks probes every link that is up on a phone node and waits until
// each answered or went down, and after a link went down until one is up
// again (each at most linkCheckAnswerWait, linkCheckRedialWait). A node
// that is not a phone's checks nothing.
func (node *bridgeNode) checkLinks() linkCheck {
	started := time.Now()
	var result linkCheck
	keeper := node.phonePeers
	if keeper == nil {
		return result
	}
	// The phone is awake: with no peer up the core redials them now
	// (redialOnWake), as when the app sends.
	keeper.appSends()
	type probe struct {
		key      string
		rx       uint64
		resolved bool
	}
	var probes []*probe
	seen := make(map[string]bool)
	for _, info := range node.core.GetPeers() {
		key := string(info.Key)
		if !info.Up || key == "" || seen[key] {
			continue
		}
		seen[key] = true
		probes = append(probes, &probe{key: key, rx: info.RXBytes})
	}
	for _, p := range probes {
		_, _ = node.core.WriteTo(nil, iwt.Addr(p.key))
	}
	result.Probed = len(probes)
	deadline := started.Add(linkCheckAnswerWait)
	for left := len(probes); left > 0; {
		rx, up := node.peerLinks()
		for _, p := range probes {
			switch {
			case p.resolved:
			case !up[p.key]:
				p.resolved = true
				result.Dropped++
				left--
			case rx[p.key] > p.rx:
				p.resolved = true
				result.Answered++
				left--
			}
		}
		if left == 0 || time.Now().After(deadline) {
			break
		}
		time.Sleep(linkCheckStep)
	}
	if result.Dropped > 0 {
		// The keeper heard of it from the core's log line (and looks again
		// within phonePeerCheckInterval anyway).
		keeper.lookNow()
		until := time.Now().Add(linkCheckRedialWait)
		for {
			if _, up := node.peerLinks(); len(up) > 0 || time.Now().After(until) {
				break
			}
			time.Sleep(linkCheckStep)
		}
	}
	_, up := node.peerLinks()
	result.Up = len(up)
	result.Ms = time.Since(started).Milliseconds()
	if result.Dropped > 0 {
		node.logger.Infof("link check: %d of %d links did not answer, %d up after %d ms",
			result.Dropped, result.Probed, result.Up, result.Ms)
	}
	return result
}

// peerLinks are, by peer key, the bytes received over the links that are up
// (the most of a key's links) and which keys have a link up.
func (node *bridgeNode) peerLinks() (map[string]uint64, map[string]bool) {
	rx := make(map[string]uint64)
	up := make(map[string]bool)
	for _, info := range node.core.GetPeers() {
		key := string(info.Key)
		if !info.Up || key == "" {
			// A connection still in its handshake (upPeers).
			continue
		}
		up[key] = true
		if info.RXBytes > rx[key] {
			rx[key] = info.RXBytes
		}
	}
	return rx, up
}

// YggCheckLinksJson probes the links of a phone node that are up, on a
// wake the phone has anyway, so one that died without a word is noticed
// and replaced while the phone is awake (checkLinks): {probed, answered,
// dropped, up, ms}. It blocks for up to about 16 s: the app calls it off
// its isolate's thread.
//
//export YggCheckLinksJson
func YggCheckLinksJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(node.checkLinks())
	})
}
