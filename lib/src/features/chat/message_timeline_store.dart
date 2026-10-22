import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/storage/binary_buffer.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';

final NotifierProvider<MessageTimelineRevisionController, int>
messageTimelineRevisionProvider =
    NotifierProvider<MessageTimelineRevisionController, int>(
      MessageTimelineRevisionController.new,
    );

final class MessageTimelineRevisionController extends Notifier<int> {
  @override
  int build() => 0;

  void bump() {
    state += 1;
  }
}

abstract interface class MessageTimelineStore {
  Future<List<ChatMessage>> load(String peerAddress);

  Future<void> save(String peerAddress, List<ChatMessage> messages);

  Future<void> append(String peerAddress, ChatMessage message);
}

/// Messages in one stored piece of a conversation.
const int kTimelineSegmentMessages = 200;

/// A piece also takes no more messages past this many bytes (photos and
/// voice notes sent inline are kept in the message).
const int kTimelineSegmentBytes = 256 * 1024;

/// Conversations whose messages stay in memory (the most recently used).
const int kTimelineCachedThreads = 8;

/// …and no more than about this many bytes of them (the one in use always
/// stays).
const int kTimelineCachedBytes = 16 * 1024 * 1024;

/// Conversations on disk, in pieces (every write is sealed with AES-GCM on
/// the UI isolate, so its size is what a change costs):
///
/// * `<thread>/seg/<n>` — a piece: up to [segmentSize] messages (fewer when
///   they are big), in the order of the conversation;
/// * `<thread>/idx` — the index: the pieces in order, the next free piece
///   number, and a generation that changes with every write.
///
/// A new message rewrites only the last piece (or starts a new one), a
/// changed message only the piece it is in; the small index is written
/// with each change. The messages of the last few conversations stay in
/// memory and are used while the index on disk still has the generation
/// they were read with — so the background service (another isolate,
/// writing the same files) is never overwritten with a stale copy.
///
/// Order of writes: pieces, then the index, then pieces no longer used are
/// deleted (the index names them until they are gone). No index means no
/// conversation.
///
/// `<thread>` is `threads/<address>` and `threads/` is one of
/// [kZenHiddenNamePrefixes]: in the encrypted store none of these keys
/// becomes a readable file name. Nothing lists folders to find them.
final class FileMessageTimelineStore implements MessageTimelineStore {
  FileMessageTimelineStore({
    required FileBinaryStore store,
    String storagePrefix = 'threads',
    int segmentSize = kTimelineSegmentMessages,
    int segmentBytes = kTimelineSegmentBytes,
    int cachedThreads = kTimelineCachedThreads,
    int cachedBytes = kTimelineCachedBytes,
  }) : this.onDisk(
         FileLedgerDisk(store),
         storagePrefix: storagePrefix,
         segmentSize: segmentSize,
         segmentBytes: segmentBytes,
         cachedThreads: cachedThreads,
         cachedBytes: cachedBytes,
       );

  /// On any key-value [disk] (tests use one in memory).
  FileMessageTimelineStore.onDisk(
    this.disk, {
    this.storagePrefix = 'threads',
    this.segmentSize = kTimelineSegmentMessages,
    this.segmentBytes = kTimelineSegmentBytes,
    this.cachedThreads = kTimelineCachedThreads,
    this.cachedBytes = kTimelineCachedBytes,
    Random? random,
  }) : assert(segmentSize > 0),
       assert(segmentBytes > 0),
       _random = random ?? Random();

  static const int _versionMarker = 255;
  static const int _currentVersion = 8;

  final LedgerDisk disk;
  final String storagePrefix;

  /// Messages per piece.
  final int segmentSize;

  /// A piece past this many bytes (estimated) takes no more messages.
  final int segmentBytes;

  /// How many conversations stay in memory.
  final int cachedThreads;

  /// About how many bytes of them (estimated).
  final int cachedBytes;

  final Random _random;

  /// Conversations in memory (most recently used last).
  final Map<String, _Thread> _cache = <String, _Thread>{};

  /// Work on a conversation runs one at a time.
  final Map<String, Future<void>> _busy = <String, Future<void>>{};

