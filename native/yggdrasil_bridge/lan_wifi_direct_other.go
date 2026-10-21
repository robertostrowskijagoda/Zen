//go:build !windows

package main

// Elsewhere Wi-Fi Direct interfaces are named p2p-… (lanTransportFor).
func lanWifiDirectAdapter(name string) bool { return false }
