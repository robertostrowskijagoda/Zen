package main

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/mlkem"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"sync"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
)

// The local link handshake: run by both ends of any stream (a TCP
// connection on the LAN, a Bluetooth socket) the same way, so neither needs
// to know beforehand who is on the other side or who speaks first.
//
//  1. Each side sends an opening: the version and a fresh random nonce.
//  2. Each side sends a hello: fresh one-time keys — X25519 and an
//     ML-KEM-768 encapsulation key — and, for every device it may link
//     with, a selector HMAC(selKey, its own mesh address | its one-time
//     keys | the OTHER side's nonce)[:8], shuffled and padded with random
//     ones to a fixed number (localSelectorCounts). A hello so answers only
//     the opening it was made for: one recorded from a phone and played to
//     it or to its friends later, anywhere, names nothing they would answer
//     (bound to the one-time keys alone, it made the phone and every friend
//     of its owner go on, which followed them and told who is friends with
//     whom), and one sent back to its sender names the wrong address. Nor
//     does its size tell how many devices the phone links with.
//  3. Each side looks for a selector it can make for the other's address,
//     one-time keys and its own nonce: that names the shared secret. None:
//     a stranger, the stream is closed and nothing else was said.
//  4. Each side encapsulates a secret to the other's ML-KEM key and sends
//     the ciphertext.
//  5. Keys: HKDF(X25519(ephemerals) | the ML-KEM secret of the lower
//     side | that of the higher side, salt: the pair's link key, info: both
//     openings, both hellos and both ciphertexts). A side without the
//     pair's secret cannot get them, and someone who recorded the stream
//     cannot either, later, with a quantum computer: the stream is hybrid
//     post-quantum (it carries signals already sealed by the session layer
//     anyway). The pair's secret is post-quantum too once the devices
//     paired (runtime_lan_discovery.dart); a pair that never reached each
//     other over the network has only the X25519 one of the two devices'
//     keys.
//  6. Each side's first encrypted record is its Yggdrasil public key; it
//     must hash to the mesh address the secret was given for.
//
// Then the stream carries AES-256-GCM records (length-prefixed, a counter
// for nonce, one key per direction). Yggdrasil peers over it with that key
// pinned and a password from the same handshake (localLinkSession).
//
// A device with an older version sends its hello where the opening
// belongs; either side then closes, and the two link only over the
// internet until both have this version. Answering an older hello would
// answer a recorded one too.
const (
	localHandshakeVersion = 3
	localNonceSize        = 16
	localOpeningSize      = 1 + localNonceSize
	// The one-time keys of a hello: X25519, then ML-KEM-768.
	localEphemeralSize = 32 + mlkem.EncapsulationKeySize768
	localSelectorSize  = 8
	// The whole handshake, and the wait for the other side's opening on a
	// network stream: both ends start at once there, so an opening that
	// does not come within it is a connection that says nothing and only
	// holds a handshake slot.
	localHandshakeTimeout  = 8 * time.Second
	localFirstFrameTimeout = 2 * time.Second
	localMaxSelectors      = localLinkMaxPeers + 64
	localRecordMaxPlain    = 16 * 1024
	localRecordOverhead    = 16
	localKeyMaterialLength = 32 + 32 + 16
)

// localSelectorCounts are the numbers of selectors a hello may carry: the
// smallest that holds every device. Nearly everyone links with fewer than
// 64 devices, so nearly every hello has the same size.
var localSelectorCounts = []int{64, 256, 1024, localMaxSelectors}

// localHelloSize is the size of a hello with count selectors.
func localHelloSize(count int) int {
	return 1 + localEphemeralSize + 2 + count*localSelectorSize
}

// localHelloSizeAllowed tells whether a frame of size bytes may be a hello.
func localHelloSizeAllowed(size int) bool {
	for _, count := range localSelectorCounts {
		if size == localHelloSize(count) {
			return true
		}
	}
	return false
}

// localLinkSession is a stream that passed the handshake.
type localLinkSession struct {
	conn *localSecureConn
	peer localPeer
	// The other side's Yggdrasil key (its address is peer.address).
	remoteKey ed25519.PublicKey
	// Yggdrasil's link password for this one link (both sides derive it).
	password string
}

// localSelector names the pair of peer in a hello sent by sender (a mesh
// address, 16 bytes) with its one-time keys ephemeral, in answer to the
// other side's nonce.
func localSelector(peer *localPeer, sender, ephemeral, nonce []byte) []byte {
	mac := hmac.New(sha256.New, peer.selKey[:])
	mac.Write([]byte("sel3"))
	mac.Write(sender)
	mac.Write(ephemeral)
	mac.Write(nonce)
	return mac.Sum(nil)[:localSelectorSize]
}

