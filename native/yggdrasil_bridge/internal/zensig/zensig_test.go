package zensig

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"testing"

	"zen/native/yggdrasil_bridge/internal/mldsa"
)

func seedOf(label string) []byte {
	sum := sha256.Sum256([]byte(label))
	return sum[:]
}

// Fixed vectors: the seed is SHA-256 of the label, the message is
// "zen hybrid signature test vector". The hashes pin the derivation (HKDF
// label, ML-DSA-65 key expansion) and both signature layouts; a change to
// any of them must show up here (and in every stored record).
var vectors = []struct {
	label        string
	ed           string // Ed25519 public key
	pqKeyHash    string // SHA-256 of the ML-DSA-65 public key (= F)
	sigHash      string // SHA-256 of the signature (names the key by F)
	keyedSigHash string // SHA-256 of the keyed signature (carries the key)
}{
	{
		label:        "zen-sig-vector-1",
		ed:           "5b90b773c1a5588e3d23cd6bd32f99168e7db7f973427dd4292d3dd8edef32a1",
		pqKeyHash:    "616d8e5ce803836c8d5290a944ac3b7a8cd72ce7f4cdc96090464f52d21d2a7e",
		sigHash:      "6012f1199ad528a734ea5e5069525a8ff5ac38723c4386cf1607e44f756967f5",
		keyedSigHash: "8fecc8502e64432995b6bdca68e94cdba0cb1658ef4333fbd380884bfa927828",
	},
	{
		label:        "zen-sig-vector-2",
		ed:           "7cf3c2181b287d1b76bf11291659bfd945404d7127fa9228be55cc0e53f54bbb",
		pqKeyHash:    "0533107785ad0b463d7965a6201ba1aadcb78e0709d8411a769d6ebe0e9bd2df",
		sigHash:      "dcfb1171db1940eb429c4e5ad15025bdcee77046f10a3c5f6b1c7f4f252fa1f1",
		keyedSigHash: "3fe55918b7e7bf05e83337a5f17c034043801642b638b6bd2dd2192679ba26f0",
	},
}

var vectorMessage = []byte("zen hybrid signature test vector")

func TestVectors(t *testing.T) {
	for _, v := range vectors {
		seed := seedOf(v.label)
		pk, err := PublicKeyOf(seed)
		if err != nil {
			t.Fatal(err)
		}
		sig, err := Sign(seed, vectorMessage)
		if err != nil {
			t.Fatal(err)
		}
		keyed, err := SignWithKey(seed, vectorMessage)
		if err != nil {
			t.Fatal(err)
		}
		sigHash := sha256.Sum256(sig)
		keyedHash := sha256.Sum256(keyed)
		got := [4]string{
			hex.EncodeToString(pk.Ed),
			hex.EncodeToString(pk.Fingerprint[:]),
			hex.EncodeToString(sigHash[:]),
			hex.EncodeToString(keyedHash[:]),
		}
		want := [4]string{v.ed, v.pqKeyHash, v.sigHash, v.keyedSigHash}
		if got != want {
			t.Errorf("%s: got\n  ed %s\n  F  %s\n  sig %s\n  keyed %s", v.label, got[0], got[1], got[2], got[3])
		}
		if err := Verify(pk.Ed, pk.PQ, vectorMessage, sig); err != nil {
			t.Errorf("%s: %v", v.label, err)
		}
		if err := Verify(pk.Ed, nil, vectorMessage, keyed); err != nil {
			t.Errorf("%s keyed: %v", v.label, err)
		}
	}
}

