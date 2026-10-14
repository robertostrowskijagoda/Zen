import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/media_vault.dart';

/// Files bigger than this are not copied to the account's other devices
/// (the message is, without the file).
const int kMaxSyncedFileBytes = 25 * 1024 * 1024;

/// One message as the account's devices pass it on (no file bytes).
Map<String, dynamic> chatMessageToSync(ChatMessage m) => <String, dynamic>{
  'id': m.id,
  's': m.sender,
  't': m.text,
  'at': m.sentAtMillis,
  'd': m.direction.name,
  'ty': m.type.name,
  if (m.fileName != null) 'fn': m.fileName,
  if (m.mimeType != null) 'mt': m.mimeType,
  if (m.attachmentSizeBytes != null) 'sz': m.attachmentSizeBytes,
  if (m.durationMs != null) 'du': m.durationMs,
  if (m.gifUrl != null) 'g': m.gifUrl,
  'ds': m.deliveryState.name,
  if (m.readAtMillis != null) 'r': m.readAtMillis,
};

ChatMessage? chatMessageFromSync(Object? json) {
  if (json is! Map) {
    return null;
  }
  final Object? id = json['id'];
  final Object? sender = json['s'];
  final Object? text = json['t'];
  final Object? at = json['at'];
  if (id is! String || sender is! String || text is! String || at is! int) {
    return null;
  }
  T byName<T extends Enum>(List<T> values, Object? name, T fallback) =>
      values.where((T v) => v.name == name).firstOrNull ?? fallback;
  int? asInt(Object? v) => v is int ? v : null;
  String? asString(Object? v) => v is String ? v : null;
  return ChatMessage(
    id: id,
    sender: sender,
    text: text,
    sentAtMillis: at,
    direction: byName(
      ChatMessageDirection.values,
      json['d'],
      ChatMessageDirection.incoming,
    ),
    type: byName(ChatMessageType.values, json['ty'], ChatMessageType.text),
    fileName: asString(json['fn']),
    mimeType: asString(json['mt']),
    attachmentSizeBytes: asInt(json['sz']),
    durationMs: asInt(json['du']),
    gifUrl: asString(json['g']),
    deliveryState: byName(
      ChatMessageDeliveryState.values,
      json['ds'],
      ChatMessageDeliveryState.none,
    ),
    readAtMillis: asInt(json['r']),
  );
}

bool _hasFile(ChatMessage m) =>
    m.type != ChatMessageType.text && m.gifUrl == null;

bool _fileReady(ChatMessage m) =>
    (m.attachmentBytes?.isNotEmpty ?? false) ||
    (m.attachmentPath?.trim().isNotEmpty ?? false);

/// The timeline store, telling [onNewOutgoing] about every message this
/// device sends (once it is complete: a file message once its file is in).
final class SyncingMessageTimelineStore implements MessageTimelineStore {
  SyncingMessageTimelineStore(this.delegate);

  final MessageTimelineStore delegate;
  void Function(String peer, ChatMessage message)? onNewOutgoing;

  /// Per conversation: ids of outgoing messages already known complete.
  final Map<String, Set<String>> _known = <String, Set<String>>{};

  Future<Set<String>> _knownFor(String peer) async {
    final Set<String>? had = _known[peer];
    if (had != null) {
      return had;
    }
    final Set<String> ids = <String>{
      for (final ChatMessage m in await delegate.load(peer))
        if (m.direction == ChatMessageDirection.outgoing &&
            (!_hasFile(m) || _fileReady(m)))
          m.id,
    };
    return _known[peer] ??= ids;
  }

  void _check(String peer, Set<String> known, Iterable<ChatMessage> messages) {
    for (final ChatMessage m in messages) {
      if (m.direction != ChatMessageDirection.outgoing ||
          known.contains(m.id) ||
          (_hasFile(m) && !_fileReady(m))) {
        continue;
      }
      known.add(m.id);
      try {
        onNewOutgoing?.call(peer, m);
      } on Object catch (error, stack) {
        logZenError('Kopia wiadomości dla innych urządzeń', error, stack);
      }
    }
  }

  @override
  Future<void> append(String peerAddress, ChatMessage message) async {
    final Set<String> known = await _knownFor(peerAddress);
    await delegate.append(peerAddress, message);
    _check(peerAddress, known, <ChatMessage>[message]);
  }