  @override
  Future<List<ChatMessage>> load(String peerAddress) async {
    final String key = _keyFor(peerAddress);
    try {
      return await _serial(key, () async => (await _open(key)).all);
    } on StateError {
      // Locked: nothing to show, as before — and what was read before does
      // not stay in memory either.
      _cache.clear();
      return const <ChatMessage>[];
    } on Object {
      // A damaged index: nothing to show, as before. Nothing is written
      // over it either.
      return const <ChatMessage>[];
    }
  }

  @override
  Future<void> append(String peerAddress, ChatMessage message) {
    final String key = _keyFor(peerAddress);
    return _serial(key, () async {
      final _Thread thread = await _open(key);
      final List<ChatMessage> all = thread.all;
      if (all.isNotEmpty && all.last.sentAtMillis > message.sentAtMillis) {
        // Older than what came since (held by relays while offline): it goes
        // in between, which may touch a piece before the last.
        await _commit(key, thread, insertChronologically(all, message));
        return;
      }
      final List<_Segment> segments = thread.segments;
      final _Segment? last = segments.isEmpty ? null : segments.last;
      if (last != null && last.readable && !_isFull(last.messages)) {
        final _Segment grown = _Segment(last.id, <ChatMessage>[
          ...last.messages,
          message,
        ]);
        await _store(
          key,
          thread,
          segments: <_Segment>[
            ...segments.sublist(0, segments.length - 1),
            grown,
          ],
          written: <_Segment>[grown],
        );
        return;
      }
      final _Segment fresh = _Segment(thread.nextId, <ChatMessage>[message]);
      await _store(
        key,
        thread,
        segments: <_Segment>[...segments, fresh],
        written: <_Segment>[fresh],
        nextId: thread.nextId + 1,
      );
    });
  }

  @override
  Future<void> save(String peerAddress, List<ChatMessage> messages) {
    final String key = _keyFor(peerAddress);
    return _serial(key, () async {
      if (messages.isEmpty) {
        await _clear(key);
        return;
      }
      await _commit(key, await _open(key), messages);
    });
  }

  // ---- Reading -----------------------------------------------------------

  /// The conversation under [key]: from memory while the index on disk has
  /// the generation it was read with, else read again. Throws when the
  /// index cannot be read (or the store is locked): nothing may then be
  /// written.
  Future<_Thread> _open(String key) async {
    final _ThreadIndex? index = _ThreadIndex.decode(
      await disk.read(_indexKey(key)),
    );
    final _Thread? cached = _cache[key];
    if (index == null) {
      if (cached != null && cached.gen == null) {
        return _remember(key, cached);
      }
      return _remember(key, _Thread.empty());
    }
    if (cached != null && cached.gen == index.gen) {
      return _remember(key, cached);
    }
    final List<_Segment> segments = <_Segment>[];
    for (final ({int id, int count}) entry in index.segments) {
      segments.add(await _readSegment(key, entry.id, entry.count));
    }
    return _remember(
      key,
      _Thread(
        gen: index.gen,
        nextId: index.nextId,
        segments: segments,
        drop: await _dropSegments(key, index.drop),
      ),
    );
  }

  /// A piece; one that is gone counts as empty, one that cannot be read is
  /// kept as it is (never written over, its messages not shown).
  Future<_Segment> _readSegment(String key, int id, int countHint) async {
    try {
      final Uint8List? bytes = await disk.read(_segmentKey(key, id));
      if (bytes == null || bytes.isEmpty) {
        return _Segment(id, const <ChatMessage>[]);
      }
      return _Segment(id, _decodeMessages(bytes));
    } on Object {
      return _Segment.unreadable(id, countHint);
    }
  }

  // ---- Writing -----------------------------------------------------------

