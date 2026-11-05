import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// Where scheduled messages wait (in the encrypted store, this device only).
const String kScheduledMessagesKey = 'chat/scheduled';

/// The most messages that may wait.
const int kMaxScheduledMessages = 200;

/// A message written now that goes at [atMillis].
@immutable
final class ScheduledMessage {
  const ScheduledMessage({
    required this.id,
    required this.to,
    required this.text,
    required this.atMillis,
  });

  final String id;

  /// The friend's address.
  final String to;
  final String text;
  final int atMillis;

  Map<String, Object?> toJson() => <String, Object?>{
    'to': to,
    't': text,
    'a': atMillis,
  };

  static ScheduledMessage? fromJson(String id, Object? json) {
    if (json is! Map ||
        json['to'] is! String ||
        json['t'] is! String ||
        json['a'] is! int) {
      return null;
    }
    return ScheduledMessage(
      id: id,
      to: json['to'] as String,
      text: json['t'] as String,
      atMillis: json['a'] as int,
    );
  }
}

/// "Wyślij później": messages to friends written now and sent at a chosen
/// time. They wait on this device and go when Zen runs at that time, or
/// as soon as it opens after it; [send] is the chat's own send, so they go
/// the way any message goes (the outbox, the mailboxes).
final class ScheduledMessagesService extends ChangeNotifier {
  ScheduledMessagesService({
    required this.disk,
    required this.send,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final LedgerDisk disk;

  /// Sends [text] to the friend at [to] now.
  final Future<void> Function(String to, String text) send;
  final int Function() _now;
  final Random _random;

  Map<String, ScheduledMessage> _waiting = <String, ScheduledMessage>{};
  bool _loaded = false;
  bool _started = false;
  Timer? _timer;
  Future<void>? _sending;

  /// What waits for [address], the soonest first; everything without one.
  List<ScheduledMessage> waiting([String? address]) =>
      _waiting.values
          .where(
            (ScheduledMessage m) =>
                address == null || PeerShareCodec.addressesEqual(m.to, address),
          )
          .toList()
        ..sort(
          (ScheduledMessage a, ScheduledMessage b) =>
              a.atMillis.compareTo(b.atMillis),
        );

  Future<void> load() async {
    Map<String, ScheduledMessage> read = <String, ScheduledMessage>{};
    try {
      final Uint8List? raw = await disk.read(kScheduledMessagesKey);
      if (raw != null) {
        final Object? json = jsonDecode(utf8.decode(raw));
        if (json is Map) {
          read = <String, ScheduledMessage>{
            for (final MapEntry<dynamic, dynamic> e in json.entries)
              if (e.key is String)
                if (ScheduledMessage.fromJson(e.key as String, e.value)
                    case final ScheduledMessage m)
                  m.id: m,
          };
        }
      }
    } on Object catch (error) {
      logZenWarning('Reading the scheduled messages failed: $error');
    }
    _waiting = read;
    _loaded = true;
    notifyListeners();
  }

  /// Schedules [text] to the friend at [to] for [atMillis].
  Future<ScheduledMessage?> schedule({
    required String to,
    required String text,
    required int atMillis,
  }) async {
    final String clean = text.trim();
    if (clean.isEmpty) {
      return null;
    }
    await _ensureLoaded();
    if (_waiting.length >= kMaxScheduledMessages) {
      throw StateError('Too many scheduled messages');
    }
    final ScheduledMessage m = ScheduledMessage(
      id: '${_now().toRadixString(36)}-${_random.nextInt(1 << 30).toRadixString(36)}',
      to: PeerShareCodec.normalizeAddress(to),
      text: clean,
      atMillis: atMillis,
    );
    _waiting = <String, ScheduledMessage>{..._waiting, m.id: m};
    await _save();
    return m;
  }

  /// Takes the scheduled message [id] back.
  Future<void> cancel(String id) async {
    await _ensureLoaded();
    if (_waiting.remove(id) != null) {
      await _save();
    }
  }

  /// Sends what is due, then waits for the next one while Zen runs: one
  /// timer at its time, none while nothing waits (no ticking for nothing).
  void start() {
    _started = true;
    unawaited(sendDue());
  }

  void stop() {
    _started = false;
    _timer?.cancel();
    _timer = null;
  }

  /// The timer for the soonest message. At most an hour: a phone's timers
  /// stand still while it sleeps, so a long one is checked again (and
  /// [sendDue] runs when Zen comes back to the screen too).
  void _plan() {
    _timer?.cancel();
    _timer = null;
    if (!_started || _waiting.isEmpty) {
      return;
    }
    final int soonest = _waiting.values
        .map((ScheduledMessage m) => m.atMillis)
        .reduce(min);
    final int wait = (soonest - _now()).clamp(
      0,
      const Duration(hours: 1).inMilliseconds,
    );
    _timer = Timer(Duration(milliseconds: wait), () => unawaited(sendDue()));
  }

  /// Sends every message whose time came (one run at a time). A message
  /// whose send fails stays and is tried on the next run.
  Future<void> sendDue() => _sending ??= _sendDue().whenComplete(() {
    _sending = null;
  });

  Future<void> _sendDue() async {
    await _ensureLoaded();
    final int now = _now();
    final List<ScheduledMessage> due = waiting()
        .where((ScheduledMessage m) => m.atMillis <= now)
        .toList();
    for (final ScheduledMessage m in due) {
      try {
        await send(m.to, m.text);
        _waiting.remove(m.id);
        await _save();
      } on Object catch (error) {
        logZenWarning('Sending a scheduled message failed: $error');
      }
    }
    // A failed one is tried again in a minute at the soonest.
    if (_waiting.values.any((ScheduledMessage m) => m.atMillis <= now)) {
      _timer?.cancel();
      _timer = _started
          ? Timer(const Duration(minutes: 1), () => unawaited(sendDue()))
          : null;
    } else {
      _plan();
    }
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) {
      await load();
    }
  }

  Future<void> _save() async {
    await disk.write(
      kScheduledMessagesKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            for (final ScheduledMessage m in _waiting.values) m.id: m.toJson(),
          }),
        ),
      ),
    );
    if (_sending == null) {
      _plan();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// This account's scheduled messages, sent through the chat as any other.
final Provider<ScheduledMessagesService> scheduledMessagesProvider =
    Provider<ScheduledMessagesService>((Ref ref) {
      final ScheduledMessagesService service = ScheduledMessagesService(
        disk: ref.read(ledgerDiskProvider),
        send: (String to, String text) => ref
            .read(socialHubControllerProvider.notifier)
            .sendLocalMessage(peerAddress: to, text: text),
      );
      ref.onDispose(service.dispose);
      return service;
    });
