import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/media/media_vault.dart';

/// One saved call recording.
@immutable
final class CallRecording {
  const CallRecording({
    required this.id,
    required this.peer,
    required this.millis,
    required this.bytes,
    required this.file,
    this.mime = 'video/mp4',
  });

  final String id;

  /// Name of the encrypted file in the media vault
  /// ([MediaVault.fileNameOf]).
  final String file;

  /// Who the call was with (display name at the time).
  final String peer;
  final int millis;
  final int bytes;

  /// `video/mp4` (Android), `audio/mp4` (AAC: iPhone, iPad, Mac) or
  /// `audio/wav` (Windows, Linux); the last two are sound only.
  final String mime;

  bool get isAudioOnly => mime.startsWith('audio/');

  /// File extension when exported or played.
  String get extension => switch (mime) {
    'audio/wav' => 'wav',
    'audio/mp4' => 'm4a',
    _ => 'mp4',
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'peer': peer,
    'at': millis,
    'bytes': bytes,
    'file': file,
    'mime': mime,
  };

  static CallRecording? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? peer = json['peer'];
    final Object? at = json['at'];
    final Object? bytes = json['bytes'];
    final Object? mime = json['mime'];
    final Object? file = json['file'];
    if (id is! String ||
        peer is! String ||
        at is! int ||
        bytes is! int ||
        file is! String) {
      return null;
    }
    return CallRecording(
      id: id,
      peer: peer,
      millis: at,
      bytes: bytes,
      file: file,
      mime: mime is String ? mime : 'video/mp4',
    );
  }
}

/// Recordings kept encrypted in the app, never as plain files: each one a
/// file of the [MediaVault] (sealed piece by piece, so any length fits and
/// memory stays small), listed in a small index on [disk].
final class CallRecordingStore {
  CallRecordingStore(this.disk, this.vault);

  final LedgerDisk disk;
  final MediaVault vault;

  static const String _indexKey = 'recordings/index';

  Future<List<CallRecording>> list() async {
    final Uint8List? raw = await disk.read(_indexKey);
    if (raw == null) {
      return const <CallRecording>[];
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      return <CallRecording>[
        if (json is List)
          for (final Object? item in json) ?CallRecording.fromJson(item),
      ]..sort((CallRecording a, CallRecording b) => b.millis - a.millis);
    } on FormatException {
      return const <CallRecording>[];
    }
  }

  Future<void> _saveIndex(List<CallRecording> items) => disk.write(
    _indexKey,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<Map<String, dynamic>>[
          for (final CallRecording r in items) r.toJson(),
        ]),
      ),
    ),
  );

  /// Encrypts the plain recording [source] into the vault and lists it.
  /// [source] itself is left as it is (the caller deletes it once this
  /// returns); on failure nothing new stays behind.
  Future<CallRecording> addFile({
    required String peer,
    required File source,
    required int millis,
    String mime = 'video/mp4',
  }) async {
    final int bytes = await source.length();
    final String path = await vault.putFile(source, deleteSource: false);
    try {
      final CallRecording rec = CallRecording(
        id: 'rec-$millis-${MediaVault.fileNameOf(path).substring(0, 8)}',
        peer: peer,
        millis: millis,
        bytes: bytes,
        file: MediaVault.fileNameOf(path),
        mime: mime,
      );
      await _saveIndex(<CallRecording>[rec, ...await list()]);
      return rec;
    } on Object {
      await vault.delete(path);
      rethrow;
    }
  }

  /// Where the encrypted file of [rec] is.
  Future<String> pathOf(CallRecording rec) => vault.pathOf(rec.file);

  /// A short-lived plain copy of [rec] for a player (random name in the
  /// temporary media folder); the caller deletes it after use.
  Future<File> openTemporary(CallRecording rec) async =>
      vault.openTemporary(await pathOf(rec), extension: '.${rec.extension}');

  /// Decrypts [rec] into the plain file [target], piece by piece.
  Future<void> exportTo(CallRecording rec, File target) async =>
      vault.decryptToFile(await pathOf(rec), target);

  Future<void> delete(String id) async {
    final List<CallRecording> all = await list();
    for (final CallRecording r in all) {
      if (r.id == id) {
        await vault.delete(await pathOf(r));
      }
    }
    await _saveIndex(<CallRecording>[
      for (final CallRecording r in all)
        if (r.id != id) r,
    ]);
  }
}

/// What became of a finished recording.
enum CallRecordingOutcome {
  /// Encrypted in the app; the plain file is gone.
  saved,

  /// Nothing was recorded (no file, or an empty one).
  empty,

