package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/base64"
	"encoding/json"
	"fmt"

	"zen/native/yggdrasil_bridge/internal/zensig"
)

// The hybrid signature (Ed25519 + ML-DSA-65, internal/zensig) for the app:
// lib/src/core/crypto/hybrid_signature_ffi.dart. Arguments and results
// are standard base64 inside a JSON object. The app hands over the SHA-512
// digest of a message, never the message itself, so a call costs the same
// for a two-megabyte pyramid record as for a short one. The calls are
// synchronous; the app makes them from a worker isolate.

type sigRequest struct {
	Seed      string `json:"seed"`
	PublicKey string `json:"publicKey"`
	PQKey     string `json:"pqKey"`
	Digest    string `json:"digest"`
	Signature string `json:"signature"`
	WithKey   bool   `json:"withKey"`
}

func parseSigRequest(payload *C.char) (sigRequest, error) {
	var request sigRequest
	if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
		return request, fmt.Errorf("%w: %v", zensig.ErrBadInput, err)
	}
	return request, nil
}

func sigBytes(value string, size int, what string) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(decoded) != size {
		return nil, fmt.Errorf("%w: %s", zensig.ErrBadInput, what)
	}
	return decoded, nil
}

// YggSigPublicKeyJson: {seed} -> {ed, pq, fingerprint}.
//
//export YggSigPublicKeyJson
func YggSigPublicKeyJson(payload *C.char) *C.char {
	request, err := parseSigRequest(payload)
	if err != nil {
		return responseError(err)
	}
	seed, err := sigBytes(request.Seed, zensig.SeedSize, "seed")
	if err != nil {
		return responseError(err)
	}
	key, err := zensig.PublicKeyOf(seed)
	if err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{
		"ed":          base64.StdEncoding.EncodeToString(key.Ed),
		"pq":          base64.StdEncoding.EncodeToString(key.PQ),
		"fingerprint": base64.StdEncoding.EncodeToString(key.Fingerprint[:]),
	})
}

// YggSigSignJson: {seed, digest, withKey} -> {signature}; with withKey the
// keyed form (it carries the ML-DSA key instead of naming it).
//
//export YggSigSignJson
func YggSigSignJson(payload *C.char) *C.char {
	request, err := parseSigRequest(payload)
	if err != nil {
		return responseError(err)
	}
	seed, err := sigBytes(request.Seed, zensig.SeedSize, "seed")
	if err != nil {
		return responseError(err)
	}
	digest, err := sigBytes(request.Digest, zensig.DigestSize, "digest")
	if err != nil {
		return responseError(err)
	}
	sign := zensig.SignDigest
	if request.WithKey {
		sign = zensig.SignDigestWithKey
	}
	sig, err := sign(seed, digest)
	if err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{
		"signature": base64.StdEncoding.EncodeToString(sig),
	})
}

// YggSigVerifyJson: {publicKey (Ed25519), pqKey (ML-DSA, needed when the
// signature names it by fingerprint), digest, signature} -> {valid}. A
// malformed signature, or one whose key is missing or another, is not
// valid (no error).
//
//export YggSigVerifyJson
func YggSigVerifyJson(payload *C.char) *C.char {
	request, err := parseSigRequest(payload)
	if err != nil {
		return responseError(err)
	}
	publicKey, err := sigBytes(request.PublicKey, zensig.EdPublicKeySize, "public key")
	if err != nil {
		return responseError(err)
	}
	digest, err := sigBytes(request.Digest, zensig.DigestSize, "digest")
	if err != nil {
		return responseError(err)
	}
	var pqKey []byte
	if request.PQKey != "" {
		if pqKey, err = sigBytes(request.PQKey, zensig.PQPublicKeySize, "ML-DSA key"); err != nil {
			return responseError(err)
		}
	}
	sig, err := base64.StdEncoding.DecodeString(request.Signature)
	valid := err == nil && zensig.VerifyDigest(publicKey, pqKey, digest, sig) == nil
	return responseOK(map[string]any{"valid": valid})
}
