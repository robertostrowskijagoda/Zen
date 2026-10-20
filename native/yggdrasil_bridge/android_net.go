//go:build android

package main

func init() {
	configureAndroidResolver()
}

// configureAndroidResolver gives Go a resolver on Android, where it finds no
// /etc/resolv.conf: the system resolver first, then DNS over TLS to the
// configured servers (dns_fallback.go). Peers given by name need it; the
// curated peer lists use IP literals wherever they can.
func configureAndroidResolver() {
	bridgeDNS.install()
}
