//go:build darwin && !ios

package main

import (
	"context"
	"os/exec"
	"time"
)

// onBatteryPower asks pmset which source the Mac draws from.
func onBatteryPower() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, "/usr/bin/pmset", "-g", "batt").Output()
	if err != nil {
		return false
	}
	return pmsetOnBattery(string(output))
}
