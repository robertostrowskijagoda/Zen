package main

import (
	"encoding/hex"
	"fmt"
	"sort"
	"strings"
	"time"
)

// "People nearby" over the shared local network (the same Wi-Fi or
// router), next to Bluetooth. The LAN beacons (lan_discovery.go) carry the
// very advert the phone shows over Bluetooth: the 16-byte token of the
// current slot and its 4-byte hint (nearby_crypto.dart). Friends recognise
// it with the mask key and hash-chain anchors they were given; to anyone
// else it is a pseudonym that changes every slot. No address, account or
// stable id goes out.
//
// The app hands over the adverts of the coming slots at once and the bridge
// picks the one of the slot it is in, so a token never stays on the network
// past its slot (and nothing is shown once the list is over). Adverts heard
// from others are kept only while the app looks around ("W pobliżu" open,
// or a short look in the background), for at most lanNearbyMemory.
//
// Battery: the advert rides on the beacons that go out for local links
// anyway. A device with no devices to link with does not beacon for it on
// its own: it only answers devices that look around (their beacons say so),
// with one beacon sent straight back.
const (
	// Bytes of one slot's advert: the token, then the hint. Must match
	// kNearbyAdvertBytes in Dart.
	lanNearbyAdvertBytes = 16 + 4
	// One token's slot. Must match kNearbySlot in Dart.
	lanNearbySlot = 10 * time.Minute
	// Slots the app may hand over at once (two weeks).
	lanNearbyMaxSlots = 2016
	// How long an advert heard stays listed (Dart's NearbyService.fresh).
	lanNearbyMemory = 2 * time.Minute
	// Different adverts listed at most: anyone on the network can make up
	// as many as they like.
	lanNearbyMaxHeard = 256
	// Beacons while looking around: as often as the LAN allows.
	lanNearbyLookInterval = lanMinBeaconInterval
	// The beacon's info byte: the length of its nearby advert in the low
	// bits, and whether its sender looks around.
	lanNearbyLookingBit = 0x80
	lanNearbyLengthMask = 0x7f
)

// lanNearby is what the app set for the LAN (YggSetLocalLinksJson,
// "Nearby"): adverts of the slots from start on, and whether it looks
// around now.
type lanNearby struct {
	start   int64
	adverts []byte
	looking bool
}

func lanNearbySlotAt(now time.Time) int64 {
	return now.UnixMilli() / lanNearbySlot.Milliseconds()
}

// parseLanNearby checks the app's "Nearby" settings: Adverts is hex of
// whole adverts, at most lanNearbyMaxSlots of them (empty: nothing shown).
func parseLanNearby(start int64, advertsHex string, looking bool) (lanNearby, error) {
	adverts, err := hex.DecodeString(strings.TrimSpace(advertsHex))
	if err != nil || len(adverts)%lanNearbyAdvertBytes != 0 ||
		len(adverts)/lanNearbyAdvertBytes > lanNearbyMaxSlots || start < 0 {
		return lanNearby{}, fmt.Errorf("%w: nearby adverts", errLocalLinkBadInput)
	}
	if len(adverts) == 0 {
		adverts = nil
	}
	return lanNearby{start: start, adverts: adverts, looking: looking}, nil
}

// shown is the advert of the slot of now, nil before or past the list.
func (n lanNearby) shown(now time.Time) []byte {
	index := lanNearbySlotAt(now) - n.start
	if n.adverts == nil || index < 0 || index >= int64(len(n.adverts)/lanNearbyAdvertBytes) {
		return nil
	}
	from := int(index) * lanNearbyAdvertBytes
	return n.adverts[from : from+lanNearbyAdvertBytes]
}

// visible tells whether there is anything to show (now or later).
func (n lanNearby) visible() bool {
	return n.adverts != nil
}

// lanNearbyHeard is an advert heard on the network while looking around.
type lanNearbyHeard struct {
	at time.Time
}

// rememberNearby keeps an advert heard now (only while looking around).
func (lan *lanDiscovery) rememberNearby(advert []byte, now time.Time) {
	if len(advert) != lanNearbyAdvertBytes {
		return
	}
	var key [lanNearbyAdvertBytes]byte
	copy(key[:], advert)
	lan.mu.Lock()
	defer lan.mu.Unlock()
	if lan.nearby == nil {
		lan.nearby = map[[lanNearbyAdvertBytes]byte]lanNearbyHeard{}
	}
	if _, known := lan.nearby[key]; !known && len(lan.nearby) >= lanNearbyMaxHeard {
		lan.pruneNearby(now)
		if len(lan.nearby) >= lanNearbyMaxHeard {
			return
		}
	}
	lan.nearby[key] = lanNearbyHeard{at: now}
}

// pruneNearby drops the adverts heard too long ago; lan.mu is held.
func (lan *lanDiscovery) pruneNearby(now time.Time) {
	for key, heard := range lan.nearby {
		if now.Sub(heard.at) >= lanNearbyMemory {
			delete(lan.nearby, key)
		}
	}
}

// forgetNearby drops every advert heard (the app stopped looking around).
func (lan *lanDiscovery) forgetNearby() {
	lan.mu.Lock()
	lan.nearby = nil
	lan.mu.Unlock()
}

// nearbyHeard lists the adverts heard lately, newest first:
// [{"advert": hex, "at": unix ms}].
func (lan *lanDiscovery) nearbyHeard(now time.Time) []map[string]any {
	lan.mu.Lock()
	defer lan.mu.Unlock()
	lan.pruneNearby(now)
	out := make([]map[string]any, 0, len(lan.nearby))
	for key, heard := range lan.nearby {
		out = append(out, map[string]any{
			"advert": hex.EncodeToString(key[:]),
			"at":     heard.at.UnixMilli(),
		})
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i]["at"].(int64) > out[j]["at"].(int64)
	})
	return out
}
