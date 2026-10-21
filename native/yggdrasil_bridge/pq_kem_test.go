package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/mlkem"
	"crypto/mlkem/mlkemtest"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha3"
	"encoding/binary"
	"encoding/hex"
	"net"
	"testing"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
)

func TestPQKEMRoundTrip(t *testing.T) {
	seed := make([]byte, pqSeedSize)
	if _, err := rand.Read(seed); err != nil {
		t.Fatal(err)
	}
	publicKey, err := pqPublicKeyOf(seed)
	if err != nil {
		t.Fatalf("public key: %v", err)
	}
	if len(publicKey) != pqPublicKeySize || pqPublicKeySize != mlkem.EncapsulationKeySize768+32 {
		t.Fatalf("public key of %d bytes", len(publicKey))
	}
	info := []byte("zen.test|a|b")
	ciphertext, secret, err := pqEncapsulate(publicKey, info)
	if err != nil {
		t.Fatalf("encapsulate: %v", err)
	}
	if len(ciphertext) != pqCiphertextSize || pqCiphertextSize != mlkem.CiphertextSize768+32 || len(secret) != pqSecretSize {
		t.Fatalf("ciphertext %d, secret %d bytes", len(ciphertext), len(secret))
	}
	key, err := pqPrivateKey(seed)
	if err != nil {
		t.Fatal(err)
	}
	opened, err := pqDecapsulate(key, ciphertext, info)
	if err != nil || !bytes.Equal(opened, secret) {
		t.Fatalf("decapsulate: %v, same secret %v", err, bytes.Equal(opened, secret))
	}

	// Another key, another info, a changed ciphertext: another secret.
	other := bytes.Clone(seed)
	other[0] ^= 1
	otherKey, _ := pqPrivateKey(other)
	if got, _ := pqDecapsulate(otherKey, ciphertext, info); bytes.Equal(got, secret) {
		t.Fatal("another key opened the secret")
	}
	if got, _ := pqDecapsulate(key, ciphertext, []byte("zen.test|a|c")); bytes.Equal(got, secret) {
		t.Fatal("the secret is not bound to the info")
	}
	for _, at := range []int{0, mlkem.CiphertextSize768 - 1, mlkem.CiphertextSize768} {
		damaged := bytes.Clone(ciphertext)
		damaged[at] ^= 0x40
		if got, _ := pqDecapsulate(key, damaged, info); bytes.Equal(got, secret) {
			t.Fatalf("a ciphertext changed at %d gave the same secret", at)
		}
	}
	// Two encapsulations never give the same secret.
	_, again, _ := pqEncapsulate(publicKey, info)
	if bytes.Equal(again, secret) {
		t.Fatal("encapsulation is not randomized")
	}

	if _, _, err := pqEncapsulate(publicKey[:100], info); err == nil {
		t.Fatal("a short public key must be refused")
	}
	if _, err := pqDecapsulate(key, ciphertext[:100], info); err == nil {
		t.Fatal("a short ciphertext must be refused")
	}
	if _, err := pqPublicKeyOf(seed[:31]); err == nil {
		t.Fatal("a short seed must be refused")
	}
}

// hpkeLabeled* are RFC 9180's labelled HKDF steps, written out here to check
// the bridge's hybrid derivation independently of crypto/hpke.
func hpkeSuite() []byte {
	suite := []byte("HPKE")
	suite = binary.BigEndian.AppendUint16(suite, pqKEMID)
	suite = binary.BigEndian.AppendUint16(suite, 0x0001) // HKDF-SHA256
	return binary.BigEndian.AppendUint16(suite, 0xffff)  // export only
}

func hpkeLabeledExtract(t *testing.T, salt []byte, label string, ikm []byte) []byte {
	t.Helper()
	input := append([]byte("HPKE-v1"), hpkeSuite()...)
	input = append(input, label...)
	input = append(input, ikm...)
	prk, err := hkdf.Extract(sha256.New, input, salt)
	if err != nil {
		t.Fatal(err)
	}
	return prk
}

