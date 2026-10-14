import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

/// How long one nearby token lives: after that the phone looks like a new,
/// unrelated one to anyone who is not a friend.
const Duration kNearbyEpoch = Duration(minutes: 15);

int nearbyEpoch(int millis) => millis ~/ kNearbyEpoch.inMilliseconds;

/// The token a phone with [secret] shows in [epoch]: friends who know the
/// secret recognise it, nobody else can link two tokens.
Uint8List nearbyToken(String secret, int epoch) {
  final List<int> key = base64Url.decode(secret);
  final List<int> mac = crypto.Hmac(
    crypto.sha256,
    key,
  ).convert(utf8.encode('zen-nearby|$epoch')).bytes;
  return Uint8List.fromList(mac.sublist(0, 16));
}

/// [bytes] as lowercase hex.
String nearbyHex(List<int> bytes) =>
    bytes.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Bluetooth wave version of an alarm told to phones nearby (§16.3).
///
/// 5: signed (HMAC-SHA256 with the sender's nearby secret, which only
/// friends have) and dated. Older versions are not read.
const int kAlarmWaveVersion = 5;

/// A wave dated further than this from the receiver's clock (either way)
/// is dropped: a recorded wave cannot be played back later.
const Duration kAlarmWaveFreshFor = Duration(minutes: 10);

/// What an alarm id may look like (the app makes base36 ids).
final RegExp kAlarmIdPattern = RegExp(r'^[0-9A-Za-z_-]{1,40}$');

final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

/// An alarm wave heard over Bluetooth (§16.3).
///
/// `{v, id, at, end?, t?, m?}`: `t` is the sender's nearby token (friends
/// look up who it is), `m` the MAC over all of it. Without `t` and `m` the
/// wave is unsigned (the sender has no nearby secret yet): nobody can tell
/// whose it is.
@immutable
final class AlarmWave {
  const AlarmWave({
    required this.id,
    required this.at,
    required this.ended,
    this.token = '',
    this.mac = '',
  });

  final String id;

  /// When the sender made it (the sender's clock).
  final int at;
  final bool ended;
  final String token;
  final String mac;

  bool get signed => token.isNotEmpty && mac.isNotEmpty;

  /// The wave for alarm [id], made at [at]. Signed with [secret] (this
  /// person's nearby secret) when there is one and it is readable.
  static Map<String, dynamic> build({
    required String id,
    required int at,
    required bool ended,
    String? secret,
  }) {
    final Map<String, dynamic> wave = <String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': id,
      'at': at,
      if (ended) 'end': true,
    };
    if (secret == null) {
      return wave;
    }
    try {
      final String token = nearbyHex(nearbyToken(secret, nearbyEpoch(at)));
      wave['t'] = token;
      wave['m'] = _mac(secret, id: id, at: at, ended: ended, token: token);
    } on FormatException {
      // A damaged secret: the wave goes unsigned.
    }
    return wave;
  }

  /// [json] when it is a well-formed wave of this version, else `null`.
  static AlarmWave? parse(Map<dynamic, dynamic> json) {
    final Object? id = json['id'];
    final Object? at = json['at'];
    final Object? end = json['end'];
    final Object? t = json['t'];
    final Object? m = json['m'];
    if (json['v'] != kAlarmWaveVersion ||
        id is! String ||
        !kAlarmIdPattern.hasMatch(id) ||
        at is! int ||
        (end != null && end is! bool) ||
        (t != null && (t is! String || !_hex32.hasMatch(t))) ||
        (m != null && (m is! String || !_hex32.hasMatch(m)))) {
      return null;
    }
    return AlarmWave(
      id: id,
      at: at,
      ended: end == true,
      token: t is String ? t : '',
      mac: m is String ? m : '',
    );
  }

  /// Dated close enough to [now] (the receiver's clock).
  bool isFreshAt(int now) =>
      (now - at).abs() <= kAlarmWaveFreshFor.inMilliseconds;

  /// Whether the owner of [secret] made this very wave.
  bool verify(String secret) {
    if (!signed) {
      return false;
    }
    final String expected;
    try {
      expected = _mac(secret, id: id, at: at, ended: ended, token: token);
    } on FormatException {
      return false;
    }
    // Same length (both 32 hex): compare every character.
    int diff = 0;
    for (int i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ mac.codeUnitAt(i);
    }
    return diff == 0;
  }
}

String _mac(
  String secret, {
  required String id,
  required int at,
  required bool ended,
  required String token,
}) {
  final List<int> key = base64Url.decode(secret);
  final List<int> mac = crypto.Hmac(crypto.sha256, key)
      .convert(
        utf8.encode(
          'zen-nearby-alarm|$kAlarmWaveVersion|$id|$at|'
          '${ended ? 1 : 0}|$token',
        ),
      )
      .bytes;
  return nearbyHex(mac.sublist(0, 16));
}
