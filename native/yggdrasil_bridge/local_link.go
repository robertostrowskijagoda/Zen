package main

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	mathbits "math/bits"
	"net"
	"sort"
	"strings"
	"time"
)

// Local links: friends (and the account's own devices) near each other
// connect directly, with no internet, over whatever carries a byte stream:
// the same Wi-Fi or a Wi-Fi Direct group (lan_discovery.go), and native
// transports such as Bluetooth that hand the bridge a stream
// (local_link_stream.go). Yggdrasil then peers over that stream, so chats,
// calls and everything else work as on the mesh.
//
// Nobody else may learn who is there. The app gives the bridge one secret
// per device it may link with (a friend's device or one of the account's
// own), the same on both sides: once the two devices paired over the
// post-quantum session layer, it mixes in random contributions they
// exchanged there; before, it comes from their static keys alone (X25519,
// runtime_lan_discovery.dart). A stranger has none of them.
//
//   - Adverts (LAN beacons, Wi-Fi Direct service records, Bluetooth
//     advertisements) carry a Bloom filter of tags: one per secret, keyed
//     by it, for the current time slot and a fresh random salt. Only the
//     other holder of a secret can test its tag; to anyone else an advert
//     is random bytes that change every time (its size tells roughly how
//     many devices the sender links with).
//   - A filter holds only as many tags as keep a false match rare
//     (localAdvertCapacity): the 16 bytes a Bluetooth advert carries made
//     every phone nearby take a filter of 20 devices for one of its own,
//     and dial. Own devices go in first, then the ones linked lately, then
//     the others by turns (localAdvertOrder). A filter fuller than
//     localLinkMaxBloomFill means nothing and is not tested at all: an
//     advert with every bit set matched every phone.
//   - Linking runs a handshake (local_link_handshake.go) that proves the
//     secret on both sides before anything else is said, and encrypts the
//     stream. Inside it each side names its Yggdrasil key, which must belong
//     to the address the secret was given for; Yggdrasil then peers with
//     that key pinned.
const (
	localLinkSecretSize = 32
	// Devices one node links with at most (own devices and friends' ones).
	localLinkMaxPeers = 2048
	// Adverts name a time slot: a tag is only good near the time it was
	// made, so a recorded advert stops working.
	localLinkSlot = 5 * time.Minute
	// Slots an advert may be off by (clocks of phones without a network
	// drift).
	localLinkMaxSlotSkew = 3
	// 2: tags with seven positions of their own (bloomPositions).
	localLinkAdvertVersion = 2
	// version, slot (low 16 bits), salt.
	localLinkAdvertHeader = 1 + 2 + 4
	// Smallest and largest Bloom filter; LAN beacons size it to the number
	// of devices, Bluetooth asks for what fits. Sixteen bits per device:
	// at most 35% of the bits set, a false match for 1 in 1,400 devices
	// tested (0.354^7).
	localLinkMinBloomBytes = 8
	localLinkMaxBloomBytes = 1024
	localLinkBloomBitsPer  = 16
	localLinkBloomHashes   = 7
	// Most of a filter's bits that may be set, in percent. Above it a
	// filter matches too much to mean anything: at 40% a device tested
	// matches by chance once in 600 (0.4^7), so a forged filter just below
	// it pulls a phone that links with 40 devices into dialling one time
	// in 16; one with every bit set pulled every phone. An honest filter
	// stays below it (buildLocalAdvert).
	localLinkMaxBloomFill = 40
	// Concurrent local links at most.
	localLinkMaxLinks = 16
)

var (
	errLocalLinkStranger = errors.New("local link: not a known device")
	errLocalLinkBadInput = errors.New("local link: malformed input")
)

// localPeer is one device this node may link with locally.
type localPeer struct {
	// Its mesh address (normalised), which its Yggdrasil key must match.
	address string
	// One of this account's own devices (else a friend's).
	own bool
	// Keys derived from the pair's secret, one per use.
	tagKey  [32]byte
	selKey  [32]byte
	linkKey [32]byte
}

// releaseLocalPeers overwrites the keys of peers no longer used and lets
// their memory be swapped again (memguard.go).
func releaseLocalPeers(peers []localPeer) {
	unlockMemory(sliceBytes(peers))
	for i := range peers {
		wipeBytes(peers[i].tagKey[:])
		wipeBytes(peers[i].selKey[:])
		wipeBytes(peers[i].linkKey[:])
	}
}

func localSubKey(secret []byte, label string) [32]byte {
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(label))
	var out [32]byte
	copy(out[:], mac.Sum(nil))
	return out
}