  /// Makes the conversation [next], rewriting only the pieces whose
  /// messages changed. Messages keep the piece they are in; new ones join
  /// the piece of the message before them (at the end: the last piece used,
  /// then new pieces). Messages moved from one piece to another (never done
  /// by the app) have the whole conversation written afresh.
  Future<void> _commit(
    String key,
    _Thread thread,
    List<ChatMessage> next,
  ) async {
    final List<_Segment> old = thread.segments;
    final Map<ChatMessage, int> byInstance = Map<ChatMessage, int>.identity();
    final Map<String, int> byId = <String, int>{};
    for (int s = 0; s < old.length; s++) {
      for (final ChatMessage m in old[s].messages) {
        byInstance[m] = s;
        byId.putIfAbsent(m.id, () => s);
      }
    }
    final List<int?> homes = <int?>[
      for (final ChatMessage m in next) byInstance[m] ?? byId[m.id],
    ];
    int firstHome = -1;
    int lastHome = -1;
    int lastHomed = -1;
    for (int i = 0; i < homes.length; i++) {
      final int? home = homes[i];
      if (home == null) {
        continue;
      }
      if (home < lastHome) {
        await _rewriteAll(key, thread, next);
        return;
      }
      if (firstHome < 0) {
        firstHome = home;
      }
      lastHome = home;
      lastHomed = i;
    }

    final List<List<ChatMessage>> runs = List<List<ChatMessage>>.generate(
      old.length,
      (_) => <ChatMessage>[],
    );
    int current = firstHome;
    for (int i = 0; i <= lastHomed; i++) {
      current = homes[i] ?? current;
      runs[current].add(next[i]);
    }
    final List<ChatMessage> rest = next.sublist(lastHomed + 1);
    int taken = 0;
    if (lastHome >= 0) {
      final List<ChatMessage> host = runs[lastHome];
      int bytes = _bytesOf(host);
      while (taken < rest.length &&
          host.length < segmentSize &&
          bytes < segmentBytes) {
        bytes += _estimateBytes(rest[taken]);
        host.add(rest[taken]);
        taken++;
      }
    }

    final List<_Segment> layout = <_Segment>[];
    final List<_Segment> written = <_Segment>[];
    final List<int> removed = <int>[];
    for (int s = 0; s < old.length; s++) {
      final _Segment was = old[s];
      if (!was.readable) {
        layout.add(was);
        continue;
      }
      final List<ChatMessage> run = runs[s];
      if (run.isEmpty) {
        removed.add(was.id);
        continue;
      }
      if (_sameMessages(was.messages, run)) {
        layout.add(was);
        continue;
      }
      final _Segment changed = _Segment(was.id, run);
      layout.add(changed);
      written.add(changed);
    }
    int nextId = thread.nextId;
    for (final List<ChatMessage> chunk in _chunks(rest.sublist(taken))) {
      final _Segment fresh = _Segment(nextId++, chunk);
      layout.add(fresh);
      written.add(fresh);
    }
    if (written.isEmpty && removed.isEmpty) {
      return;
    }
    await _store(
      key,
      thread,
      segments: layout,
      written: written,
      removed: removed,
      nextId: nextId,
    );
  }

  /// [next] in new pieces (new numbers: until the index names them, the
  /// old pieces stay what counts).
  Future<void> _rewriteAll(
    String key,
    _Thread thread,
    List<ChatMessage> next,
  ) async {
    final List<_Segment> layout = <_Segment>[
      for (final _Segment s in thread.segments)
        if (!s.readable) s,
    ];
    final List<_Segment> written = <_Segment>[];
    int nextId = thread.nextId;
    for (final List<ChatMessage> chunk in _chunks(next)) {
      final _Segment fresh = _Segment(nextId++, chunk);
      layout.add(fresh);
      written.add(fresh);
    }
    await _store(
      key,
      thread,
      segments: layout,
      written: written,
      removed: <int>[
        for (final _Segment s in thread.segments)
          if (s.readable) s.id,
      ],
      nextId: nextId,
    );
  }

  /// Writes the [written] pieces, then the index of [segments] (with a new
  /// generation), then deletes the [removed] pieces.
  Future<void> _store(
    String key,
    _Thread thread, {
    required List<_Segment> segments,
    required List<_Segment> written,
    List<int> removed = const <int>[],
    int? nextId,
  }) async {
    try {
      for (final _Segment segment in written) {
        await disk.write(
          _segmentKey(key, segment.id),
          _encodeMessages(segment.messages),
        );
      }
      final int gen = _newGen(thread.gen);
      final int next = nextId ?? thread.nextId;
      final List<int> drop = <int>[...thread.drop, ...removed];
      await disk.write(
        _indexKey(key),
        _ThreadIndex(
          gen: gen,
          nextId: next,
          segments: _entriesOf(segments),
          drop: drop,
        ).encode(),
      );
      _remember(
        key,
        _Thread(
          gen: gen,
          nextId: next,
          segments: segments,
          drop: await _dropSegments(key, drop),
        ),
      );
    } on Object {
      // What is on disk is not known now: read it again next time.
      _cache.remove(key);
      rethrow;
    }
  }

