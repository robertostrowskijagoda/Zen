package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
)

// The hybrid KEM for the app's own seals (mailbox mail, the locked inbox):
// lib/src/features/security/hybrid_kem_ffi.dart. Every argument and result
// is standard base64 inside a JSON object; seeds and secrets are 32 bytes.
// The device key of the signal port never leaves the bridge.

type pqRequest struct {
	Seed       string `json:"seed"`
	PublicKey  string `json:"publicKey"`
	Ciphertext string `json:"ciphertext"`
	Info       string `json:"info"`
}

func parsePQRequest(payload *C.char) (pqRequest, error) {
	var request pqRequest
	if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
		return request, fmt.Errorf("%w: %v", errPQBadInput, err)
	}
	return request, nil
}

func pqBytes(value string, size int, what string) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("%w: %s", errPQBadInput, what)
	}
	if size >= 0 && len(decoded) != size {
		return nil, fmt.Errorf("%w: %s of %d bytes", errPQBadInput, what, len(decoded))
	}
	return decoded, nil
}

// YggPqPublicKeyJson: {seed} -> {publicKey}.
//
//export YggPqPublicKeyJson
func YggPqPublicKeyJson(payload *C.char) *C.char {
	request, err := parsePQRequest(payload)
	if err != nil {
		return responseError(err)
	}
	seed, err := pqBytes(request.Seed, pqSeedSize, "seed")
	if err != nil {
		return responseError(err)
	}
	publicKey, err := pqPublicKeyOf(seed)
	if err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{
		"publicKey": base64.StdEncoding.EncodeToString(publicKey),
	})
}

// YggPqEncapsulateJson: {publicKey, info} -> {ciphertext, secret}.
//
//export YggPqEncapsulateJson
func YggPqEncapsulateJson(payload *C.char) *C.char {
	request, err := parsePQRequest(payload)
	if err != nil {
		return responseError(err)
	}
	publicKey, err := pqBytes(request.PublicKey, pqPublicKeySize, "public key")
	if err != nil {
		return responseError(err)
	}
	info, err := pqBytes(request.Info, -1, "info")
	if err != nil {
		return responseError(err)
	}
	ciphertext, secret, err := pqEncapsulate(publicKey, info)
	if err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{
		"ciphertext": base64.StdEncoding.EncodeToString(ciphertext),
		"secret":     base64.StdEncoding.EncodeToString(secret),
	})
}

// YggPqDecapsulateJson: {seed, ciphertext, info} -> {secret}.
//
//export YggPqDecapsulateJson
func YggPqDecapsulateJson(payload *C.char) *C.char {
	request, err := parsePQRequest(payload)
	if err != nil {
		return responseError(err)
	}
	seed, err := pqBytes(request.Seed, pqSeedSize, "seed")
	if err != nil {
		return responseError(err)
	}
	ciphertext, err := pqBytes(request.Ciphertext, pqCiphertextSize, "ciphertext")
	if err != nil {
		return responseError(err)
	}
	info, err := pqBytes(request.Info, -1, "info")
	if err != nil {
		return responseError(err)
	}
	key, err := pqPrivateKey(seed)
	if err != nil {
		return responseError(err)
	}
	secret, err := pqDecapsulate(key, ciphertext, info)
	if err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{
		"secret": base64.StdEncoding.EncodeToString(secret),
	})
}
