package main

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"time"
)

// The session layer (pq_session.go) on a node's signal port.

// pqEndpointOf is the node's session layer, made on first use from its
// identity key.
func (node *bridgeNode) pqEndpointOf() (*pqEndpoint, error) {
	node.pqOnce.Do(func() {
		node.configMu.RLock()
		var nodeKey ed25519.PrivateKey
		if node.config != nil {
			nodeKey = ed25519.PrivateKey(node.config.PrivateKey)
		}
		node.configMu.RUnlock()
		if node.core == nil || len(nodeKey) != ed25519.PrivateKeySize {
			node.pqErr = errors.New("pq: the node has no identity key")
			return
		}
		local := net.ParseIP(node.core.Address().String())
		node.pq, node.pqErr = newPQEndpoint(nodeKey, local, node.writeSignalWire)
	})
	return node.pq, node.pqErr
}

// sealAndSendSignal sends a signal text (as buildSignalWirePayload made
// it) through the session layer.
func (node *bridgeNode) sealAndSendSignal(destination net.IP, wire string) error {
	if node.pqPlain {
		return node.writeSignalWire(destination, []byte(wire))
	}
	endpoint, err := node.pqEndpointOf()
	if err != nil {
		return err
	}
	return endpoint.send(destination, []byte(wire))
}

// openSignal is the signal text a reassembled signal from source carries:
// opened by the session layer and decompressed. Anything not sealed is
// refused.
func (node *bridgeNode) openSignal(source net.IP, wire string) (string, bool) {
	if node.pqPlain {
		return wire, true
	}
	if !isPQWire(wire) {
		debugf("[ZEN-GO] pq: refusing an unsealed signal from %s\n", source)
		return "", false
	}
	endpoint, err := node.pqEndpointOf()
	if err != nil {
		return "", false
	}
	plain, ok := endpoint.receive(source, []byte(wire))
	if !ok {
		return "", false
	}
	return inflateSignalText(source.String(), string(plain))
}

// writeSignalWire splits a signal text into fragments and sends them from
// the node's own address to destination.
func (node *bridgeNode) writeSignalWire(destination net.IP, wire []byte) error {
	localAddress := net.ParseIP(node.core.Address().String())
	if localAddress == nil {
		return errors.New("could not resolve local yggdrasil address")
	}
	chunks := splitSignalPayloadRaw(string(wire))
	packetID := fmt.Sprintf("%d-%d", time.Now().UnixNano(), nextSignalPacket.Add(1))
	for index, chunk := range chunks {
		envelopeBytes, err := json.Marshal(signalEnvelope{
			ID:      packetID,
			Index:   index,
			Total:   len(chunks),
			Payload: chunk,
		})
		if err != nil {
			return err
		}
		packet, err := buildYggPacket(localAddress, destination, yggSignalPort, envelopeBytes)
		if err != nil {
			return err
		}
		if _, err := node.iprwc.Write(packet); err != nil {
			fmt.Printf("[ZEN-GO] sendSignal write error: %v\n", err)
			return err
		}
	}
	return nil
}
