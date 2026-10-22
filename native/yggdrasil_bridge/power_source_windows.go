//go:build windows

package main

import (
	"unsafe"

	"golang.org/x/sys/windows"
)

// systemPowerStatus is SYSTEM_POWER_STATUS.
type systemPowerStatus struct {
	acLineStatus        byte
	batteryFlag         byte
	batteryLifePercent  byte
	systemStatusFlag    byte
	batteryLifeTime     uint32
	batteryFullLifeTime uint32
}

var procGetSystemPowerStatus = windows.NewLazySystemDLL("kernel32.dll").NewProc("GetSystemPowerStatus")

// onBatteryPower asks Windows whether the AC line is off.
func onBatteryPower() bool {
	var status systemPowerStatus
	if err := procGetSystemPowerStatus.Find(); err != nil {
		return false
	}
	ok, _, _ := procGetSystemPowerStatus.Call(uintptr(unsafe.Pointer(&status)))
	if ok == 0 {
		return false
	}
	return windowsPowerOnBattery(status.acLineStatus, status.batteryFlag)
}
