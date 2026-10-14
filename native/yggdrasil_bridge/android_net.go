//go:build android

package main

import (
	"context"
	"net"
	"time"
)

func init() {
	configureAndroidResolver()
}

func configureAndroidResolver() {
	// Flutter loads this .so via dlopen; Android's getaddrinfo from a
	// non-JNI thread often fails. The pure-Go resolver talking to public
	// DNS over UDP/TCP works as long as raw sockets are allowed (INTERNET).
	servers := []string{
		"8.8.8.8:53",
		"1.1.1.1:53",
		"[2001:4860:4860::8888]:53",
		"[2606:4700:4700::1111]:53",
	}
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			dialer := net.Dialer{Timeout: 2 * time.Second}
			var last error
			for _, server := range servers {
				conn, err := dialer.DialContext(ctx, "udp", server)
				if err == nil {
					return conn, nil
				}
				last = err
			}
			for _, server := range servers {
				conn, err := dialer.DialContext(ctx, "tcp", server)
				if err == nil {
					return conn, nil
				}
				last = err
			}
			return nil, last
		},
	}
}
