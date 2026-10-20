//go:build !windows && !(linux && !android)

package main

// Android, iOS and macOS open their Bluetooth streams in their platform
// bridges and hand them to the node themselves (local_link_stream.go).
const (
	btHasL2cap  = false
	btHasRfcomm = false
)

func btSupported() bool { return false }

func btListen() (btListener, map[string]any, error) { return nil, nil, errBtUnsupported }

func btDial(device string, psm int, classic bool) (btConn, error) { return nil, errBtUnsupported }

func btPaired() ([]string, error) { return nil, errBtUnsupported }
