package main

/*
#include <stdlib.h>
#include <string.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"net/url"
	"runtime"
	"time"
	"unsafe"

	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/version"
)

// YggFreeString frees a string the bridge handed out, overwriting it first:
// answers may carry secrets (a KEM secret, memguard.go).
//
//export YggFreeString
func YggFreeString(pointer *C.char) {
	if pointer == nil {
		return
	}
	C.memset(unsafe.Pointer(pointer), 0, C.strlen(pointer))
	C.free(unsafe.Pointer(pointer))
}

//export YggGetVersion
func YggGetVersion() *C.char {
	return C.CString(version.BuildVersion())
}

// YggGetBuildInfoJson tells which Yggdrasil and which Go this library was
// built with (a Go security fix needs a rebuild even when no source
// changed).
//
//export YggGetBuildInfoJson
func YggGetBuildInfoJson() *C.char {
	return responseOK(map[string]any{
		"yggdrasil": version.BuildVersion(),
		"go":        runtime.Version(),
		"os":        runtime.GOOS,
		"arch":      runtime.GOARCH,
	})
}

// YggSetDnsServersJson replaces the servers the bridge resolves names with
// when the system resolver does not answer (Android, dns_fallback.go):
// a JSON list such as ["tls://9.9.9.9:853#dns.quad9.net"], or
// {"servers": [...], "useSystem": false}. An empty list restores the
// defaults (public resolvers over DNS-over-TLS).
//
//export YggSetDnsServersJson
func YggSetDnsServersJson(payload *C.char) *C.char {
	if err := bridgeDNS.configureJSON(C.GoString(payload)); err != nil {
		return responseError(err)
	}
	return responseOK(map[string]any{"configured": true})
}

//export YggGenerateConfigJson
func YggGenerateConfigJson() *C.char {
	cfg := config.GenerateConfig()
	cfg.IfName = "none"
	cfg.AdminListen = "none"
	ensureDefaultRuntimeConfig(cfg)
	data, err := json.Marshal(cfg)
	if err != nil {
		return responseError(err)
	}
	return responseOK(string(data))
}

//export YggSummarizeConfigJson
func YggSummarizeConfigJson(configJSON *C.char) *C.char {
	cfg := config.GenerateConfig()
	cfg.IfName = "none"
	cfg.AdminListen = "none"
	if err := cfg.UnmarshalHJSON([]byte(C.GoString(configJSON))); err != nil {
		return responseError(err)
	}
	ensureDefaultRuntimeConfig(cfg)
	return responseOK(summarizeConfig(cfg))
}

//export YggStartNode
func YggStartNode(configJSON *C.char) *C.char {
	node, err := createNode(C.GoString(configJSON))
	if err != nil {
		return responseError(err)
	}
	handle := nextHandle.Add(1)
	node.touch()
	nodes.Store(handle, node)
	node.identity.running(handle, node)
	return responseOK(normalizeNodeState(handle, node))
}

//export YggStopNode
func YggStopNode(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		if err := node.shutdown(int32(handle)); err != nil {
			return responseError(err)
		}
		return responseOK(map[string]any{"stopped": true})
	})
}

// shutdown stops everything the node runs, then the node itself, and lets
// its handle and its key go.
func (node *bridgeNode) shutdown(handle int32) error {
	node.stopDoor()
	_, _ = node.setMailboxDoors(nil)
	node.stopLocalLinks()
	node.closeAllRelays()
	node.stopLeafMonitor()
	node.stopPeerProbeMonitor()
	node.stopPeerNudge()
	if node.phonePeers != nil {
		node.phonePeers.stopWatch()
	}
	node.stopTransitWatch()
	if node.power != nil {
		node.power.stopWatch()
	}
	for _, guard := range node.peerGuards {
		guard.close()
	}
	if node.multicast != nil {
		if err := node.multicast.Stop(); err != nil {
			return err
		}
	}
	node.core.Stop()
	nodes.Delete(handle)
	// The key is free for the next node only now that this one is down.
	node.identity.release()
	// Wakes the app's thread blocked in YggWaitSignal.
	node.signalInbox.close()
	return nil
}

//export YggGetNodeInfo
func YggGetNodeInfo(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(normalizeNodeState(int32(handle), node))
	})
}

//export YggGetPeersJson
func YggGetPeersJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(buildPeerJSON(node.core.GetPeers()))
	})
}

//export YggGetPathsJson
func YggGetPathsJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(node.core.GetPaths())
	})
}

//export YggGetTreeJson
func YggGetTreeJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(node.core.GetTree())
	})
}

//export YggGetSessionsJson
func YggGetSessionsJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(node.core.GetSessions())
	})
}

//export YggRetryPeersNow
func YggRetryPeersNow(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		if node.leafMonitor != nil {
			if node.peerProbe != nil {
				node.peerProbe.triggerNow()
			}
			node.leafMonitor.triggerNow()
			return responseOK(normalizeNodeState(int32(handle), node))
		}
		if runtimeManagedPeerCount() > 0 {
			node.runPeerProbeCycle()
			return responseOK(normalizeNodeState(int32(handle), node))
		}
		node.core.RetryPeersNow()
		return responseOK(normalizeNodeState(int32(handle), node))
	})
}

//export YggAddPeer
func YggAddPeer(handle C.int, peerURI *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		if node.leafMonitor != nil {
			return responseError(errors.New("manual peer changes are disabled in strict leaf mode"))
		}
		uri := C.GoString(peerURI)
		parsed, err := url.Parse(uri)
		if err != nil {
			return responseError(err)
		}
		if node.setBridgeAside(uri) {
			// A computer on battery: dialled once it is plugged in.
			return responseOK(normalizeNodeState(int32(handle), node))
		}
		// A friend's bridge is dialled also while a phone holds
		// (transit_guard.go never sets bridges aside).
		if err := node.core.AddPeer(parsed, ""); err != nil {
			return responseError(err)
		}
		node.updateConfiguredPeer(uri, true)
		return responseOK(normalizeNodeState(int32(handle), node))
	})
}

//export YggRemovePeer
func YggRemovePeer(handle C.int, peerURI *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		if node.leafMonitor != nil {
			return responseError(errors.New("manual peer changes are disabled in strict leaf mode"))
		}
		uri := C.GoString(peerURI)
		parsed, err := url.Parse(uri)
		if err != nil {
			return responseError(err)
		}
		if node.forgetBridgeAside(uri) {
			// Set aside on battery, never dialled.
			return responseOK(normalizeNodeState(int32(handle), node))
		}
		if err := node.core.RemovePeer(parsed, ""); err != nil {
			return responseError(err)
		}
		node.updateConfiguredPeer(uri, false)
		return responseOK(normalizeNodeState(int32(handle), node))
	})
}

//export YggCallPeer
func YggCallPeer(handle C.int, peerURI *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		parsed, err := url.Parse(C.GoString(peerURI))
		if err != nil {
			return responseError(err)
		}
		if err := node.core.CallPeer(parsed, ""); err != nil {
			return responseError(err)
		}
		return responseOK(normalizeNodeState(int32(handle), node))
	})
}

//export YggStartSignaling
func YggStartSignaling(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		startPacketLoop(node)
		return responseOK(
			map[string]any{
				"started": true,
				"port":    yggSignalPort,
			},
		)
	})
}

//export YggSendSignal
func YggSendSignal(handle C.int, remoteAddress *C.char, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		startPacketLoop(node)
		if err := sendSignal(node, C.GoString(remoteAddress), C.GoString(payload)); err != nil {
			return responseError(err)
		}
		return responseOK(map[string]any{"sent": true})
	})
}

func signalInboxResponse(message signalMessage) *C.char {
	data := map[string]any{
		"available": true,
		"from":      message.From,
		"payload":   message.Payload,
	}
	if message.Door {
		data["door"] = true
	}
	if message.Key != "" {
		data["key"] = message.Key
	}
	return responseOK(data)
}

func waitSignalResponse(node *bridgeNode, timeout time.Duration) *C.char {
	startPacketLoop(node)
	// Taking a signal releases its share of the inbox budget.
	message, ok := node.signalInbox.wait(timeout)
	if !ok {
		if node.signalInbox.isClosed() {
			// The node stopped: the app's waiting thread can end.
			return responseOK(map[string]any{"available": false, "closed": true})
		}
		return responseOK(map[string]any{"available": false})
	}
	return signalInboxResponse(message)
}

//export YggPollSignal
func YggPollSignal(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return waitSignalResponse(node, 0)
	})
}

// YggWaitSignal blocks up to timeoutMs for a signal. The app calls it from
// a thread of its own (a Dart isolate), so signals arrive as they come
// instead of on a polling timer. When the node stops, a waiting call
// returns at once with {"available": false, "closed": true}.
//
//export YggWaitSignal
func YggWaitSignal(handle C.int, timeoutMs C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		timeout := time.Duration(timeoutMs)
		if timeout < 0 {
			timeout = 0
		}
		return waitSignalResponse(node, timeout*time.Millisecond)
	})
}

//export YggOpenRelayJson
func YggOpenRelayJson(handle C.int, payload *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		startPacketLoop(node)

		var request struct {
			CallID        string `json:"callId"`
			RemoteAddress string `json:"remoteAddress"`
		}
		if err := json.Unmarshal([]byte(C.GoString(payload)), &request); err != nil {
			return responseError(err)
		}

		port, err := node.openRelay(request.CallID, request.RemoteAddress)
		if err != nil {
			return responseError(err)
		}

		return responseOK(
			map[string]any{
				"port": port,
			},
		)
	})
}

//export YggCloseRelay
func YggCloseRelay(handle C.int, callID *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		node.closeRelay(C.GoString(callID))
		return responseOK(map[string]any{"closed": true})
	})
}

// YggStartDoorNode runs the flat's door next to the node (door_node.go):
// a second node with its own key (seedHex: a 32-byte ed25519 seed as hex,
// kept by the app), never peered to this one, that takes and sends only
// flat frames. A door with another key is replaced; the same key keeps it.
//
//export YggStartDoorNode
func YggStartDoorNode(handle C.int, seedHex *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		// Sessions with the door need the node's packet loop.
		startPacketLoop(node)
		if _, err := node.startDoor(C.GoString(seedHex)); err != nil {
			return responseError(err)
		}
		return responseOK(node.doorState())
	})
}

//export YggStopDoorNode
func YggStopDoorNode(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		node.stopDoor()
		return responseOK(map[string]any{"stopped": true})
	})
}

// YggSetMailboxDoorsJson runs exactly the mailbox doors (door_node.go) whose
// keys seedsJson lists (a JSON array of 32-byte ed25519 seeds as hex): doors
// this phone runs for friends whose own phone may be offline. Returns
// {"addresses": {seed: address}}.
//
//export YggSetMailboxDoorsJson
func YggSetMailboxDoorsJson(handle C.int, seedsJSON *C.char) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		var seeds []string
		if err := json.Unmarshal([]byte(C.GoString(seedsJSON)), &seeds); err != nil {
			return responseError(err)
		}
		startPacketLoop(node)
		addresses, err := node.setMailboxDoors(seeds)
		if err != nil {
			return responseError(err)
		}
		return responseOK(map[string]any{"addresses": addresses})
	})
}

// YggGetDoorNodeJson tells whether the door runs, and its address.
//
//export YggGetDoorNodeJson
func YggGetDoorNodeJson(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return responseOK(node.doorState())
	})
}
