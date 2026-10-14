package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"errors"
	"net/url"
	"time"
	"unsafe"

	"github.com/yggdrasil-network/yggdrasil-go/src/config"
	"github.com/yggdrasil-network/yggdrasil-go/src/version"
)

//export YggFreeString
func YggFreeString(pointer *C.char) {
	C.free(unsafe.Pointer(pointer))
}

//export YggGetVersion
func YggGetVersion() *C.char {
	return C.CString(version.BuildVersion())
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
	nodes.Store(handle, node)
	return responseOK(normalizeNodeState(handle, node))
}

//export YggStopNode
func YggStopNode(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		node.closeAllRelays()
		node.stopLeafMonitor()
		node.stopPeerProbeMonitor()
		node.stopPeerNudge()
		if node.multicast != nil {
			if err := node.multicast.Stop(); err != nil {
				return responseError(err)
			}
		}
		node.core.Stop()
		nodes.Delete(int32(handle))
		return responseOK(map[string]any{"stopped": true})
	})
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
	return responseOK(
		map[string]any{
			"available": true,
			"from":      message.From,
			"payload":   message.Payload,
		},
	)
}

func waitSignalResponse(node *bridgeNode, timeout time.Duration) *C.char {
	startPacketLoop(node)
	if timeout <= 0 {
		select {
		case message := <-node.signalInbox:
			return signalInboxResponse(message)
		default:
			return responseOK(map[string]any{"available": false})
		}
	}

	timer := time.NewTimer(timeout)
	defer func() {
		if timer.Stop() {
			return
		}
		select {
		case <-timer.C:
		default:
		}
	}()

	select {
	case message := <-node.signalInbox:
		return signalInboxResponse(message)
	case <-timer.C:
		return responseOK(map[string]any{"available": false})
	}
}

//export YggPollSignal
func YggPollSignal(handle C.int) *C.char {
	return withNode(handle, func(node *bridgeNode) *C.char {
		return waitSignalResponse(node, 0)
	})
}

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
