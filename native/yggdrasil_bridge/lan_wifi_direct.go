package main

import "strings"

// Windows runs Wi-Fi Direct on virtual 802.11 adapters next to the Wi-Fi
// station ("Microsoft Wi-Fi Direct Virtual Adapter", "Local Area
// Connection* N"): an 802.11 adapter that is not a WLAN station interface.
// They are told apart by type, not by their (localized) names; the runner
// does the same (wifi_direct_bridge.cpp).
const lanIfTypeIEEE80211 = 71

// isWifiDirectAdapter: adapterGUID as GetAdaptersAddresses gives it
// ("{…}"), stations the WLAN station interfaces in lower case.
func isWifiDirectAdapter(ifType uint32, adapterGUID string, stations map[string]bool) bool {
	return ifType == lanIfTypeIEEE80211 && adapterGUID != "" && len(stations) > 0 &&
		!stations[strings.ToLower(adapterGUID)]
}
