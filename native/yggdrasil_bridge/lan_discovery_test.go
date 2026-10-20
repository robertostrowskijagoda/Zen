package main

import (
	"regexp"
	"strings"
	"testing"
)

const testLanSecret = "00112233445566778899aabbccddeeff"

func TestParseZenLanDiscovery(t *testing.T) {
	setting := parseZenLanDiscovery(`{"Peers":[],"ZenLanDiscovery":{"Enabled":true,"Secret":"` + testLanSecret + `","OnWiFi":true}}`)
	if !setting.Enabled || setting.Secret != testLanSecret || !setting.OnWiFi {
		t.Fatalf("got %+v", setting)
	}
	for _, other := range []string{`{}`, `not json`, `{"ZenLanDiscovery":"yes"}`} {
		if parseZenLanDiscovery(other).Enabled {
			t.Fatalf("%q must leave discovery off", other)
		}
	}
}

func TestLanDiscoveryPassword(t *testing.T) {
	first, ok := lanDiscoveryPassword(testLanSecret)
	if !ok || len(first) != 32 {
		t.Fatalf("got %q %v", first, ok)
	}
	again, _ := lanDiscoveryPassword(strings.ToUpper(testLanSecret))
	if again != first {
		t.Fatal("the same secret must give the same password on every device")
	}
	other, _ := lanDiscoveryPassword("ff112233445566778899aabbccddeeff")
	if other == first {
		t.Fatal("another secret must give another password")
	}
	if strings.Contains(first, testLanSecret) {
		t.Fatal("the password must not reveal the secret")
	}
	for _, bad := range []string{"", "zz", "0011"} {
		if _, ok := lanDiscoveryPassword(bad); ok {
			t.Fatalf("%q is not a usable secret", bad)
		}
	}
}

func TestLanDiscoveryPlan(t *testing.T) {
	on := zenLanDiscovery{Enabled: true, Secret: testLanSecret}
	if _, _, ok := lanDiscoveryPlan(zenLanDiscovery{Secret: testLanSecret}, "windows", false); ok {
		t.Fatal("off unless the app enables it")
	}
	if _, _, ok := lanDiscoveryPlan(zenLanDiscovery{Enabled: true}, "linux", false); ok {
		t.Fatal("never without a password")
	}
	regex, password, ok := lanDiscoveryPlan(on, "windows", false)
	if !ok || regex != defaultMulticastInterfaceRegex || password == "" {
		t.Fatalf("a computer runs it on its interfaces, got %q %q %v", regex, password, ok)
	}
	if _, _, ok := lanDiscoveryPlan(on, "android", true); ok {
		t.Fatal("a phone needs Wi-Fi and the person's opt-in")
	}
	on.OnWiFi = true
	regex, _, ok = lanDiscoveryPlan(on, "android", true)
	if !ok {
		t.Fatal("a phone on Wi-Fi that opted in takes part")
	}
	wifi := regexp.MustCompile(regex)
	for _, name := range []string{"wlan0", "swlan0", "ap0"} {
		if !wifi.MatchString(name) {
			t.Fatalf("%s is Wi-Fi", name)
		}
	}
	for _, name := range []string{"rmnet_data0", "ccmni0", "lo", "dummy0", "tun0", "eth0"} {
		if wifi.MatchString(name) {
			t.Fatalf("%s is not Wi-Fi", name)
		}
	}
	regex, _, ok = lanDiscoveryPlan(on, "ios", true)
	if !ok || !regexp.MustCompile(regex).MatchString("en0") || regexp.MustCompile(regex).MatchString("pdp_ip0") {
		t.Fatalf("iPhone: Wi-Fi (en0) only, got %q", regex)
	}
}
