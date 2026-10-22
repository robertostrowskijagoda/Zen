package main

import (
	"strings"
	"sync"
	"time"
)

// A computer on battery (a laptop in the tray) is no bridge: its public
// peering port stops taking peers (peerListenGuard.setPaused) and it dials
// desktopBatteryPeerCount public peers instead of desktopPublicPeerCount.
// Plugged in again, it is a bridge with all its peers again. The power
// source is read every desktopPowerCheckInterval (onBatteryPower in the
// power_source_*.go files: GetSystemPowerStatus on Windows, pmset on macOS,
// /sys/class/power_supply on Linux).
const (
	desktopBatteryPeerCount   = 4
	desktopPowerCheckInterval = 2 * time.Minute
	// Friends' bridges a computer on battery keeps dialled (the rest wait
	// until it is plugged in again).
	desktopBatteryBridgeCount = 1
)

// desktopPowerSaver remembers whether the computer runs on battery and the
// public peers it dials when plugged in.
type desktopPowerSaver struct {
	mu        sync.Mutex
	onBattery bool
	// The public peers to dial again once plugged in.
	full []string
	// Friends' bridges set aside while on battery, dialled again once
	// plugged in.
	bridges  []string
	stop     chan struct{}
	stopOnce sync.Once
}

func newDesktopPowerSaver(onBattery bool, full []string) *desktopPowerSaver {
	return &desktopPowerSaver{
		onBattery: onBattery,
		full:      append([]string(nil), full...),
		stop:      make(chan struct{}),
	}
}

func (saver *desktopPowerSaver) stopWatch() {
	saver.stopOnce.Do(func() { close(saver.stop) })
}

// powerSupplyInfo is one entry of /sys/class/power_supply.
type powerSupplyInfo struct {
	kind   string // "Mains", "USB", "Battery"...
	online string // "1" when a charger is plugged in
	status string // "Charging", "Discharging"... (batteries)
	scope  string // "Device" for a mouse's or a keyboard's battery
}

// linuxSuppliesOnBattery: true when a system battery discharges and no
// charger is online. A computer without a battery is plugged in.
func linuxSuppliesOnBattery(supplies []powerSupplyInfo) bool {
	discharging := false
	for _, supply := range supplies {
		kind := strings.TrimSpace(supply.kind)
		switch kind {
		case "Mains", "USB", "USB_C", "USB_PD", "USB_PD_DRP":
			if strings.TrimSpace(supply.online) == "1" {
				return false
			}
		case "Battery":
			if strings.EqualFold(strings.TrimSpace(supply.scope), "Device") {
				continue
			}
			if strings.EqualFold(strings.TrimSpace(supply.status), "Discharging") {
				discharging = true
			}
		}
	}
	return discharging
}

// pmsetOnBattery reads `pmset -g batt` (macOS): its first line names the
// source, "Now drawing from 'Battery Power'" or "'AC Power'".
func pmsetOnBattery(output string) bool {
	return strings.Contains(output, "'Battery Power'")
}

// windowsPowerOnBattery reads SYSTEM_POWER_STATUS: the AC line is off
// (0) and there is a system battery (flag 128: none, 255: unknown).
func windowsPowerOnBattery(acLineStatus, batteryFlag byte) bool {
	return acLineStatus == 0 && batteryFlag != 128 && batteryFlag != 255
}
