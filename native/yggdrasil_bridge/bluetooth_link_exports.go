package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"sort"
)

// The app's calls for the Bluetooth streams of bluetooth_link.go (Linux and
// Windows; elsewhere they answer "unsupported"). Each takes a JSON object
// and none takes a node: the streams go to endpoints the app got from its
// node (YggOpenLocalLinkJson).

var btLinksInstance = newBtLinks(btListen, btDial)

func btRequest(payload *C.char, into any) error {
	text := C.GoString(payload)
	if text == "" {
		text = "{}"
	}
	return json.Unmarshal([]byte(text), into)
}

// YggBtLinkStateJson: {} → {"supported": bool, "l2cap": bool, "rfcomm": bool}.
//
//export YggBtLinkStateJson
func YggBtLinkStateJson(payload *C.char) *C.char {
	supported := btSupported()
	return responseOK(map[string]any{
		"supported": supported,
		"l2cap":     supported && btHasL2cap,
		"rfcomm":    supported && btHasRfcomm,
	})
}

// YggBtLinkStartJson listens for incoming streams: {} → {"psm": n} (Linux,
// the L2CAP channel to show) or {"channel": n} (Windows, RFCOMM).
//
//export YggBtLinkStartJson
func YggBtLinkStartJson(payload *C.char) *C.char {
	info, err := btLinksInstance.start()
	if err != nil {
		return responseError(err)
	}
	return responseOK(info)
}

// YggBtLinkStopJson closes the listener and every stream.
//
//export YggBtLinkStopJson
func YggBtLinkStopJson(payload *C.char) *C.char {
	btLinksInstance.stop()
	return responseOK(map[string]any{"stopped": true})
}

// YggBtLinkPollJson: {} → {"listening", "incoming": [id], "dials": {id:
// "ok"|"failed"}, "devices": [device]}. Each incoming stream and each
// ended dial is reported once.
//
//export YggBtLinkPollJson
func YggBtLinkPollJson(payload *C.char) *C.char {
	return responseOK(btLinksInstance.poll())
}

// YggBtLinkAcceptJson: {"id", "port", "token"} pumps an incoming stream
// into the node's endpoint.
//
//export YggBtLinkAcceptJson
func YggBtLinkAcceptJson(payload *C.char) *C.char {
	var request struct {
		ID    string `json:"id"`
		Port  int    `json:"port"`
		Token string `json:"token"`
	}
	if err := btRequest(payload, &request); err != nil {
		return responseError(err)
	}
	token, err := parseBtToken(request.Token)
	if err != nil {
		btLinksInstance.reject(request.ID)
		return responseError(err)
	}
	if err := btLinksInstance.accept(request.ID, request.Port, token); err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{"accepted": true})
}

// YggBtLinkRejectJson: {"id"} closes an incoming stream.
//
//export YggBtLinkRejectJson
func YggBtLinkRejectJson(payload *C.char) *C.char {
	var request struct {
		ID string `json:"id"`
	}
	if err := btRequest(payload, &request); err != nil {
		return responseError(err)
	}
	btLinksInstance.reject(request.ID)
	return responseOK(map[string]any{"rejected": true})
}

// YggBtLinkDialJson: {"device", "psm", "classic", "port", "token"} → {"id"}:
// opens a stream to device (Linux "AA:BB:CC:DD:EE:FF/public|random" and
// the PSM it showed; Windows a paired device's address, classic) and pumps
// it into the endpoint. The outcome comes with YggBtLinkPollJson.
//
//export YggBtLinkDialJson
func YggBtLinkDialJson(payload *C.char) *C.char {
	var request struct {
		Device  string `json:"device"`
		Psm     int    `json:"psm"`
		Classic bool   `json:"classic"`
		Port    int    `json:"port"`
		Token   string `json:"token"`
	}
	if err := btRequest(payload, &request); err != nil {
		return responseError(err)
	}
	token, err := parseBtToken(request.Token)
	if err != nil {
		return responseError(err)
	}
	id, err := btLinksInstance.dialAsync(request.Device, request.Psm, request.Classic, request.Port, token)
	if err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{"id": id})
}

// YggBtLinkPairedJson: {} → {"devices": [address]}: phones and computers
// paired in the system's Bluetooth settings (Windows) with no stream open.
//
//export YggBtLinkPairedJson
func YggBtLinkPairedJson(payload *C.char) *C.char {
	devices, err := btPaired()
	if err != nil {
		return responseError(err)
	}
	open := btLinksInstance.openDevices()
	out := []string{}
	for _, device := range devices {
		if !open[device] {
			out = append(out, device)
		}
	}
	sort.Strings(out)
	return responseOK(map[string]any{"devices": out})
}
