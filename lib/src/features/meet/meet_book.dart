import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/nearby_crypto.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// "Chcę pogadać" and friends (§16.2): what someone is up for right now.
///
/// Sent by name, so the order here is only the order on screen; an older
/// app that does not know a newer status simply shows none.
enum IntentKind {
  /// Not the alarm (§16.3, danger, location, sound): "please, today" — a
  /// louder notification than [help].
  urgent('🆘'),
  help('🤝'),
  canHelp('🙋'),
  talk('💬'),
  out('🍻'),
  walk('🚶'),
  eat('🍽️'),
  play('🎲'),
  dnd('🔕'),

  /// Opt-in, only while dating is on (§16.2, §19); never shown to the
  /// people the dating profile is hidden from.
  dating('💘'),

  /// The person's own words ([IntentStatus.note], required, short) and an
  /// emoji they picked ([IntentStatus.emoji]). An older app does not know
  /// it and shows no status.
  custom('✨');

  const IntentKind(this.emoji);

  final String emoji;

  String get label => switch (this) {
    IntentKind.urgent => t('Pilnie potrzebuję pomocy'),
    IntentKind.help => t('Potrzebuję pomocy'),
    IntentKind.canHelp => t('Mogę pomóc'),
    IntentKind.talk => t('Chcę pogadać'),
    IntentKind.out => t('Chcę wyjść'),
    IntentKind.walk => t('Idę na spacer'),
    IntentKind.eat => t('Chcę coś zjeść razem'),
    IntentKind.play => t('Chcę pograć'),
    IntentKind.dnd => t('Nie przeszkadzać'),
    IntentKind.dating => t('Randkuję'),
    IntentKind.custom => t('Własny status'),
  };

  static IntentKind? byName(Object? name) =>
      IntentKind.values.where((IntentKind k) => k.name == name).firstOrNull;
}

/// Emoji to pick for a custom status ([IntentKind.custom]); the first is
/// the default.
const List<String> kCustomStatusEmoji = <String>[
  '✨',
  '😊',
  '😴',
  '🎉',
  '💪',
  '📚',
  '💻',
  '☕',
  '🎵',
  '🤒',
  '✈️',
  '🏠',
];

@immutable
final class IntentStatus {
  const IntentStatus({
    required this.kind,
    required this.setAt,
    this.until = 0,
    this.note = '',
    this.onlyClose = false,
    this.emoji = '',
  });

  final IntentKind kind;
  final int setAt;

  /// When it goes out by itself; 0 = until switched off.
  final int until;
  final String note;

  /// Shown to "przyjaciele" only.
  final bool onlyClose;

  /// The emoji of a custom status ('' = the kind's own).
  final String emoji;

  /// Longest text of a custom status (UTF-16 units).
  static const int maxCustomChars = 40;

  /// Longest emoji kept (UTF-16 units: one emoji with its modifiers).
  static const int maxEmojiUnits = 8;

  bool get isCustom => kind == IntentKind.custom;

  /// The emoji to show: a custom status's own, else the kind's.
  String get shownEmoji => isCustom && emoji.isNotEmpty ? emoji : kind.emoji;

  /// The name to show: a custom status's own words, else the kind's label.
  String get shownLabel => isCustom && note.isNotEmpty ? note : kind.label;

  /// The note to show under the name (a custom status's words are its name).
  String get shownNote => isCustom ? '' : note;

  bool activeAt(int now) => until == 0 || now < until;

  /// [text] cut to [maxCustomChars] (never in the middle of an emoji's
  /// surrogate pair).
  static String cutCustom(String text) {
    if (text.length <= maxCustomChars) {
      return text;
    }
    final int last = text.codeUnitAt(maxCustomChars - 1);
    final bool splitsPair = last >= 0xD800 && last <= 0xDBFF;
    return text.substring(0, splitsPair ? maxCustomChars - 1 : maxCustomChars);
  }

