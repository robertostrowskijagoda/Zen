import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/account/account_media.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/media_vault.dart';

/// Files bigger than this are not copied to the account's other devices
/// (the message is, without the file): the largest file the ledger's file
/// store takes. Files travel piece by piece (never whole in memory).
const int kMaxSyncedFileBytes = kMaxStreamedMediaBytes;

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
  // Still being queued here is "sent" there: the other device's own queue
  // does not know it, and would otherwise take it for one that got lost.
  'ds':
      (m.deliveryState == ChatMessageDeliveryState.sending
              ? ChatMessageDeliveryState.sent
              : m.deliveryState)
          .name,
  if (m.readAtMillis != null) 'r': m.readAtMillis,
  // Reply, reactions, edit, deletion, forwarding (also what the circle
  // backup keeps of a conversation).
  'x': ?chatMessageExtrasToJson(m),
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
  final ChatMessage base = ChatMessage(
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
    deliveryState: byName(
      ChatMessageDeliveryState.values,
      json['ds'],
      ChatMessageDeliveryState.none,
    ),
    readAtMillis: asInt(json['r']),
  );
  return chatMessageWithExtras(base, json['x']);
}

bool _hasFile(ChatMessage m) => m.type != ChatMessageType.text;

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
        logZenError('Message copies for other devices', error, stack);
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

  /// With its file as [bytes] (small, or no media vault here) or as
  /// [storedPath] (a media vault file written piece by piece).
  Future<void> importSyncedMessage(
    String key,
    ChatMessage message, {
    Uint8List? bytes,
    String? storedPath,
  });

  /// [address] was removed on another device at [atMillis] (0: now).
  Future<void> forgetFriendFromOtherDevice(String address, {int atMillis = 0});
  Future<void> forgetGroupFromOtherDevice(String groupId);
}

/// Keeps the conversations of the account's devices the same:
///
/// * what this device sends is copied (sealed, with its file) into the
///   account's `own` space, which only its own devices get;
/// * a newly linked device gets this device's whole history once;
/// * a friend removed or a group left on another device goes here too.
final class DeviceChatSync {
  DeviceChatSync({
    required this.node,
    required this.target,
    this.vault,
    this.policy,
    this.retryEvery = const Duration(minutes: 5),
    this.fileWait = const Duration(minutes: 2),
    this.fileAttempts = 20,
    this.fileGiveUpAfter = const Duration(days: 3),
    int Function()? clock,
  }) : _clock = clock ?? _systemNow;

  final LedgerNode node;
  final ChatSyncTarget target;

  /// Opens attachments kept encrypted (by default [MediaVault.current]).
  final MediaVault? vault;

  /// When files may travel (mobile data); always when null.
  final AccountMediaPolicy? policy;

  /// How often files that had to wait are tried again.
  final Duration retryEvery;

  /// How long one file is waited for before it goes on the waiting list.
  final Duration fileWait;

  /// A waiting file is given up once it was asked for this many times ...
  final int fileAttempts;

  /// ... and has waited at least this long (the other device may just be
  /// off for a while): its message is then marked as one whose file will
  /// not come, and it is not asked for again.
  final Duration fileGiveUpAfter;

  final int Function() _clock;

  static int _systemNow() => DateTime.now().millisecondsSinceEpoch;

