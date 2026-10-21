// Command zensig is Zen's hybrid signature (Ed25519 + ML-DSA-65,
// internal/zensig) for the maintainers' tools, which are plain Dart and
// cannot load the bridge: tool/zen_release.dart and tool/zen_pyramid.dart
// run it as
//
//	go run ./cmd/zensig        (in native/yggdrasil_bridge)
//
// It reads one JSON request from stdin and writes one JSON answer to
// stdout; bytes are base64url with padding. Seeds never go on the command
// line. As in the bridge, the tools hand over the SHA-512 digest of a
// message (D, "digest"); "message" may be given instead.
//
//	{"op":"public","seed":S}                         -> {"ed","pq","fingerprint","id"}
//	{"op":"sign","seed":S,"digest":D,"withKey":B}    -> {"signature"}
//	{"op":"verify","publicKey":K,"pqKey":P,"digest":D,"signature":G} -> {"valid"}
//
// The tools sign releases and the pyramid's genesis, which are checked by
// phones that know only the key's fingerprint: they sign with "withKey"
// (the signature carries the ML-DSA key). "pqKey" is needed to verify a
// signature that names its key by fingerprint.
package main

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"zen/native/yggdrasil_bridge/internal/zensig"
)

type request struct {
	Op        string `json:"op"`
	Seed      string `json:"seed"`
	PublicKey string `json:"publicKey"`
	Message   string `json:"message"`
	PQKey     string `json:"pqKey"`
	Digest    string `json:"digest"`
	Signature string `json:"signature"`
	WithKey   bool   `json:"withKey"`
}

var b64 = base64.URLEncoding

func decode(value, what string) ([]byte, error) {
	out, err := b64.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("%s: not base64url", what)
	}
	return out, nil
}

// digestOf is D of the request: its digest, or the digest of its message.
func digestOf(r request) ([]byte, error) {
	if r.Digest != "" {
		digest, err := decode(r.Digest, "digest")
		if err != nil {
			return nil, err
		}
		if len(digest) != zensig.DigestSize {
			return nil, fmt.Errorf("digest: %d bytes", len(digest))
		}
		return digest, nil
	}
	message, err := decode(r.Message, "message")
	if err != nil {
		return nil, err
	}
	digest := zensig.Digest(message)
	return digest[:], nil
}

func run(in io.Reader) (map[string]any, error) {
	var r request
	if err := json.NewDecoder(io.LimitReader(in, 64<<20)).Decode(&r); err != nil {
		return nil, fmt.Errorf("request: %v", err)
	}
	switch r.Op {
	case "public":
		seed, err := decode(r.Seed, "seed")
		if err != nil {
			return nil, err
		}
		key, err := zensig.PublicKeyOf(seed)
		if err != nil {
			return nil, err
		}
		return map[string]any{
			"ed":          b64.EncodeToString(key.Ed),
			"pq":          b64.EncodeToString(key.PQ),
			"fingerprint": b64.EncodeToString(key.Fingerprint[:]),
			"id":          key.ID(),
		}, nil
	case "sign":
		seed, err := decode(r.Seed, "seed")
		if err != nil {
			return nil, err
		}
		digest, err := digestOf(r)
		if err != nil {
			return nil, err
		}
		sign := zensig.SignDigest
		if r.WithKey {
			sign = zensig.SignDigestWithKey
		}
		sig, err := sign(seed, digest)
		if err != nil {
			return nil, err
		}
		return map[string]any{"signature": b64.EncodeToString(sig)}, nil
	case "verify":
		key, err := decode(r.PublicKey, "publicKey")
		if err != nil {
			return nil, err
		}
		digest, err := digestOf(r)
		if err != nil {
			return nil, err
		}
		sig, err := decode(r.Signature, "signature")
		if err != nil {
			return nil, err
		}
		var pqKey []byte
		if r.PQKey != "" {
			if pqKey, err = decode(r.PQKey, "pqKey"); err != nil {
				return nil, err
			}
		}
		return map[string]any{"valid": zensig.VerifyDigest(key, pqKey, digest, sig) == nil}, nil
	}
	return nil, errors.New("op: public, sign or verify")
}

func main() {
	answer, err := run(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "zensig:", err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(answer); err != nil {
		os.Exit(1)
	}
}