  /// [value] when it is a short emoji-like string, else ''.
  static String cleanEmoji(Object? value) {
    if (value is! String) {
      return '';
    }
    final String e = value.trim();
    if (e.isEmpty || e.length > maxEmojiUnits || e.contains(RegExp(r'\s'))) {
      return '';
    }
    return e;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'k': kind.name,
    'at': setAt,
    'until': until,
    if (note.isNotEmpty) 'note': note,
    if (onlyClose) 'close': true,
    if (emoji.isNotEmpty) 'e': emoji,
  };

  static IntentStatus? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final IntentKind? kind = IntentKind.byName(json['k']);
    final Object? at = json['at'];
    final Object? until = json['until'];
    final Object? note = json['note'];
    if (kind == null || at is! int || until is! int || until < 0) {
      return null;
    }
    final String text = note is String
        ? (note.length > 140 ? note.substring(0, 140) : note)
        : '';
    final bool custom = kind == IntentKind.custom;
    if (custom && text.trim().isEmpty) {
      return null; // a custom status is its words
    }
    return IntentStatus(
      kind: kind,
      setAt: at,
      until: until,
      note: custom ? cutCustom(text.trim()) : text,
      onlyClose: json['close'] == true,
      emoji: custom ? cleanEmoji(json['e']) : '',
    );
  }
}

/// Who sees this person's friend list (§16.1, §24.1).
enum FriendListAudience {
  /// Every friend, weak acquaintances too.
  all,

  /// Friends at level "Znajomy" and up (the default, §8): a weak
  /// acquaintance sees it only after asking and being let in.
  friends,

  /// Only friends this person let see it, after they asked.
  onRequest,

  /// Nobody.
  nobody;

  static FriendListAudience? byName(Object? name) => FriendListAudience.values
      .where((FriendListAudience a) => a.name == name)
      .firstOrNull;
}

/// How a friend answered an alarm.
enum AlarmResponse {
  coming,
  calling,
  cant;

  String get label => switch (this) {
    AlarmResponse.coming => t('Jadę'),
    AlarmResponse.calling => t('Dzwonię'),
    AlarmResponse.cant => t('Nie mogę'),
  };

  static AlarmResponse? byName(Object? name) => AlarmResponse.values
      .where((AlarmResponse r) => r.name == name)
      .firstOrNull;
}

/// A piece of sound recorded during an alarm (§16.3): the audio itself
/// lives in the store under [MeetStore.audioKey].
@immutable
final class AlarmClip {
  const AlarmClip({required this.n, required this.at, this.ms = 0});

  /// Its number within the alarm (0, 1, …).
  final int n;
  final int at;

  /// How long it is.
  final int ms;

  Map<String, int> toJson() => <String, int>{'n': n, 'at': at, 'ms': ms};

  static AlarmClip? fromJson(Object? json) {
    if (json is! Map || json['n'] is! int || json['at'] is! int) {
      return null;
    }
    return AlarmClip(
      n: json['n'] as int,
      at: json['at'] as int,
      ms: json['ms'] is int ? json['ms'] as int : 0,
    );
  }
}

/// What a friend's phone told about this person's alarm (§16.3): when it
/// got it and when the friend opened it. Times are this phone's.
@immutable
final class AlarmDelivery {
  const AlarmDelivery({this.got, this.seen});

  /// When the friend's phone confirmed it has the alarm.
  final int? got;

  /// When the friend opened it on screen.
  final int? seen;

  Map<String, int> toJson() => <String, int>{'g': ?got, 's': ?seen};

  static AlarmDelivery? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? g = json['g'];
    final Object? s = json['s'];
    if (g is! int && s is! int) {
      return null;
    }
    return AlarmDelivery(got: g is int ? g : null, seen: s is int ? s : null);
  }
}

/// How far this person's alarm got with one friend (§16.3): sent and not
/// confirmed yet, on their phone, opened, answered.
enum AlarmReach { sent, delivered, seen, answered }

/// One alarm (§16.3), sent or received.
@immutable
final class AlarmRecord {
  const AlarmRecord({
    required this.id,
    required this.from,
    required this.at,
    this.lat,
    this.lon,
    this.accuracy,
    this.locatedAt,
    this.note = '',
    this.responses = const <String, AlarmResponse>{},
    this.endedAt,
    this.duress = false,
    this.clips = const <AlarmClip>[],
    this.nearby = false,
    this.sentTo = const <String>[],
    this.deliveries = const <String, AlarmDelivery>{},
  });

