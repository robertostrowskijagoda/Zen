package main

import (
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/yggdrasil-network/yggdrasil-go/src/address"
)

// strangerTestNode is a locked phone's node (with the stranger budget) on
// a clock the test moves, with a session layer that knows friend.
func strangerTestNode(t *testing.T, clock *time.Time, friends ...string) *bridgeNode {
	t.Helper()
	_, nodeKey, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	ip := net.IP(address.AddrForKey(nodeKey.Public().(ed25519.PublicKey))[:])
	endpoint, err := newPQEndpoint(nodeKey, ip, func(net.IP, []byte) error { return nil })
	if err != nil {
		t.Fatal(err)
	}
	endpoint.setKnown(friends)
	budget := newStrangerSignalBudget()
	budget.now = func() time.Time { return *clock }
	node := &bridgeNode{pq: endpoint, strangerSignals: budget}
	node.pqOnce.Do(func() {})
	return node
}

func strangerTestAddress(i int) net.IP {
	return net.ParseIP(fmt.Sprintf("201:%x::1", 0x1000+i))
}

// admitted counts how many of n signals from source the node hands over.
func admitted(node *bridgeNode, source net.IP, n int) int {
	count := 0
	for range n {
		if node.admitSignal(source, signalSourceNetOf(source)) {
			count++
		}
	}
	return count
}

func TestALockedPhoneHandsOverStrangersSignalsWithinAnHourlyBudget(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0)
	friend := strangerTestAddress(0)
	node := strangerTestNode(t, &clock, friend.String())
	stranger := strangerTestAddress(1)

	// A flood from one stranger: its burst, then one signal every two
	// minutes (30 an hour), however fast it sends.
	if got := admitted(node, stranger, 1000); got != strangerSignalBurstPerSource {
		t.Fatalf("a flood got %d signals through at once, want %d", got, strangerSignalBurstPerSource)
	}
	clock = clock.Add(2 * time.Minute)
	if got := admitted(node, stranger, 1000); got != 1 {
		t.Fatalf("two minutes later %d more signals, want 1", got)
	}
	// A whole hour of flooding, a signal a second.
	through := 0
	for range 3600 {
		clock = clock.Add(time.Second)
		through += admitted(node, stranger, 1)
	}
	if through > strangerSignalsPerHourPerSource+1 {
		t.Fatalf("an hour of flooding got %d signals through, want at most %d", through, strangerSignalsPerHourPerSource+1)
	}

	// A friend is never counted, while strangers' budget is spent.
	if got := admitted(node, friend, 5000); got != 5000 {
		t.Fatalf("a friend got %d of 5000 signals through", got)
	}
}

func TestStrangersWithManyAddressesShareOneBudget(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0)
	node := strangerTestNode(t, &clock)

	// Addresses cost nothing: each new one has its share, but all of them
	// together get the total's burst, and then its hourly rate.
	through := 0
	for i := range 500 {
		through += admitted(node, strangerTestAddress(100+i), 50)
	}
	if through != strangerSignalBurst {
		t.Fatalf("500 strangers got %d signals through at once, want %d", through, strangerSignalBurst)
	}
	through = 0
	for minute := range 60 {
		clock = clock.Add(time.Minute)
		for i := range 50 {
			through += admitted(node, strangerTestAddress(1000+minute*50+i), 10)
		}
	}
	if through > strangerSignalsPerHour+1 {
		t.Fatalf("an hour of new strangers got %d signals through, want at most %d", through, strangerSignalsPerHour+1)
	}
}

func TestContactsTheAppNamesAreNotCountedAsStrangers(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0)
	node := strangerTestNode(t, &clock)
	member := strangerTestAddress(7)
	// A member of a group, heard by the locked receiver: named to the node.
	if got := node.strangerSignals.listen([]string{member.String(), "not an address", "10.0.0.1"}); got != 1 {
		t.Fatalf("listened to %d addresses, want 1", got)
	}
	if got := admitted(node, member, 2000); got != 2000 {
		t.Fatalf("a listened member got %d of 2000 signals through", got)
	}
	// Strangers still have their whole budget.
	if got := admitted(node, strangerTestAddress(8), 100); got != strangerSignalBurstPerSource {
		t.Fatalf("a stranger got %d signals through, want %d", got, strangerSignalBurstPerSource)
	}
}

func TestOnlyALockedPhoneHasAStrangerBudget(t *testing.T) {
	// Any other node (the app's, a computer's) hands every signal over.
	node := &bridgeNode{}
	stranger := strangerTestAddress(1)
	if got := admitted(node, stranger, 5000); got != 5000 {
		t.Fatalf("a node without the budget handed over %d of 5000", got)
	}
}

func TestTheSetPinsRequestNamesListenedContacts(t *testing.T) {
	clock := time.Unix(1_800_000_000, 0)
	node := strangerTestNode(t, &clock)
	member := strangerTestAddress(9)
	var request pqSetPinsRequest
	if err := json.Unmarshal([]byte(`{"listen":["`+member.String()+`"]}`), &request); err != nil {
		t.Fatal(err)
	}
	if request.Known != nil || node.strangerSignals.listen(request.Listen) != 1 {
		t.Fatal("the listen field was not taken")
	}
	if !node.strangerSignals.listensTo(member.String()) {
		t.Fatal("a named member is not listened to")
	}
}
