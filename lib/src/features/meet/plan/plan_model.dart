import 'package:flutter/foundation.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// "Dołączam" by default once this many people join (§17.6).
const int kPlanDefaultThreshold = 3;
const int kPlanMinThreshold = 2;
const int kPlanMaxThreshold = 20;

/// Longest title and place of a plan.
const int kPlanMaxTitle = 80;
const int kPlanMaxPlace = 100;

/// A plan stays on screen this long after its time, then fades.
const Duration kPlanFadeAfter = Duration(hours: 6);

/// Who sees a plan (§17.6).
enum PlanReach {
  close('Bliscy'),
  friends('Znajomi'),
  friendsOfFriends('Znajomi znajomych');

  const PlanReach(this.label);

  final String label;

  /// Unknown names fall back to the narrowest reach.
  static PlanReach byName(Object? n) =>
      PlanReach.values.where((PlanReach r) => r.name == n).firstOrNull ??
      PlanReach.close;
}

/// A friend's answer to a plan.
enum PlanAnswerKind {
  join('Dołączam'),
  maybe('Może');

  const PlanAnswerKind(this.label);

  final String label;

  static PlanAnswerKind? byName(Object? n) => PlanAnswerKind.values
      .where((PlanAnswerKind k) => k.name == n)
      .firstOrNull;
}

String _clip(Object? v, int max) =>
    v is String ? (v.length > max ? v.substring(0, max) : v) : '';

/// Someone who answered a plan.
@immutable
final class PlanAnswer {
  const PlanAnswer({
    required this.address,
    required this.name,
    required this.kind,
    required this.at,
    this.via,
    this.viaName = '',
  });

  final String address;
  final String name;
  final PlanAnswerKind kind;
  final int at;

  /// The organizer's friend this person is connected through (`null` for
  /// the organizer's own friend).
  final String? via;
  final String viaName;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    'n': name,
    'k': kind.name,
    'at': at,
    if (via != null) 'via': via,
    if (viaName.isNotEmpty) 'vn': viaName,
  };

  static PlanAnswer? fromJson(Object? json) {
    if (json is! Map || json['a'] is! String || json['at'] is! int) {
      return null;
    }
    final PlanAnswerKind? kind = PlanAnswerKind.byName(json['k']);
    if (kind == null) {
      return null;
    }
    final Object? via = json['via'];
    return PlanAnswer(
      address: PeerShareCodec.normalizeAddress(json['a'] as String),
      name: _clip(json['n'], 60),
      kind: kind,
      at: json['at'] as int,
      via: via is String && via.isNotEmpty
          ? PeerShareCodec.normalizeAddress(via)
          : null,
      viaName: _clip(json['vn'], 60),
    );
  }
}

/// "Plan na weekend" (§17.6): a light plan ("Sobota: rower nad Wisłą,
/// 10:00, kto chętny?"). The organizer's phone holds the truth and sends
/// everyone in reach the current copy; once [threshold] people join, it
/// becomes an event (§17.1).
@immutable
final class WeekendPlan {
  const WeekendPlan({
    required this.id,
    required this.organizer,
    required this.organizerName,
    required this.title,
    required this.startsAt,
    this.place = '',
    this.reach = PlanReach.friends,
    this.threshold = kPlanDefaultThreshold,
    this.answers = const <String, PlanAnswer>{},
    this.eventId,
    this.cancelled = false,
    this.updatedAt = 0,
  });

  final String id;

  /// The organizer's mesh address ('self' when it is this person).
  final String organizer;
  final String organizerName;
  final String title;
  final String place;
  final int startsAt;
  final PlanReach reach;

  /// How many "Dołączam" turn the plan into an event.
  final int threshold;
  final Map<String, PlanAnswer> answers;

  /// The event the plan turned into.
  final String? eventId;
  final bool cancelled;
  final int updatedAt;

  bool get isMine => organizer == 'self';
  bool get isEvent => eventId != null;

  List<PlanAnswer> _of(PlanAnswerKind kind) =>
      answers.values.where((PlanAnswer a) => a.kind == kind).toList()
        ..sort((PlanAnswer a, PlanAnswer b) => a.at.compareTo(b.at));

