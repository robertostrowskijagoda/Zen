package main

import "testing"

func TestLinuxPowerSupplies(t *testing.T) {
	cases := []struct {
		name     string
		supplies []powerSupplyInfo
		want     bool
	}{
		{"desktop without a battery", nil, false},
		{"laptop on battery", []powerSupplyInfo{
			{kind: "Mains", online: "0"},
			{kind: "Battery", status: "Discharging"},
		}, true},
		{"laptop plugged in", []powerSupplyInfo{
			{kind: "Mains", online: "1"},
			{kind: "Battery", status: "Charging"},
		}, false},
		{"full battery, plugged in by USB-C", []powerSupplyInfo{
			{kind: "Battery", status: "Not charging"},
			{kind: "USB", online: "1"},
		}, false},
		{"a mouse's battery is not the computer's", []powerSupplyInfo{
			{kind: "Battery", status: "Discharging", scope: "Device"},
		}, false},
	}
	for _, c := range cases {
		if got := linuxSuppliesOnBattery(c.supplies); got != c.want {
			t.Fatalf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestPmsetAndWindowsPower(t *testing.T) {
	if !pmsetOnBattery("Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%; discharging") {
		t.Fatal("a Mac on battery")
	}
	if pmsetOnBattery("Now drawing from 'AC Power'\n") {
		t.Fatal("a Mac plugged in")
	}
	if !windowsPowerOnBattery(0, 1) {
		t.Fatal("AC off with a battery")
	}
	if windowsPowerOnBattery(1, 8) || windowsPowerOnBattery(0, 128) || windowsPowerOnBattery(255, 255) {
		t.Fatal("plugged in, no battery, or unknown: not on battery")
	}
}
