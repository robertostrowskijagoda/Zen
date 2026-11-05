//go:build race

package main

// raceEnabled: built with the race detector (`go test -race`, CI's "Race
// detector" step), which slows the code several times over; the few tests
// that measure throughput or time skip themselves then.
const raceEnabled = true
