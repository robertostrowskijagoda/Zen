// Package zensig is Zen's hybrid signature: Ed25519 and ML-DSA-65 (FIPS
// 204) together, valid only when both halves are (docs/PROTOCOL.md §4.1).
//
// A key is the 32-byte seed Zen already keeps for it (account, device,
// pyramid, alarm, maintainer… keys): the Ed25519 key is that seed as
// RFC 8032 defines it, and the ML-DSA-65 key is expanded from
//
//	ξ = HKDF-SHA256(ikm = seed, salt = none, info = "zen.sig.mldsa65.v1"), 32 bytes
//
// so a backup or recovery of the seed restores both halves, and the
// Ed25519 public key stays the key's id everywhere.
//
// A signature binds both public keys to each other and to the message:
//
//	F   = SHA-256(ML-DSA public key)                    the key's PQ fingerprint
//	D   = SHA-512(message)
//	T   = "zen.sig.v1" 0x00 | Ed25519 public key (32) | F (32) | D (64)
//	sig = Ed25519(T) (64) | F (32) | ML-DSA-65(T, ctx "zen.sig.v1") (3309)
//
// 3405 bytes. Both halves sign the same T, which names both keys, so
// neither half can be moved to another key or stripped. The signature
// names its ML-DSA key by F only: the key itself (1952 bytes) is published
// once, in the record that introduces it (a device certificate, a pyramid
// admission…), and the verifier hands it over.
//
// Where no such record can exist yet — the record that introduces a key,
// a release manifest, anything checked by someone who may never have met
// the signer — the signature carries the key instead of F (the keyed
// form, 5325 bytes; the halves are the same):
//
//	keyed = Ed25519(T) (64) | ML-DSA public key (1952) | ML-DSA-65(T) (3309)
//
// ML-DSA signs deterministically (FIPS 204 §3.4), as Ed25519 does: one key
// and one message always give the same bytes.
//
// What a verifier still has to know is which ML-DSA key belongs to an
// Ed25519 key it meets for the first time; the app pins the first one it
// sees (and anchors keys in records where a record names them, by F).
package zensig

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base64"
	"errors"
	"fmt"
	"sync"

	"zen/native/yggdrasil_bridge/internal/mldsa"
)

const (
	SeedSize        = 32
	EdPublicKeySize = ed25519.PublicKeySize
	EdSignatureSize = ed25519.SignatureSize
	PQPublicKeySize = mldsa.PublicKeySize65
	PQSignatureSize = mldsa.SignatureSize65
	FingerprintSize = sha256.Size
	DigestSize      = sha512.Size
	// SignatureSize is a signature that names its ML-DSA key by F.
	SignatureSize = EdSignatureSize + FingerprintSize + PQSignatureSize
	// KeyedSignatureSize is a signature that carries its ML-DSA key.
	KeyedSignatureSize = EdSignatureSize + PQPublicKeySize + PQSignatureSize
	Context            = "zen.sig.v1"
	PQSeedInfo         = "zen.sig.mldsa65.v1"
	toBeSignedPrefix   = Context + "\x00"
	toBeSignedSize     = len(toBeSignedPrefix) + EdPublicKeySize + FingerprintSize + DigestSize
)

var (
	ErrBadInput = errors.New("zensig: malformed input")
	ErrEd25519  = errors.New("zensig: the Ed25519 half does not verify")
	ErrMLDSA    = errors.New("zensig: the ML-DSA-65 half does not verify")
	ErrBadPQKey = errors.New("zensig: the ML-DSA-65 public key does not parse")
	// ErrPQKeyNeeded: the signature names its ML-DSA key by F and none
	// was handed over.
	ErrPQKeyNeeded = errors.New("zensig: the signature's ML-DSA-65 key is needed")
	// ErrWrongPQKey: the ML-DSA key handed over is not the one the
	// signature names or carries.
	ErrWrongPQKey = errors.New("zensig: another ML-DSA-65 key than the signature's")
	errSeedLength = fmt.Errorf("%w: a seed has %d bytes", ErrBadInput, SeedSize)
)

// PublicKey is both halves of a key.
type PublicKey struct {
	Ed          ed25519.PublicKey
	PQ          []byte
	Fingerprint [FingerprintSize]byte
}

