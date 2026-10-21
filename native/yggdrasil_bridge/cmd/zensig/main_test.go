package main

import (
	"crypto/sha256"
	"strings"
	"testing"

	"zen/native/yggdrasil_bridge/internal/zensig"
)

func ask(t *testing.T, request string) map[string]any {
	t.Helper()
	answer, err := run(strings.NewReader(request))
	if err != nil {
		t.Fatalf("%s: %v", request, err)
	}
	return answer
}

func TestSignAndVerifyThroughJSON(t *testing.T) {
	sum := sha256.Sum256([]byte("zen-pyramid-test-power"))
	seed := b64.EncodeToString(sum[:])
	pub := ask(t, `{"op":"public","seed":"`+seed+`"}`)
	if pub["ed"] != "fqYYVc7Xq7McGfJVv19kLU9HelAXejJ8bQBcT73kFO8=" {
		t.Fatalf("ed %v", pub["ed"])
	}
	if pub["id"] != pub["ed"].(string)+"."+pub["fingerprint"].(string) {
		t.Fatalf("id %v", pub["id"])
	}
	message := b64.EncodeToString([]byte("a release manifest"))
	signed := ask(t, `{"op":"sign","seed":"`+seed+`","message":"`+message+`","withKey":true}`)
	sig := signed["signature"].(string)
	if raw, _ := b64.DecodeString(sig); len(raw) != zensig.KeyedSignatureSize {
		t.Fatalf("a keyed signature of %d bytes", len(raw))
	}
	digest := zensig.Digest([]byte("a release manifest"))
	d := b64.EncodeToString(digest[:])
	bySig := ask(t, `{"op":"sign","seed":"`+seed+`","digest":"`+d+`","withKey":true}`)
	if bySig["signature"] != sig {
		t.Fatal("signing the digest and the message differ")
	}
	ok := ask(t, `{"op":"verify","publicKey":"`+pub["ed"].(string)+`","digest":"`+d+`","signature":"`+sig+`"}`)
	if ok["valid"] != true {
		t.Fatal("own signature refused")
	}
	// The short form names the key: verified only with it.
	short := ask(t, `{"op":"sign","seed":"`+seed+`","digest":"`+d+`"}`)["signature"].(string)
	if raw, _ := b64.DecodeString(short); len(raw) != zensig.SignatureSize {
		t.Fatalf("a signature of %d bytes", len(raw))
	}
	without := ask(t, `{"op":"verify","publicKey":"`+pub["ed"].(string)+`","digest":"`+d+`","signature":"`+short+`"}`)
	with := ask(t, `{"op":"verify","publicKey":"`+pub["ed"].(string)+`","pqKey":"`+pub["pq"].(string)+`","digest":"`+d+`","signature":"`+short+`"}`)
	if without["valid"] != false || with["valid"] != true {
		t.Fatalf("short form: without the key %v, with it %v", without["valid"], with["valid"])
	}
	other := b64.EncodeToString([]byte("another manifest"))
	bad := ask(t, `{"op":"verify","publicKey":"`+pub["ed"].(string)+`","message":"`+other+`","signature":"`+sig+`"}`)
	if bad["valid"] != false {
		t.Fatal("another message verified")
	}
	if _, err := run(strings.NewReader(`{"op":"nope"}`)); err == nil {
		t.Fatal("unknown op taken")
	}
}
