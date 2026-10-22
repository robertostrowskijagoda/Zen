//go:build linux && !android

package main

import (
	"os"
	"path/filepath"
	"strings"
)

// onBatteryPower reads the power supplies the kernel lists.
func onBatteryPower() bool {
	entries, err := os.ReadDir("/sys/class/power_supply")
	if err != nil {
		return false
	}
	read := func(dir, name string) string {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(data))
	}
	supplies := make([]powerSupplyInfo, 0, len(entries))
	for _, entry := range entries {
		dir := filepath.Join("/sys/class/power_supply", entry.Name())
		supplies = append(supplies, powerSupplyInfo{
			kind:   read(dir, "type"),
			online: read(dir, "online"),
			status: read(dir, "status"),
			scope:  read(dir, "scope"),
		})
	}
	return linuxSuppliesOnBattery(supplies)
}