  final String id;

  /// Who raised it ('self' for this person's own alarm).
  final String from;
  final int at;
  final double? lat;
  final double? lon;
  final double? accuracy;
  final int? locatedAt;
  final String note;

  /// Who answered and how (address → answer; 'self' for this person).
  final Map<String, AlarmResponse> responses;

  /// When it was called off ("Jestem bezpieczny").
  final int? endedAt;

  /// Called off with the panic PIN: the person may be forced to say they
  /// are safe. Only friends see this; the person's own screen does not.
  final bool duress;

  /// Sound recorded during the alarm that this phone has (sent or got).
  final List<AlarmClip> clips;

  /// Heard over Bluetooth from a friend nearby (the mesh copy may follow).
  final bool nearby;

  /// This person's own alarm: the friends it went to (normalised
  /// addresses). Only they may confirm it.
  final List<String> sentTo;

  /// This person's own alarm: what friends' phones confirmed (address →
  /// delivery). A friend whose phone never confirms stays "sent".
  final Map<String, AlarmDelivery> deliveries;

  /// Most friends one alarm keeps track of.
  static const int maxRecipients = 1000;

  /// Most answers one alarm keeps (B10: a friend's copy carries everyone's
  /// answers, so its size has a limit).
  static const int maxResponses = 200;

  /// Longest address kept as the key of an answer.
  static const int maxResponseKey = 64;

  bool get isOwn => from == 'self';
  bool get isActive => endedAt == null;
  bool get hasLocation => lat != null && lon != null;

  /// A friend's alarm heard only over Bluetooth that ended by itself (no
  /// network copy came, §16.3): nobody knows how it ended.
  bool get expiredNearby => !isOwn && nearby && !isActive;

  /// How far this alarm got with [friend] (a normalised address).
  AlarmReach reachOf(String friend) {
    if (responses.containsKey(friend)) {
      return AlarmReach.answered;
    }
    final AlarmDelivery? d = deliveries[friend];
    if (d?.seen != null) {
      return AlarmReach.seen;
    }
    if (d?.got != null) {
      return AlarmReach.delivered;
    }
    return AlarmReach.sent;
  }

  /// Friends it went to whose phone confirmed it (or who answered).
  int get deliveredCount =>
      sentTo.where((String f) => reachOf(f) != AlarmReach.sent).length;

  /// Friends it went to whose phone has not confirmed it yet.
  List<String> get unconfirmed => <String>[
    for (final String f in sentTo)
      if (reachOf(f) == AlarmReach.sent) f,
  ];

  AlarmRecord copyWith({
    double? lat,
    double? lon,
    double? accuracy,
    int? locatedAt,
    Map<String, AlarmResponse>? responses,
    int? endedAt,
    bool? duress,
    List<AlarmClip>? clips,
    bool? nearby,
    List<String>? sentTo,
    Map<String, AlarmDelivery>? deliveries,
  }) => AlarmRecord(
    id: id,
    from: from,
    at: at,
    lat: lat ?? this.lat,
    lon: lon ?? this.lon,
    accuracy: accuracy ?? this.accuracy,
    locatedAt: locatedAt ?? this.locatedAt,
    note: note,
    responses: responses ?? this.responses,
    endedAt: endedAt ?? this.endedAt,
    duress: duress ?? this.duress,
    clips: clips ?? this.clips,
    nearby: nearby ?? this.nearby,
    sentTo: sentTo ?? this.sentTo,
    deliveries: deliveries ?? this.deliveries,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'from': from,
    'at': at,
    if (lat != null) 'lat': lat,
    if (lon != null) 'lon': lon,
    if (accuracy != null) 'acc': accuracy,
    if (locatedAt != null) 'locAt': locatedAt,
    if (note.isNotEmpty) 'note': note,
    'resp': <String, String>{
      for (final MapEntry<String, AlarmResponse> e in responses.entries)
        e.key: e.value.name,
    },
    if (endedAt != null) 'end': endedAt,
    if (duress) 'duress': true,
    if (clips.isNotEmpty)
      'clips': <Map<String, int>>[for (final AlarmClip c in clips) c.toJson()],
    if (nearby) 'near': true,
    if (sentTo.isNotEmpty) 'to': sentTo,
    if (deliveries.isNotEmpty)
      'dlv': <String, Map<String, int>>{
        for (final MapEntry<String, AlarmDelivery> e in deliveries.entries)
          e.key: e.value.toJson(),
      },
  };

