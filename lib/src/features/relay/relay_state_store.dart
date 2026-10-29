import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/relay/relay_models.dart';

abstract interface class RelayStateStore {
  Future<RelayState> load();

  Future<void> save(RelayState state);
}

/// Storage for the sealed chunks of attachments that travel through
/// mailboxes (see `RelayEngine.submitAttachment`): the ones this device
/// sends, holds for friends, or is collecting. Kept out of [RelayState] so
/// that megabytes of ciphertext are never part of the state document.
///
/// Keys are short `/`-separated lowercase hex paths made by the engine.
abstract interface class RelayBlobStore {
  Future<void> writeBlobChunk(String key, Uint8List bytes);

  Future<Uint8List?> readBlobChunk(String key);

  Future<void> deleteBlobChunk(String key);
}

/// Outbox payloads whose JSON is at least this long (an attachment) are
/// kept in a file of their own (`relay/out/<id>`), written once, instead of
/// inside `relay/state`.
const int kRelayInlinePayloadChars = 4 * 1024;

/// The most bytes of payloads the outbox holds (big payloads only: small
/// ones, like receipts, always fit). Past it a new message is refused with
/// [RelayOutboxFullException] instead of growing the queue without end.
const int kRelayOutboxMaxBytes = 32 * 1024 * 1024;

/// A message did not fit into the outbox ([kRelayOutboxMaxBytes]): too much
/// is still waiting for recipients who have been offline. The chat shows
/// the message as not sent.
final class RelayOutboxFullException implements Exception {
  const RelayOutboxFullException();

  @override
  String toString() => t(
    'Kolejka wysyłki jest pełna. Poczekaj, aż znajomi odbiorą to, '
    'co czeka, i spróbuj ponownie.',
  );
}

/// The format of `relay/state` written and read.
const int kRelayStateFormat = 1;

/// Relay state in the app's (optionally encrypted) binary store.
///
/// Split so a busy relay does not rewrite megabytes per message:
///
/// * `relay/state` — identity, relay directory, outbox entries, receipts
///   (small);
/// * `relay/out/<id>` — the payload of a big outbox entry (an attachment),
///   written once when it is queued and deleted when it leaves;
/// * `relay/mail/<peer>` — ciphertext held for one friend, written only when
///   that friend's mail actually changed.
///
/// Every file is written aside and moved into place ([FileBinaryStore]);
/// payloads go first, so the state never names one that is not on disk.
///
/// Both the UI isolate and the Android background service use this store;
/// only the one owning the mesh node writes, and it reloads when it takes the
/// node over.
final class FileRelayStateStore implements RelayStateStore, RelayBlobStore {
  FileRelayStateStore({required this.store, this.storageKey = 'relay/state'});

  final FileBinaryStore store;
  final String storageKey;

  /// Last content written or read per key; unchanged documents are skipped.
  final Map<String, String> _lastContent = <String, String>{};

  /// Outbox entries whose payload is in a file of its own on disk.
  final Set<String> _payloadFiles = <String>{};

  String _mailKey(String recipient) =>
      'relay/mail/${base64Url.encode(utf8.encode(recipient)).replaceAll('=', '')}';

  static String _payloadKey(String rid) =>
      'relay/out/${base64Url.encode(utf8.encode(rid)).replaceAll('=', '')}';

  /// What can be read: a damaged file (neither it nor its backup reads)
  /// is set aside ([FileBinaryStore.quarantine]) and left out — the state
  /// itself starts fresh, a big payload's message is dropped from the
  /// outbox, a friend's held mail is gone — and the rest loads. Never
  /// throws for damage: the engine loads the state before every send, and
  /// one bad file must not stop everything from going out. A newer build's
  /// state still throws (it is kept; a fresh one would announce a new
  /// identity to every friend).
  @override
  Future<RelayState> load() async {
    _lastContent.clear();
    _payloadFiles.clear();
    final String? core;
    try {
      core = await _readString(storageKey);
    } on NewerFormatException {
      rethrow;
    } on FormatException catch (error, stackTrace) {
      await store.quarantine(storageKey);
      return _fresh(error, stackTrace);
    }
    if (core == null) {
      return RelayState();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(core);
    } on FormatException catch (error, stackTrace) {
      await store.quarantine(storageKey);
      return _fresh(error, stackTrace);
    }
    if (store.heldAsNewer(storageKey, decoded, current: kRelayStateFormat)) {
      // A newer build's state (its identity, its queue): kept as it is.
      // Starting fresh here would announce a new identity to every friend.
      throw NewerFormatException(
        storageKey,
        found: (decoded as Map)['v'],
        supported: kRelayStateFormat,
      );
    }
    final RelayState state;
    try {
      if (decoded is Map && decoded['out'] is List) {
        final List<Object?> out = <Object?>[];
        for (final Object? item in decoded['out'] as List) {
          if (item is Map && item['pf'] != null && item['rid'] is String) {
            final String rid = item['rid'] as String;
            final Object? payload = await _readJson(
              _payloadKey(rid),
              remember: false,
            );
            if (payload is! Map) {
              // Its payload is gone or damaged: nothing left to send.
              continue;
            }
            _payloadFiles.add(rid);
            out.add(<String, dynamic>{
              ...Map<String, dynamic>.from(item),
              'p': payload,
            });
          } else {
            out.add(item);
          }
        }
        decoded['out'] = out;
      }
      state = RelayState.fromJson(decoded);
    } catch (error, stackTrace) {
      await store.quarantine(storageKey);
      return _fresh(error, stackTrace);
    }
    final List<String> recipients = decoded is Map && decoded['mbx'] is List
        ? (decoded['mbx'] as List).whereType<String>().toList()
        : const <String>[];
    for (final String recipient in recipients) {
      final Object? mail = await _readJson(_mailKey(recipient));
      if (mail is! Map) {
        continue;
      }
      final Map<String, Map<String, dynamic>> held =
          <String, Map<String, dynamic>>{};
      mail.forEach((Object? id, Object? envelope) {
        if (id is String && envelope is Map) {
          held[id] = Map<String, dynamic>.from(envelope);
        }
      });
      if (held.isNotEmpty) {
        state.mailbox[recipient] = held;
      }
    }
    return state;
  }