func hpkeLabeledExpand(t *testing.T, prk []byte, label string, info []byte, length int) []byte {
	t.Helper()
	labeled := binary.BigEndian.AppendUint16(nil, uint16(length))
	labeled = append(labeled, "HPKE-v1"...)
	labeled = append(labeled, hpkeSuite()...)
	labeled = append(labeled, label...)
	labeled = append(labeled, info...)
	out, err := hkdf.Expand(sha256.New, prk, string(labeled), length)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// The hybrid derivation, step by step: ML-KEM-768 and X25519 secrets
// combined as X-Wing does (SHA3-256 over both secrets, the X25519
// ciphertext and public key, and the label), then HPKE's key schedule and
// exporter. A fixed seed, fixed encapsulation randomness and a fixed
// ephemeral key make a vector; the value is also pinned, so a change of
// the construction cannot go unnoticed.
func TestPQHybridDerivationVector(t *testing.T) {
	seed := make([]byte, pqSeedSize)
	for index := range seed {
		seed[index] = byte(index)
	}
	key, err := pqPrivateKey(seed)
	if err != nil {
		t.Fatal(err)
	}
	publicKey := key.PublicKey().Bytes()
	if got := sha256.Sum256(publicKey); hex.EncodeToString(got[:]) != pqVectorPublicKeyHash {
		t.Fatalf("public key hash %x", got)
	}
	encapsulationKey, err := mlkem.NewEncapsulationKey768(publicKey[:mlkem.EncapsulationKeySize768])
	if err != nil {
		t.Fatal(err)
	}
	random := bytes.Repeat([]byte{0x24}, 32)
	secretPQ, ciphertextPQ, err := mlkemtest.Encapsulate768(encapsulationKey, random)
	if err != nil {
		t.Fatal(err)
	}
	ephemeral, err := ecdh.X25519().NewPrivateKey(bytes.Repeat([]byte{0x42}, 32))
	if err != nil {
		t.Fatal(err)
	}
	recipientX, err := ecdh.X25519().NewPublicKey(publicKey[mlkem.EncapsulationKeySize768:])
	if err != nil {
		t.Fatal(err)
	}
	secretX, err := ephemeral.ECDH(recipientX)
	if err != nil {
		t.Fatal(err)
	}
	ciphertextX := ephemeral.PublicKey().Bytes()
	combiner := sha3.New256()
	combiner.Write(secretPQ)
	combiner.Write(secretX)
	combiner.Write(ciphertextX)
	combiner.Write(publicKey[mlkem.EncapsulationKeySize768:])
	combiner.Write([]byte("\\./" + "/^\\"))
	shared := combiner.Sum(nil)

	info := []byte("zen.test.vector")
	context := append([]byte{0}, hpkeLabeledExtract(t, nil, "psk_id_hash", nil)...)
	context = append(context, hpkeLabeledExtract(t, nil, "info_hash", info)...)
	secret := hpkeLabeledExtract(t, shared, "secret", nil)
	exporter := hpkeLabeledExpand(t, secret, "exp", context, sha256.Size)
	want := hpkeLabeledExpand(t, exporter, "sec", []byte(pqExportLabel), pqSecretSize)

	ciphertext := append(bytes.Clone(ciphertextPQ), ciphertextX...)
	got, err := pqDecapsulate(key, ciphertext, info)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("bridge secret %x, independent derivation %x", got, want)
	}
	if hex.EncodeToString(got) != pqVectorSecret {
		t.Fatalf("secret %x changed", got)
	}
}

const (
	pqVectorPublicKeyHash = "c9a3565ffde4f72b51661be391ee13e46378d7f06dd5c8bf5af9d2cfb5b8336b"
	pqVectorSecret        = "3068ec520cf9e7f2bb4b78b15705682150172ec09107d82f0b425b426f7d98de"
)

func pqTestNode(t *testing.T, fill byte) (ed25519.PrivateKey, net.IP) {
	t.Helper()
	nodeKey := ed25519.NewKeyFromSeed(bytes.Repeat([]byte{fill}, ed25519.SeedSize))
	ip := net.IP(address.AddrForKey(nodeKey.Public().(ed25519.PublicKey))[:])
	return nodeKey, ip
}

func TestPQDeviceKeyComesFromTheNodeKey(t *testing.T) {
	nodeA, _ := pqTestNode(t, 1)
	nodeB, _ := pqTestNode(t, 2)
	seedA, err := pqDeviceSeed(nodeA)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := pqDeviceSeed(nodeA)
	seedB, _ := pqDeviceSeed(nodeB)
	if !bytes.Equal(seedA, again) || bytes.Equal(seedA, seedB) || bytes.Equal(seedA, nodeA.Seed()) {
		t.Fatal("the device key must be stable per node key and differ from it")
	}
}

func TestPQKeyRecordIsBoundToTheSenderAddress(t *testing.T) {
	nodeKey, ip := pqTestNode(t, 3)
	_, otherIP := pqTestNode(t, 4)
	seed, _ := pqDeviceSeed(nodeKey)
	publicKey, _ := pqPublicKeyOf(seed)
	record, err := pqBuildRecord(nodeKey, publicKey)
	if err != nil {
		t.Fatal(err)
	}
	if len(record) != pqRecordSize {
		t.Fatalf("record of %d bytes", len(record))
	}
	got, err := pqVerifyRecord(record, ip)
	if err != nil || !bytes.Equal(got, publicKey) {
		t.Fatalf("own record: %v", err)
	}
	// Someone else showing this record (a relay, a stranger) is refused.
	if _, err := pqVerifyRecord(record, otherIP); err == nil {
		t.Fatal("a record must only be taken from its own node's address")
	}
	// A swapped key, a changed field, a signature from another key, an
	// unknown signature suite: all refused.
	for _, at := range []int{1, 2 + 5, 2 + 32, 2 + 32 + 2 + 4 + 10, pqRecordBodySize + 3} {
		damaged := bytes.Clone(record)
		damaged[at] ^= 0x01
		if _, err := pqVerifyRecord(damaged, ip); err == nil {
			t.Fatalf("a record changed at %d was taken", at)
		}
	}
	otherKey, _ := pqTestNode(t, 4)
	forged, _ := pqBuildRecord(otherKey, publicKey)
	copy(forged[2:2+32], nodeKey.Public().(ed25519.PublicKey))
	if _, err := pqVerifyRecord(forged, ip); err == nil {
		t.Fatal("a record signed by another key was taken")
	}
	if _, err := pqVerifyRecord(record[:len(record)-1], ip); err == nil {
		t.Fatal("a short record was taken")
	}
}

// One session setup: an encapsulation and its decapsulation.
func BenchmarkPQKEMSessionSetup(b *testing.B) {
	seed := bytes.Repeat([]byte{7}, pqSeedSize)
	key, _ := pqPrivateKey(seed)
	publicKey := key.PublicKey().Bytes()
	info := []byte("zen.bench")
	b.ResetTimer()
	for range b.N {
		ciphertext, _, err := pqEncapsulate(publicKey, info)
		if err != nil {
			b.Fatal(err)
		}
		if _, err := pqDecapsulate(key, ciphertext, info); err != nil {
			b.Fatal(err)
		}
	}
}