  /// [v] when it is a number within ±[max], else `null`.
  static double? _num(Object? v, double max) {
    if (v is! num) {
      return null;
    }
    final double d = v.toDouble();
    return d.isFinite && d.abs() <= max ? d : null;
  }

  /// Longest note kept (the app lets one write 140 characters).
  static const int maxNoteChars = 280;

  static String _clip(String s, int max) =>
      s.length > max ? s.substring(0, max) : s;

  static AlarmRecord? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? from = json['from'];
    final Object? at = json['at'];
    if (id is! String ||
        !kAlarmIdPattern.hasMatch(id) ||
        from is! String ||
        from.isEmpty ||
        from.length > 200 ||
        at is! int) {
      return null;
    }
    final Object? resp = json['resp'];
    final Object? clips = json['clips'];
    final Object? to = json['to'];
    final Object? dlv = json['dlv'];
    final double? accuracy = _num(json['acc'], 1000000);
    return AlarmRecord(
      id: id,
      from: from,
      at: at,
      lat: _num(json['lat'], 90),
      lon: _num(json['lon'], 180),
      accuracy: accuracy != null && accuracy >= 0 ? accuracy : null,
      locatedAt: json['locAt'] is int ? json['locAt'] as int : null,
      note: json['note'] is String
          ? _clip(json['note'] as String, maxNoteChars)
          : '',
      responses: <String, AlarmResponse>{
        if (resp is Map)
          for (final MapEntry<dynamic, dynamic> e in resp.entries.take(
            maxResponses,
          ))
            if (e.key is String &&
                (e.key as String).isNotEmpty &&
                (e.key as String).length <= maxResponseKey &&
                AlarmResponse.byName(e.value) != null)
              e.key as String: AlarmResponse.byName(e.value)!,
      },
      endedAt: json['end'] is int ? json['end'] as int : null,
      duress: json['duress'] == true,
      clips: <AlarmClip>[
        if (clips is List)
          for (final Object? c in clips.take(20))
            if (AlarmClip.fromJson(c) != null) AlarmClip.fromJson(c)!,
      ],
      nearby: json['near'] == true,
      sentTo: <String>[
        if (to is List)
          for (final Object? a in to.take(maxRecipients))
            if (a is String && a.isNotEmpty && a.length <= 200) a,
      ],
      deliveries: <String, AlarmDelivery>{
        if (dlv is Map)
          for (final MapEntry<dynamic, dynamic> e in dlv.entries.take(
            maxRecipients,
          ))
            if (e.key is String &&
                (e.key as String).length <= 200 &&
                AlarmDelivery.fromJson(e.value) != null)
              e.key as String: AlarmDelivery.fromJson(e.value)!,
      },
    );
  }
}

/// What the "meeting" features keep on this device: statuses, alarms,
/// nearby keys and who was met in person. Shared by the app and the
/// Android background service (both read it fresh before changing it).
final class MeetBook {
  IntentStatus? myIntent;
  final Map<String, IntentStatus> friendIntents = <String, IntentStatus>{};
  final List<AlarmRecord> alarms = <AlarmRecord>[];

  /// Salted hash of the alarm PIN ("Jestem bezpieczny").
  String? alarmPinHash;
  String? alarmPinSalt;

  /// Salted hash (same salt) of the panic PIN: it seems to end the alarm,
  /// but tells friends the person is being forced.
  String? alarmPanicHash;

  /// Friends' nearby keys (address → what they gave,
  /// [FriendNearbyKey.parse]).
  final Map<String, String> friendNearbySecrets = <String, String>{};

  /// Friends who have this person's current nearby keys.
  final Set<String> nearbyGivenTo = <String>{};

  /// This person's private nearby key (§15, S6): never sent; friends get
  /// only what comes from it, one set per friend
  /// ([NearbyOwnKeys.materialFor]).
  String? nearbyPrivate;

