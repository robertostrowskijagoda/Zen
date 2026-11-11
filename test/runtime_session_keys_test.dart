import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final String _key = 'ab' * 32;
final String _other = 'cd' * 32;

void main() {
  test(
    'vouched keys are pinned once the node runs, conflicts reported',
    () async {
      final List<(Map<String, String>, bool)> calls =
          <(Map<String, String>, bool)>[];
      // The runtime hands the bridge normalised addresses.
      final String bob = PeerShareCodec.normalizeAddress('200::b');
      final Map<String, String> pinned = <String, String>{bob: _other};
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
        bootstrap: () async => RuntimeNodeSession(
          transport: MemorySignalTransport(),
          snapshot: RuntimeTransportSnapshot.started(
            localAddress: '200::1',
            peers: 1,
          ),
          sessionKey: _key,
          pinSessionKeys: (Map<String, String> pins, bool keep) {
            calls.add((Map<String, String>.of(pins), keep));
            final Map<String, String> conflicts = <String, String>{};
            pins.forEach((String address, String key) {
              final String? had = pinned[address];
              if (keep && had != null && had != key) {
                conflicts[address] = had;
              } else {
                pinned[address] = key;
              }
            });
            return conflicts;
          },
        ),
      );
      addTearDown(runtime.dispose);
      final List<String> conflicts = <String>[];
      runtime.sessionKeyConflicts.listen(conflicts.add);

      // Before the node is up: kept, pinned on start.
      runtime.vouchSessionKeys(<String, String>{
        '200:0:0:0:0:0:0:a': _key,
        '200::bad': 'short',
      }, force: false);
      expect(calls, isEmpty);
      expect(runtime.sessionKey, '');
      await runtime.start();
      expect(runtime.sessionKey, _key);
      expect(calls.single.$1, <String, String>{
        PeerShareCodec.normalizeAddress('200::a'): _key,
      });
      expect(calls.single.$2, isTrue);

      // A different pin stays and is reported once.
      runtime.vouchSessionKeys(<String, String>{'200::b': _key}, force: false);
      runtime.vouchSessionKeys(<String, String>{'200::b': _key}, force: false);
      await Future<void>.delayed(Duration.zero);
      expect(conflicts, <String>[bob]);
      expect(pinned[bob], _other);

      // Forced: the signed key replaces the pin.
      runtime.vouchSessionKeys(<String, String>{'200::b': _key}, force: true);
      expect(calls.last.$2, isFalse);
      expect(pinned[bob], _key);
    },
  );

  test(
    'keys only a friend\'s list names go to the bridge as hints, never as pins',
    () async {
      final List<(Map<String, String>, bool)> pinCalls =
          <(Map<String, String>, bool)>[];
      final List<Map<String, String>> hintCalls = <Map<String, String>>[];
      final String bob = PeerShareCodec.normalizeAddress('200::b');
      final String carol = PeerShareCodec.normalizeAddress('200::c');
      int starts = 0;
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
        bootstrap: () async {
          starts++;
          return RuntimeNodeSession(
            transport: MemorySignalTransport(),
            snapshot: RuntimeTransportSnapshot.started(
              localAddress: '200::1',
              peers: 1,
            ),
            sessionKey: _key,
            pinSessionKeys: (Map<String, String> pins, bool keep) {
              pinCalls.add((Map<String, String>.of(pins), keep));
              return const <String, String>{};
            },
            hintSessionKeys: (Map<String, String> hints) {
              hintCalls.add(Map<String, String>.of(hints));
              // The bridge pinned another key for Bob from his own record.
              return <String, String>{
                if (hints[bob] != null && hints[bob] != _other) bob: _other,
              };
            },
          );
        },
      );
      addTearDown(runtime.dispose);
      final List<String> conflicts = <String>[];
      runtime.sessionKeyConflicts.listen(conflicts.add);

      // Before the node is up: kept, handed over as hints on start. One
      // that contradicts a pin is someone's word against the device's own:
      // nobody is warned about the device.
      runtime.vouchSessionKeys(<String, String>{'200::b': _key});
      await runtime.start();
      expect(starts, 1);
      expect(pinCalls, isEmpty);
      expect(hintCalls.single, <String, String>{bob: _key});
      await Future<void>.delayed(Duration.zero);
      expect(conflicts, isEmpty);

      // While it runs: at once, and never as a pin.
      runtime.vouchSessionKeys(<String, String>{'200::c': _key});
      expect(hintCalls.last, <String, String>{carol: _key});
      expect(pinCalls, isEmpty);

      // A signed record for the same address makes it a vouch: a list's
      // word on it is no longer handed over.
      runtime.vouchSessionKeys(<String, String>{'200::c': _key}, force: false);
      expect(pinCalls.single.$1, <String, String>{carol: _key});
      expect(pinCalls.single.$2, isTrue);
      final int hinted = hintCalls.length;
      runtime.vouchSessionKeys(<String, String>{'200::c': _other});
      expect(hintCalls.length, hinted);
    },
  );

  test('hints go with the friend who gave them; known peers are named to '
      'the bridge, again after every start', () async {
    final List<Map<String, String>> hintCalls = <Map<String, String>>[];
    final List<Map<String, String>> dropCalls = <Map<String, String>>[];
    final List<List<String>> knownCalls = <List<String>>[];
    final String carol = PeerShareCodec.normalizeAddress('200::c');
    final String dan = PeerShareCodec.normalizeAddress('200::d');
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
      bootstrap: () async => RuntimeNodeSession(
        transport: MemorySignalTransport(),
        snapshot: RuntimeTransportSnapshot.started(
          localAddress: '200::1',
          peers: 1,
        ),
        sessionKey: _key,
        pinSessionKeys: (Map<String, String> pins, bool keep) =>
            const <String, String>{},
        hintSessionKeys: (Map<String, String> hints) {
          hintCalls.add(Map<String, String>.of(hints));
          return const <String, String>{};
        },
        dropSessionKeyHints: (Map<String, String> hints) =>
            dropCalls.add(Map<String, String>.of(hints)),
        setKnownPeers: (List<String> known) =>
            knownCalls.add(List<String>.of(known)),
      ),
    );
    addTearDown(runtime.dispose);

    runtime.setKnownPeers(<String>['200:0:0:0:0:0:0:b', '200::b']);
    runtime
      ..replaceSessionKeyHints('200::b', <String, String>{
        '200::c': _key,
        '200::d': _key,
      })
      ..replaceSessionKeyHints(
        sessionKeySourceOfAccount('acc'),
        <String, String>{'200::d': _other},
      );
    await runtime.start();
    expect(knownCalls.single, <String>[
      PeerShareCodec.normalizeAddress('200::b'),
    ]);
    expect(hintCalls.single, <String, String>{carol: _key, dan: _other});

    // The friend at 200::b is removed: what only it named goes; what the
    // account's records name stays.
    runtime.keepSessionKeyHintsOf(<String>{sessionKeySourceOfAccount('acc')});
    expect(dropCalls.single, <String, String>{carol: _key});
    expect(hintCalls, hasLength(1));
    // The account goes too.
    runtime.keepSessionKeyHintsOf(const <String>{});
    expect(dropCalls.last, <String, String>{dan: _other});

    // A friend's new list in full: what it no longer names goes.
    runtime
      ..replaceSessionKeyHints('200::e', <String, String>{
        '200::c': _key,
        '200::d': _key,
      })
      ..replaceSessionKeyHints('200::e', <String, String>{'200::d': _key});
    expect(dropCalls.last, <String, String>{carol: _key});

    // The same known peers again: nothing to say.
    runtime.setKnownPeers(<String>['200::b']);
    expect(knownCalls, hasLength(1));
    runtime.setKnownPeers(const <String>[]);
    expect(knownCalls.last, isEmpty);
  });

  test('the bridge answer to a pin request is read', () {
    expect(
      sessionKeyConflictsFrom(<String, dynamic>{
        'taken': 1,
        'conflicts': <String, dynamic>{'200::b': _other, 'x': 3},
      }),
      <String, String>{'200::b': _other},
    );
    expect(sessionKeyConflictsFrom(<String, dynamic>{}), isEmpty);
  });

  test('the locked inbox keeps the sender\'s device key', () {
    final SignalTransportFrame frame = SignalTransportFrame(
      from: '200::b',
      payload: const <String, dynamic>{'type': 'message'},
      receivedAtMillis: 5,
      senderKey: _key,
    );
    final SignalTransportFrame? again = decodeInboxFrame(
      encodeInboxFrame(frame),
    );
    expect(again?.senderKey, _key);
    expect(
      decodeInboxFrame(
        encodeInboxFrame(
          const SignalTransportFrame(
            from: '200::b',
            payload: <String, dynamic>{},
            receivedAtMillis: 5,
          ),
        ),
      )?.senderKey,
      isNull,
    );
  });
}