  /// Deletes the whole conversation: its pieces, then the index. Stopped
  /// halfway, the index names pieces that are gone (they count as empty)
  /// and deleting again finishes it.
  Future<void> _clear(String key) async {
    final Set<int> ids = <int>{};
    final _Thread? cached = _cache.remove(key);
    if (cached != null) {
      ids
        ..addAll(cached.segments.map((_Segment s) => s.id))
        ..addAll(cached.drop);
    }
    try {
      final _ThreadIndex? index = _ThreadIndex.decode(
        await disk.read(_indexKey(key)),
      );
      if (index != null) {
        ids
          ..addAll(index.segments.map((({int id, int count}) e) => e.id))
          ..addAll(index.drop);
      }
    } on Object {
      // A damaged index: the pieces known from memory go, and the index.
    }
    for (final int id in ids) {
      await disk.delete(_segmentKey(key, id));
    }
    await disk.delete(_indexKey(key));
    _remember(key, _Thread.empty());
  }

  /// Deletes pieces no longer used; returns those that could not be.
  Future<List<int>> _dropSegments(String key, List<int> ids) async {
    final List<int> left = <int>[];
    for (final int id in ids) {
      if (!await _deleteQuietly(_segmentKey(key, id))) {
        left.add(id);
      }
    }
    return left;
  }

  Future<bool> _deleteQuietly(String key) async {
    try {
      await disk.delete(key);
      return true;
    } on Object {
      return false;
    }
  }

  // ---- Memory and order --------------------------------------------------

  _Thread _remember(String key, _Thread thread) {
    _cache
      ..remove(key)
      ..[key] = thread;
    int bytes = 0;
    for (final _Thread cached in _cache.values) {
      bytes += cached.bytes;
    }
    while (_cache.length > 1 &&
        (_cache.length > cachedThreads || bytes > cachedBytes)) {
      bytes -= _cache.remove(_cache.keys.first)!.bytes;
    }
    return thread;
  }

  Future<T> _serial<T>(String key, Future<T> Function() action) async {
    final Future<void>? before = _busy[key];
    final Completer<void> done = Completer<void>();
    _busy[key] = done.future;
    try {
      if (before != null) {
        await before;
      }
      return await action();
    } finally {
      done.complete();
      if (identical(_busy[key], done.future)) {
        _busy.remove(key);
      }
    }
  }

  int _newGen(int? previous) {
    while (true) {
      final int gen =
          (_random.nextInt(0x7fffffff) << 31) | _random.nextInt(0x7fffffff);
      if (gen != previous) {
        return gen;
      }
    }
  }

  // ---- Pieces --------------------------------------------------------------

  bool _isFull(List<ChatMessage> messages) =>
      messages.length >= segmentSize || _bytesOf(messages) >= segmentBytes;

  List<List<ChatMessage>> _chunks(List<ChatMessage> messages) {
    final List<List<ChatMessage>> chunks = <List<ChatMessage>>[];
    List<ChatMessage> current = <ChatMessage>[];
    int bytes = 0;
    for (final ChatMessage m in messages) {
      if (current.isNotEmpty &&
          (current.length >= segmentSize || bytes >= segmentBytes)) {
        chunks.add(current);
        current = <ChatMessage>[];
        bytes = 0;
      }
      current.add(m);
      bytes += _estimateBytes(m);
    }
    if (current.isNotEmpty) {
      chunks.add(current);
    }
    return chunks;
  }

  static List<({int id, int count})> _entriesOf(List<_Segment> segments) =>
      <({int id, int count})>[
        for (final _Segment s in segments) (id: s.id, count: s.count),
      ];

  static int _bytesOf(List<ChatMessage> messages) {
    int total = 0;
    for (final ChatMessage m in messages) {
      total += _estimateBytes(m);
    }
    return total;
  }

  /// About how much [m] takes stored.
  static int _estimateBytes(ChatMessage m) =>
      64 +
      m.id.length +
      m.sender.length +
      m.text.length * 2 +
      (m.fileName?.length ?? 0) +
      (m.mimeType?.length ?? 0) +
      (m.attachmentPath?.length ?? 0) +
      (m.attachmentBytes?.length ?? 0);

