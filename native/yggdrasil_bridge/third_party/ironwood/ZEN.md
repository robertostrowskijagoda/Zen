# ironwood, as Zen builds it

A copy of github.com/Arceliar/ironwood v0.0.0-20261023231900-0712eccbb962
(MPL-2.0, see LICENSE) with two changes, used through the `replace` line
in ../../go.mod. Everything else is upstream's, byte for byte.

## The change: a new session init when the first one was not answered

`encrypted/session.go`, `_bufferAndInit` (marked "Zen:"). While a session
with a node is not acknowledged yet, every packet written to it sent the
same session init again, with the same `seq`. The other side answers an
init with a given `seq` only once (`sessionInfo.handleInit`). When that one
answer was lost, because the other side had no path back yet (as to a node
that just joined the mesh: its bloom filter climbs the tree a router round,
a second, per hop), the inits that followed were all ignored until the
other side's session timed out, a minute later. In Zen: an invitation sent
from a phone that just came on the mesh stayed "waiting for acceptance"
for a minute.

Now a buffered init older than a second is replaced by a new one (new keys,
newer `seq`, as ironwood makes a first init), so each try a second later is
answered again, and the answer goes as soon as there is a way back. A node
with the upstream ironwood answers it the same way: only the side that
starts the session needs the change.

`TestFreshNodeReachesAnOldOneWithinSeconds` (../../first_contact_test.go)
shows it: a node five hops below the root writing to one next to it at once
got its first packet through after 7–8 s here, never within 40 s before.

## The change: counters and round-trip times read across actors

`encrypted/session.go`, `encrypted/debug.go`, `network/peers.go` and
`network/debug.go` (marked "Zen:"). Each session counts what it sent and
received (`rx`, `tx`) in its own actor, while `Debug.GetSessions` read
them from the session manager's. A peer's signature request time (`srst`)
was written by its writer and read by the peer (`_handleSigRes`) and by
`Debug.GetPeers`. The race detector (`go test -race`) found both. The
counters are now `atomic.Uint64`, the times `atomic.Int64` nanoseconds of
the monotonic clock (as `time.Time.Sub` measured them). Nothing else
changes: the same numbers, read safely.

## Updating

Copy the new upstream version over this folder, apply both changes again
(search upstream's `_bufferAndInit`, `rx`, `tx`, `srst` and `srrt`), set the version above and in
../../go.mod's `require`, and run the bridge's tests and
`dart run tool/go_licenses.dart`.
