import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';

const int kBlobChunkSize = 256 * 1024;

/// Largest single file (a video) accepted.
const int kMaxBlobBytes = 200 * 1024 * 1024;

const int kMaxBlobMimeLength = 80;

/// Describes one file: its size and the hash of every 256 KB piece.
/// The blob id is the hash of this manifest, so the id pins down every byte.
@immutable
final class BlobManifest {
  const BlobManifest._(this.size, this.mime, this.chunks, this.id);

  final int size;
  final String mime;
  final List<String> chunks;
  final String id;

  static Map<String, dynamic> _json(
    int size,
    String mime,
    List<String> chunks,
  ) => <String, dynamic>{
    't': 'blob',
    'size': size,
    'mime': mime,
    'chunk': kBlobChunkSize,
    'chunks': chunks,
  };

  Map<String, dynamic> toJson() => _json(size, mime, chunks);

  static BlobManifest? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'blob' ||
        json['chunk'] != kBlobChunkSize ||
        json['size'] is! int ||
        json['mime'] is! String ||
        (json['mime'] as String).length > kMaxBlobMimeLength ||
        json['chunks'] is! List) {
      return null;
    }
    final int size = json['size'] as int;
    final List<dynamic> chunks = json['chunks'] as List<dynamic>;
    final int expectedChunks = size <= 0
        ? 0
        : (size + kBlobChunkSize - 1) ~/ kBlobChunkSize;
    if (size < 0 ||
        size > kMaxBlobBytes ||
        chunks.length != expectedChunks ||
        !chunks.every((dynamic c) => isHex(c, 64))) {
      return null;
    }
    final List<String> typed = List<String>.unmodifiable(chunks);
    final String mime = json['mime'] as String;
    return BlobManifest._(
      size,
      mime,
      typed,
      sha256Hex(canonicalJsonBytes(_json(size, mime, typed))),
    );
  }

  static BlobManifest describe(Uint8List bytes, String mime) {
    final List<String> chunks = <String>[
      for (int i = 0; i < bytes.length; i += kBlobChunkSize)
        sha256Hex(
          Uint8List.sublistView(
            bytes,
            i,
            i + kBlobChunkSize < bytes.length
                ? i + kBlobChunkSize
                : bytes.length,
          ),
        ),
    ];
    return fromJson(_json(bytes.length, mime, chunks))!;
  }

  int chunkLength(int index) {
    final int start = index * kBlobChunkSize;
    final int rest = size - start;
    return rest < kBlobChunkSize ? rest : kBlobChunkSize;
  }
}

/// Where file pieces live. [has] is answered from memory; the bytes may be
/// on disk.
abstract interface class BlobChunkBackend {
  bool has(String hash);

  Iterable<String> get hashes;

  Future<Uint8List?> read(String hash);

  Future<void> write(String hash, Uint8List data);

  Future<void> delete(String hash);
}

final class MemoryBlobChunkBackend implements BlobChunkBackend {
  final Map<String, Uint8List> _chunks = <String, Uint8List>{};

  @override
  bool has(String hash) => _chunks.containsKey(hash);

  @override
  Iterable<String> get hashes => _chunks.keys;

  @override
  Future<Uint8List?> read(String hash) async => _chunks[hash];

  @override
  Future<void> write(String hash, Uint8List data) async {
    _chunks[hash] = data;
  }

  @override
  Future<void> delete(String hash) async {
    _chunks.remove(hash);
  }
}

/// Files by hash, stored as verified pieces. A piece is accepted only when
/// its hash matches a manifest we hold, so nobody can make us store data
/// we did not ask for.
final class BlobStore {
  BlobStore({BlobChunkBackend? backend})
    : backend = backend ?? MemoryBlobChunkBackend();

  final BlobChunkBackend backend;
  final Map<String, BlobManifest> _manifests = <String, BlobManifest>{};

  /// Hashes the user removed from this device ("Usuń z mojego
  /// urządzenia"): never stored or served again.
  final Set<String> refused = <String>{};

  /// Manifests we want (asked for, not yet complete).
  final Set<String> wanted = <String>{};