// ID is the key's hybrid id: the Ed25519 key and the fingerprint F, each
// base64url with padding (as the app writes keys), joined by a dot.
func (k PublicKey) ID() string {
	return base64.URLEncoding.EncodeToString(k.Ed) + "." +
		base64.URLEncoding.EncodeToString(k.Fingerprint[:])
}

// Fingerprint is F of an ML-DSA-65 public key.
func Fingerprint(pqPublicKey []byte) [FingerprintSize]byte {
	return sha256.Sum256(pqPublicKey)
}

// Digest is D of a message: what the app hands over instead of the message
// itself (a pyramid record may be megabytes).
func Digest(message []byte) [DigestSize]byte {
	return sha512.Sum512(message)
}

// privateKey is an expanded key pair. It is expanded again for every
// signature and never kept: the seeds stay with the app, which forgets the
// account key while it is locked.
type privateKey struct {
	ed ed25519.PrivateKey
	pq *mldsa.PrivateKey
	pk PublicKey
}

func expand(seed []byte) (*privateKey, error) {
	if len(seed) != SeedSize {
		return nil, errSeedLength
	}
	ξ, err := hkdf.Key(sha256.New, seed, nil, PQSeedInfo, mldsa.PrivateKeySize)
	if err != nil {
		return nil, err
	}
	pq, err := mldsa.NewPrivateKey65(ξ)
	if err != nil {
		return nil, err
	}
	ed := ed25519.NewKeyFromSeed(seed)
	pqPublic := pq.PublicKey().Bytes()
	return &privateKey{
		ed: ed,
		pq: pq,
		pk: PublicKey{
			Ed:          ed.Public().(ed25519.PublicKey),
			PQ:          pqPublic,
			Fingerprint: Fingerprint(pqPublic),
		},
	}, nil
}

// Parsed ML-DSA public keys, by fingerprint: parsing (expanding the
// matrix) is half the cost of a verification, and the same few signers
// come again and again (a pyramid, a feed). About 70 KB each.
const pqKeyCacheSize = 32

var (
	pqKeyCacheMu sync.Mutex
	pqKeyCache   = map[[FingerprintSize]byte]*mldsa.PublicKey{}
	pqKeyOrder   [][FingerprintSize]byte
)

func parsePQKey(raw []byte, fingerprint [FingerprintSize]byte) (*mldsa.PublicKey, error) {
	pqKeyCacheMu.Lock()
	key := pqKeyCache[fingerprint]
	pqKeyCacheMu.Unlock()
	if key != nil {
		return key, nil
	}
	key, err := mldsa.NewPublicKey65(raw)
	if err != nil {
		return nil, err
	}
	pqKeyCacheMu.Lock()
	defer pqKeyCacheMu.Unlock()
	if _, had := pqKeyCache[fingerprint]; !had {
		if len(pqKeyOrder) >= pqKeyCacheSize {
			delete(pqKeyCache, pqKeyOrder[0])
			pqKeyOrder = pqKeyOrder[1:]
		}
		pqKeyCache[fingerprint] = key
		pqKeyOrder = append(pqKeyOrder, fingerprint)
	}
	return key, nil
}

// PublicKeyOf is the public key of seed.
func PublicKeyOf(seed []byte) (PublicKey, error) {
	key, err := expand(seed)
	if err != nil {
		return PublicKey{}, err
	}
	return key.pk, nil
}

func toBeSigned(ed []byte, fingerprint [FingerprintSize]byte, digest []byte) []byte {
	t := make([]byte, 0, toBeSignedSize)
	t = append(t, toBeSignedPrefix...)
	t = append(t, ed...)
	t = append(t, fingerprint[:]...)
	return append(t, digest...)
}

func signDigest(seed, digest []byte, withKey bool) ([]byte, error) {
	if len(digest) != DigestSize {
		return nil, fmt.Errorf("%w: a digest of %d bytes", ErrBadInput, len(digest))
	}
	key, err := expand(seed)
	if err != nil {
		return nil, err
	}
	t := toBeSigned(key.pk.Ed, key.pk.Fingerprint, digest)
	pqSig, err := mldsa.SignDeterministic(key.pq, t, Context)
	if err != nil {
		return nil, err
	}
	size := SignatureSize
	if withKey {
		size = KeyedSignatureSize
	}
	sig := make([]byte, 0, size)
	sig = append(sig, ed25519.Sign(key.ed, t)...)
	if withKey {
		sig = append(sig, key.pk.PQ...)
	} else {
		sig = append(sig, key.pk.Fingerprint[:]...)
	}
	return append(sig, pqSig...), nil
}