// newLocalPeer checks a peer the app named: a mesh address and a 32-byte
// secret as hex.
func newLocalPeer(address, secretHex string, own bool) (localPeer, error) {
	ip := net.ParseIP(strings.TrimSpace(address))
	if ip == nil || ip.To4() != nil || !meshRange.Contains(ip) {
		return localPeer{}, fmt.Errorf("%w: address %q", errLocalLinkBadInput, address)
	}
	secret, err := hex.DecodeString(strings.TrimSpace(secretHex))
	defer wipeBytes(secret)
	if err != nil || len(secret) != localLinkSecretSize {
		return localPeer{}, fmt.Errorf("%w: secret for %s", errLocalLinkBadInput, ip)
	}
	return localPeer{
		address: ip.String(),
		own:     own,
		tagKey:  localSubKey(secret, "zen.local.tag.v1"),
		selKey:  localSubKey(secret, "zen.local.sel.v1"),
		linkKey: localSubKey(secret, "zen.local.link.v1"),
	}, nil
}

// meshRange is Yggdrasil's address range (200::/7).
var meshRange = &net.IPNet{IP: net.ParseIP("200::"), Mask: net.CIDRMask(7, 128)}

// localLinkSettings is what the app sets (YggSetLocalLinksJson):
//
//	{"Lan": true, "BeaconSeconds": 10,
//	 "Peers": [{"Address": "200:…", "Secret": "<64 hex>", "Own": false}]}
//
// Lan runs discovery on the local networks (lan_discovery.go); Peers are
// every device this node may link with, over any transport. Nearby (may be
// left out) is "people nearby" on the local networks (lan_nearby.go): the
// adverts of the slots from Start on, hex, and whether the app looks around:
//
//	"Nearby": {"Start": 2950000, "Adverts": "<hex>", "Looking": true}
type localLinkSettings struct {
	lan           bool
	beaconSeconds int
	peers         []localPeer
	nearby        lanNearby
}

func parseLocalLinkSettings(payload string) (localLinkSettings, error) {
	var raw struct {
		Lan           bool `json:"Lan"`
		BeaconSeconds int  `json:"BeaconSeconds"`
		Peers         []struct {
			Address string `json:"Address"`
			Secret  string `json:"Secret"`
			Own     bool   `json:"Own"`
		} `json:"Peers"`
		Nearby *struct {
			Start   int64  `json:"Start"`
			Adverts string `json:"Adverts"`
			Looking bool   `json:"Looking"`
		} `json:"Nearby"`
	}
	if err := json.Unmarshal([]byte(payload), &raw); err != nil {
		return localLinkSettings{}, err
	}
	if len(raw.Peers) > localLinkMaxPeers {
		return localLinkSettings{}, fmt.Errorf("%w: %d peers (at most %d)", errLocalLinkBadInput, len(raw.Peers), localLinkMaxPeers)
	}
	settings := localLinkSettings{lan: raw.Lan, beaconSeconds: raw.BeaconSeconds}
	if raw.Nearby != nil {
		nearby, err := parseLanNearby(raw.Nearby.Start, raw.Nearby.Adverts, raw.Nearby.Looking)
		if err != nil {
			return localLinkSettings{}, err
		}
		settings.nearby = nearby
	}
	seen := make(map[string]bool, len(raw.Peers))
	for _, entry := range raw.Peers {
		peer, err := newLocalPeer(entry.Address, entry.Secret, entry.Own)
		if err != nil {
			return localLinkSettings{}, err
		}
		if seen[peer.address] {
			continue
		}
		seen[peer.address] = true
		settings.peers = append(settings.peers, peer)
	}
	return settings, nil
}

func localLinkSlotAt(now time.Time) int64 {
	return now.Unix() / int64(localLinkSlot/time.Second)
}

// localLinkBloomBytes is the filter size for n devices (localLinkBloomBitsPer
// each), in steps of 16 bytes so the size says little.
func localLinkBloomBytes(n int) int {
	size := (n*localLinkBloomBitsPer + 7) / 8
	size = (size + 15) / 16 * 16
	if size < 16 {
		size = 16
	}
	if size > localLinkMaxBloomBytes {
		size = localLinkMaxBloomBytes
	}
	return size
}

// bloomPositions are the filter bits of peer's tag for slot and salt.
func (peer *localPeer) bloomPositions(slot int64, salt []byte, bits uint32) [localLinkBloomHashes]uint32 {
	mac := hmac.New(sha256.New, peer.tagKey[:])
	var slotBytes [8]byte
	binary.BigEndian.PutUint64(slotBytes[:], uint64(slot))
	mac.Write([]byte("adv"))
	mac.Write(slotBytes[:])
	mac.Write(salt)
	sum := mac.Sum(nil)
	// Seven positions of their own, not one step repeated: in a small
	// filter the steps of two devices often fall in line, and a stranger
	// then matched several times as often as the filter's fill says.
	var out [localLinkBloomHashes]uint32
	for i := range out {
		out[i] = binary.BigEndian.Uint32(sum[4*i:4*i+4]) % bits
	}
	return out
}

// localAdvertCapacity is how many devices a filter of bloomBytes bytes
// holds (localLinkBloomBitsPer bits each).
func localAdvertCapacity(bloomBytes int) int {
	return bloomBytes * 8 / localLinkBloomBitsPer
}

