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

// YggPqPinsJson: the device keys this node pinned, by address, with their
// kind (pq_session.go, pinsState): {pins: {address: fingerprint}, firm,
// vouched, seen: {address: unix seconds}, known, conflicts: {address:
// vouched fingerprint}, own}. The app keeps them and hands them back after
// a restart (YggPqSetPinsJson with restore), so a key seen once stays the
// only one taken for that address. conflicts are the records refused since
// the last call because they contradict a vouched key: the app warns.
//
//export YggPqPinsJson
func YggPqPinsJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		endpoint, err := node.pqEndpointOf()
		if err != nil {
			return responseError(err)
		}
		state := endpoint.pinsState()
		return responseOK(map[string]any{
			"pins":      state.Pins,
			"firm":      state.Firm,
			"vouched":   state.Vouched,
			"seen":      state.Seen,
			"known":     state.Known,
			"conflicts": endpoint.takeConflicts(),
			"own":       endpoint.ownFingerprint(),
		})
	})
}

// pqSetPinsRequest is what YggPqSetPinsJson takes.
type pqSetPinsRequest struct {
	Pins map[string]string `json:"pins"`
	Keep bool              `json:"keep"`
	Hint bool              `json:"hint"`
	// With hint: the hints named go (nobody gives them any more).
	Drop bool `json:"drop"`
	// The pins kept from an earlier run, with their kind (pinsState).
	Restore bool             `json:"restore"`
	Firm    []string         `json:"firm"`
	Vouched []string         `json:"vouched"`
	Seen    map[string]int64 `json:"seen"`
	// When present: the addresses the app knows (setKnown).
	Known *[]string `json:"known"`
	// Addresses the app listens to besides the known ones (the contacts a
	// locked receiver heard from): their signals do not count against a
	// locked phone's budget for strangers (stranger_signals.go).
	Listen []string `json:"listen"`
}

// applyPinsRequest does what a YggPqSetPinsJson request asks:
// -> {taken, conflicts: {address: pinned}, known}.
func applyPinsRequest(endpoint *pqEndpoint, request pqSetPinsRequest) map[string]any {
	answer := map[string]any{}
	if request.Known != nil {
		answer["known"] = endpoint.setKnown(*request.Known)
	}
	taken := 0
	conflicts := map[string]string{}
	switch {
	case request.Restore:
		taken = endpoint.restorePins(pqPinsState{
			Pins:    request.Pins,
			Firm:    request.Firm,
			Vouched: request.Vouched,
			Seen:    request.Seen,
		})
	case request.Hint && request.Drop:
		taken = endpoint.dropHints(request.Pins)
	case request.Hint:
		taken, conflicts = endpoint.importHints(request.Pins)
	case len(request.Pins) > 0:
		taken, conflicts = endpoint.importPins(request.Pins, request.Keep)
	}
	answer["taken"] = taken
	answer["conflicts"] = conflicts
	return answer
}

// YggPqSetPinsJson: {pins: {address: fingerprint}, keep, hint, drop,
// restore, firm, vouched, seen, known} (pqSetPinsRequest).
//
//   - restore (with firm, vouched, seen): the pins kept from an earlier run,
//     each of the kind it was (pq_session.go, restorePins).
//   - keep: keys a hello signed by the device named over a session with
//     that key; a different pin already there stays and is reported.
//   - neither: such a hello contradicts the session it came over; the key
//     replaces the pin.
//   - hint: only someone's word (a friend's friend list or device record):
//     hints, which never move a pin (importHints); with drop, those hints
//     go.
//   - known (alone or with any of the above): the addresses of the app's
//     friends and this person's own devices, the only peers that use the
//     known peers' KEM budget and keep their entries and pins.
//   - listen: addresses added to those a node that only receives hands
//     over every signal of (stranger_signals.go); nothing elsewhere.
//
// -> {taken, conflicts: {address: pinned}, known, listened}.
//
//export YggPqSetPinsJson
func YggPqSetPinsJson(handle C.int, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		var request pqSetPinsRequest
		if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
			return responseError(err)
		}
		endpoint, err := node.pqEndpointOf()
		if err != nil {
			return responseError(err)
		}
		answer := applyPinsRequest(endpoint, request)
		if len(request.Listen) > 0 && node.strangerSignals != nil {
			answer["listened"] = node.strangerSignals.listen(request.Listen)
		}
		return responseOK(answer)
	})
}