  @override
  Future<void> save(String peerAddress, List<ChatMessage> messages) async {
    final Set<String> known = await _knownFor(peerAddress);
    await delegate.save(peerAddress, messages);
    _check(peerAddress, known, messages);
  }

  @override
  Future<List<ChatMessage>> load(String peerAddress) =>
      delegate.load(peerAddress);
}

/// What [DeviceChatSync] needs from the social layer.
abstract interface class ChatSyncTarget {
  List<String> conversationKeys();
  Future<List<ChatMessage>> conversationMessages(String key);
  Future<void> importSyncedMessage(
    String key,
    ChatMessage message, {
    Uint8List? bytes,
  });
  Future<void> forgetFriendFromOtherDevice(String address);
  Future<void> forgetGroupFromOtherDevice(String groupId);
}

/// Keeps the conversations of the account's devices the same (§6):
///
/// * what this device sends is copied (sealed, with its file) into the
///   account's `own` space, which only its own devices get;
/// * a newly linked device gets this device's whole history once;
/// * a friend removed or a group left on another device goes here too.
final class DeviceChatSync {
  DeviceChatSync({required this.node, required this.target, this.vault});

  final LedgerNode node;
  final ChatSyncTarget target;

  /// Opens attachments kept encrypted (by default [MediaVault.current]).
  final MediaVault? vault;

  final Set<String> _imported = <String>{};
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  Future<void> _queue = Future<void>.value();
  static const String _historyKey = 'ledger/history_sent';
  bool _stopped = false;

  Future<void> start() async {
    await node.start();
    _subs
      ..add(node.ownEntries.listen((LogEntry e) => _enqueue(() => _apply(e))))
      ..add(node.devicesChanged.listen((_) => _enqueue(_maybeSendHistory)));
    for (final LogEntry e in node.pendingOwnEntries()) {
      _enqueue(() => _apply(e));
    }
    _enqueue(_maybeSendHistory);
  }