  static bool _sameMessages(List<ChatMessage> a, List<ChatMessage> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (!_sameMessage(a[i], b[i])) {
        return false;
      }
    }
    return true;
  }

  static bool _sameMessage(ChatMessage a, ChatMessage b) =>
      identical(a, b) ||
      (a.id == b.id &&
          a.sender == b.sender &&
          a.text == b.text &&
          a.sentAtMillis == b.sentAtMillis &&
          a.direction == b.direction &&
          a.deliveryState == b.deliveryState &&
          a.type == b.type &&
          a.fileName == b.fileName &&
          a.mimeType == b.mimeType &&
          a.attachmentSizeBytes == b.attachmentSizeBytes &&
          a.attachmentPath == b.attachmentPath &&
          a.readAtMillis == b.readAtMillis &&
          a.durationMs == b.durationMs &&
          a.expiresAtMillis == b.expiresAtMillis &&
          _sameExtras(a, b) &&
          _sameBytes(a.attachmentBytes, b.attachmentBytes));

  static String? _extrasOf(ChatMessage m) {
    final Map<String, dynamic>? extras = chatMessageExtrasToJson(m);
    return extras == null ? null : jsonEncode(extras);
  }

  static bool _sameExtras(ChatMessage a, ChatMessage b) =>
      a.reply == b.reply &&
      a.editedAtMillis == b.editedAtMillis &&
      a.deletedAtMillis == b.deletedAtMillis &&
      a.forwarded == b.forwarded &&
      _extrasOf(a) == _extrasOf(b);

  static bool _sameBytes(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) {
      return true;
    }
    if (a == null || b == null || a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  // ---- Keys ----------------------------------------------------------------

  /// The logical key of a thread (the pieces and the index are below it).
  /// In the encrypted store it never becomes a file name: `threads/` is one
  /// of [kZenHiddenNamePrefixes], so the file is named by a keyed hash and
  /// the friend's address is not on disk in the clear.
  String _keyFor(String peerAddress) {
    final String encoded = base64Url
        .encode(utf8.encode(peerAddress))
        .replaceAll('=', '');
    return '$storagePrefix/$encoded';
  }

  static String _indexKey(String key) => '$key/idx';

  static String _segmentKey(String key, int id) => '$key/seg/$id';

  // ---- Bytes ---------------------------------------------------------------

  /// A piece's messages in the stored format.
  static Uint8List _encodeMessages(List<ChatMessage> messages) {
    final BinaryWriter writer = BinaryWriter()
      ..writeUint8(_versionMarker)
      ..writeUint8(_currentVersion)
      ..writeUint32(messages.length);
    for (final ChatMessage message in messages) {
      writer
        ..writeString(message.id)
        ..writeString(message.sender)
        ..writeString(message.text)
        ..writeInt64(message.sentAtMillis)
        ..writeUint8(message.direction.index)
        ..writeUint8(message.deliveryState.index)
        ..writeUint8(message.type.index)
        ..writeNullableString(message.fileName)
        ..writeNullableString(message.mimeType)
        ..writeNullableUint32(message.attachmentSizeBytes)
        ..writeNullableBytes(message.attachmentBytes)
        ..writeNullableString(message.attachmentPath)
        ..writeNullableInt64(message.readAtMillis)
        ..writeNullableInt64(message.durationMs)
        ..writeNullableInt64(message.expiresAtMillis)
        // Reply, reactions, edit, deletion, forwarding (JSON).
        ..writeNullableString(_extrasOf(message));
    }
    return writer.toBytes();
  }

  /// Messages in the stored format; a damaged tail is cut off, a damaged
  /// header or another version throws (the piece is then kept as it is).
  static List<ChatMessage> _decodeMessages(Uint8List bytes) {
    final BinaryReader reader = BinaryReader(bytes);
    final int marker = reader.readUint8();
    final int version = reader.readUint8();
    if (marker != _versionMarker || version != _currentVersion) {
      throw FormatException('Unsupported messages version $version.');
    }
    final int count = reader.readUint32();
    final List<ChatMessage> messages = <ChatMessage>[];
    for (int index = 0; index < count; index += 1) {
      try {
        messages.add(_readMessage(reader));
      } catch (_) {
        break;
      }
    }
    return List<ChatMessage>.unmodifiable(messages);
  }

  static ChatMessageDirection _directionFromIndex(int index) {
    if (index < 0 || index >= ChatMessageDirection.values.length) {
      return ChatMessageDirection.incoming;
    }
    return ChatMessageDirection.values[index];
  }

  static ChatMessageDeliveryState _deliveryStateFromIndex(int index) {
    if (index < 0 || index >= ChatMessageDeliveryState.values.length) {
      return ChatMessageDeliveryState.delivered;
    }
    return ChatMessageDeliveryState.values[index];
  }

  static ChatMessageType _typeFromIndex(int index) {
    if (index < 0 || index >= ChatMessageType.values.length) {
      return ChatMessageType.text;
    }
    return ChatMessageType.values[index];
  }

  static ChatMessage _readMessage(BinaryReader reader) {
    final String id = reader.readString();
    final String sender = reader.readString();
    final String text = reader.readString();
    final int sentAtMillis = reader.readInt64();
    final ChatMessageDirection direction = _directionFromIndex(
      reader.readUint8(),
    );
    final ChatMessageDeliveryState deliveryState = _deliveryStateFromIndex(
      reader.readUint8(),
    );
    final ChatMessage base = ChatMessage(
      id: id,
      sender: sender,
      text: text,
      sentAtMillis: sentAtMillis,
      direction: direction,
      deliveryState: deliveryState,
      type: _typeFromIndex(reader.readUint8()),
      fileName: reader.readNullableString(),
      mimeType: reader.readNullableString(),
      attachmentSizeBytes: reader.readNullableUint32(),
      attachmentBytes: reader.readNullableBytes(),
      attachmentPath: reader.readNullableString(),
      readAtMillis: reader.readNullableInt64(),
      durationMs: reader.readNullableInt64(),
      expiresAtMillis: reader.readNullableInt64(),
    );
    final String? extras = reader.readNullableString();
    if (extras == null || extras.isEmpty) {
      return base;
    }
    try {
      return chatMessageWithExtras(base, jsonDecode(extras));
    } on FormatException {
      return base;
    }
  }
}

