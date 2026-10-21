package main

import "testing"

func TestWifiDirectAdapterIsAVirtualWifiAdapter(t *testing.T) {
	stations := map[string]bool{"{0a1b2c3d-0000-0000-0000-000000000001}": true}
	if !isWifiDirectAdapter(71, "{0A1B2C3D-0000-0000-0000-000000000002}", stations) {
		t.Fatal("an 802.11 adapter that is no station is Wi-Fi Direct's")
	}
	if isWifiDirectAdapter(71, "{0A1B2C3D-0000-0000-0000-000000000001}", stations) {
		t.Fatal("the station itself is the normal Wi-Fi")
	}
	if isWifiDirectAdapter(6, "{0A1B2C3D-0000-0000-0000-000000000002}", stations) {
		t.Fatal("Ethernet is no Wi-Fi Direct")
	}
	if isWifiDirectAdapter(71, "{0A1B2C3D-0000-0000-0000-000000000002}", nil) {
		t.Fatal("without the WLAN service nothing is told apart")
	}
	if lanTransportFor("p2p-wlan0-0") != "wifi-direct" {
		t.Fatal("Android's groups are Wi-Fi Direct")
	}
}
