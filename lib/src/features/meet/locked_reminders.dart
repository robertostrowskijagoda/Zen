import 'package:flutter/foundation.dart';

/// Most reminders a nearby kit carries.
const int kLockedRemindersMax = 60;

/// How long after its time a reminder may still be shown while locked (a
/// phone that slept a little still says it; a day later it does not).
const Duration kLockedReminderLate = Duration(hours: 2);

/// A notification worked out in advance by the unlocked app (a circle's
/// dinner tomorrow, "Jak było?") for the Android background service to show
/// at [at] while the app is locked or closed: the service cannot read the
/// circles (they are under the master key), so it gets the finished text in
/// the nearby kit, sealed with the background key like the rest of it. The
/// same [id] as the app's own, so a notification is never there twice.
@immutable
final class LockedReminder {
  const LockedReminder({
    required this.id,
    required this.at,
    required this.title,
    required this.body,
    required this.slot,
  });

  final String id;
  final int at;
  final String title;
  final String body;
  final String slot;

  /// Whether it is to be shown at [now].
  bool dueAt(int now) =>
      now >= at && now - at < kLockedReminderLate.inMilliseconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'at': at,
    't': title,
    'b': body,
    's': slot,
  };

  static LockedReminder? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['at'] is! int ||
        json['t'] is! String ||
        json['b'] is! String ||
        json['s'] is! String) {
      return null;
    }
    String clip(String v, int max) => v.length > max ? v.substring(0, max) : v;
    return LockedReminder(
      id: clip(json['id'] as String, 120),
      at: json['at'] as int,
      title: clip(json['t'] as String, 200),
      body: clip(json['b'] as String, 400),
      slot: clip(json['s'] as String, 120),
    );
  }
}