/// A conversation as read (or last written) by this store.
final class _Thread {
  _Thread({
    required this.gen,
    required this.nextId,
    required this.segments,
    this.drop = const <int>[],
  });

  /// Nothing stored (no index on disk).
  _Thread.empty() : this(gen: null, nextId: 0, segments: const <_Segment>[]);

  /// The index's generation; `null` while there is no index.
  final int? gen;

  /// The number the next new piece gets (numbers are never reused).
  final int nextId;

  /// The pieces, in order.
  final List<_Segment> segments;

  /// Pieces no longer used that could not be deleted yet.
  final List<int> drop;

  List<ChatMessage>? _all;
  int? _bytes;

  /// Every readable message, in order.
  List<ChatMessage> get all => _all ??= List<ChatMessage>.unmodifiable(
    <ChatMessage>[for (final _Segment s in segments) ...s.messages],
  );

  /// About how much memory the messages take.
  int get bytes => _bytes ??= FileMessageTimelineStore._bytesOf(all);
}

/// One piece of a conversation.
final class _Segment {
  _Segment(this.id, List<ChatMessage> messages)
    : messages = List<ChatMessage>.unmodifiable(messages),
      count = messages.length,
      readable = true;

  /// A piece that could not be read: kept as it is, shown as nothing.
  _Segment.unreadable(this.id, this.count)
    : messages = const <ChatMessage>[],
      readable = false;

  final int id;
  final List<ChatMessage> messages;
  final int count;
  final bool readable;
}

/// The index of a conversation's pieces.
final class _ThreadIndex {
  const _ThreadIndex({
    required this.gen,
    required this.nextId,
    required this.segments,
    this.drop = const <int>[],
  });

  static const int _marker = 0x49;
  static const int _version = 1;

  final int gen;
  final int nextId;
  final List<({int id, int count})> segments;
  final List<int> drop;

  Uint8List encode() {
    final BinaryWriter writer = BinaryWriter()
      ..writeUint8(_marker)
      ..writeUint8(_version)
      ..writeInt64(gen)
      ..writeUint32(nextId)
      // Reserved, always false.
      ..writeBool(false)
      ..writeUint32(segments.length);
    for (final ({int id, int count}) segment in segments) {
      writer
        ..writeUint32(segment.id)
        ..writeUint32(segment.count);
    }
    writer.writeUint32(drop.length);
    for (final int id in drop) {
      writer.writeUint32(id);
    }
    return writer.toBytes();
  }

