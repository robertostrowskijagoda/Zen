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
	defer wipeBytes(seed)
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
	defer wipeBytes(secret)
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
	defer wipeBytes(seed)
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
	defer wipeBytes(secret)
	return responseOK(map[string]any{
		"secret": base64.StdEncoding.EncodeToString(secret),
	})
}

// YggPqPinsJson: the device keys this node pinned, by address (pq_session.go):
// {pins: {address: fingerprint}, own}. The app keeps them and hands them
// back after a restart (YggPqSetPinsJson), so a key seen once stays the
// only one taken for that address.
//
//export YggPqPinsJson
func YggPqPinsJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		endpoint, err := node.pqEndpointOf()
		if err != nil {
			return responseError(err)
		}
		return responseOK(map[string]any{
			"pins": endpoint.pinsSnapshot(),
			"own":  endpoint.ownFingerprint(),
		})
	})
}

// YggPqSetPinsJson: {pins: {address: fingerprint}, keep} adds pins kept
// from an earlier run or vouched for by friends' signed records (they win
// over what this run merely saw). With keep, a different pin already there
// stays and is reported: -> {taken, conflicts: {address: pinned}}.
//
//export YggPqSetPinsJson
func YggPqSetPinsJson(handle C.int, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		var request struct {
			Pins map[string]string `json:"pins"`
			Keep bool              `json:"keep"`
		}
		if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
			return responseError(err)
		}
		endpoint, err := node.pqEndpointOf()
		if err != nil {
			return responseError(err)
		}
		taken, conflicts := endpoint.importPins(request.Pins, request.Keep)
		return responseOK(map[string]any{"taken": taken, "conflicts": conflicts})
	})
}
