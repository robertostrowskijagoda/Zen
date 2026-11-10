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

      // Before the node is up: kept, handed over as hints on start.
      runtime.vouchSessionKeys(<String, String>{'200::b': _key});
      await runtime.start();
      expect(starts, 1);
      expect(pinCalls, isEmpty);
      expect(hintCalls.single, <String, String>{bob: _key});
      await Future<void>.delayed(Duration.zero);
      expect(conflicts, <String>[bob]);

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
