import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';

/// The choices offered for disappearing messages (seconds; 0 = off).
const List<int> kDisappearChoices = <int>[0, 3600, 86400, 604800];

/// The longest timer accepted from a peer (4 weeks).
const int kMaxDisappearSeconds = 28 * 86400;

/// A timer as people say it.
String disappearLabel(int seconds) {
  if (seconds <= 0) {
    return t('wyłączone');
  }
  if (seconds % 86400 == 0) {
    final int days = seconds ~/ 86400;
    return tn(days, one: '{n} dzień', few: '{n} dni', many: '{n} dni');
  }
  if (seconds % 3600 == 0) {
    final int hours = seconds ~/ 3600;
    return tn(hours, one: '{n} godzina', few: '{n} godz.', many: '{n} godz.');
  }
  final int minutes = (seconds / 60).ceil();
  return tn(minutes, one: '{n} min', few: '{n} min', many: '{n} min');
}

/// A timer received from someone else: clamped to what the app offers.
int sanitizeDisappearSeconds(Object? raw) {
  if (raw is! int || raw <= 0) {
    return 0;
  }
  return raw.clamp(60, kMaxDisappearSeconds);
}

/// How long a disappeared message is remembered after it expired: the
/// longest a mailbox keeps a copy (two weeks, see `RelayEngine.messageTtl`)
/// and a day for clocks that differ. A copy can only be on its way that long.
const Duration kDisappearedMemory = Duration(days: 15);

/// The most disappeared messages remembered (the oldest go first).
const int kMaxDisappearedMessages = 2000;

/// How a disappeared message is remembered: `<conversation key>|<id>`.
String disappearedMessageKey(String key, String id) => '$key|$id';

/// [remembered] (key → when the message expired) with message [id] of
/// conversation [key] added, less what no copy can reach any more and the
/// oldest past [kMaxDisappearedMessages].
Map<String, int> rememberDisappeared(
  Map<String, int> remembered, {
  required String key,
  required String id,
  required int expiredAtMillis,
  required int nowMillis,
}) {
  final int forgetBefore = nowMillis - kDisappearedMemory.inMilliseconds;
  final Map<String, int> next = <String, int>{
    for (final MapEntry<String, int> e in remembered.entries)
      if (e.value >= forgetBefore) e.key: e.value,
  };
  next[disappearedMessageKey(key, id)] = expiredAtMillis;
  if (next.length > kMaxDisappearedMessages) {
    final List<MapEntry<String, int>> oldestFirst = next.entries.toList()
      ..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) =>
            a.value.compareTo(b.value),
      );
    for (final MapEntry<String, int> e in oldestFirst.take(
      next.length - kMaxDisappearedMessages,
    )) {
      next.remove(e.key);
    }
  }
  return next;
}

/// The timeline store with disappearing messages:
///
/// * a new message in a conversation with a timer gets its expiry (now +
///   the timer) as it is stored — whichever way it came (sent, received,
///   copied from another own device);
/// * expired messages are never shown again, even before they are swept;
/// * [sweep] deletes them for good, and [onExpired] removes their files.
final class DisappearingTimelineStore implements MessageTimelineStore {
  DisappearingTimelineStore(this.delegate, {int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MessageTimelineStore delegate;
  final int Function() _now;

  /// Seconds messages in a conversation live (0 = they stay); set by the
  /// social hub, which knows the conversations.
  int Function(String key) timerFor = _off;

  /// A message was deleted because it expired (to remove its files).
  Future<void> Function(String key, ChatMessage message)? onExpired;

  /// A message got an expiry (to plan the sweep).
  void Function(int expiresAtMillis)? onStamped;

  static int _off(String key) => 0;

  /// The store underneath [store], past any [DisappearingTimelineStore].
  static MessageTimelineStore unwrap(MessageTimelineStore store) =>
      store is DisappearingTimelineStore ? unwrap(store.delegate) : store;

  ChatMessage _stamp(String key, ChatMessage m) {
    if (m.expiresAtMillis != null || m.isSystem) {
      return m;
    }
    final int seconds = timerFor(key);
    if (seconds <= 0) {
      return m;
    }
    final int at = _now() + seconds * 1000;
    onStamped?.call(at);
    return m.copyWith(expiresAtMillis: at);
  }

  @override
  Future<List<ChatMessage>> load(String peerAddress) async {
    final List<ChatMessage> all = await delegate.load(peerAddress);
    final int now = _now();
    if (!all.any((ChatMessage m) => m.isExpiredAt(now))) {
      return all;
    }
    return List<ChatMessage>.unmodifiable(
      all.where((ChatMessage m) => !m.isExpiredAt(now)),
    );
  }

  @override
  Future<void> append(String peerAddress, ChatMessage message) =>
      delegate.append(peerAddress, _stamp(peerAddress, message));

  @override
  Future<void> save(String peerAddress, List<ChatMessage> messages) async {
    final List<ChatMessage> before = await delegate.load(peerAddress);
    final Set<String> had = <String>{for (final ChatMessage m in before) m.id};
    final List<ChatMessage> next = <ChatMessage>[
      for (final ChatMessage m in messages)
        had.contains(m.id) ? m : _stamp(peerAddress, m),
    ];
    await delegate.save(peerAddress, List<ChatMessage>.unmodifiable(next));
    // Expired ones the caller never saw (load hides them) are gone now:
    // their files go too.
    final Set<String> kept = <String>{for (final ChatMessage m in next) m.id};
    final int now = _now();
    for (final ChatMessage m in before) {
      if (!kept.contains(m.id) && m.isExpiredAt(now)) {
        await _expired(peerAddress, m);
      }
    }
  }

  Future<void> _expired(String key, ChatMessage m) async {
    try {
      await onExpired?.call(key, m);
    } on Object catch (error, stack) {
      logZenError('Deleting a disappearing message', error, stack);
    }
  }

  /// Deletes every expired message in [keys]; returns how many.
  Future<int> sweep(Iterable<String> keys) async {
    final int now = _now();
    int removed = 0;
    for (final String key in keys) {
      final List<ChatMessage> all = await delegate.load(key);
      final List<ChatMessage> expired = <ChatMessage>[
        for (final ChatMessage m in all)
          if (m.isExpiredAt(now)) m,
      ];
      if (expired.isEmpty) {
        continue;
      }
      await delegate.save(
        key,
        List<ChatMessage>.unmodifiable(
          all.where((ChatMessage m) => !m.isExpiredAt(now)),
        ),
      );
      for (final ChatMessage m in expired) {
        await _expired(key, m);
      }
      removed += expired.length;
    }
    return removed;
  }

  /// Whether message [id] of [key] expired but is still on file (hidden,
  /// not swept yet).
  Future<bool> holdsExpired(String key, String id) async {
    final int now = _now();
    return (await delegate.load(
      key,
    )).any((ChatMessage m) => m.id == id && m.isExpiredAt(now));
  }

  /// When the next message in [keys] expires, if any does.
  Future<int?> nextExpiry(Iterable<String> keys) async {
    int? next;
    for (final String key in keys) {
      for (final ChatMessage m in await delegate.load(key)) {
        final int? at = m.expiresAtMillis;
        if (at != null && (next == null || at < next)) {
          next = at;
        }
      }
    }
    return next;
  }
}
