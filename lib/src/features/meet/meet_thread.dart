import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Longest message in a small chat about one thing.
const int kMeetThreadMaxText = 500;

/// Messages one thread keeps (the oldest go).
const int kMeetThreadMaxMessages = 200;

/// Threads kept at most (the oldest go).
const int kMeetThreadMaxThreads = 200;

final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,40}$');

/// One message in a small chat about one thing — a circle's dinner, an
/// accepted request for food — like the chat about an invitation among
/// neighbours: short, kept on the phone, only with the people of that
/// thing.
@immutable
final class MeetThreadMessage {
  const MeetThreadMessage({
    required this.id,
    required this.from,
    required this.text,
    required this.at,
    this.mine = false,
  });

  final String id;

  /// Who wrote it (normalised address).
  final String from;
  final String text;
  final int at;

  /// Written on this phone.
  final bool mine;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'f': from,
    'x': text,
    't': at,
    if (mine) 'me': true,
  };

  static MeetThreadMessage? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['f'] is! String ||
        json['x'] is! String ||
        json['t'] is! int) {
      return null;
    }
    final String? text = cleanThreadText(json['x'] as String);
    if (text == null || !_idPattern.hasMatch(json['id'] as String)) {
      return null;
    }
    return MeetThreadMessage(
      id: json['id'] as String,
      from: PeerShareCodec.normalizeAddress(json['f'] as String),
      text: text,
      at: json['t'] as int,
      mine: json['me'] == true,
    );
  }
}

/// [text] trimmed and cut to [kMeetThreadMaxText]; `null` when empty.
String? cleanThreadText(String text) {
  final String v = text.trim();
  if (v.isEmpty) {
    return null;
  }
  return v.length > kMeetThreadMaxText ? v.substring(0, kMeetThreadMaxText) : v;
}

/// Whether [id] may name a thread message.
bool isThreadMessageId(Object? id) => id is String && _idPattern.hasMatch(id);

/// A fresh message id.
String newThreadMessageId(Random random) => List<String>.generate(
  16,
  (_) => random.nextInt(36).toRadixString(36),
).join();

/// Small chats by key (e.g. "circle|2026-10-15"), with what this person
/// last read in each.
final class MeetThreads {
  final Map<String, List<MeetThreadMessage>> _threads =
      <String, List<MeetThreadMessage>>{};
  final Map<String, int> _read = <String, int>{};

  /// The messages of [key], oldest first.
  List<MeetThreadMessage> thread(String key) =>
      List<MeetThreadMessage>.unmodifiable(
        _threads[key] ?? const <MeetThreadMessage>[],
      );

  /// Adds [m] to [key]; false when it is there already (the same id).
  bool add(String key, MeetThreadMessage m) {
    final List<MeetThreadMessage> list =
        _threads.remove(key) ?? <MeetThreadMessage>[];
    // The thread written to last goes last (the oldest are dropped first).
    _threads[key] = list;
    if (list.any((MeetThreadMessage x) => x.id == m.id)) {
      return false;
    }
    // In time order; equal times keep the order they came in.
    int at = list.length;
    while (at > 0 && list[at - 1].at > m.at) {
      at--;
    }
    list.insert(at, m);
    while (list.length > kMeetThreadMaxMessages) {
      list.removeAt(0);
    }
    while (_threads.length > kMeetThreadMaxThreads) {
      final String oldest = _threads.keys.first;
      _threads.remove(oldest);
      _read.remove(oldest);
    }
    return true;
  }

  /// Messages from others in [key] after this person last read it.
  int unread(String key) {
    final int since = _read[key] ?? 0;
    return (_threads[key] ?? const <MeetThreadMessage>[])
        .where((MeetThreadMessage m) => !m.mine && m.at > since)
        .length;
  }

  void markRead(String key, int at) => _read[key] = at;

  /// Drops the threads [gone] says are over.
  void removeWhere(bool Function(String key) gone) {
    _threads.removeWhere((String k, List<MeetThreadMessage> _) => gone(k));
    _read.removeWhere((String k, int _) => gone(k));
  }

  void clear() {
    _threads.clear();
    _read.clear();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'th': <String, dynamic>{
      for (final MapEntry<String, List<MeetThreadMessage>> e
          in _threads.entries)
        e.key: <Map<String, dynamic>>[
          for (final MeetThreadMessage m in e.value) m.toJson(),
        ],
    },
    'rd': _read,
  };

  void readJson(Object? json) {
    clear();
    if (json is! Map) {
      return;
    }
    final Object? th = json['th'];
    if (th is Map) {
      for (final MapEntry<dynamic, dynamic> e in th.entries.take(
        kMeetThreadMaxThreads,
      )) {
        if (e.key is! String || e.value is! List) {
          continue;
        }
        _threads[e.key as String] = <MeetThreadMessage>[
          for (final Object? m in (e.value as List).take(
            kMeetThreadMaxMessages,
          ))
            if (MeetThreadMessage.fromJson(m) case final MeetThreadMessage x) x,
        ];
      }
    }
    final Object? rd = json['rd'];
    if (rd is Map) {
      rd.forEach((Object? k, Object? v) {
        if (k is String && v is int) {
          _read[k] = v;
        }
      });
    }
  }
}
