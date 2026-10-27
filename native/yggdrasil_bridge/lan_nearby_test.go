package main

import (
	"bytes"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"
)

// testNearbyAdverts are count adverts, each byte the slot's number.
func testNearbyAdverts(count int) []byte {
	out := make([]byte, 0, count*lanNearbyAdvertBytes)
	for i := 0; i < count; i++ {
		out = append(out, bytes.Repeat([]byte{byte(i + 1)}, lanNearbyAdvertBytes)...)
	}
	return out
}

// testNearbyLan is the LAN side of a manager with no node and no socket:
// what it would send goes to sent.
func testNearbyLan(nearby lanNearby) (*lanDiscovery, *[]*net.UDPAddr, *[][]byte) {
	m := &localLinkManager{
		self:     "200:1::1",
		settings: localLinkSettings{lan: true, nearby: nearby},
		links:    map[string]*localLink{},
	}
	var to []*net.UDPAddr
	var packets [][]byte
	lan := &lanDiscovery{
		m:          m,
		tcpPort:    40000,
		ownSalts:   map[[4]byte]time.Time{},
		lastSource: map[string]time.Time{},
		lastReply:  map[string]time.Time{},
		lastDial:   map[string]time.Time{},
		perSource:  map[string]int{},
	}
	lan.sent = func(packet []byte, addr *net.UDPAddr) {
		to = append(to, addr)
		packets = append(packets, packet)
	}
	m.lan = lan
	return lan, &to, &packets
}

func TestLanNearbySettings(t *testing.T) {
	adverts := testNearbyAdverts(3)
	settings, err := parseLocalLinkSettings(fmt.Sprintf(
		`{"Lan": true, "Nearby": {"Start": 100, "Adverts": %q, "Looking": true}}`,
		hex.EncodeToString(adverts),
	))
	if err != nil {
		t.Fatal(err)
	}
	if settings.nearby.start != 100 || !bytes.Equal(settings.nearby.adverts, adverts) || !settings.nearby.looking {
		t.Fatalf("nearby settings: %+v", settings.nearby)
	}
	settings, err = parseLocalLinkSettings(`{"Lan": true}`)
	if err != nil || settings.nearby.visible() || settings.nearby.looking {
		t.Fatalf("without Nearby nothing is shown: %+v %v", settings.nearby, err)
	}
	settings, err = parseLocalLinkSettings(`{"Lan": true, "Nearby": {"Start": 5, "Adverts": "", "Looking": true}}`)
	if err != nil || settings.nearby.visible() || !settings.nearby.looking {
		t.Fatalf("looking around without being shown: %+v %v", settings.nearby, err)
	}
	for _, bad := range []string{
		`{"Nearby": {"Start": 1, "Adverts": "zz"}}`,
		fmt.Sprintf(`{"Nearby": {"Start": 1, "Adverts": %q}}`, hex.EncodeToString(adverts[:25])),
		fmt.Sprintf(`{"Nearby": {"Start": -1, "Adverts": %q}}`, hex.EncodeToString(adverts)),
		fmt.Sprintf(`{"Nearby": {"Start": 1, "Adverts": %q}}`, strings.Repeat("00", (lanNearbyMaxSlots+1)*lanNearbyAdvertBytes)),
	} {
		if _, err := parseLocalLinkSettings(bad); !errors.Is(err, errLocalLinkBadInput) {
			t.Fatalf("%.60s…: %v", bad, err)
		}
	}
}

func TestLanNearbyShowsTheAdvertOfTheSlot(t *testing.T) {
	now := time.Now()
	slot := lanNearbySlotAt(now)
	nearby := lanNearby{start: slot - 1, adverts: testNearbyAdverts(3)}
	if got := nearby.shown(now); !bytes.Equal(got, bytes.Repeat([]byte{2}, lanNearbyAdvertBytes)) {
		t.Fatalf("the advert of this slot: %x", got)
	}
	if got := nearby.shown(now.Add(lanNearbySlot)); got[0] != 3 {
		t.Fatalf("the next slot's: %x", got)
	}
	if nearby.shown(now.Add(2*lanNearbySlot)) != nil {
		t.Fatal("nothing once the list is over (never a stale token)")
	}
	if nearby.shown(now.Add(-2*lanNearbySlot)) != nil {
		t.Fatal("nothing before the list")
	}
	if (lanNearby{}).shown(now) != nil {
		t.Fatal("not visible: nothing shown")
	}
}

func TestLanNearbyAdvertsAreHeardOnlyWhileLooking(t *testing.T) {
	now := time.Now()
	other, _, _ := testNearbyLan(lanNearby{start: lanNearbySlotAt(now), adverts: testNearbyAdverts(1)})
	theirs := other.beacon()
	if fields, ok := parseLanBeacon(theirs); !ok || fields.nearby == nil || fields.looking {
		t.Fatalf("a visible device's beacon carries its advert: %v %+v", ok, fields)
	}
	from := &net.UDPAddr{IP: net.IPv4(192, 168, 1, 20), Port: lanBeaconPort}

	idle, _, _ := testNearbyLan(lanNearby{})
	idle.handleBeacon(theirs, from)
	if heard := idle.nearbyHeard(time.Now()); len(heard) != 0 {
		t.Fatalf("nothing is kept while nobody looks around: %v", heard)
	}

	looking, _, _ := testNearbyLan(lanNearby{looking: true})
	looking.handleBeacon(theirs, from)
	heard := looking.nearbyHeard(time.Now())
	if len(heard) != 1 || heard[0]["advert"] != hex.EncodeToString(testNearbyAdverts(1)) {
		t.Fatalf("heard while looking: %v", heard)
	}
	if len(looking.nearbyHeard(time.Now().Add(lanNearbyMemory))) != 0 {
		t.Fatal("an advert heard long ago is no longer listed")
	}
	looking.rememberNearby(testNearbyAdverts(1), time.Now())
	looking.forgetNearby()
	if len(looking.nearbyHeard(time.Now())) != 0 {
		t.Fatal("forgotten once the app stops looking around")
	}
}