// localAddressBytes is a mesh address as 16 bytes (nil if it is none).
func localAddressBytes(address string) []byte {
	ip := net.ParseIP(address)
	if ip == nil || ip.To4() != nil {
		return nil
	}
	return ip.To16()
}

// buildLocalHello is version, one-time keys, count, selectors: one for each
// of peers, made by self (this node's mesh address, 16 bytes) for the
// other side's nonce, among random ones.
func buildLocalHello(peers []localPeer, self, ephemeral, nonce []byte, random io.Reader) ([]byte, error) {
	if len(ephemeral) != localEphemeralSize || len(self) != net.IPv6len || len(nonce) != localNonceSize {
		return nil, fmt.Errorf("%w: hello input", errLocalLinkBadInput)
	}
	padded := 0
	for _, count := range localSelectorCounts {
		if len(peers) <= count {
			padded = count
			break
		}
	}
	if padded == 0 {
		return nil, fmt.Errorf("%w: %d devices", errLocalLinkBadInput, len(peers))
	}
	selectors := make([][]byte, 0, padded)
	for i := range peers {
		selectors = append(selectors, localSelector(&peers[i], self, ephemeral, nonce))
	}
	for len(selectors) < padded {
		filler := make([]byte, localSelectorSize)
		if _, err := io.ReadFull(random, filler); err != nil {
			return nil, err
		}
		selectors = append(selectors, filler)
	}
	// Shuffled: the position must not tell which device it stands for.
	for i := len(selectors) - 1; i > 0; i-- {
		j, err := rand.Int(random, big.NewInt(int64(i+1)))
		if err != nil {
			return nil, err
		}
		k := int(j.Int64())
		selectors[i], selectors[k] = selectors[k], selectors[i]
	}
	hello := make([]byte, 0, localHelloSize(padded))
	hello = append(hello, localHandshakeVersion)
	hello = append(hello, ephemeral...)
	hello = binary.BigEndian.AppendUint16(hello, uint16(len(selectors)))
	for _, s := range selectors {
		hello = append(hello, s...)
	}
	return hello, nil
}

func parseLocalHello(hello []byte) (ephemeral []byte, selectors map[string]bool, err error) {
	const head = 1 + localEphemeralSize
	if len(hello) < head+2 || hello[0] != localHandshakeVersion {
		return nil, nil, fmt.Errorf("%w: hello", errLocalLinkBadInput)
	}
	ephemeral = hello[1:head]
	count := int(binary.BigEndian.Uint16(hello[head : head+2]))
	if !localHelloSizeAllowed(len(hello)) || len(hello) != localHelloSize(count) {
		return nil, nil, fmt.Errorf("%w: hello selectors", errLocalLinkBadInput)
	}
	selectors = make(map[string]bool, count)
	for i := 0; i < count; i++ {
		start := head + 2 + i*localSelectorSize
		selectors[string(hello[start:start+localSelectorSize])] = true
	}
	return ephemeral, selectors, nil
}

func writeLocalFrame(w io.Writer, body []byte) error {
	frame := binary.BigEndian.AppendUint16(make([]byte, 0, 2+len(body)), uint16(len(body)))
	frame = append(frame, body...)
	_, err := w.Write(frame)
	return err
}

func readLocalFrame(r io.Reader, limit int) ([]byte, error) {
	return readLocalFrameOf(r, func(size int) bool { return size <= limit })
}

// readLocalFrameOf reads a frame whose size ok takes: one of another size is
// refused before its body is waited for.
func readLocalFrameOf(r io.Reader, ok func(size int) bool) ([]byte, error) {
	var header [2]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	size := int(binary.BigEndian.Uint16(header[:]))
	if !ok(size) {
		return nil, fmt.Errorf("%w: frame of %d bytes", errLocalLinkBadInput, size)
	}
	body := make([]byte, size)
	if _, err := io.ReadFull(r, body); err != nil {
		return nil, err
	}
	return body, nil
}

// localLinkHandshake runs the handshake on conn as nodeKey's node, with
// the devices in peers. On success the stream belongs to the session.
func localLinkHandshake(conn net.Conn, peers []localPeer, nodeKey ed25519.PublicKey) (*localLinkSession, error) {
	return localLinkHandshakeWithin(conn, peers, nodeKey, localHandshakeTimeout)
}

