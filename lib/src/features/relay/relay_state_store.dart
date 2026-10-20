import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
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

/// Relay state in the app's (optionally encrypted) binary store.
///
/// Split in two so a busy relay does not rewrite megabytes per message:
///
/// * `relay/state` — identity, relay directory, outbox, receipts (small);
/// * `relay/mail/<peer>` — ciphertext held for one friend, written only when
///   that friend's mail actually changed.
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

  String _mailKey(String recipient) =>
      'relay/mail/${base64Url.encode(utf8.encode(recipient)).replaceAll('=', '')}';

  @override
  Future<RelayState> load() async {
    _lastContent.clear();
    final String? core = await _readString(storageKey);
    if (core == null) {
      return RelayState();
    }
    try {
      final RelayState state = RelayState.fromJsonString(core);
      final Object? decoded = jsonDecode(core);
      final List<String> recipients = decoded is Map && decoded['mbx'] is List
          ? (decoded['mbx'] as List).whereType<String>().toList()
          : const <String>[];
      for (final String recipient in recipients) {
        final String? raw = await _readString(_mailKey(recipient));
        if (raw == null) {
          continue;
        }
        final Object? mail = jsonDecode(raw);
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
    } catch (error, stackTrace) {
      // A corrupt file must not take messaging down; start over (the
      // identity is regenerated and re-announced to every friend).
      logZenError(
        'Relay state is unreadable; starting fresh',
        error,
        stackTrace,
      );
      return RelayState();
    }
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
    final Map<String, dynamic> core =
        jsonDecode(state.toJsonString(includeMailbox: false))
            as Map<String, dynamic>;
    core['mbx'] = state.mailbox.keys.toList();
    await _writeIfChanged(storageKey, jsonEncode(core));
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

  Future<String?> _readString(String key) async {
    final Uint8List? bytes = await store.read(key);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    final String content = utf8.decode(bytes);
    _lastContent[key] = content;
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