func TestLanNearbyAnswersThoseWhoLookAround(t *testing.T) {
	now := time.Now()
	looker, _, _ := testNearbyLan(lanNearby{looking: true})
	asks := looker.beacon()
	if fields, ok := parseLanBeacon(asks); !ok || !fields.looking || fields.nearby != nil {
		t.Fatalf("a beacon that looks around: %v %+v", ok, fields)
	}
	from := &net.UDPAddr{IP: net.IPv4(192, 168, 1, 30), Port: lanBeaconPort}

	visible, to, packets := testNearbyLan(lanNearby{start: lanNearbySlotAt(now), adverts: testNearbyAdverts(1)})
	if visible.m.beaconsWanted() {
		t.Fatal("shown only to people nearby, it sends nothing by itself")
	}
	visible.handleBeacon(asks, from)
	if len(*to) != 1 || !(*to)[0].IP.Equal(from.IP) || (*to)[0].Port != lanBeaconPort {
		t.Fatalf("one beacon straight back to whoever looks: %v", *to)
	}
	answer, ok := parseLanBeacon((*packets)[0])
	if !ok || !bytes.Equal(answer.nearby, testNearbyAdverts(1)) {
		t.Fatalf("the answer carries the advert: %v %+v", ok, answer)
	}
	// The looker takes the answer.
	looker.handleBeacon((*packets)[0], &net.UDPAddr{IP: net.IPv4(192, 168, 1, 31), Port: lanBeaconPort})
	if len(looker.nearbyHeard(time.Now())) != 1 {
		t.Fatal("the looker hears the answer")
	}
	// Not again at once (a looker beacons every few seconds).
	visible.handleBeacon(looker.beacon(), &net.UDPAddr{IP: from.IP, Port: lanBeaconPort})
	if len(*to) != 1 {
		t.Fatalf("answers to one address are spaced out: %d", len(*to))
	}

	hidden, hiddenTo, _ := testNearbyLan(lanNearby{})
	hidden.handleBeacon(asks, from)
	if len(*hiddenTo) != 0 {
		t.Fatal("a device not shown nearby does not answer")
	}
	notAsked, notAskedTo, _ := testNearbyLan(lanNearby{start: lanNearbySlotAt(now), adverts: testNearbyAdverts(1)})
	quiet, _, _ := testNearbyLan(lanNearby{})
	notAsked.handleBeacon(quiet.beacon(), from)
	if len(*notAskedTo) != 0 {
		t.Fatal("only a beacon that looks around is answered")
	}
}

func TestLanNearbyHeardStaysBounded(t *testing.T) {
	lan, _, _ := testNearbyLan(lanNearby{looking: true})
	now := time.Now()
	for i := 0; i < 4*lanNearbyMaxHeard; i++ {
		advert := make([]byte, lanNearbyAdvertBytes)
		advert[0], advert[1] = byte(i>>8), byte(i)
		lan.rememberNearby(advert, now)
	}
	if n := len(lan.nearbyHeard(now)); n != lanNearbyMaxHeard {
		t.Fatalf("made-up adverts kept: %d", n)
	}
	// Old ones make room for new ones.
	later := now.Add(lanNearbyMemory)
	lan.rememberNearby(bytes.Repeat([]byte{0xee}, lanNearbyAdvertBytes), later)
	if n := len(lan.nearbyHeard(later)); n != 1 {
		t.Fatalf("after a while only the new one: %d", n)
	}
}

func TestLanRunsForPeopleNearby(t *testing.T) {
	shown := lanNearby{start: 1, adverts: testNearbyAdverts(1)}
	cases := []struct {
		settings localLinkSettings
		want     bool
	}{
		{localLinkSettings{lan: true}, false},
		{localLinkSettings{lan: true, nearby: shown}, true},
		{localLinkSettings{lan: true, nearby: lanNearby{looking: true}}, true},
		{localLinkSettings{lan: false, nearby: lanNearby{looking: true, adverts: shown.adverts}}, false},
		{localLinkSettings{lan: true, peers: []localPeer{testLocalPeer(t, 1)}}, true},
	}
	for i, c := range cases {
		if got := lanWanted(c.settings); got != c.want {
			t.Fatalf("case %d: %v", i, got)
		}
	}

	_, _, manager, _ := testManagers(t)
	manager.apply(localLinkSettings{lan: true, nearby: shown})
	lan := manager.status()["lan"].(map[string]any)
	if lan["error"] != nil {
		t.Skipf("beacon port unavailable here: %v", lan["error"])
	}
	if lan["running"] != true {
		t.Fatalf("the LAN runs to be shown nearby: %+v", lan)
	}
	if heard, ok := manager.status()["nearby"].([]map[string]any); !ok || len(heard) != 0 {
		t.Fatalf("nothing heard yet: %+v", manager.status()["nearby"])
	}
	manager.apply(localLinkSettings{lan: true})
	if manager.status()["lan"].(map[string]any)["running"] != false {
		t.Fatal("hidden and not looking: the LAN stops")
	}
}
