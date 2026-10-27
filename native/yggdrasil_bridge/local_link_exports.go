package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
)

// The app's calls for local links (local_link.go). All of them take the
// node handle; the manager is made on first use and stops with the node.

// localLinks is the node's manager, made on first use.
func (node *bridgeNode) localLinkManager() *localLinkManager {
	node.localLinksMu.Lock()
	defer node.localLinksMu.Unlock()
	if node.localLinks == nil {
		node.localLinks = newLocalLinkManager(node.core, node.logger)
		if keep, held := node.transitHoldLink(); held {
			node.localLinks.hold(keep)
		}
	}
	return node.localLinks
}

// existingLocalLinks is the node's manager, nil when none was made.
func (node *bridgeNode) existingLocalLinks() *localLinkManager {
	node.localLinksMu.Lock()
	defer node.localLinksMu.Unlock()
	return node.localLinks
}

// stopLocalLinks closes every local link (the node stops).
func (node *bridgeNode) stopLocalLinks() {
	node.localLinksMu.Lock()
	manager := node.localLinks
	node.localLinks = nil
	node.localLinksMu.Unlock()
	if manager != nil {
		manager.stop()
	}
}

// YggSetLocalLinksJson sets the devices this node links with and whether
// it looks for them on the local networks:
//
//	{"Lan": true, "BeaconSeconds": 10,
//	 "Peers": [{"Address": "200:…", "Secret": "<64 hex>", "Own": false}],
//	 "Nearby": {"Start": slot, "Adverts": "<hex>", "Looking": false}}
//
// "Nearby" (people nearby on the LAN, lan_nearby.go) may be left out.
// Returns the status (YggGetLocalLinksJson).
//
//export YggSetLocalLinksJson
func YggSetLocalLinksJson(handle C.int, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		settings, err := parseLocalLinkSettings(C.GoString(payload))
		if err != nil {
			return responseError(err)
		}
		manager := node.localLinkManager()
		manager.apply(settings)
		return responseOK(manager.status())
	})
}

// YggGetLocalLinksJson: {"lan": {"on", "running", "interfaces", "error"?},
// "peers": n, "links": [{"id", "transport", "address", "remote", "own",
// "since", "up"}], "nearby": [{"advert", "at"}]}.
//
//export YggGetLocalLinksJson
func YggGetLocalLinksJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(node.localLinkManager().status())
	})
}

// YggOpenLocalLinkJson gives a native transport an endpoint for one stream:
// {"transport": "bluetooth"} → {"id", "port", "token"}. The transport
// connects to 127.0.0.1:port within a minute, writes the 16 token bytes
// (hex here) and then pumps the stream both ways; closing either side ends
// the link.
//
//export YggOpenLocalLinkJson
func YggOpenLocalLinkJson(handle C.int, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		var request struct {
			Transport string `json:"transport"`
		}
		if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
			return responseError(err)
		}
		endpoint, port, err := node.localLinkManager().openStream(request.Transport)
		if err != nil {
			return responseError(err)
		}
		return responseOK(map[string]any{
			"id":    endpoint.id,
			"port":  port,
			"token": hex.EncodeToString(endpoint.token),
		})
	})
}

// YggCloseLocalLink ends a link (or an endpoint still waiting) by id.
//
//export YggCloseLocalLink
func YggCloseLocalLink(handle C.int, id *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(map[string]any{"closed": node.localLinkManager().closeLink(C.GoString(id))})
	})
}

// YggLocalLinkAdvertJson: an advert for a native transport to show (a
// Bluetooth advertisement, a Wi-Fi Direct service record):
// {"bytes": n} (Bloom filter size, 0: sized to the devices) →
// {"advert": hex}. Make a new one at least every few minutes: it names a
// time slot, and a new salt makes it unlinkable to the last one.
//
//export YggLocalLinkAdvertJson
func YggLocalLinkAdvertJson(handle C.int, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		var request struct {
			Bytes int `json:"bytes"`
		}
		if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
			return responseError(err)
		}
		advert, err := node.localLinkManager().advert(request.Bytes)
		if err != nil {
			return responseError(err)
		}
		return responseOK(map[string]any{"advert": hex.EncodeToString(advert)})
	})
}

// YggLocalLinkMatchJson: {"advert": hex} → {"match": bool}, whether a
// nearby device's advert may be one this node links with (and is not
// linked already). Only then is it worth opening a stream to it.
//
//export YggLocalLinkMatchJson
func YggLocalLinkMatchJson(handle C.int, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		var request struct {
			Advert string `json:"advert"`
		}
		if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
			return responseError(err)
		}
		advert, err := hex.DecodeString(request.Advert)
		if err != nil {
			return responseError(fmt.Errorf("advert: %w", err))
		}
		return responseOK(map[string]any{"match": node.localLinkManager().matches(advert)})
	})
}
