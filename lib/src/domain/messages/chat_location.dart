import 'package:flutter/foundation.dart';

/// Where a message carries a shared position (on the wire and in storage).
const String kLocationKey = 'loc';

/// The longest a position is shared for.
const Duration kMaxLocationShare = Duration(hours: 8);

/// A position shared in a chat until [untilMillis]: while that lasts the
/// sender's Zen sends newer ones (as edits of the same message, so a Zen
/// without this feature shows the newest map link in its text).
@immutable
final class ChatLocation {
  const ChatLocation({
    required this.lat,
    required this.lon,
    required this.accuracy,
    required this.atMillis,
    required this.untilMillis,
    this.arrived = false,
  });

  final double lat;
  final double lon;

  /// Metres.
  final double accuracy;

  /// When it was measured.
  final int atMillis;

  /// Until when newer positions come; at or before [atMillis]: shared once,
  /// or the sharing ended.
  final int untilMillis;

  /// The sharer said "Jestem na miejscu": the last position, where they
  /// arrived (the sharing ended with it).
  final bool arrived;

  /// Newer positions still come at [nowMillis].
  bool isLiveAt(int nowMillis) => nowMillis < untilMillis;

  ChatLocation copyWith({int? untilMillis, bool? arrived}) => ChatLocation(
    lat: lat,
    lon: lon,
    accuracy: accuracy,
    atMillis: atMillis,
    untilMillis: untilMillis ?? this.untilMillis,
    arrived: arrived ?? this.arrived,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'la': lat,
    'lo': lon,
    'ac': accuracy.round(),
    'at': atMillis,
    'un': untilMillis,
    if (arrived) 'ar': true,
  };

  static ChatLocation? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? lat = json['la'];
    final Object? lon = json['lo'];
    final Object? accuracy = json['ac'];
    final Object? at = json['at'];
    final Object? until = json['un'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180 ||
        at is! int ||
        until is! int ||
        at <= 0) {
      return null;
    }
    return ChatLocation(
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      accuracy: accuracy is num && accuracy.isFinite && accuracy >= 0
          ? accuracy.toDouble()
          : 0,
      atMillis: at,
      // Never longer than the longest sharing.
      untilMillis: until.clamp(0, at + kMaxLocationShare.inMilliseconds),
      arrived: json['ar'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatLocation &&
      other.lat == lat &&
      other.lon == lon &&
      other.accuracy == accuracy &&
      other.atMillis == atMillis &&
      other.untilMillis == untilMillis &&
      other.arrived == arrived;

  @override
  int get hashCode =>
      Object.hash(lat, lon, accuracy, atMillis, untilMillis, arrived);
}