  /// Addresses blocked in "W pobliżu" (§15), normalised.
  final Set<String> nearbyBlocked = <String>{};

  /// Whether this phone shows itself to people nearby (§15). Off until the
  /// person turns it on (privacy by default).
  bool nearbyVisible = false;

  /// Who may see this person's friend list (§9, §16.1, §24.1).
  FriendListAudience friendListAudience = FriendListAudience.friends;

  /// Friends allowed to see the list while it is shown only on request
  /// (normalised addresses). Kept when the audience changes, so going back
  /// to "on request" keeps earlier approvals.
  final Set<String> friendListAllowed = <String>{};

  /// Most friends kept in [friendListAllowed].
  static const int maxListAllowed = 2000;

  /// Whether the list goes out at all (to everyone or to those allowed).
  bool get shareFriendList => friendListAudience != FriendListAudience.nobody;

  /// Whether [friend] may see the list now ([weak]: they are only a weak
  /// acquaintance, §8).
  bool showsFriendListTo(String friend, {bool weak = false}) =>
      switch (friendListAudience) {
        FriendListAudience.all => true,
        FriendListAudience.friends =>
          !weak || friendListAllowed.contains(_key(friend)),
        FriendListAudience.nobody => false,
        FriendListAudience.onRequest => friendListAllowed.contains(
          _key(friend),
        ),
      };

  /// Record sound during this person's alarm and send it to the friends
  /// who get the alarm (§16.3, off by default).
  bool alarmRecordAudio = false;

  /// Also tell phones nearby over Bluetooth (§16.3, off by default):
  /// friends recognise this phone, others see only "someone nearby needs
  /// help".
  bool alarmNearby = false;

  /// Raise the alarm by pressing the power button 5 times (§16.3, Android,
  /// off by default).
  bool alarmPowerButton = false;

  /// Phone numbers for the backup SMS of the alarm (§16.3): the system SMS
  /// app opens with the alarm text, the person presses send. Never leaves
  /// this phone.
  List<String> alarmSmsNumbers = <String>[];

  /// Seed (base64url) of this person's alarm key (§16.3): an Ed25519 key
  /// that signs alarm frames only, certified by the device key; the alarm
  /// kit hands it to the locked Android service instead of any other key.
  String? alarmKeySeed;

  /// The id the next alarm raised from the alarm kit carries (the kit's
  /// mailbox copies are sealed with it); a new one once it was used.
  String? alarmKitId;

  /// Friends' certified alarm keys (address → public keys, newest last):
  /// an alarm frame signed with one of them must check out.
  final Map<String, List<String>> friendAlarmKeys = <String, List<String>>{};

  /// Most alarm keys kept per friend (one per device of theirs).
  static const int maxAlarmKeysPerFriend = 4;

  /// Look around for friends now and then without the "W pobliżu" screen
  /// open (§15, off by default: scanning is for that screen): a short
  /// low-power scan every few minutes that only marks friends met in person.
  bool nearbyBackgroundScan = false;

  /// What was last sent as the friend list (to send again only on change).
  String friendListSent = '';

  /// Friends' friend lists: friend → (address → their own name). Kept
  /// outside the book on disk (one file per friend, see [MeetStore]), so
  /// the book stays small and an alarm is never stuck behind big lists.
  final Map<String, Map<String, String>> friendLists =
      <String, Map<String, String>>{};

  /// What each friend's list was when it came (their digest): their hello
  /// carries the digest of what they send now, and a difference means a
  /// list got lost on the way — this phone asks for it again (B1/B2).
  final Map<String, String> friendListDigests = <String, String>{};

  /// Friends of [friend] (empty when they do not share).
  Map<String, String> friendsOf(String friend) =>
      friendLists[_key(friend)] ?? const <String, String>{};

  static const int maxAlarms = 50;

  /// Alarms kept at most even when all of them are still going on (B10):
  /// a new friend's alarm is not kept past this.
  static const int maxAlarmsHard = 200;

  /// Alarms of one friend kept at most (a person in trouble raises one at
  /// a time): more never push anyone else's alarm out.
  static const int maxAlarmsPerFriend = 10;