// localAdvertTooFull tells whether more than localLinkMaxBloomFill percent
// of a filter's bits are set.
func localAdvertTooFull(bloom []byte) bool {
	ones := 0
	for _, b := range bloom {
		ones += mathbits.OnesCount8(b)
	}
	return ones*100 > len(bloom)*8*localLinkMaxBloomFill
}

// buildLocalAdvert makes an advert of peers for the slot of now, with a
// Bloom filter of bloomBytes bytes (0: sized to the number of peers). It
// holds the first localAdvertCapacity of peers (the caller puts the ones
// that matter first, localAdvertOrder), under a new salt while the filter
// came out fuller than receivers take, and without the last of them should
// that go on.
func buildLocalAdvert(peers []localPeer, now time.Time, bloomBytes int, random io.Reader) ([]byte, error) {
	if bloomBytes == 0 {
		bloomBytes = localLinkBloomBytes(len(peers))
	}
	if bloomBytes < localLinkMinBloomBytes || bloomBytes > localLinkMaxBloomBytes {
		return nil, fmt.Errorf("%w: advert of %d bytes", errLocalLinkBadInput, bloomBytes)
	}
	if capacity := localAdvertCapacity(bloomBytes); len(peers) > capacity {
		peers = peers[:capacity]
	}
	slot := localLinkSlotAt(now)
	for tries := 1; ; tries++ {
		advert := make([]byte, localLinkAdvertHeader+bloomBytes)
		advert[0] = localLinkAdvertVersion
		binary.BigEndian.PutUint16(advert[1:3], uint16(slot))
		if _, err := io.ReadFull(random, advert[3:7]); err != nil {
			return nil, err
		}
		bloom := advert[localLinkAdvertHeader:]
		bits := uint32(len(bloom) * 8)
		for i := range peers {
			for _, pos := range peers[i].bloomPositions(slot, advert[3:7], bits) {
				bloom[pos/8] |= 1 << (pos % 8)
			}
		}
		if !localAdvertTooFull(bloom) {
			return advert, nil
		}
		if tries%8 == 0 && len(peers) > 0 {
			peers = peers[:len(peers)-1]
		}
	}
}

// localAdvertRecent is how long a device linked with counts as seen lately
// (localAdvertOrder).
const localAdvertRecent = 14 * 24 * time.Hour

// localAdvertOrder is peers in the order an advert with room for capacity
// of them takes them: the account's own devices, then the ones linked
// lately (the latest first), then the rest by turns, the next ones each
// slot, so every friend is in now and then.
func localAdvertOrder(peers []localPeer, linked map[string]time.Time, now time.Time, capacity int) []localPeer {
	if len(peers) <= capacity {
		return peers
	}
	var own, recent, rest []localPeer
	for _, peer := range peers {
		at, ok := linked[peer.address]
		switch {
		case peer.own:
			own = append(own, peer)
		case ok && now.Sub(at) < localAdvertRecent:
			recent = append(recent, peer)
		default:
			rest = append(rest, peer)
		}
	}
	sort.SliceStable(recent, func(i, j int) bool {
		return linked[recent[i].address].After(linked[recent[j].address])
	})
	out := append(append(make([]localPeer, 0, len(peers)), own...), recent...)
	if room := capacity - len(out); room > 0 && len(rest) > 0 {
		start := int((localLinkSlotAt(now) * int64(room)) % int64(len(rest)))
		if start < 0 {
			start += len(rest)
		}
		rest = append(rest[start:], rest[:start]...)
	}
	return append(out, rest...)
}

// localAdvertSlot is the full slot an advert names, if it is near now.
func localAdvertSlot(advert []byte, now time.Time) (int64, bool) {
	if len(advert) < localLinkAdvertHeader+localLinkMinBloomBytes ||
		len(advert) > localLinkAdvertHeader+localLinkMaxBloomBytes ||
		advert[0] != localLinkAdvertVersion {
		return 0, false
	}
	mine := localLinkSlotAt(now)
	diff := int16(uint16(mine) - binary.BigEndian.Uint16(advert[1:3]))
	if diff > localLinkMaxSlotSkew || diff < -localLinkMaxSlotSkew {
		return 0, false
	}
	return mine - int64(diff), true
}

// matchLocalAdvert returns the peers whose tag the advert holds: the
// devices that may have sent it (a Bloom filter can match by chance; the
// handshake tells for sure). A filter too full to mean anything matches
// nothing, on every transport.
func matchLocalAdvert(peers []localPeer, advert []byte, now time.Time) []*localPeer {
	slot, ok := localAdvertSlot(advert, now)
	if !ok {
		return nil
	}
	salt := advert[3:7]
	bloom := advert[localLinkAdvertHeader:]
	if localAdvertTooFull(bloom) {
		return nil
	}
	bits := uint32(len(bloom) * 8)
	var out []*localPeer
	for i := range peers {
		hit := true
		for _, pos := range peers[i].bloomPositions(slot, salt, bits) {
			if bloom[pos/8]&(1<<(pos%8)) == 0 {
				hit = false
				break
			}
		}
		if hit {
			out = append(out, &peers[i])
		}
	}
	return out
}

func randomLocalID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}
