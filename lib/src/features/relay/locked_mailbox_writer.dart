import 'dart:async';
import 'dart:io';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Where the app leaves the [LockedMailboxKit] for the locked service:
/// sealed with the background key, like the outbox kit. Only the app writes
/// it.
BackgroundKitFile lockedMailboxKitFile({
  required Future<Directory> Function() supportDirectory,
  required AppSecurityCredentialsStore credentials,
  bool createKey = false,
}) => BackgroundKitFile(
  supportDirectory: supportDirectory,
  credentials: credentials,
  storageKey: 'background/mailbox-kit',
  fileName: 'mailbox-kit.zenbg',
  createKey: createKey,
);

/// Where the locked service keeps what it holds as this device's mailbox
/// (the same [LockedMailboxKit] shape). Only the service writes it; the app
/// takes it over ([RelayEngine.takeLockedMailbox]) and never deletes it:
/// taking it again changes nothing, and the service starts from it and the
/// app's kit together.
BackgroundKitFile lockedMailboxHeldFile({
  required Future<Directory> Function() supportDirectory,
  required AppSecurityCredentialsStore credentials,
}) => BackgroundKitFile(
  supportDirectory: supportDirectory,
  credentials: credentials,
  storageKey: 'background/mailbox-held',
  fileName: 'mailbox-held.zenbg',
);

/// Keeps the [LockedMailboxKit] in step with the unlocked app: written
/// [delay] after the mailbox changes, and at once with [flush] (before the
/// app hands the node to the locked service). [takeHeld] brings in what the
/// service held meanwhile; [attach] does that first.
final class LockedMailboxKitWriter {
  LockedMailboxKitWriter({
    required this.engine,
    required Future<void> Function(Object? json) write,
    required Future<Object?> Function() readHeld,
    this.delay = const Duration(seconds: 10),
  }) : _write = write,
       _readHeld = readHeld;

  final RelayEngine engine;
  final Future<void> Function(Object? json) _write;
  final Future<Object?> Function() _readHeld;

  /// Every message that comes in changes the kit (what this device took):
  /// changes within this time make one write, and the handoff flushes.
  final Duration delay;

  Timer? _timer;
  Future<void> _writing = Future<void>.value();
  String? _written;
  bool _attached = false;

  void attach() {
    if (_attached) {
      return;
    }
    _attached = true;
    engine.lockedMailboxRevision.addListener(_changed);
    unawaitedLogged(
      takeHeld().whenComplete(_changed),
      context: 'Taking over the locked mailbox failed',
    );
  }

  void detach() {
    if (!_attached) {
      return;
    }
    _attached = false;
    engine.lockedMailboxRevision.removeListener(_changed);
    _timer?.cancel();
    _timer = null;
  }

  /// Takes over what the locked service held (nothing when it never ran).
  Future<void> takeHeld() async {
    try {
      await engine.takeLockedMailbox(
        LockedMailboxKit.fromJson(await _readHeld()),
      );
    } on Object catch (error, stackTrace) {
      logZenError('Taking over the locked mailbox failed', error, stackTrace);
    }
  }

  void _changed() {
    // Not pushed further by more changes meanwhile: they ride on it.
    if (!_attached || _timer != null) {
      return;
    }
    _timer = Timer(delay, () {
      _timer = null;
      unawaitedLogged(flush(), context: 'Writing the mailbox kit failed');
    });
  }

  /// Writes the kit now (unless it says what the stored one says).
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    _writing = _writing.then((_) async {
      try {
        // Without its own address (the node is not up yet) or the friends
        // (not read yet) this device would seem to serve nobody: the stored
        // kit stays.
        if (!engine.knowsFriends) {
          return;
        }
        final LockedMailboxKit kit = await engine.lockedMailboxKit();
        final String signature = kit.signature;
        if (kit.self.isEmpty || signature == _written) {
          return;
        }
        await _write(kit.toJson());
        _written = signature;
      } on Object catch (error, stackTrace) {
        logZenError('Writing the mailbox kit failed', error, stackTrace);
      }
    });
    return _writing;
  }
}
