import 'dart:async';
import 'dart:convert';

import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// The pyramid state of one device for the account's other devices:
/// sealed [PyramidService.sharedState] in the account's `own` space.
const String kPyramidShareKind = 'pyramid_state';

/// Keeps the pyramid the same on every device of the account: the
/// devices hold the same pyramid key, and with this they also know
/// the same membership, records and votes in progress, so the person can
/// act from any of them.
///
/// After a change (and when a device joins the account) this device's
/// [PyramidService.sharedState] is sealed into the account's `own` space;
/// what another device saved there is merged in with
/// [PyramidService.mergeFromOwnDevice], which only adds — a vote cast on
/// one device stays cast on all of them.
final class PyramidDeviceSync {
  PyramidDeviceSync({
    required this.node,
    required this.pyramid,
    this.delay = const Duration(seconds: 5),
  });

  final LedgerNode node;
  final PyramidService pyramid;

  /// Quiet time after a change before the state is saved for the others.
  final Duration delay;

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  Timer? _timer;
  Future<void> _queue = Future<void>.value();
  bool _stopped = false;

  /// The state as last saved for the other devices (JSON).
  String? _published;

  Future<void> start() async {
    await node.start();
    if (_stopped) {
      return;
    }
    _subs
      ..add(
        node.ownEntries.listen((LogEntry e) {
          if (e.kind == kPyramidShareKind) {
            _enqueue(() => _apply(e));
          }
        }),
      )
      ..add(node.devicesChanged.listen((_) => _schedule()));
    pyramid.addListener(_schedule);
    // What the other devices saved while this one was away: their newest
    // state each (merging only adds, so taking one twice changes nothing).
    for (final LogEntry e in _newestPerDevice()) {
      _enqueue(() => _apply(e));
    }
    _schedule();
  }

  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    pyramid.removeListener(_schedule);
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  /// Waits until everything queued so far is done (tests).
  Future<void> get idle => _queue;

  /// Saves the state for the other devices now (tests; normally after
  /// [delay]).
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _enqueue(_publish);
    return _queue;
  }

  void _schedule() {
    if (_stopped) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      _enqueue(_publish);
    });
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      if (_stopped) {
        return;
      }
      try {
        await work();
      } on Object catch (error, stack) {
        logZenError('Pyramid on the account devices', error, stack);
      }
    });
  }

  Iterable<LogEntry> _newestPerDevice() {
    if (!node.isReady) {
      return const <LogEntry>[];
    }
    final String own = node.identity.deviceKey.id;
    final Map<String, LogEntry> newest = <String, LogEntry>{};
    for (final LogEntry e in node.store.entries(
      accountSpace('own', node.account),
    )) {
      if (e.kind != kPyramidShareKind || e.device == own) {
        continue;
      }
      final LogEntry? had = newest[e.device];
      if (had == null || e.hlc > had.hlc) {
        newest[e.device] = e;
      }
    }
    return newest.values;
  }

  Future<void> _apply(LogEntry e) async {
    final Map<String, dynamic>? body = node.bodyOf(e);
    if (body == null) {
      return;
    }
    final bool changed = await pyramid.mergeFromOwnDevice(body);
    await node.markOwnApplied(e.id);
    if (changed && body['fol'] is int) {
      // Kept here now too: its records come from friends who keep it.
      await pyramid.greet();
    }
  }

  Future<void> _publish() async {
    // Only for a device that has other devices: a device linked later is
    // told through [LedgerNode.devicesChanged].
    if (node.ownDevices.length < 2) {
      return;
    }
    final Map<String, dynamic>? state = pyramid.sharedState();
    if (state == null) {
      return;
    }
    final String json = jsonEncode(state);
    if (json == _published) {
      return;
    }
    if (await node.publishForOwnDevices(kPyramidShareKind, state) != null) {
      _published = json;
    }
  }
}