  /// `null` when there is no index; throws [FormatException] when it is not
  /// one this version can read.
  static _ThreadIndex? decode(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    try {
      final BinaryReader reader = BinaryReader(bytes);
      if (reader.readUint8() != _marker) {
        throw const FormatException('Not a conversation index.');
      }
      final int version = reader.readUint8();
      if (version != _version) {
        throw FormatException('Unsupported conversation index $version.');
      }
      final int gen = reader.readInt64();
      final int nextId = reader.readUint32();
      // Reserved.
      reader.readBool();
      final int count = reader.readUint32();
      final List<({int id, int count})> segments = <({int id, int count})>[];
      for (int i = 0; i < count; i++) {
        final int id = reader.readUint32();
        segments.add((id: id, count: reader.readUint32()));
      }
      final int dropCount = reader.readUint32();
      final List<int> drop = <int>[
        for (int i = 0; i < dropCount; i++) reader.readUint32(),
      ];
      return _ThreadIndex(
        gen: gen,
        nextId: nextId,
        segments: segments,
        drop: drop,
      );
    } on StateError {
      throw const FormatException('The conversation index is cut short.');
    }
  }
}

final class MemoryMessageTimelineStore implements MessageTimelineStore {
  MemoryMessageTimelineStore([
    Map<String, List<ChatMessage>> initialThreads =
        const <String, List<ChatMessage>>{},
  ]) : _threads = <String, List<ChatMessage>>{
         for (final MapEntry<String, List<ChatMessage>> entry
             in initialThreads.entries)
           entry.key: List<ChatMessage>.from(entry.value, growable: false),
       };

  final Map<String, List<ChatMessage>> _threads;

  @override
  Future<void> append(String peerAddress, ChatMessage message) async {
    final List<ChatMessage> current =
        _threads[peerAddress] ?? const <ChatMessage>[];
    _threads[peerAddress] = insertChronologically(current, message);
  }

  @override
  Future<List<ChatMessage>> load(String peerAddress) async {
    return List<ChatMessage>.unmodifiable(
      _threads[peerAddress] ?? const <ChatMessage>[],
    );
  }

  @override
  Future<void> save(String peerAddress, List<ChatMessage> messages) async {
    if (messages.isEmpty) {
      _threads.remove(peerAddress);
      return;
    }
    _threads[peerAddress] = List<ChatMessage>.from(messages, growable: false);
  }
}

Map<String, List<ChatMessage>> buildPreviewMessageThreads() {
  return <String, List<ChatMessage>>{
    'ada.ygg': const <ChatMessage>[
      ChatMessage(
        id: 'ada-system-1',
        sender: 'system',
        text: 'Połączenie z Ada jest gotowe.',
        sentAtMillis: 1775807880000,
        direction: ChatMessageDirection.system,
      ),
      ChatMessage(
        id: 'ada-incoming-1',
        sender: 'ada.ygg',
        text: 'Jestem online, mogę wejść na rozmowę za 5 minut.',
        sentAtMillis: 1775808000000,
        direction: ChatMessageDirection.incoming,
      ),
    ],
    'maks.ygg': const <ChatMessage>[
      ChatMessage(
        id: 'maks-incoming-1',
        sender: 'maks.ygg',
        text: 'Wrzucilem build i logi do naszej skrzynki odbiorczej.',
        sentAtMillis: 1775806860000,
        direction: ChatMessageDirection.incoming,
      ),
    ],
    'nina.ygg': const <ChatMessage>[
      ChatMessage(
        id: 'nina-system-1',
        sender: 'system',
        text: 'Transfer zakończył się bez zrywania połączenia.',
        sentAtMillis: 1775721600000,
        direction: ChatMessageDirection.system,
      ),
    ],
  };
}

/// [thread] with [message] placed by its send time.
///
/// Nearly always an append. A message that was held by relays while this
/// device was offline can be older than what arrived since, and belongs
/// before it, not at the bottom.
List<ChatMessage> insertChronologically(
  List<ChatMessage> thread,
  ChatMessage message,
) {
  int index = thread.length;
  while (index > 0 && thread[index - 1].sentAtMillis > message.sentAtMillis) {
    index--;
  }
  return <ChatMessage>[
    ...thread.sublist(0, index),
    message,
    ...thread.sublist(index),
  ];
}