func TestLayoutAndDerivation(t *testing.T) {
	seed := seedOf("zen-sig-layout")
	pk, err := PublicKeyOf(seed)
	if err != nil {
		t.Fatal(err)
	}
	// The Ed25519 half is the seed's own RFC 8032 key: the key's id does
	// not change.
	if !bytes.Equal(pk.Ed, ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)) {
		t.Fatal("the Ed25519 key is not the seed's")
	}
	if len(pk.PQ) != PQPublicKeySize || pk.Fingerprint != sha256.Sum256(pk.PQ) {
		t.Fatal("bad ML-DSA public key or fingerprint")
	}
	sig, err := Sign(seed, []byte("m"))
	if err != nil {
		t.Fatal(err)
	}
	if len(sig) != SignatureSize || SignatureSize != 3405 {
		t.Fatalf("signature of %d bytes", len(sig))
	}
	if !bytes.Equal(sig[EdSignatureSize:EdSignatureSize+FingerprintSize], pk.Fingerprint[:]) {
		t.Fatal("the signature does not name the ML-DSA key")
	}
	keyed, err := SignWithKey(seed, []byte("m"))
	if err != nil {
		t.Fatal(err)
	}
	if len(keyed) != KeyedSignatureSize || KeyedSignatureSize != 5325 {
		t.Fatalf("keyed signature of %d bytes", len(keyed))
	}
	if !bytes.Equal(SignatureKey(keyed), pk.PQ) || SignatureKey(sig) != nil {
		t.Fatal("the keyed signature does not carry the ML-DSA key")
	}
	// The same two halves in both forms: only the key's part differs.
	if !bytes.Equal(sig[:EdSignatureSize], keyed[:EdSignatureSize]) ||
		!bytes.Equal(sig[EdSignatureSize+FingerprintSize:], keyed[EdSignatureSize+PQPublicKeySize:]) {
		t.Fatal("the forms sign differently")
	}
	again, _ := Sign(seed, []byte("m"))
	if !bytes.Equal(sig, again) {
		t.Fatal("signing is not deterministic")
	}
	for _, s := range [][]byte{sig, keyed} {
		f, err := SignatureFingerprint(s)
		if err != nil || f != pk.Fingerprint {
			t.Fatal("SignatureFingerprint")
		}
	}
	if id := pk.ID(); len(id) != 44+1+44 || id[44] != '.' {
		t.Fatalf("hybrid id %q", id)
	}
	// Another seed, another ML-DSA key.
	other, _ := PublicKeyOf(seedOf("zen-sig-other"))
	if bytes.Equal(other.PQ, pk.PQ) {
		t.Fatal("two seeds share an ML-DSA key")
	}
	if _, err := PublicKeyOf(seed[:31]); !errors.Is(err, ErrBadInput) {
		t.Fatal("a short seed was taken")
	}
}

func TestTheKeyIsNeededAndMustBeTheNamedOne(t *testing.T) {
	seed := seedOf("zen-sig-key")
	pk, _ := PublicKeyOf(seed)
	other, _ := PublicKeyOf(seedOf("zen-sig-key-other"))
	msg := []byte("a like")
	sig, _ := Sign(seed, msg)
	keyed, _ := SignWithKey(seed, msg)
	if !errors.Is(Verify(pk.Ed, nil, msg, sig), ErrPQKeyNeeded) {
		t.Error("a signature naming its key verified without the key")
	}
	if !errors.Is(Verify(pk.Ed, other.PQ, msg, sig), ErrWrongPQKey) {
		t.Error("another ML-DSA key was taken for the named one")
	}
	if !errors.Is(Verify(pk.Ed, other.PQ, msg, keyed), ErrWrongPQKey) {
		t.Error("a keyed signature verified against another expected key")
	}
	if err := Verify(pk.Ed, pk.PQ, msg, keyed); err != nil {
		t.Errorf("a keyed signature with its own key: %v", err)
	}
}

