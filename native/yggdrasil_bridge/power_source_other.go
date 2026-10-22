//go:build !windows && !(linux && !android) && !(darwin && !ios)

package main

// onBatteryPower: phones keep their own few peers (phone_peers.go) and are
// never bridges, so they never count as a computer on battery.
func onBatteryPower() bool {
	return false
}