  /// Who joined, first come first.
  List<PlanAnswer> get joined => _of(PlanAnswerKind.join);
  List<PlanAnswer> get maybe => _of(PlanAnswerKind.maybe);
  int get joinCount => joined.length;

  /// Still on screen at [now] (not cancelled, its time not long gone).
  bool showsAt(int now) =>
      !cancelled && now < startsAt + kPlanFadeAfter.inMilliseconds;

  WeekendPlan copyWith({
    String? organizer,
    Map<String, PlanAnswer>? answers,
    String? eventId,
    bool? cancelled,
    int? updatedAt,
  }) => WeekendPlan(
    id: id,
    organizer: organizer ?? this.organizer,
    organizerName: organizerName,
    title: title,
    place: place,
    startsAt: startsAt,
    reach: reach,
    threshold: threshold,
    answers: answers ?? this.answers,
    eventId: eventId ?? this.eventId,
    cancelled: cancelled ?? this.cancelled,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'org': organizer,
    'orgName': organizerName,
    'title': title,
    if (place.isNotEmpty) 'place': place,
    'at': startsAt,
    'reach': reach.name,
    'min': threshold,
    'ans': <Map<String, dynamic>>[
      for (final PlanAnswer a in answers.values) a.toJson(),
    ],
    if (eventId != null) 'ev': eventId,
    if (cancelled) 'cancelled': true,
    'upd': updatedAt,
  };

  /// Most answers taken from one copy.
  static const int maxAnswers = 300;

  static WeekendPlan? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? org = json['org'];
    final Object? title = json['title'];
    final Object? at = json['at'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 40 ||
        org is! String ||
        org.isEmpty ||
        title is! String ||
        title.trim().isEmpty ||
        at is! int) {
      return null;
    }
    final Object? min = json['min'];
    final Object? ans = json['ans'];
    final Object? ev = json['ev'];
    final Map<String, PlanAnswer> answers = <String, PlanAnswer>{};
    if (ans is List) {
      for (final Object? a in ans.take(maxAnswers)) {
        final PlanAnswer? answer = PlanAnswer.fromJson(a);
        if (answer != null) {
          answers[answer.address] = answer;
        }
      }
    }
    return WeekendPlan(
      id: id,
      organizer: org,
      organizerName: _clip(json['orgName'], 60),
      title: _clip(title.trim(), kPlanMaxTitle),
      place: _clip(json['place'], kPlanMaxPlace),
      startsAt: at,
      reach: PlanReach.byName(json['reach']),
      threshold: min is int
          ? min.clamp(kPlanMinThreshold, kPlanMaxThreshold)
          : kPlanDefaultThreshold,
      answers: answers,
      eventId: ev is String && ev.isNotEmpty && ev.length <= 40 ? ev : null,
      cancelled: json['cancelled'] == true,
      updatedAt: json['upd'] is int ? json['upd'] as int : 0,
    );
  }
}

const List<String> _weekdays = <String>[
  'Poniedziałek',
  'Wtorek',
  'Środa',
  'Czwartek',
  'Piątek',
  'Sobota',
  'Niedziela',
];

/// When a plan is, said the short way: "Dziś, 18:00", "Jutro, 10:00",
/// "Sobota, 10:00" (this week), else "25.10, 10:00".
String planWhen(int millis, int now) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(millis);
  final DateTime n = DateTime.fromMillisecondsSinceEpoch(now);
  String two(int v) => v.toString().padLeft(2, '0');
  final String time = '${two(d.hour)}:${two(d.minute)}';
  // Rounded: a day around a clock change is 23 or 25 hours long.
  final int days =
      (DateTime(
                d.year,
                d.month,
                d.day,
              ).difference(DateTime(n.year, n.month, n.day)).inHours /
              24)
          .round();
  if (days == 0) {
    return 'Dziś, $time';
  }
  if (days == 1) {
    return 'Jutro, $time';
  }
  if (days > 1 && days < 7) {
    return '${_weekdays[d.weekday - 1]}, $time';
  }
  return '${d.day}.${two(d.month)}, $time';
}