  String _key(String address) => PeerShareCodec.normalizeAddress(address);

  IntentStatus? intentOf(String address, int now) {
    final IntentStatus? s = friendIntents[_key(address)];
    return s != null && s.activeAt(now) ? s : null;
  }

  void setFriendIntent(String address, IntentStatus? status) {
    if (status == null) {
      friendIntents.remove(_key(address));
    } else {
      friendIntents[_key(address)] = status;
    }
  }

  AlarmRecord? alarm(String id) =>
      alarms.where((AlarmRecord a) => a.id == id).firstOrNull;

  AlarmRecord? get ownActiveAlarm =>
      alarms.where((AlarmRecord a) => a.isOwn && a.isActive).firstOrNull;

  List<AlarmRecord> activeAlarmsFromFriends() => <AlarmRecord>[
    for (final AlarmRecord a in alarms)
      if (!a.isOwn && a.isActive) a,
  ];

  /// Adds or replaces [record]. Returns `false` when a new alarm of a
  /// friend is not kept: they already have [maxAlarmsPerFriend] here, none
  /// of them over. When the list grows past [maxAlarms], the oldest alarm
  /// of a friend that is over goes; this person's own alarms and alarms
  /// still going on are never pushed out (so the list may stay longer).
  bool putAlarm(AlarmRecord record) {
    final int i = alarms.indexWhere((AlarmRecord a) => a.id == record.id);
    if (i >= 0) {
      alarms[i] = record;
      return true;
    }
    if (!record.isOwn) {
      final List<AlarmRecord> theirs = <AlarmRecord>[
        for (final AlarmRecord a in alarms)
          if (a.from == record.from) a,
      ];
      if (theirs.length >= maxAlarmsPerFriend) {
        final int over = alarms.lastIndexWhere(
          (AlarmRecord a) => a.from == record.from && !a.isActive,
        );
        if (over < 0) {
          return false;
        }
        alarms.removeAt(over);
      }
      if (alarms.length >= maxAlarmsHard &&
          !alarms.any((AlarmRecord a) => !a.isOwn && !a.isActive)) {
        return false;
      }
    }
    alarms.insert(0, record);
    while (alarms.length > maxAlarms) {
      final int drop = alarms.lastIndexWhere(
        (AlarmRecord a) => !a.isOwn && !a.isActive,
      );
      if (drop < 0) {
        break;
      }
      alarms.removeAt(drop);
    }
    return true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    if (myIntent != null) 'my': myIntent!.toJson(),
    'fi': <String, dynamic>{
      for (final MapEntry<String, IntentStatus> e in friendIntents.entries)
        e.key: e.value.toJson(),
    },
    'alarms': <Map<String, dynamic>>[
      for (final AlarmRecord a in alarms) a.toJson(),
    ],
    if (alarmPinHash != null) 'pin': alarmPinHash,
    if (alarmPinSalt != null) 'pinSalt': alarmPinSalt,
    if (alarmPanicHash != null) 'panic': alarmPanicHash,
    'fns': friendNearbySecrets,
    'given': nearbyGivenTo.toList(),
    if (nearbyPrivate != null) 'np': nearbyPrivate,
    if (nearbyBlocked.isNotEmpty) 'nb': nearbyBlocked.toList(),
    if (nearbyVisible) 'visible': true,
    'la': friendListAudience.name,
    if (friendListAllowed.isNotEmpty) 'listOk': friendListAllowed.toList(),
    if (alarmRecordAudio) 'alarmAudio': true,
    if (alarmNearby) 'alarmNearby': true,
    if (alarmPowerButton) 'alarmPower': true,
    if (alarmSmsNumbers.isNotEmpty) 'alarmSms': alarmSmsNumbers,
    if (alarmKeySeed != null) 'ak': alarmKeySeed,
    if (alarmKitId != null) 'kid': alarmKitId,
    if (friendAlarmKeys.isNotEmpty) 'fak': friendAlarmKeys,
    // Always written: a book without it (never chosen) means on.
    'bgScan': nearbyBackgroundScan,
    'listSent': friendListSent,
    'ld': friendListDigests,
  };