  /// Not encrypted (no space, the app locked): the plain file waits in the
  /// temporary media folder for another try until the app closes.
  failed,
}

/// Moves a finished recording from its temporary file into the encrypted
/// store. The plain file is deleted only once the recording is safely
/// stored; when that fails it stays and this throws. Returns the
/// recording, or null when the file is missing or empty.
Future<CallRecording?> keepCallRecording(
  CallRecordingStore store, {
  required String path,
  required String mime,
  required String label,
  int? millis,
}) async {
  final File file = File(path);
  if (!file.existsSync()) {
    return null;
  }
  if (file.lengthSync() == 0) {
    await file.delete();
    return null;
  }
  final CallRecording rec = await store.addFile(
    peer: label.trim().isEmpty ? t('Rozmowa') : label.trim(),
    source: file,
    millis: millis ?? DateTime.now().millisecondsSinceEpoch,
    mime: mime,
  );
  try {
    await file.delete();
  } on FileSystemException catch (error) {
    // Stored already; the temporary folder is emptied at exit anyway.
    logZenWarning('Deleting a plain call recording failed: $error');
  }
  return rec;
}

/// A finished recording that could not be stored yet: its plain file, its
/// type and who the call was with.
@immutable
final class UnsavedCallRecording {
  const UnsavedCallRecording({
    required this.path,
    required this.mime,
    required this.label,
    required this.millis,
  });

  final String path;
  final String mime;
  final String label;
  final int millis;
}

/// Stores finished recordings and remembers the ones it could not store,
/// so the person is told and can try again (until the app closes: the
/// plain files never outlive it).
final class CallRecordingKeeper extends ChangeNotifier {
  CallRecordingKeeper(this.store);

  final CallRecordingStore store;
  final List<UnsavedCallRecording> _unsaved = <UnsavedCallRecording>[];
  bool _disposed = false;

  void _changed() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Recordings waiting for another try, oldest first.
  List<UnsavedCallRecording> get unsaved =>
      List<UnsavedCallRecording>.unmodifiable(_unsaved);

  /// Stores the recording at [path]; never throws.
  Future<CallRecordingOutcome> keep({
    required String path,
    required String mime,
    required String label,
    int? millis,
  }) => _keep(
    UnsavedCallRecording(
      path: path,
      mime: mime,
      label: label,
      millis: millis ?? DateTime.now().millisecondsSinceEpoch,
    ),
  );

  Future<CallRecordingOutcome> _store(UnsavedCallRecording item) async {
    try {
      final CallRecording? rec = await keepCallRecording(
        store,
        path: item.path,
        mime: item.mime,
        label: item.label,
        millis: item.millis,
      );
      return rec == null
          ? CallRecordingOutcome.empty
          : CallRecordingOutcome.saved;
    } on Object catch (error, stackTrace) {
      logZenError('Saving the call recording failed', error, stackTrace);
      return CallRecordingOutcome.failed;
    }
  }

  Future<CallRecordingOutcome> _keep(UnsavedCallRecording item) async {
    final CallRecordingOutcome outcome = await _store(item);
    final bool known = _unsaved.any(
      (UnsavedCallRecording u) => u.path == item.path,
    );
    if (outcome == CallRecordingOutcome.failed && !known) {
      _unsaved.add(item);
      _changed();
    } else if (outcome != CallRecordingOutcome.failed && known) {
      _unsaved.removeWhere((UnsavedCallRecording u) => u.path == item.path);
      _changed();
    }
    return outcome;
  }

  /// Tries every waiting recording again; true when none is left.
  Future<bool> retry() async {
    for (final UnsavedCallRecording item in unsaved) {
      await _keep(item);
    }
    return _unsaved.isEmpty;
  }

  /// Gives up on the waiting recordings: their plain files go now.
  Future<void> discard() async {
    final List<UnsavedCallRecording> items = unsaved;
    _unsaved.clear();
    _changed();
    for (final UnsavedCallRecording item in items) {
      try {
        final File file = File(item.path);
        if (file.existsSync()) {
          await file.delete();
        }
      } on FileSystemException catch (error) {
        logZenWarning('Deleting a plain call recording failed: $error');
      }
    }
  }
}

/// The keeper of this account: the recordings index on its disk, the files
/// in its media vault.
final Provider<CallRecordingKeeper> callRecordingKeeperProvider =
    Provider<CallRecordingKeeper>((Ref ref) {
      final CallRecordingKeeper keeper = CallRecordingKeeper(
        CallRecordingStore(
          ref.watch(ledgerDiskProvider),
          ref.watch(mediaVaultProvider),
        ),
      );
      ref.onDispose(keeper.dispose);
      return keeper;
    });