  /// Files fetched because of another account's ledger entry: by the
  /// writer whose entry first asked for each here ([noteFetchFor]). Only
  /// that writer's removals and the storage limits may drop such a file. A
  /// file this device made ([put]), or that something else asked for first
  /// (a chat, the account's own devices), has no writer here: what other
  /// people remove never touches it.
  final Map<String, String> fetchedFor = <String, String>{};

  /// Files dropped because of other people's entries, not by the user:
  /// by the writer whose removal dropped each ([dropFor]), or '' for the
  /// storage limits ([expire]). They are [refused] only for what that
  /// writer names: another writer's entry ([allowFor]) may fetch a file
  /// dropped by someone's removal again, and a chat ([claim]) any of them,
  /// so nobody can make this device refuse other people's files for good.
  final Map<String, String> droppedFor = <String, String>{};

  /// Called after any change worth saving (manifest added or removed).
  void Function()? onChanged;

  Iterable<BlobManifest> get manifests => _manifests.values;

  BlobManifest? manifest(String id) => _manifests[id];

  bool hasManifest(String id) => _manifests.containsKey(id);

  Future<Uint8List?> chunk(String hash) => backend.read(hash);

  /// Puts back what was saved before (no checks: our own disk).
  void restore({
    required Iterable<BlobManifest> manifests,
    required Iterable<String> refused,
    required Iterable<String> wanted,
    Map<String, String> fetchedFor = const <String, String>{},
    Map<String, String> droppedFor = const <String, String>{},
  }) {
    for (final BlobManifest m in manifests) {
      _manifests[m.id] = m;
    }
    this.refused.addAll(refused);
    this.wanted.addAll(wanted);
    this.fetchedFor.addAll(fetchedFor);
    droppedFor.forEach((String id, String by) {
      if (this.refused.contains(id)) {
        this.droppedFor[id] = by;
      }
    });
  }

  /// Stores [bytes] as a new blob; returns its id.
  Future<String> put(
    Uint8List bytes, {
    String mime = 'application/octet-stream',
  }) async {
    if (bytes.length > kMaxBlobBytes) {
      throw ArgumentError(t('Plik jest za duży.'));
    }
    final BlobManifest manifest = BlobManifest.describe(bytes, mime);
    for (int i = 0; i < manifest.chunks.length; i++) {
      final int start = i * kBlobChunkSize;
      if (!backend.has(manifest.chunks[i])) {
        await backend.write(
          manifest.chunks[i],
          Uint8List.fromList(
            Uint8List.sublistView(
              bytes,
              start,
              start + manifest.chunkLength(i),
            ),
          ),
        );
      }
    }
    _manifests[manifest.id] = manifest;
    refused.remove(manifest.id);
    wanted.remove(manifest.id);
    // Made here: no writer's removal can drop it.
    fetchedFor.remove(manifest.id);
    droppedFor.remove(manifest.id);
    onChanged?.call();
    return manifest.id;
  }

  /// Accepts a manifest we asked for, after checking it hashes to [id].
  bool acceptManifest(String id, Object? json) {
    if (refused.contains(id) || !wanted.contains(id)) {
      return false;
    }
    final BlobManifest? manifest = BlobManifest.fromJson(json);
    if (manifest == null || manifest.id != id) {
      return false;
    }
    if (!_manifests.containsKey(id)) {
      _manifests[id] = manifest;
      onChanged?.call();
    }
    return true;
  }

  /// Accepts a piece if some wanted manifest names it.
  Future<bool> acceptChunk(String hash, Uint8List data) async {
    if (backend.has(hash) || data.length > kBlobChunkSize) {
      return false;
    }
    final bool named = wanted.any(
      (String id) => _manifests[id]?.chunks.contains(hash) ?? false,
    );
    if (!named || sha256Hex(data) != hash) {
      return false;
    }
    await backend.write(hash, data);
    return true;
  }

  List<String> missingChunks(String id) {
    final BlobManifest? manifest = _manifests[id];
    if (manifest == null) {
      return const <String>[];
    }
    return <String>[
      for (final String c in manifest.chunks)
        if (!backend.has(c)) c,
    ];
  }