  static MeetBook fromJson(Object? json) {
    final MeetBook book = MeetBook();
    if (json is! Map || json['v'] != 1) {
      return book;
    }
    book.myIntent = IntentStatus.fromJson(json['my']);
    final Object? fi = json['fi'];
    if (fi is Map) {
      for (final MapEntry<dynamic, dynamic> e in fi.entries) {
        final IntentStatus? s = IntentStatus.fromJson(e.value);
        if (e.key is String && s != null) {
          book.friendIntents[e.key as String] = s;
        }
      }
    }
    final Object? alarms = json['alarms'];
    if (alarms is List) {
      for (final Object? a in alarms.take(maxAlarmsHard)) {
        final AlarmRecord? r = AlarmRecord.fromJson(a);
        if (r != null) {
          book.alarms.add(r);
        }
      }
    }
    book.alarmPinHash = json['pin'] is String ? json['pin'] as String : null;
    book.alarmPinSalt = json['pinSalt'] is String
        ? json['pinSalt'] as String
        : null;
    book.alarmPanicHash = json['panic'] is String
        ? json['panic'] as String
        : null;
    book.nearbyPrivate = json['np'] is String ? json['np'] as String : null;
    final Object? nb = json['nb'];
    if (nb is List) {
      book.nearbyBlocked.addAll(nb.whereType<String>().take(1000));
    }
    final Object? fns = json['fns'];
    if (fns is Map) {
      for (final MapEntry<dynamic, dynamic> e in fns.entries) {
        if (e.key is String && e.value is String) {
          book.friendNearbySecrets[e.key as String] = e.value as String;
        }
      }
    }
    book.nearbyVisible = json['visible'] == true;
    book.friendListAudience =
        FriendListAudience.byName(json['la']) ?? FriendListAudience.friends;
    final Object? listOk = json['listOk'];
    if (listOk is List) {
      book.friendListAllowed.addAll(
        listOk
            .whereType<String>()
            .where((String a) => a.isNotEmpty && a.length <= 200)
            .take(maxListAllowed),
      );
    }
    book.alarmRecordAudio = json['alarmAudio'] == true;
    book.alarmNearby = json['alarmNearby'] == true;
    book.alarmPowerButton = json['alarmPower'] == true;
    final Object? sms = json['alarmSms'];
    if (sms is List) {
      book.alarmSmsNumbers = <String>[
        for (final Object? n in sms.take(5))
          if (n is String && RegExp(r'^\+?\d{5,15}$').hasMatch(n)) n,
      ];
    }
    book.alarmKeySeed = json['ak'] is String ? json['ak'] as String : null;
    final Object? kid = json['kid'];
    book.alarmKitId = kid is String && kAlarmIdPattern.hasMatch(kid)
        ? kid
        : null;
    final Object? fak = json['fak'];
    if (fak is Map) {
      for (final MapEntry<dynamic, dynamic> e in fak.entries) {
        final Object? keys = e.value;
        if (e.key is String && keys is List) {
          book.friendAlarmKeys[e.key as String] = <String>[
            for (final Object? k in keys.take(maxAlarmKeysPerFriend))
              if (k is String && k.length <= 64) k,
          ];
        }
      }
    }
    book.nearbyBackgroundScan = json['bgScan'] == true;
    book.friendListSent = json['listSent'] is String
        ? json['listSent'] as String
        : '';
    final Object? digests = json['ld'];
    if (digests is Map) {
      for (final MapEntry<dynamic, dynamic> e in digests.entries) {
        if (e.key is String && e.value is String) {
          book.friendListDigests[e.key as String] = e.value as String;
        }
      }
    }
    final Object? given = json['given'];
    if (given is List) {
      book.nearbyGivenTo.addAll(given.whereType<String>());
    }
    return book;
  }
}

/// Reads and writes the [MeetBook] (key `meet/state` in the encrypted
/// store). Changes go through [update] so the app and the background
/// service never overwrite each other's work with a stale copy.
final class MeetStore {
  MeetStore(this.disk);

  final LedgerDisk disk;
  static const String key = 'meet/state';