// localLinkHandshakeWithin is localLinkHandshake waiting at most firstFrame
// for the other side's opening.
func localLinkHandshakeWithin(conn net.Conn, peers []localPeer, nodeKey ed25519.PublicKey, firstFrame time.Duration) (*localLinkSession, error) {
	started := time.Now()
	if firstFrame <= 0 || firstFrame > localHandshakeTimeout {
		firstFrame = localHandshakeTimeout
	}
	_ = conn.SetDeadline(started.Add(firstFrame))
	self := localAddressBytes(meshAddressForKey(nodeKey))
	if self == nil {
		return nil, fmt.Errorf("%w: node key", errLocalLinkBadInput)
	}
	opening := make([]byte, localOpeningSize)
	opening[0] = localHandshakeVersion
	if _, err := rand.Read(opening[1:]); err != nil {
		return nil, err
	}
	nonce := opening[1:]
	// Written while reading: on a stream without buffers (a pipe) both
	// sides writing first would wait for each other forever.
	sent := make(chan error, 1)
	go func() { sent <- writeLocalFrame(conn, opening) }()
	remoteOpening, err := readLocalFrameOf(conn, func(size int) bool { return size == localOpeningSize })
	if err != nil {
		return nil, err
	}
	if err := <-sent; err != nil {
		return nil, err
	}
	if remoteOpening[0] != localHandshakeVersion {
		return nil, fmt.Errorf("%w: handshake version %d", errLocalLinkBadInput, remoteOpening[0])
	}
	remoteNonce := remoteOpening[1:]
	if bytes.Equal(remoteNonce, nonce) {
		return nil, errors.New("local link: the stream talks to itself")
	}
	_ = conn.SetDeadline(started.Add(localHandshakeTimeout))
	private, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	kem, err := mlkem.GenerateKey768()
	if err != nil {
		return nil, err
	}
	ephemeral := append(private.PublicKey().Bytes(), kem.EncapsulationKey().Bytes()...)
	hello, err := buildLocalHello(peers, self, ephemeral, remoteNonce, rand.Reader)
	if err != nil {
		return nil, err
	}
	go func() { sent <- writeLocalFrame(conn, hello) }()
	remoteHello, err := readLocalFrameOf(conn, localHelloSizeAllowed)
	if err != nil {
		return nil, err
	}
	if err := <-sent; err != nil {
		return nil, err
	}
	remoteEphemeral, selectors, err := parseLocalHello(remoteHello)
	if err != nil {
		return nil, err
	}
	var peer *localPeer
	for i := range peers {
		sender := localAddressBytes(peers[i].address)
		if sender != nil && selectors[string(localSelector(&peers[i], sender, remoteEphemeral, nonce))] {
			peer = &peers[i]
			break
		}
	}
	if peer == nil {
		return nil, errLocalLinkStranger
	}
	remotePublic, err := ecdh.X25519().NewPublicKey(remoteEphemeral[:32])
	if err != nil {
		return nil, err
	}
	remoteKem, err := mlkem.NewEncapsulationKey768(remoteEphemeral[32:])
	if err != nil {
		return nil, err
	}
	order := bytes.Compare(ephemeral, remoteEphemeral)
	if order == 0 {
		return nil, errors.New("local link: the stream talks to itself")
	}
	// The ML-KEM exchange: a secret for the other side, one from it.
	mySecret, myCiphertext := remoteKem.Encapsulate()
	defer clear(mySecret)
	go func() { sent <- writeLocalFrame(conn, myCiphertext) }()
	theirCiphertext, err := readLocalFrame(conn, mlkem.CiphertextSize768)
	if err != nil {
		return nil, err
	}
	if err := <-sent; err != nil {
		return nil, err
	}
	if len(theirCiphertext) != mlkem.CiphertextSize768 {
		return nil, fmt.Errorf("%w: ciphertext", errLocalLinkBadInput)
	}
	theirSecret, err := kem.Decapsulate(theirCiphertext)
	if err != nil {
		return nil, err
	}
	defer clear(theirSecret)
	shared, err := private.ECDH(remotePublic)
	if err != nil {
		return nil, err
	}
	defer clear(shared)
	lowOpening, highOpening := opening, remoteOpening
	low, high := hello, remoteHello
	lowCiphertext, highCiphertext := myCiphertext, theirCiphertext
	lowSecret, highSecret := mySecret, theirSecret
	if order > 0 {
		lowOpening, highOpening = remoteOpening, opening
		low, high = remoteHello, hello
		lowCiphertext, highCiphertext = theirCiphertext, myCiphertext
		lowSecret, highSecret = theirSecret, mySecret
	}
	transcript := sha256.New()
	transcript.Write([]byte("zen.local.v3"))
	transcript.Write(lowOpening)
	transcript.Write(highOpening)
	transcript.Write(low)
	transcript.Write(high)
	transcript.Write(lowCiphertext)
	transcript.Write(highCiphertext)
	input := make([]byte, 0, len(shared)+len(lowSecret)+len(highSecret))
	input = append(append(append(input, shared...), lowSecret...), highSecret...)
	defer clear(input)
	material, err := hkdf.Key(sha256.New, input, peer.linkKey[:], "zen.local.v3 keys "+string(transcript.Sum(nil)), localKeyMaterialLength)
	if err != nil {
		return nil, err
	}
	defer clear(material[:64])
	lowKey, highKey := material[0:32], material[32:64]
	sendKey, recvKey := lowKey, highKey
	if order > 0 {
		sendKey, recvKey = highKey, lowKey
	}
	secure, err := newLocalSecureConn(conn, sendKey, recvKey)
	if err != nil {
		return nil, err
	}
	go func() {
		_, err := secure.Write(nodeKey)
		sent <- err
	}()
	confirm := make([]byte, ed25519.PublicKeySize+1)
	n, err := secure.readRecord(confirm)
	if err != nil {
		return nil, err
	}
	if err := <-sent; err != nil {
		return nil, err
	}
	if n != ed25519.PublicKeySize {
		return nil, fmt.Errorf("%w: confirm", errLocalLinkBadInput)
	}
	remoteKey := ed25519.PublicKey(append([]byte(nil), confirm[:n]...))
	if bytes.Equal(remoteKey, nodeKey) {
		return nil, errors.New("local link: the other side has this node's key")
	}
	addr := address.AddrForKey(remoteKey)
	if addr == nil || net.IP(addr[:]).String() != peer.address {
		return nil, errors.New("local link: the other side's key is not the device's")
	}
	_ = conn.SetDeadline(time.Time{})
	return &localLinkSession{
		conn:      secure,
		peer:      *peer,
		remoteKey: remoteKey,
		password:  hex.EncodeToString(material[64:80]),
	}, nil
}