  /// Piece [index] of blob [id], or `null` while it (or the manifest) has
  /// not arrived: a film is played piece by piece while it downloads.
  Future<Uint8List?> chunkAt(String id, int index) async {
    final BlobManifest? manifest = _manifests[id];
    if (manifest == null ||
        index < 0 ||
        index >= manifest.chunks.length ||
        !backend.has(manifest.chunks[index])) {
      return null;
    }
    return backend.read(manifest.chunks[index]);
  }

  bool isComplete(String id) =>
      _manifests.containsKey(id) && missingChunks(id).isEmpty;

  /// The whole file, or `null` until every piece is here.
  Future<Uint8List?> read(String id) async {
    final BlobManifest? manifest = _manifests[id];
    if (manifest == null || !isComplete(id)) {
      return null;
    }
    final BytesBuilder out = BytesBuilder(copy: false);
    for (final String c in manifest.chunks) {
      final Uint8List? data = await backend.read(c);
      if (data == null) {
        return null;
      }
      out.add(data);
    }
    return out.takeBytes();
  }

  /// Marks [id] as wanted (it will be fetched from peers).
  void want(String id) {
    if (!refused.contains(id) && !isComplete(id) && wanted.add(id)) {
      onChanged?.call();
    }
  }

  void markDone(String id) {
    if (wanted.remove(id)) {
      onChanged?.call();
    }
  }

  /// An entry of [writer] asks for [id]: remembered as the writer that
  /// brought it, unless something asked for it, holds it or refused it
  /// before (the first reason wins).
  void noteFetchFor(String id, String writer) {
    if (writer.isEmpty ||
        refused.contains(id) ||
        wanted.contains(id) ||
        _manifests.containsKey(id) ||
        fetchedFor.containsKey(id)) {
      return;
    }
    fetchedFor[id] = writer;
    onChanged?.call();
  }

  /// [id] is used by something other than the feed (a chat): no removal
  /// by other people drops it any more, and such a drop is undone.
  void claim(String id) {
    final bool had = fetchedFor.remove(id) != null;
    final bool dropped = droppedFor.remove(id) != null;
    if (dropped) {
      refused.remove(id);
    }
    if (had || dropped) {
      onChanged?.call();
    }
  }

  /// An entry of [writer] names [id]: a drop caused by another writer's
  /// removal no longer stops it from being fetched.
  void allowFor(String id, String writer) {
    final String? by = droppedFor[id];
    if (by == null || by.isEmpty || by == writer) {
      return;
    }
    droppedFor.remove(id);
    refused.remove(id);
    onChanged?.call();
  }

  /// Whether [id] is not to be fetched for an entry of [writer].
  bool refusedFor(String id, String writer) {
    if (!refused.contains(id)) {
      return false;
    }
    final String? by = droppedFor[id];
    return by == null || by.isEmpty || by == writer;
  }

  /// Drops [id] because [writer] removed what named it, but only when an
  /// entry of [writer] brought it here ([fetchedFor]): nobody can make this
  /// device drop a file of others by naming it. Returns whether it went.
  Future<bool> dropFor(String id, String writer) async {
    if (writer.isEmpty || fetchedFor[id] != writer) {
      return false;
    }
    await refuse(id);
    droppedFor[id] = writer;
    onChanged?.call();
    return true;
  }

  /// Drops [id] for the storage limits, only when another account's entry
  /// brought it here ([fetchedFor]). Returns whether it went.
  Future<bool> expire(String id) async {
    if (!fetchedFor.containsKey(id)) {
      return false;
    }
    await refuse(id);
    droppedFor[id] = '';
    onChanged?.call();
    return true;
  }

  /// Removes [id] from this device for good.
  Future<void> refuse(String id) async {
    refused.add(id);
    wanted.remove(id);
    fetchedFor.remove(id);
    droppedFor.remove(id);
    final BlobManifest? manifest = _manifests.remove(id);
    if (manifest != null) {
      final Set<String> stillUsed = <String>{
        for (final BlobManifest m in _manifests.values) ...m.chunks,
      };
      for (final String c in manifest.chunks) {
        if (!stillUsed.contains(c)) {
          await backend.delete(c);
        }
      }
    }
    onChanged?.call();
  }
}
