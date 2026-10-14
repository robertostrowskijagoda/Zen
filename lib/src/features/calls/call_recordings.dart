import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';

/// One saved call recording (§13.2).
@immutable
final class CallRecording {
  const CallRecording({
    required this.id,
    required this.peer,
    required this.millis,
    required this.bytes,
    this.mime = 'video/mp4',
  });

  final String id;

  /// Who the call was with (display name at the time).
  final String peer;
  final int millis;
  final int bytes;

  /// `video/mp4` (Android) or `audio/wav` (Windows: sound only).
  final String mime;

  bool get isAudioOnly => mime.startsWith('audio/');

  /// File extension when exported or played.
  String get extension => mime == 'audio/wav' ? 'wav' : 'mp4';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'peer': peer,
    'at': millis,
    'bytes': bytes,
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
    if (id is! String || peer is! String || at is! int || bytes is! int) {
      return null;
    }
    return CallRecording(
      id: id,
      peer: peer,
      millis: at,
      bytes: bytes,
      mime: mime is String ? mime : 'video/mp4',
    );
  }
}

/// Recordings kept in the app's encrypted storage, never as plain files.
final class CallRecordingStore {
  CallRecordingStore(this.disk);

  final LedgerDisk disk;

  static const String _indexKey = 'recordings/index';

  static String _key(String id) => 'recordings/$id';

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

  Future<CallRecording> add({
    required String peer,
    required Uint8List data,
    required int millis,
    String mime = 'video/mp4',
  }) async {
    final CallRecording rec = CallRecording(
      id: 'rec-$millis',
      peer: peer,
      millis: millis,
      bytes: data.length,
      mime: mime,
    );
    await disk.write(_key(rec.id), data);
    await _saveIndex(<CallRecording>[rec, ...await list()]);
    return rec;
  }

  Future<Uint8List?> read(String id) => disk.read(_key(id));

  Future<void> delete(String id) async {
    await disk.delete(_key(id));
    await _saveIndex(<CallRecording>[
      for (final CallRecording r in await list())
        if (r.id != id) r,
    ]);
  }
}

/// Moves a finished recording from its temporary file into the encrypted
/// store (and removes the plain file). Returns it, or null when the file
/// is missing or empty.
Future<CallRecording?> keepCallRecording(
  LedgerDisk disk, {
  required String path,
  required String mime,
  required String label,
  int? millis,
}) async {
  final File file = File(path);
  if (!file.existsSync()) {
    return null;
  }
  try {
    final Uint8List data = await file.readAsBytes();
    if (data.isEmpty) {
      return null;
    }
    return await CallRecordingStore(disk).add(
      peer: label.trim().isEmpty ? 'Rozmowa' : label.trim(),
      data: data,
      millis: millis ?? DateTime.now().millisecondsSinceEpoch,
      mime: mime,
    );
  } finally {
    if (file.existsSync()) {
      await file.delete();
    }
  }
}