  /// The JSON in [key]; null when it is missing, a newer build's, or
  /// damaged (then set aside: [FileBinaryStore.readOrSetAside]).
  Future<Object?> _readJson(String key, {bool remember = true}) async {
    final Uint8List? bytes = await store.readOrSetAside(key);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    try {
      final String content = utf8.decode(bytes);
      final Object? json = jsonDecode(content);
      if (remember) {
        _lastContent[key] = content;
      }
      return json;
    } on FormatException {
      logZenWarning('A relay file holds no JSON; left out.');
      await store.quarantine(key);
      return null;
    }
  }

  RelayState _fresh(Object error, StackTrace stackTrace) {
    // A corrupt file must not take messaging down; start over (the
    // identity is regenerated and re-announced to every friend).
    logZenError('Relay state is unreadable; starting fresh', error, stackTrace);
    return RelayState();
  }

  @override
  Future<void> save(RelayState state) async {
    final Set<String> previousRecipients = _lastContent.keys
        .where((String key) => key.startsWith('relay/mail/'))
        .toSet();
    for (final MapEntry<String, Map<String, Map<String, dynamic>>> entry
        in state.mailbox.entries) {
      final String key = _mailKey(entry.key);
      previousRecipients.remove(key);
      await _writeIfChanged(key, jsonEncode(entry.value));
    }
    for (final String stale in previousRecipients) {
      _lastContent.remove(stale);
      await store.delete(stale);
    }
    // Big payloads apart: written once (before the state that names them).
    final Map<String, String> newPayloads = <String, String>{};
    Map<String, dynamic> outboxEntry(RelayOutboxEntry entry) {
      final Map<String, dynamic> json = entry.toJson();
      if (!_payloadFiles.contains(entry.rid)) {
        final String payload = jsonEncode(entry.payload);
        if (payload.length < kRelayInlinePayloadChars) {
          return json;
        }
        newPayloads[entry.rid] = payload;
      }
      return json
        ..remove('p')
        ..['pf'] = 1;
    }

    final String core = state.toJsonString(
      includeMailbox: false,
      outboxEntry: outboxEntry,
      extra: <String, dynamic>{'mbx': state.mailbox.keys.toList()},
    );
    for (final MapEntry<String, String> payload in newPayloads.entries) {
      await store.write(
        _payloadKey(payload.key),
        Uint8List.fromList(utf8.encode(payload.value)),
      );
      _payloadFiles.add(payload.key);
    }
    await _writeIfChanged(storageKey, core);
    // Payloads of entries that left the outbox.
    for (final String rid in _payloadFiles.toList()) {
      if (!state.outbox.containsKey(rid)) {
        _payloadFiles.remove(rid);
        await store.delete(_payloadKey(rid));
      }
    }
  }

  // Blob chunks live next to the state as one file each: `relay/blob/<key>`.

  @override
  Future<void> writeBlobChunk(String key, Uint8List bytes) async {
    await store.write('relay/blob/$key', bytes);
  }

  @override
  Future<Uint8List?> readBlobChunk(String key) => store.read('relay/blob/$key');

  @override
  Future<void> deleteBlobChunk(String key) => store.delete('relay/blob/$key');

  Future<void> _writeIfChanged(String key, String content) async {
    if (_lastContent[key] == content) {
      return;
    }
    await store.write(key, Uint8List.fromList(utf8.encode(content)));
    _lastContent[key] = content;
  }

  Future<String?> _readString(String key, {bool remember = true}) async {
    final Uint8List? bytes = await store.read(key);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    final String content = utf8.decode(bytes);
    if (remember) {
      _lastContent[key] = content;
    }
    return content;
  }
}

final class MemoryRelayStateStore implements RelayStateStore, RelayBlobStore {
  String? _raw;

  /// Blob chunks, kept across "restarts" like the state.
  final Map<String, Uint8List> blobChunks = <String, Uint8List>{};

  @override
  Future<void> writeBlobChunk(String key, Uint8List bytes) async {
    blobChunks[key] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> readBlobChunk(String key) async => blobChunks[key];

  @override
  Future<void> deleteBlobChunk(String key) async {
    blobChunks.remove(key);
  }

  /// Serialized on every save, so tests exercise the real (de)serialisation
  /// and a "restart" is simply a new engine over the same store.
  @override
  Future<RelayState> load() async {
    final String? raw = _raw;
    return raw == null ? RelayState() : RelayState.fromJsonString(raw);
  }

  @override
  Future<void> save(RelayState state) async {
    _raw = state.toJsonString();
  }
}
