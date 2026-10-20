package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"runtime"
)

// LAN discovery (Yggdrasil multicast, §5.1 pkt 6).
//
// Beacons on the local network carry this node's public key, which is also
// the person's Zen address, and every Yggdrasil node there that knows the
// password peers with it. So discovery is off unless the app turns it on,
// and then only with a password derived from a secret the app gives (the
// one the person's own devices share): their devices on the same Wi-Fi
// find each other, strangers' nodes cannot peer.
//
// The app passes the setting in the node config JSON, next to Yggdrasil's
// own keys (Yggdrasil ignores unknown keys):
//
//	"ZenLanDiscovery": {"Enabled": true, "Secret": "<hex, 16+ bytes>", "OnWiFi": true}
//
// Phones take part only with OnWiFi (the app saw Wi-Fi and the person
// opted in) and only on Wi-Fi interfaces, never on mobile data.
type zenLanDiscovery struct {
	Enabled bool   `json:"Enabled"`
	Secret  string `json:"Secret"`
	OnWiFi  bool   `json:"OnWiFi"`
}

const (
	zenLanDiscoveryKey       = "ZenLanDiscovery"
	minLanDiscoverySecret    = 16
	lanDiscoveryPasswordInfo = "zen/lan-discovery/v1"
	// Wi-Fi (and this phone's hotspot) interfaces only: wlan0, swlan0,
	// ap0 on Android; en0 is Wi-Fi on iPhone.
	androidWifiMulticastRegex = "^(wlan|swlan|ap|wl)[0-9]*$"
	iosWifiMulticastRegex     = "^en0$"
)

// parseZenLanDiscovery reads the app's setting from the node config JSON.
func parseZenLanDiscovery(configJSON string) zenLanDiscovery {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal([]byte(configJSON), &envelope); err != nil {
		return zenLanDiscovery{}
	}
	raw, ok := envelope[zenLanDiscoveryKey]
	if !ok {
		return zenLanDiscovery{}
	}
	var setting zenLanDiscovery
	if err := json.Unmarshal(raw, &setting); err != nil {
		return zenLanDiscovery{}
	}
	return setting
}

// lanDiscoveryPassword derives the multicast password from the app's
// secret: the same on every device that holds the secret, unrelated to it
// otherwise (the password travels in link handshakes, the secret never).
func lanDiscoveryPassword(secretHex string) (string, bool) {
	secret, err := hex.DecodeString(secretHex)
	if err != nil || len(secret) < minLanDiscoverySecret {
		return "", false
	}
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(lanDiscoveryPasswordInfo))
	return hex.EncodeToString(mac.Sum(nil))[:32], true
}

// lanDiscoveryPlan says whether (and on which interfaces) LAN discovery
// runs for setting on this platform, and with which password.
func lanDiscoveryPlan(setting zenLanDiscovery, goos string, phone bool) (regex string, password string, ok bool) {
	if !setting.Enabled {
		return "", "", false
	}
	password, ok = lanDiscoveryPassword(setting.Secret)
	if !ok {
		return "", "", false
	}
	if !phone {
		return defaultMulticastInterfaceRegex, password, true
	}
	if !setting.OnWiFi {
		return "", "", false
	}
	switch goos {
	case "android":
		return androidWifiMulticastRegex, password, true
	case "ios":
		return iosWifiMulticastRegex, password, true
	default:
		return "", "", false
	}
}

func currentLanDiscoveryPlan(setting zenLanDiscovery) (string, string, bool) {
	return lanDiscoveryPlan(setting, runtime.GOOS, isPhoneOS())
}