  static const String _pendingKey = 'account/sync/media_pending';
  Timer? _retry;

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
    _enqueue(retryWaitingFiles);
    _retry = Timer.periodic(retryEvery, (_) => _enqueue(retryWaitingFiles));
  }

  Future<void> stop() async {
    _stopped = true;
    _retry?.cancel();
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
        logZenError('Shared device conversations', error, stack);
      }
    });
  }

  /// Waits until everything queued so far is done (tests).
  Future<void> get idle => _queue;

  /// Seals the file of [m] into the ledger's file store piece by piece.
  Future<Map<String, dynamic>?> _storeFile(ChatMessage m) async {
    if (!_hasFile(m)) {
      return null;
    }
    final String mime = m.mimeType ?? 'application/octet-stream';
    final Uint8List? bytes = m.attachmentBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return storeMediaStreamed(
        node.blobs,
        size: bytes.length,
        range: (int start, int end) async =>
            Uint8List.sublistView(bytes, start, end),
        mime: mime,
      );
    }
    final String? path = m.attachmentPath?.trim();
    if (path == null || path.isEmpty) {
      return null;
    }
    final AccountFileReader reader = AccountFileReader(vault);
    final int? size = await reader.size(path);
    if (size == null || size == 0 || size > kMaxSyncedFileBytes) {
      return null;
    }
    return storeMediaStreamed(
      node.blobs,
      size: size,
      range: (int start, int end) => reader.range(path, start, end),
      mime: mime,
    );
  }

  /// This device sent [message] in conversation [key].
  void onOutgoing(String key, ChatMessage message) {
    if (message.disappears) {
      // Never into the ledger's lasting copies: the other
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

  /// A small file whole (a history bundle).
  Future<Uint8List?> _fetch(Object? refJson) async {
    final MediaRef? ref = mediaRefFromJson(refJson);
    if (ref == null || !await node.waitForBlob(ref.id)) {
      return null;
    }
    return openMedia(node.blobs, ref);
  }

  Future<void> _import(String key, ChatMessage m) async {
    _imported.add(m.id);
    await target.importSyncedMessage(key, m);
  }

  /// A file message whose file the other device did not pass on (it no
  /// longer has it, or it is too big to copy): it will not come.
  Future<void> _importWithoutFile(String key, ChatMessage m) =>
      _import(key, _hasFile(m) ? chatMessageWithoutFile(m) : m);

  /// [m] with its file [refJson]: the text at once; the file now, or —
  /// over mobile data with "Media tylko przez Wi-Fi" — once on Wi-Fi.
  Future<void> _importWithFile(
    String key,
    ChatMessage m,
    Object? refJson,
  ) async {
    _imported.add(m.id);
    final MediaRef? ref = mediaRefFromJson(refJson);
    if (ref == null) {
      await target.importSyncedMessage(key, m);
      return;
    }
    if (policy != null && !await policy!.mayFetchNow()) {
      await target.importSyncedMessage(key, m);
      await _remember(key, m, refJson);
      return;
    }
    if (!await _takeFile(key, m, ref)) {
      await target.importSyncedMessage(key, m);
      await _remember(key, m, refJson, asked: node.siblingAddresses.isNotEmpty);
    }
  }

  /// Fetches [ref] from the account's devices and hands it over piece by
  /// piece (into the media vault); false when it did not come.
  Future<bool> _takeFile(String key, ChatMessage m, MediaRef ref) async {
    // Not long: what does not come waits in the list and is tried again.
    if (!await node.waitForBlob(ref.id, timeout: fileWait)) {
      return false;
    }
    final MediaVault? v = vault ?? MediaVault.current;
    final int? length = mediaPlainLength(node.blobs, ref);
    if (length == null) {
      return false;
    }
    try {
      if (v != null) {
        final String path = await v.putStream(
          length,
          openMediaStreamed(node.blobs, ref),
        );
        await target.importSyncedMessage(key, m, storedPath: path);
      } else {
        // No media vault (tests): the file whole.
        final Uint8List? bytes = await openMedia(node.blobs, ref);
        if (bytes == null) {
          return false;
        }
        await target.importSyncedMessage(key, m, bytes: bytes);
      }
      return true;
    } on Object catch (error) {
      logZenWarning('A file from another device was not taken: $error');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _waiting() async {
    final Uint8List? raw = await node.disk.read(_pendingKey);
    if (raw == null) {
      return <Map<String, dynamic>>[];
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      return <Map<String, dynamic>>[
        if (json is List)
          for (final Object? item in json)
            if (item is Map) Map<String, dynamic>.from(item),
      ];
    } on FormatException {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _saveWaiting(List<Map<String, dynamic>> items) => node.disk
      .write(_pendingKey, Uint8List.fromList(utf8.encode(jsonEncode(items))));

  /// Puts the file of [m] on the waiting list: since when it waits (`t`)
  /// and how many times it was asked for (`n`; [asked] counts this time)
  /// are kept when it is there already.
  Future<void> _remember(
    String key,
    ChatMessage m,
    Object? refJson, {
    bool asked = false,
  }) async {
    final List<Map<String, dynamic>> items = await _waiting();
    final Map<String, dynamic>? had = items
        .where(
          (Map<String, dynamic> i) =>
              i['m'] is Map && (i['m'] as Map)['id'] == m.id,
        )
        .firstOrNull;
    final Object? since = had?['t'];
    final Object? tries = had?['n'];
    items
      ..remove(had)
      ..add(<String, dynamic>{
        'k': key,
        'm': chatMessageToSync(m),
        'f': refJson,
        't': since is int ? since : _clock(),
        'n': (tries is int ? tries : 0) + (asked ? 1 : 0),
      });
    await _saveWaiting(items);
  }

  /// How many files wait for Wi-Fi (or for the other device).
  Future<int> waitingFiles() async => (await _waiting()).length;

  /// Takes the files that had to wait, when they may travel now. One that
  /// was asked for [fileAttempts] times over at least [fileGiveUpAfter] is
  /// given up: its message says the file is not available.
  Future<void> retryWaitingFiles() async {
    final List<Map<String, dynamic>> items = await _waiting();
    if (items.isEmpty || (policy != null && !await policy!.mayFetchNow())) {
      return;
    }
    // Only a try with a device to ask counts towards giving up.
    final bool asked = node.siblingAddresses.isNotEmpty;
    final int now = _clock();
    final List<Map<String, dynamic>> left = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> item in items) {
      final Object? key = item['k'];
      final ChatMessage? m = chatMessageFromSync(item['m']);
      final MediaRef? ref = mediaRefFromJson(item['f']);
      if (key is! String || m == null || ref == null) {
        continue;
      }
      if (await _takeFile(key, m, ref)) {
        continue;
      }
      final Object? since = item['t'];
      final Object? tries = item['n'];
      final int started = since is int ? since : now;
      final int count = (tries is int ? tries : 0) + (asked ? 1 : 0);
      if (count >= fileAttempts &&
          now - started >= fileGiveUpAfter.inMilliseconds) {
        await _giveUpFile(key, m);
        continue;
      }
      left.add(<String, dynamic>{...item, 't': started, 'n': count});
    }
    await _saveWaiting(left);
  }

  /// The file of [m] will not come from the account's other devices: the
  /// message (when still here) says so, and it is not asked for again.
  Future<void> _giveUpFile(String key, ChatMessage m) async {
    final bool here = (await target.conversationMessages(
      key,
    )).any((ChatMessage have) => have.id == m.id);
    if (here) {
      await target.importSyncedMessage(key, chatMessageWithoutFile(m));
    }
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
          if (file == null) {
            await _importWithoutFile(key, m);
          } else {
            await _importWithFile(key, m, file);
          }
        }
      case kChatHistoryKind:
        await _applyHistory(body);
      case kContactRemovedKind:
        final Object? a = body['a'];
        final Object? g = body['g'];
        if (a is String) {
          await target.forgetFriendFromOtherDevice(a, atMillis: e.hlc.millis);
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
    if (jsonFormatAge(bundle, current: 1) == FormatAge.newer) {
      // Sent by a newer Zen on another device of the account.
      ZenFormatGuard.instance.noteNewer('account/history');
    }
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
          final Object? ref = files is Map ? files[m.id] : null;
          // Text first, so the conversation is there at once.
          if (ref == null) {
            await _importWithoutFile(c.key as String, m);
          } else {
            await _import(c.key as String, m);
            withFiles.add((c.key as String, m, ref));
          }
        }
      }
    }
    for (final (String key, ChatMessage m, Object? ref) in withFiles) {
      await _importWithFile(key, m, ref);
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