func TestTamperingEitherHalfIsRefused(t *testing.T) {
	seed := seedOf("zen-sig-tamper")
	pk, _ := PublicKeyOf(seed)
	msg := []byte("a ledger entry")
	sig, err := Sign(seed, msg)
	if err != nil {
		t.Fatal(err)
	}
	keyed, err := SignWithKey(seed, msg)
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify(pk.Ed, pk.PQ, msg, sig); err != nil {
		t.Fatal(err)
	}
	if !errors.Is(Verify(pk.Ed, pk.PQ, []byte("another entry"), sig), ErrEd25519) {
		t.Error("another message verified")
	}
	flip := func(s []byte, at int) []byte {
		bad := bytes.Clone(s)
		bad[at] ^= 0x01
		return bad
	}
	// The Ed25519 half.
	if !errors.Is(Verify(pk.Ed, pk.PQ, msg, flip(sig, 10)), ErrEd25519) {
		t.Error("a changed Ed25519 half verified")
	}
	// The F it names: no longer the key's.
	if !errors.Is(Verify(pk.Ed, pk.PQ, msg, flip(sig, EdSignatureSize+3)), ErrWrongPQKey) {
		t.Error("a changed fingerprint verified")
	}
	// The ML-DSA key a keyed signature carries: F changes, so the Ed25519
	// half fails.
	if err := Verify(pk.Ed, nil, msg, flip(keyed, EdSignatureSize+100)); err == nil {
		t.Error("a changed ML-DSA key verified")
	}
	// The ML-DSA half.
	pqStart := EdSignatureSize + FingerprintSize
	for _, at := range []int{pqStart, pqStart + 1000, SignatureSize - 1} {
		if !errors.Is(Verify(pk.Ed, pk.PQ, msg, flip(sig, at)), ErrMLDSA) {
			t.Errorf("a changed ML-DSA half (byte %d) verified", at)
		}
	}
	if !errors.Is(Verify(pk.Ed, nil, msg, flip(keyed, KeyedSignatureSize-1)), ErrMLDSA) {
		t.Error("a changed ML-DSA half of a keyed signature verified")
	}
	// Ed25519 alone (the classical signature of the old format) is refused.
	t64 := ed25519.Sign(ed25519.NewKeyFromSeed(seed), msg)
	if !errors.Is(Verify(pk.Ed, pk.PQ, msg, t64), ErrBadInput) {
		t.Error("an Ed25519-only signature was taken")
	}
	// A valid ML-DSA half of another key glued to this Ed25519 half: the
	// Ed25519 half signed another F.
	otherSeed := seedOf("zen-sig-tamper-other")
	otherPK, _ := PublicKeyOf(otherSeed)
	otherSig, _ := Sign(otherSeed, msg)
	mixed := append(bytes.Clone(sig[:EdSignatureSize]), otherSig[EdSignatureSize:]...)
	if !errors.Is(Verify(pk.Ed, otherPK.PQ, msg, mixed), ErrEd25519) {
		t.Error("an ML-DSA half of another key was taken")
	}
	// A quantum forger of Ed25519: a fresh Ed25519 signature over the T
	// that names the forger's own ML-DSA key verifies — which is why the
	// app pins F per key. Here: the halves are consistent, F differs.
	forgedF, _ := SignatureFingerprint(otherSig)
	if forgedF == pk.Fingerprint {
		t.Error("two keys share a fingerprint")
	}
	// Another signer's signature under this key.
	if Verify(pk.Ed, otherPK.PQ, msg, otherSig) == nil {
		t.Error("another key's signature verified")
	}
	// Truncated or empty.
	if Verify(pk.Ed, pk.PQ, msg, sig[:SignatureSize-1]) == nil || Verify(pk.Ed, pk.PQ, msg, nil) == nil {
		t.Error("a short signature verified")
	}
}

// TestSizes prints what a signature costs on the wire (base64url in
// JSON), in both forms.
func TestSizes(t *testing.T) {
	b64 := base64.URLEncoding
	compact := b64.EncodedLen(SignatureSize)
	keyed := b64.EncodedLen(KeyedSignatureSize)
	t.Logf("signature %d B (%d chars), keyed %d B (%d chars)", SignatureSize, compact, KeyedSignatureSize, keyed)
	if compact != 4540 || keyed != 7100 {
		t.Fatalf("base64url: %d and %d chars", compact, keyed)
	}
}

func BenchmarkSign(b *testing.B) {
	seed := seedOf("bench")
	msg := bytes.Repeat([]byte{7}, 1024)
	for b.Loop() {
		if _, err := Sign(seed, msg); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkVerify(b *testing.B) {
	seed := seedOf("bench")
	pk, _ := PublicKeyOf(seed)
	msg := bytes.Repeat([]byte{7}, 1024)
	sig, _ := Sign(seed, msg)
	for b.Loop() {
		if err := Verify(pk.Ed, pk.PQ, msg, sig); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkKeyFromSeed(b *testing.B) {
	seed := seedOf("bench")
	for b.Loop() {
		if _, err := PublicKeyOf(seed); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkParsePQ(b *testing.B) {
	pk, _ := PublicKeyOf(seedOf("bench"))
	for b.Loop() {
		if _, err := mldsa.NewPublicKey65(pk.PQ); err != nil {
			b.Fatal(err)
		}
	}
}