// SignDigest signs the message whose Digest is digest; the signature
// names the ML-DSA key by F.
func SignDigest(seed, digest []byte) ([]byte, error) {
	return signDigest(seed, digest, false)
}

// SignDigestWithKey is SignDigest in the keyed form: the signature
// carries the ML-DSA key.
func SignDigestWithKey(seed, digest []byte) ([]byte, error) {
	return signDigest(seed, digest, true)
}

// Sign signs message (naming the ML-DSA key by F).
func Sign(seed, message []byte) ([]byte, error) {
	digest := Digest(message)
	return SignDigest(seed, digest[:])
}

// SignWithKey signs message in the keyed form.
func SignWithKey(seed, message []byte) ([]byte, error) {
	digest := Digest(message)
	return SignDigestWithKey(seed, digest[:])
}

// SignatureKey is the ML-DSA key a keyed signature carries, or nil for a
// signature that names it by F.
func SignatureKey(sig []byte) []byte {
	if len(sig) != KeyedSignatureSize {
		return nil
	}
	return sig[EdSignatureSize : EdSignatureSize+PQPublicKeySize]
}

// SignatureFingerprint is F of the ML-DSA key a signature names or
// carries (unchecked: a verifier compares it with the key it pinned).
func SignatureFingerprint(sig []byte) ([FingerprintSize]byte, error) {
	switch len(sig) {
	case SignatureSize:
		return [FingerprintSize]byte(sig[EdSignatureSize : EdSignatureSize+FingerprintSize]), nil
	case KeyedSignatureSize:
		return Fingerprint(SignatureKey(sig)), nil
	}
	return [FingerprintSize]byte{}, fmt.Errorf("%w: a signature of %d bytes", ErrBadInput, len(sig))
}

// VerifyDigest checks sig by the Ed25519 key ed over the message whose
// Digest is digest: nil only when both halves hold. pqKey is the signer's
// ML-DSA key: needed when the signature names it by F, optional for a
// keyed one (then it must be the key carried).
func VerifyDigest(ed, pqKey, digest, sig []byte) error {
	if len(ed) != EdPublicKeySize || len(digest) != DigestSize {
		return ErrBadInput
	}
	var pqPublic, pqSig []byte
	var fingerprint [FingerprintSize]byte
	switch len(sig) {
	case SignatureSize:
		if pqKey == nil {
			return ErrPQKeyNeeded
		}
		fingerprint = [FingerprintSize]byte(sig[EdSignatureSize : EdSignatureSize+FingerprintSize])
		if Fingerprint(pqKey) != fingerprint {
			return ErrWrongPQKey
		}
		pqPublic = pqKey
		pqSig = sig[EdSignatureSize+FingerprintSize:]
	case KeyedSignatureSize:
		pqPublic = SignatureKey(sig)
		if pqKey != nil && !bytes.Equal(pqKey, pqPublic) {
			return ErrWrongPQKey
		}
		fingerprint = Fingerprint(pqPublic)
		pqSig = sig[EdSignatureSize+PQPublicKeySize:]
	default:
		return ErrBadInput
	}
	t := toBeSigned(ed, fingerprint, digest)
	if !ed25519.Verify(ed25519.PublicKey(ed), t, sig[:EdSignatureSize]) {
		return ErrEd25519
	}
	pq, err := parsePQKey(pqPublic, fingerprint)
	if err != nil {
		return ErrBadPQKey
	}
	if mldsa.Verify(pq, t, pqSig, Context) != nil {
		return ErrMLDSA
	}
	return nil
}

// Verify checks sig by the Ed25519 key ed over message (pqKey as for
// VerifyDigest).
func Verify(ed, pqKey, message, sig []byte) error {
	digest := Digest(message)
	return VerifyDigest(ed, pqKey, digest[:], sig)
}
