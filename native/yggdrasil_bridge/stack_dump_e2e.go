//go:build zene2e

package main

// Only in the bridge the real-node tests build (go build -tags zene2e,
// tool/e2e.dart), never in an app: every 10 seconds the stacks of all
// goroutines go to the file ZEN_STACK_DUMP names, so a test whose process
// hangs in a bridge call shows where (a lock or an actor nobody releases).

import (
	"os"
	"runtime"
	"time"
)

func init() {
	path := os.Getenv("ZEN_STACK_DUMP")
	if path == "" {
		return
	}
	go func() {
		buffer := make([]byte, 16<<20)
		for {
			time.Sleep(10 * time.Second)
			n := runtime.Stack(buffer, true)
			_ = os.WriteFile(path+".tmp", buffer[:n], 0o644)
			_ = os.Rename(path+".tmp", path)
		}
	}()
}