  Future<void> stop() async {
    _stopped = true;
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      if (_stopped) {
        return;
      }
      try {
        await work();
      } on Object catch (error, stack) {
        logZenError('Wspólne rozmowy urządzeń', error, stack);
      }
    });
  }

  /// Waits until everything queued so far is done (tests).
  Future<void> get idle => _queue;

  Future<Map<String, dynamic>?> _storeFile(ChatMessage m) async {
    if (!_hasFile(m)) {
      return null;
    }
    Uint8List? bytes = m.attachmentBytes;
    final String? path = m.attachmentPath?.trim();
    if ((bytes == null || bytes.isEmpty) && path != null && path.isNotEmpty) {
      final MediaVault? reader = vault ?? MediaVault.current;
      if (await File(path).exists()) {
        if (reader != null) {
          if (await reader.length(path) <= kMaxSyncedFileBytes) {
            bytes = await reader.read(path);
          }
        } else if (!isMediaVaultPath(path) &&
            await File(path).length() <= kMaxSyncedFileBytes) {
          bytes = await File(path).readAsBytes();
        }
      }
    }
    if (bytes == null || bytes.isEmpty || bytes.length > kMaxSyncedFileBytes) {
      return null;
    }
    return storeMedia(
      node.blobs,
      bytes,
      mime: m.mimeType ?? 'application/octet-stream',
    );
  }

  /// This device sent [message] in conversation [key].
  void onOutgoing(String key, ChatMessage message) {
    if (message.disappears) {
      // Never into the ledger's lasting copies (§14.1 point 10): the other
      // devices get it live (`acct_mirror`), and it dies everywhere.
      return;
    }
    if (_imported.contains(message.id) || node.siblingAddresses.isEmpty) {
      // Nobody to copy to; a device linked later gets the history.
      return;
    }
    _enqueue(() async {
      final Map<String, dynamic>? file = await _storeFile(message);
      await node.publishForOwnDevices(
        kChatCopyKind,
        <String, dynamic>{
          'peer': key,
          'm': chatMessageToSync(message),
          'f': ?file,
        },
        blobs: <String>[if (file != null) file['id'] as String],
      );
    });
  }

  Future<Uint8List?> _fetch(Object? refJson) async {
    final MediaRef? ref = mediaRefFromJson(refJson);
    if (ref == null || !await node.waitForBlob(ref.id)) {
      return null;
    }
    return openMedia(node.blobs, ref);
  }

  Future<void> _import(String key, ChatMessage m, {Uint8List? bytes}) async {
    _imported.add(m.id);
    await target.importSyncedMessage(key, m, bytes: bytes);
  }

  Future<void> _apply(LogEntry e) async {
    if (node.isOwnApplied(e.id)) {
      return;
    }
    final Map<String, dynamic>? body = node.bodyOf(e);
    if (body == null) {
      return;
    }
    switch (e.kind) {
      case kChatCopyKind:
        final Object? key = body['peer'];
        final ChatMessage? m = chatMessageFromSync(body['m']);
        if (key is String && m != null) {
          final Object? file = body['f'];
          await _import(
            key,
            m,
            bytes: file == null ? null : await _fetch(file),
          );
        }
      case kChatHistoryKind:
        await _applyHistory(body);
      case kContactRemovedKind:
        final Object? a = body['a'];
        final Object? g = body['g'];
        if (a is String) {
          await target.forgetFriendFromOtherDevice(a);
        } else if (g is String) {
          await target.forgetGroupFromOtherDevice(g);
        }
    }
    await node.markOwnApplied(e.id);
  }

  Future<void> _applyHistory(Map<String, dynamic> body) async {
    final Uint8List? raw = await _fetch(body['f']);
    if (raw == null) {
      return;
    }
    final Object? bundle = jsonDecode(utf8.decode(raw));
    if (bundle is! Map || bundle['v'] != 1) {
      return;
    }
    final Object? conversations = bundle['c'];
    final Object? files = bundle['files'];
    final List<(String, ChatMessage, Object?)> withFiles =
        <(String, ChatMessage, Object?)>[];
    if (conversations is Map) {
      for (final MapEntry<dynamic, dynamic> c in conversations.entries) {
        if (c.key is! String || c.value is! List) {
          continue;
        }
        for (final Object? item in c.value as List) {
          final ChatMessage? m = chatMessageFromSync(item);
          if (m == null) {
            continue;
          }
          // Text first, so the conversation is there at once.
          await _import(c.key as String, m);
          final Object? ref = files is Map ? files[m.id] : null;
          if (ref != null) {
            withFiles.add((c.key as String, m, ref));
          }
        }
      }
    }
    for (final (String key, ChatMessage m, Object? ref) in withFiles) {
      final Uint8List? bytes = await _fetch(ref);
      if (bytes != null) {
        await _import(key, m, bytes: bytes);
      }
    }
  }

  Future<Set<String>> _historySent() async {
    final Uint8List? raw = await node.disk.read(_historyKey);
    if (raw == null) {
      return <String>{};
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      return json is List ? json.whereType<String>().toSet() : <String>{};
    } on FormatException {
      return <String>{};
    }
  }

  /// A device of the account this one has not given its history to yet:
  /// one sealed bundle of every conversation (files up to
  /// [kMaxSyncedFileBytes] each), which every own device can take.
  Future<void> _maybeSendHistory() async {
    final List<String> others = <String>[
      for (final AccountDevice d in node.ownDevices)
        if (!d.isThis) d.device,
    ];
    if (others.isEmpty) {
      return;
    }
    final Set<String> sent = await _historySent();
    if (others.every(sent.contains)) {
      return;
    }
    final Map<String, List<Map<String, dynamic>>> conversations =
        <String, List<Map<String, dynamic>>>{};
    final Map<String, Map<String, dynamic>> files =
        <String, Map<String, dynamic>>{};
    for (final String key in target.conversationKeys()) {
      final List<Map<String, dynamic>> list = <Map<String, dynamic>>[];
      for (final ChatMessage m in await target.conversationMessages(key)) {
        if (m.direction == ChatMessageDirection.system || m.disappears) {
          continue;
        }
        list.add(chatMessageToSync(m));
        final Map<String, dynamic>? f = await _storeFile(m);
        if (f != null) {
          files[m.id] = f;
        }
      }
      if (list.isNotEmpty) {
        conversations[key] = list;
      }
    }
    if (conversations.isNotEmpty) {
      final Map<String, dynamic> bundle = await storeMedia(
        node.blobs,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'v': 1,
              'c': conversations,
              'files': files,
            }),
          ),
        ),
        mime: 'application/json',
      );
      await node.publishForOwnDevices(
        kChatHistoryKind,
        <String, dynamic>{'f': bundle},
        // The files are named inside the bundle and fetched one by one.
        blobs: <String>[bundle['id'] as String],
      );
    }
    await node.disk.write(
      _historyKey,
      Uint8List.fromList(
        utf8.encode(jsonEncode(<String>{...sent, ...others}.toList())),
      ),
    );
  }
}
