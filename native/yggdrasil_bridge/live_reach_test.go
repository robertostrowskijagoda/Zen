package main

import (
	"crypto/ed25519"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	iwt "github.com/Arceliar/ironwood/types"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// A measurement on the real Yggdrasil network, not a test of the code: run
// only with ZEN_LIVE_REACH set to a number of minutes. Phone nodes that
// only receive (as the locked receiver, with one public peer, two, or the
// app's four) answer pings from a node with four peers, as a friend's
// locked phone answers presence pings; each round says which answered,
// and the end how often each kind of node was out of reach and for how
// long at most. Every node here stays awake: what is out of reach is so
// because of the network and its peers, not because a phone slept.
func TestLiveReachOfReceiveOnlyNodes(t *testing.T) {
	minutes, _ := strconv.Atoi(os.Getenv("ZEN_LIVE_REACH"))
	if minutes <= 0 {
		t.Skip("a measurement on the real network: set ZEN_LIVE_REACH=<minutes>")
	}
	every := 60 * time.Second
	if s, err := strconv.Atoi(os.Getenv("ZEN_LIVE_REACH_EVERY")); err == nil && s > 0 {
		every = time.Duration(s) * time.Second
	}
	groups := []struct{ peers, nodes int }{{1, 6}, {2, 6}, {4, 3}}

	pinger := liveNode(t, phonePeerCount)
	pongs := make(chan string, 256)
	go func() {
		buf := make([]byte, 2048)
		for {
			n, _, err := pinger.core.ReadFrom(buf)
			if err != nil {
				return
			}
			if s := string(buf[:n]); strings.HasPrefix(s, "pong ") {
				pongs <- strings.TrimPrefix(s, "pong ")
			}
		}
	}()

	type target struct {
		name  string
		peers int
		node  *bridgeNode
		key   ed25519.PublicKey
		ok    int
		first int
		miss  int
		run   int
		worst int
		swaps int
		last  string
	}
	var targets []*target
	for _, g := range groups {
		for i := 0; i < g.nodes; i++ {
			node := liveNode(t, g.peers)
			go echo(node.core)
			targets = append(targets, &target{
				name:  fmt.Sprintf("p%d-%d", g.peers, i),
				peers: g.peers,
				node:  node,
				key:   ed25519.PublicKey(node.core.PublicKey()),
			})
		}
	}
	// Everyone's links up and the tree settled.
	time.Sleep(45 * time.Second)

	end := time.Now().Add(time.Duration(minutes) * time.Minute)
	for round := 1; time.Now().Before(end); round++ {
		started := time.Now()
		answered := map[string]bool{}
		firstTry := map[string]bool{}
		var mu sync.Mutex
		deadline := time.Now().Add(15 * time.Second)
		for try := 0; try < 3 && time.Now().Before(deadline); try++ {
			for _, tg := range targets {
				if !answered[tg.name] {
					msg := fmt.Sprintf("ping %s %d", tg.name, round)
					_, _ = pinger.core.WriteTo([]byte(msg), iwt.Addr(tg.key))
				}
			}
			wait := time.After(5 * time.Second)
		collect:
			for {
				select {
				case p := <-pongs:
					parts := strings.Fields(p)
					// "<name> <round>": the pong's own word is cut off.
					if len(parts) == 2 && parts[1] == strconv.Itoa(round) {
						mu.Lock()
						if !answered[parts[0]] && try == 0 {
							firstTry[parts[0]] = true
						}
						answered[parts[0]] = true
						mu.Unlock()
					}
				case <-wait:
					break collect
				}
			}
		}
		var line strings.Builder
		for _, tg := range targets {
			peers := upPeerURIs(tg.node)
			if tg.last != "" && peers != tg.last {
				tg.swaps++
			}
			tg.last = peers
			if answered[tg.name] {
				tg.ok++
				if firstTry[tg.name] {
					tg.first++
				}
				tg.run = 0
				line.WriteString(" " + tg.name + "+")
			} else {
				tg.miss++
				tg.run++
				if tg.run > tg.worst {
					tg.worst = tg.run
				}
				line.WriteString(" " + tg.name + "-[" + peers + "]")
			}
		}
		t.Logf("%s round %d:%s", time.Now().Format("15:04:05"), round, line.String())
		if rest := every - time.Since(started); rest > 0 {
			time.Sleep(rest)
		}
	}

	sort.SliceStable(targets, func(i, j int) bool { return targets[i].peers < targets[j].peers })
	byPeers := map[int][2]int{}
	for _, tg := range targets {
		t.Logf("%s: answered %d, first try %d, missed %d, longest out of reach %d rounds, peer changes %d",
			tg.name, tg.ok, tg.first, tg.miss, tg.worst, tg.swaps)
		s := byPeers[tg.peers]
		byPeers[tg.peers] = [2]int{s[0] + tg.ok, s[1] + tg.miss}
	}
	for _, g := range groups {
		s := byPeers[g.peers]
		t.Logf("%d peer(s): %d of %d rounds answered (%.1f%%)", g.peers, s[0], s[0]+s[1],
			100*float64(s[0])/float64(max(1, s[0]+s[1])))
	}
}

// liveNode is a phone node on the real network dialling peers of the
// public pool as a phone does (its picks first, the rest in reserve).
func liveNode(t *testing.T, peers int) *bridgeNode {
	t.Helper()
	keeper := newPhonePeerKeeper(phonePeerCandidates(publicPeerPool), phonePeerTarget(peers))
	cfg := config.GenerateConfig()
	yggCore, err := core.New(cfg.Certificate, withPeerEvents(newBridgeLogger(io.Discard), keeper))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(yggCore.Stop)
	node := &bridgeNode{
		core:        yggCore,
		config:      cfg,
		logger:      newBridgeLogger(io.Discard),
		publicPeers: map[string]bool{},
		phonePeers:  keeper,
	}
	node.swapPublicPeers(nil, keeper.dialled)
	go node.watchPhonePeers()
	t.Cleanup(keeper.stopWatch)
	return node
}

func echo(c *core.Core) {
	buf := make([]byte, 2048)
	for {
		n, from, err := c.ReadFrom(buf)
		if err != nil {
			return
		}
		if s := string(buf[:n]); strings.HasPrefix(s, "ping ") {
			_, _ = c.WriteTo([]byte("pong "+strings.TrimPrefix(s, "ping ")), from)
		}
	}
}

func upPeerURIs(node *bridgeNode) string {
	var up []string
	for _, p := range node.core.GetPeers() {
		if p.Up && len(p.Key) > 0 {
			host := p.URI
			if i := strings.Index(host, "://"); i >= 0 {
				host = host[i+3:]
			}
			up = append(up, host)
		}
	}
	sort.Strings(up)
	return strings.Join(up, ",")
}