// localSecureConn is the encrypted stream after the handshake.
type localSecureConn struct {
	raw net.Conn

	readMu  sync.Mutex
	recv    cipher.AEAD
	recvSeq uint64
	pending []byte

	writeMu sync.Mutex
	send    cipher.AEAD
	sendSeq uint64
}

func newLocalSecureConn(raw net.Conn, sendKey, recvKey []byte) (*localSecureConn, error) {
	send, err := newLocalAEAD(sendKey)
	if err != nil {
		return nil, err
	}
	recv, err := newLocalAEAD(recvKey)
	if err != nil {
		return nil, err
	}
	return &localSecureConn{raw: raw, send: send, recv: recv}, nil
}

func newLocalAEAD(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func localNonce(seq uint64) []byte {
	nonce := make([]byte, 12)
	binary.BigEndian.PutUint64(nonce[4:], seq)
	return nonce
}

// readRecord reads one record into p (which must fit it).
func (c *localSecureConn) readRecord(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	plain, err := c.nextRecord()
	if err != nil {
		return 0, err
	}
	if len(plain) > len(p) {
		return 0, fmt.Errorf("%w: record of %d bytes", errLocalLinkBadInput, len(plain))
	}
	return copy(p, plain), nil
}

// nextRecord reads and opens the next record; readMu is held.
func (c *localSecureConn) nextRecord() ([]byte, error) {
	sealed, err := readLocalFrame(c.raw, localRecordMaxPlain+localRecordOverhead)
	if err != nil {
		return nil, err
	}
	plain, err := c.recv.Open(sealed[:0], localNonce(c.recvSeq), sealed, nil)
	if err != nil {
		return nil, errors.New("local link: a record failed authentication")
	}
	c.recvSeq++
	return plain, nil
}

func (c *localSecureConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for len(c.pending) == 0 {
		plain, err := c.nextRecord()
		if err != nil {
			return 0, err
		}
		c.pending = plain
	}
	n := copy(p, c.pending)
	c.pending = c.pending[n:]
	return n, nil
}

func (c *localSecureConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	written := 0
	for written < len(p) {
		chunk := p[written:]
		if len(chunk) > localRecordMaxPlain {
			chunk = chunk[:localRecordMaxPlain]
		}
		sealed := c.send.Seal(nil, localNonce(c.sendSeq), chunk, nil)
		c.sendSeq++
		if err := writeLocalFrame(c.raw, sealed); err != nil {
			return written, err
		}
		written += len(chunk)
	}
	return written, nil
}

func (c *localSecureConn) Close() error                       { return c.raw.Close() }
func (c *localSecureConn) LocalAddr() net.Addr                { return c.raw.LocalAddr() }
func (c *localSecureConn) RemoteAddr() net.Addr               { return c.raw.RemoteAddr() }
func (c *localSecureConn) SetDeadline(t time.Time) error      { return c.raw.SetDeadline(t) }
func (c *localSecureConn) SetReadDeadline(t time.Time) error  { return c.raw.SetReadDeadline(t) }
func (c *localSecureConn) SetWriteDeadline(t time.Time) error { return c.raw.SetWriteDeadline(t) }
