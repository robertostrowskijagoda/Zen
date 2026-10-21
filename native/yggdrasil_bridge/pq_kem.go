package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hpke"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"net"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
)

// The post-quantum key encapsulation of Zen (docs/PROTOCOL.md §1.5).
//
// Yggdrasil protects traffic with X25519 and Ed25519 only, which a future
// quantum computer breaks: whoever records the traffic today could read it
// then ("harvest now, decrypt later"). Zen therefore puts its own hybrid
// layer on top: MLKEM768-X25519 ("X-Wing", draft-ietf-hpke-pq, from Go's
// crypto/hpke and crypto/mlkem), used through HPKE (RFC 9180, base mode,
// HKDF-SHA256, export only). The shared secret stays safe while either
// ML-KEM-768 or X25519 holds.
//
// A key pair is a 32-byte seed: the public key is the ML-KEM-768
// encapsulation key followed by the X25519 key (1216 bytes), a ciphertext
// the ML-KEM ciphertext followed by the ephemeral X25519 key (1120 bytes).
// The secret is HPKE's exported secret for pqExportLabel, bound to the info
// the caller gives (who talks to whom, for what).
const (
	pqSeedSize       = 32
	pqPublicKeySize  = 1184 + 32
	pqCiphertextSize = 1088 + 32
	pqSecretSize     = 32
	// HPKE KEM id of MLKEM768-X25519.
	pqKEMID       = 0x647a
	pqExportLabel = "zen.pq.secret.v1"
	// The device key: derived from the node's Ed25519 identity key, so
	// every process that runs the node (the app, Android's background
	// service) has the same one and nothing new has to be stored.
	pqDeviceKeyInfo = "zen.pq.device.v1"
	// Version of the device key derivation (a new one changes the key, not
	// the address).
	pqDeviceKeyVersion = 1
)

var errPQBadInput = errors.New("pq: malformed input")

// pqKEM is the hybrid KEM every Zen device and seal uses.
var pqKEM = hpke.MLKEM768X25519()

func pqPrivateKey(seed []byte) (hpke.PrivateKey, error) {
	if len(seed) != pqSeedSize {
		return nil, fmt.Errorf("%w: seed of %d bytes", errPQBadInput, len(seed))
	}
	return pqKEM.NewPrivateKey(seed)
}

func pqPublicKeyOf(seed []byte) ([]byte, error) {
	key, err := pqPrivateKey(seed)
	if err != nil {
		return nil, err
	}
	return key.PublicKey().Bytes(), nil
}

// pqEncapsulate makes a fresh secret for publicKey: the ciphertext only the
// holder of the key's seed turns back into the same secret.
func pqEncapsulate(publicKey, info []byte) (ciphertext, secret []byte, err error) {
	if len(publicKey) != pqPublicKeySize {
		return nil, nil, fmt.Errorf("%w: public key of %d bytes", errPQBadInput, len(publicKey))
	}
	key, err := pqKEM.NewPublicKey(publicKey)
	if err != nil {
		return nil, nil, err
	}
	ciphertext, sender, err := hpke.NewSender(key, hpke.HKDFSHA256(), hpke.ExportOnly(), info)
	if err != nil {
		return nil, nil, err
	}
	secret, err = sender.Export(pqExportLabel, pqSecretSize)
	if err != nil {
		return nil, nil, err
	}
	return ciphertext, secret, nil
}

// pqDecapsulate is the secret ciphertext carries for key and info. ML-KEM
// rejects implicitly: a wrong key or a damaged ciphertext gives another
// secret (no error), which the AEAD keyed with it then refuses.
func pqDecapsulate(key hpke.PrivateKey, ciphertext, info []byte) ([]byte, error) {
	if len(ciphertext) != pqCiphertextSize {
		return nil, fmt.Errorf("%w: ciphertext of %d bytes", errPQBadInput, len(ciphertext))
	}
	recipient, err := hpke.NewRecipient(ciphertext, key, hpke.HKDFSHA256(), hpke.ExportOnly(), info)
	if err != nil {
		return nil, err
	}
	return recipient.Export(pqExportLabel, pqSecretSize)
}