  /// Where clip [n] of alarm [alarmId] is kept (outside the book, so the
  /// book stays small).
  static String audioKey(String alarmId, int n) =>
      'meet/alarm-audio/${alarmId.replaceAll(RegExp(r'[^A-Za-z0-9]'), '')}-$n';

  /// Where [friend]'s friend list is kept (the name does not show who).
  static String listKey(String friend) =>
      'meet/list/${crypto.sha256.convert(utf8.encode(PeerShareCodec.normalizeAddress(friend))).toString().substring(0, 32)}';

  Future<void> _queue = Future<void>.value();

  /// Friends' lists as last read or written (read once, then kept).
  Map<String, Map<String, String>>? _lists;

  Future<void> _attachLists(MeetBook book) async {
    Map<String, Map<String, String>>? lists = _lists;
    if (lists == null) {
      lists = <String, Map<String, String>>{};
      for (final String friend in book.friendListDigests.keys) {
        try {
          final Uint8List? raw = await disk.read(listKey(friend));
          final Object? json = raw == null
              ? null
              : jsonDecode(utf8.decode(raw));
          if (json is Map) {
            lists[friend] = <String, String>{
              for (final MapEntry<dynamic, dynamic> e in json.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            };
          }
        } on Object catch (error, stack) {
          logZenError('Lista znajomych znajomego', error, stack);
        }
      }
      _lists = lists;
    }
    book.friendLists
      ..clear()
      ..addAll(lists);
  }

  /// Keeps [friend]'s list ([digest]: what they said it is), or forgets it
  /// when [list] is empty. Returns the book after the change.
  Future<MeetBook> setFriendList(
    String friend,
    Map<String, String> list,
    String digest,
  ) {
    final Completer<MeetBook> done = Completer<MeetBook>();
    _queue = _queue.then((_) async {
      try {
        final MeetBook book = await _read();
        final String key = PeerShareCodec.normalizeAddress(friend);
        if (list.isEmpty) {
          await disk.delete(listKey(key));
          _lists?.remove(key);
          book.friendLists.remove(key);
        } else {
          await disk.write(
            listKey(key),
            Uint8List.fromList(utf8.encode(jsonEncode(list))),
          );
          (_lists ??= <String, Map<String, String>>{})[key] = list;
          book.friendLists[key] = list;
        }
        book.friendListDigests[key] = digest;
        await disk.write(
          MeetStore.key,
          Uint8List.fromList(utf8.encode(jsonEncode(book.toJson()))),
        );
        done.complete(book);
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<MeetBook> load() async {
    try {
      return await _read();
    } on Object catch (error, stack) {
      logZenError('Odczyt spotkań', error, stack);
      return MeetBook();
    }
  }

  /// Reads in turn with the writes (never between a read and a write of
  /// [update]). Throws when the store cannot be read (e.g. still locked).
  Future<MeetBook> loadInTurn() {
    final Completer<MeetBook> done = Completer<MeetBook>();
    _queue = _queue.then((_) async {
      try {
        // Another engine (the background service) may have written lists.
        _lists = null;
        done.complete(await _read());
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<MeetBook> _read() async {
    final Uint8List? raw = await disk.read(key);
    if (raw == null) {
      return MeetBook();
    }
    final Object? json = jsonDecode(utf8.decode(raw));
    if (json is! Map || json['v'] != 1) {
      // A newer app's book (or damage): reading it as empty and writing that
      // back would wipe statuses, alarms and settings. Never written over.
      throw FormatException(
        'meet/state: unknown version ${json is Map ? json['v'] : '?'}',
      );
    }
    final MeetBook book = MeetBook.fromJson(json);
    await _attachLists(book);
    return book;
  }

  /// Reads the book, lets [change] edit it and writes it back, one change
  /// at a time. Returns what [change] returned.
  Future<T> update<T>(T Function(MeetBook book) change) {
    final Completer<T> done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        // A store that cannot be read is never written: an empty book must
        // not replace the real one (e.g. read while the app is locked).
        final MeetBook book = await _read();
        final T result = change(book);
        await disk.write(
          key,
          Uint8List.fromList(utf8.encode(jsonEncode(book.toJson()))),
        );
        done.complete(result);
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }
}
