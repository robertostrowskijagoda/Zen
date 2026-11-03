package main

import (
	"crypto/ed25519"
	"fmt"
	"io"
	"net"
	"net/url"
	"testing"
	"time"

	iwt "github.com/Arceliar/ironwood/types"
	"github.com/gologme/log"
	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/core"
)

// A node that just joined the mesh writes to one that was there before, at
// once, the way an invitation goes out right after the phone came on. Its
// session init reaches the old node within a second or two, but the old
// node's answer finds no way back until the new node's bloom filter has
// climbed the tree to it, a router round (a second) per hop: on the real
// mesh several seconds. ironwood answered an init only once, and the same
// init sent again was ignored until the old node's session timed out, a
// minute later: an invitation "waiting for acceptance" for a minute. With
// the patched ironwood (third_party/ironwood/ZEN.md) a try a second later
// is a new init, answered again, and the answer goes as soon as there is
// a way.
func TestFreshNodeReachesAnOldOneWithinSeconds(t *testing.T) {
	logger := log.New(io.Discard, "", 0)
	// Listens on loopback and peers with parent (none: the root, whose key
	// is the lowest, as one long-standing node's is on the real mesh).
	node := func(parent string, root bool) (*core.Core, string) {
		var key ed25519.PrivateKey
		for key == nil || (root && (key.Public().(ed25519.PublicKey)[0] != 0 ||
			key.Public().(ed25519.PublicKey)[1] > 0x0f)) ||
			(!root && key.Public().(ed25519.PublicKey)[0] < 0x10) {
			_, key, _ = ed25519.GenerateKey(nil)
		}
		cfg := &config.NodeConfig{PrivateKey: config.KeyBytes(key)}
		if err := cfg.GenerateSelfSignedCertificate(); err != nil {
			t.Fatalf("key: %v", err)
		}
		var options []core.SetupOption
		if parent != "" {
			options = append(options, core.Peer{URI: parent})
		}
		c, err := core.New(cfg.Certificate, logger, options...)
		if err != nil {
			t.Fatalf("core: %v", err)
		}
		t.Cleanup(c.Stop)
		listenURL, _ := url.Parse("tcp://127.0.0.1:0")
		listener, err := c.Listen(listenURL, "")
		if err != nil {
			t.Fatalf("listen: %v", err)
		}
		return c, fmt.Sprintf("tcp://127.0.0.1:%d", listener.Addr().(*net.TCPAddr).Port)
	}
	// Each node reads what reaches it, as the bridge's packet loop does:
	// ironwood hands nothing on (an answer neither) while nobody reads.
	read := func(c *core.Core, got chan<- time.Time) {
		buffer := make([]byte, 65535)
		for {
			n, _, err := c.PacketConn.ReadFrom(buffer)
			if err != nil {
				return
			}
			if n > 0 && got != nil {
				select {
				case got <- time.Now():
				default:
				}
			}
		}
	}

	// The old node next to the root; the new one five hops below it.
	_, rootURI := node("", true)
	old, _ := node(rootURI, false)
	got := make(chan time.Time, 1)
	go read(old, got)
	parent := rootURI
	for range 5 {
		_, parent = node(parent, false)
	}
	// Long enough for every filter to be everywhere.
	time.Sleep(8 * time.Second)

	fresh, _ := node(parent, false)
	go read(fresh, nil)
	waitMesh(t, "the new node never joined", func() bool { return len(fresh.GetPeers()) > 0 })
	began := time.Now()
	to := iwt.Addr(old.PublicKey())
	// What the bridge's mesh writer does for a first contact: a lookup and
	// the opening packet, again every second while the way does not open.
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	deadline := time.After(40 * time.Second)
	for {
		fresh.SendLookup(old.PublicKey())
		_, _ = fresh.PacketConn.WriteTo([]byte{doorSessionTraffic, 'h', 'i'}, to)
		select {
		case at := <-got:
			took := at.Sub(began)
			t.Logf("the first packet arrived after %v", took)
			if took > 15*time.Second {
				t.Fatalf("the first packet took %v", took)
			}
			return
		case <-deadline:
			t.Fatal("nothing arrived within 40 s: the session stalled")
		case <-ticker.C:
		}
	}
}
