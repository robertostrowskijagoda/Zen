import 'dart:async';
import 'dart:io';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/relay/locked_outbox.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Where the [LockedOutboxKit] is kept: sealed with the background key,
/// like the alarm and door kits. It holds only envelopes sealed for their
/// recipients and where they go.
BackgroundKitFile lockedOutboxKitFile({
  required Future<Directory> Function() supportDirectory,
  required AppSecurityCredentialsStore credentials,
  bool createKey = false,
}) => BackgroundKitFile(
  supportDirectory: supportDirectory,
  credentials: credentials,
  storageKey: 'background/outbox-kit',
  fileName: 'outbox-kit.zenbg',
  createKey: createKey,
);

/// Keeps the [LockedOutboxKit] in step with the unlocked app's queue: written
/// a little after the queue changes (several messages in a row make one
/// write), and at once with [flush] — the app calls it before it hands the
/// node to the locked service.
final class LockedOutboxKitWriter {
  LockedOutboxKitWriter({
    required this.engine,
    required Future<void> Function(Object? json) write,
    this.debounce = const Duration(seconds: 3),
  }) : _write = write;

  final RelayEngine engine;
  final Future<void> Function(Object? json) _write;
  final Duration debounce;

  Timer? _timer;
  Future<void> _writing = Future<void>.value();
  String? _written;
  bool _attached = false;

  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    engine.outboxRevision.addListener(_changed);
    _changed();
  }

  void detach() {
    if (!_attached) {
      return;
    }
    _attached = false;
    engine.outboxRevision.removeListener(_changed);
    _timer?.cancel();
    _timer = null;
  }

  void _changed() {
    _timer?.cancel();
    _timer = Timer(debounce, () {
      _timer = null;
      unawaitedLogged(flush(), context: 'Writing the outbox kit failed');
    });
  }

  /// Writes the kit now (unless it says what the stored one says).
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _writing = _writing.then((_) async {
      try {
        final LockedOutboxKit kit = await engine.lockedOutboxKit();
        final String signature = kit.signature;
        if (signature == _written) {
          return;
        }
        await _write(kit.toJson());
        _written = signature;
      } on Object catch (error, stackTrace) {
        logZenError('Writing the outbox kit failed', error, stackTrace);
      }
    });
    return _writing;
  }
}