// pqDeviceSeed is the seed of the device key of the node nodeKey.
func pqDeviceSeed(nodeKey ed25519.PrivateKey) ([]byte, error) {
	if len(nodeKey) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("%w: node key", errPQBadInput)
	}
	return hkdf.Key(sha256.New, nodeKey.Seed(), nil,
		fmt.Sprintf("%s|%d", pqDeviceKeyInfo, pqDeviceKeyVersion), pqSeedSize)
}

// The key record: a device's public KEM key, signed by its node identity
// key, so that nobody can swap it — not a relay, not a stranger who copies
// another device's record (the node key must hash to the sender's mesh
// address).
//
//	version(1) | suites(1) | nodeKey(32) | kemID(2) | keyVersion(4) |
//	publicKey(1216) | signature per suite
//
// suites says which signatures follow, in bit order: bit 0 is Ed25519 (64
// bytes), the only one. A verifier refuses a record naming a suite it does
// not know, so nothing can be stripped down to a weaker one. The record
// gets no ML-DSA signature: the mesh address commits to the Ed25519 node
// key alone, so an ML-DSA key here would be anchored by nothing stronger
// than Ed25519. Who a peer is in Zen rests on the app's hybrid signatures
// (internal/zensig, docs/PROTOCOL.md §4.1), not on this record.
const (
	pqRecordVersion     = 1
	pqSuiteEd25519      = 0x01
	pqRecordBodySize    = 1 + 1 + ed25519.PublicKeySize + 2 + 4 + pqPublicKeySize
	pqRecordSize        = pqRecordBodySize + ed25519.SignatureSize
	pqRecordSigningCtxt = "zen.pq.record.v1\x00"
)

func pqBuildRecord(nodeKey ed25519.PrivateKey, publicKey []byte) ([]byte, error) {
	if len(nodeKey) != ed25519.PrivateKeySize || len(publicKey) != pqPublicKeySize {
		return nil, errPQBadInput
	}
	record := make([]byte, 0, pqRecordSize)
	record = append(record, pqRecordVersion, pqSuiteEd25519)
	record = append(record, nodeKey.Public().(ed25519.PublicKey)...)
	record = binary.BigEndian.AppendUint16(record, pqKEMID)
	record = binary.BigEndian.AppendUint32(record, pqDeviceKeyVersion)
	record = append(record, publicKey...)
	signature := ed25519.Sign(nodeKey, pqRecordSigned(record))
	return append(record, signature...), nil
}

func pqRecordSigned(body []byte) []byte {
	message := make([]byte, 0, len(pqRecordSigningCtxt)+len(body))
	message = append(message, pqRecordSigningCtxt...)
	return append(message, body...)
}

// pqVerifyRecord is the public KEM key record carries when it is a record
// of the node at source, correctly signed.
func pqVerifyRecord(record []byte, source net.IP) ([]byte, error) {
	if len(record) != pqRecordSize {
		return nil, fmt.Errorf("%w: record of %d bytes", errPQBadInput, len(record))
	}
	if record[0] != pqRecordVersion || record[1] != pqSuiteEd25519 {
		return nil, fmt.Errorf("%w: record version or suites", errPQBadInput)
	}
	nodeKey := ed25519.PublicKey(record[2 : 2+ed25519.PublicKeySize])
	offset := 2 + ed25519.PublicKeySize
	if binary.BigEndian.Uint16(record[offset:offset+2]) != pqKEMID {
		return nil, fmt.Errorf("%w: record KEM", errPQBadInput)
	}
	offset += 2 + 4
	publicKey := record[offset : offset+pqPublicKeySize]
	source16 := source.To16()
	if source16 == nil || !bytes.Equal(address.AddrForKey(nodeKey)[:], source16) {
		return nil, errors.New("pq: record is not of the sender's node key")
	}
	if !ed25519.Verify(nodeKey, pqRecordSigned(record[:pqRecordBodySize]), record[pqRecordBodySize:]) {
		return nil, errors.New("pq: record signature does not verify")
	}
	if _, err := pqKEM.NewPublicKey(publicKey); err != nil {
		return nil, fmt.Errorf("pq: record key: %w", err)
	}
	return bytes.Clone(publicKey), nil
}
