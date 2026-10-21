import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// A dinner circle has 4–8 members (people, or pairs when
/// [DinnerCircle.pairs] is set), the host included.
const int kCircleMinMembers = 4;
const int kCircleMaxMembers = 8;

/// Most kitty entries a circle keeps (the oldest are dropped).
const int kCircleKittyMax = 200;

/// How long per-dinner answers (attendance, shopping, "Jak było?") are
/// kept after the dinner.
const Duration kCircleDinnerKeep = Duration(days: 60);

final RegExp _dayPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String _clip(Object? v, int max) =>
    v is String ? (v.length > max ? v.substring(0, max) : v) : '';

String _n(String a) => PeerShareCodec.normalizeAddress(a);

/// One contribution to the circle's shared kitty ("wspólna kasa na
/// składniki"), in grosze.
@immutable
final class KittyEntry {
  const KittyEntry({
    required this.by,
    required this.cents,
    required this.at,
    this.note = '',
  });

  /// The member who paid in (positive) or was reimbursed (negative).
  final String by;
  final int cents;
  final int at;
  final String note;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': by,
    'c': cents,
    't': at,
    if (note.isNotEmpty) 'n': note,
  };

  static KittyEntry? fromJson(Object? json) {
    if (json is! Map ||
        json['a'] is! String ||
        json['c'] is! int ||
        json['t'] is! int) {
      return null;
    }
    final Object? n = json['n'];
    final int c = json['c'] as int;
    if (c == 0 || c.abs() > 100000000) {
      return null;
    }
    return KittyEntry(
      by: _n(json['a'] as String),
      cents: c,
      at: json['t'] as int,
      note: n is String ? (n.length > 60 ? n.substring(0, 60) : n) : '',
    );
  }
}

/// Someone from outside the circle a member brings to one dinner
/// ("kółko otwarte"): once a month per member.
@immutable
final class CircleGuest {
  const CircleGuest({
    required this.name,
    required this.day,
    this.address,
    this.vouchedBy,
  });

  final String name;

  /// The dinner (yyyy-mm-dd).
  final String day;

  /// Their mesh address, when they are a friend of the member (they get an
  /// invitation).
  final String? address;

  /// The member who vouches for this guest ("przyprowadzający ręczy").
  final String? vouchedBy;

  Map<String, String> toJson() => <String, String>{
    'n': name,
    'd': day,
    'a': ?address,
    'v': ?vouchedBy,
  };

  static CircleGuest? fromJson(Object? json) {
    if (json is! Map || json['n'] is! String || json['d'] is! String) {
      return null;
    }
    final String n = json['n'] as String;
    final String d = json['d'] as String;
    final Object? a = json['a'];
    final Object? v = json['v'];
    return CircleGuest(
      vouchedBy: v is String && isRoutablePeerAddress(v) ? _n(v) : null,
      name: n.length > 60 ? n.substring(0, 60) : n,
      day: d.length > 10 ? d.substring(0, 10) : d,
      address: a is String && isRoutablePeerAddress(a) ? _n(a) : null,
    );
  }
}

/// A member who said "Dołączam". [pos] orders the hosting queue (a swap
/// exchanges two members' positions); [at] is when they joined, which a
/// later leave ([DinnerCircle.gone]) outdates.
@immutable
final class CircleMember {
  const CircleMember(this.address, this.name, {this.pos = 0, this.at = 0});

  final String address;
  final String name;
  final int pos;
  final int at;

  CircleMember withPos(int pos) =>
      CircleMember(address, name, pos: pos, at: at);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    'n': name,
    'p': pos,
    'j': at,
  };

  static CircleMember? fromJson(Object? json) {
    if (json is! Map || json['a'] is! String) {
      return null;
    }
    final Object? p = json['p'];
    final Object? j = json['j'];
    return CircleMember(
      _n(json['a'] as String),
      _clip(json['n'], 60),
      pos: p is int ? p : 0,
      at: j is int ? j : 0,
    );
  }
}

/// An invitation to a circle not answered yet ("Dołączam" / "Nie,
/// dziękuję").
@immutable
final class CircleInvite {
  const CircleInvite({required this.name, required this.by, required this.at});

  final String name;

  /// The member who invited.
  final String by;
  final int at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'n': name,
    'b': by,
    't': at,
  };

  static CircleInvite? fromJson(Object? json) {
    if (json is! Map || json['b'] is! String || json['t'] is! int) {
      return null;
    }
    return CircleInvite(
      name: _clip(json['n'], 60),
      by: _n(json['b'] as String),
      at: json['t'] as int,
    );
  }
}

/// "Kto będzie w czwartek?".
enum CircleAttendance {
  yes('y'),
  no('n'),
  maybe('m');

  const CircleAttendance(this.code);

  final String code;

  String get label => switch (this) {
    CircleAttendance.yes => t('Będę'),
    CircleAttendance.no => t('Nie dam rady'),
    CircleAttendance.maybe => t('Może'),
  };

  static CircleAttendance? byCode(Object? c) => CircleAttendance.values
      .where((CircleAttendance a) => a.code == c)
      .firstOrNull;
}

/// What a member does not eat, for the cook's count.
enum CircleDiet {
  vegetarian('veg'),
  vegan('vegan'),
  noGluten('gf'),
  noLactose('lf'),
  noNuts('nuts');

  const CircleDiet(this.code);

  final String code;

  String get label => switch (this) {
    CircleDiet.vegetarian => t('Wegetariańska dieta'),
    CircleDiet.vegan => t('Wegańska dieta'),
    CircleDiet.noGluten => t('Bez glutenu'),
    CircleDiet.noLactose => t('Bez laktozy'),
    CircleDiet.noNuts => t('Bez orzechów'),
  };

  static CircleDiet? byCode(Object? c) =>
      CircleDiet.values.where((CircleDiet d) => d.code == c).firstOrNull;
}

/// "Jak było?" after a dinner.
enum CircleHow {
  great('g'),
  fine('o'),
  meh('m');

  const CircleHow(this.code);

  final String code;

  String get label => switch (this) {
    CircleHow.great => t('Super'),
    CircleHow.fine => t('Dobrze'),
    CircleHow.meh => t('Tak sobie'),
  };

  static CircleHow? byCode(Object? c) =>
      CircleHow.values.where((CircleHow h) => h.code == c).firstOrNull;
}

/// A value one member set, with when they set it: per-dinner answers merge
/// entry by entry (the newer wins), so two members answering at once never
/// overwrite each other.
@immutable
final class CircleMark<T> {
  const CircleMark(this.value, this.at);

  final T value;
  final int at;
}

/// "Bartek oddaje Ani 23 zł" (grosze).
@immutable
final class CircleTransfer {
  const CircleTransfer(this.from, this.to, this.cents);

  final String from;
  final String to;
  final int cents;

  /// What "Rozliczone ✓" is stored under: the same pair and amount.
  String get key => '$from>$to>$cents';

  @override
  bool operator ==(Object other) =>
      other is CircleTransfer &&
      other.from == from &&
      other.to == to &&
      other.cents == cents;

  @override
  int get hashCode => Object.hash(from, to, cents);

  @override
  String toString() => '$from → $to: $cents';
}

/// The cook's count for one dinner.
@immutable
final class CircleHeadcount {
  const CircleHeadcount({
    required this.people,
    required this.yes,
    required this.maybe,
    required this.no,
    required this.unanswered,
    required this.guests,
    required this.diets,
  });

  /// People at the table: members who come (twice for pairs) and guests.
  final int people;
  final int yes;
  final int maybe;
  final int no;
  final int unanswered;
  final int guests;

  /// Among those who come.
  final Map<CircleDiet, int> diets;
}

typedef _DayMarks<T> = Map<String, Map<String, CircleMark<T>>>;

/// Kółko obiadowe: friends taking turns hosting a regular dinner.
///
/// Any member may change it; the newest copy wins for the settings, while
/// membership (joins, leaves, invitations) and the per-dinner answers merge
/// entry by entry ([merge]), so every phone ends up with the same circle.
@immutable
final class DinnerCircle {
  const DinnerCircle({
    required this.id,
    required this.name,
    required this.members,
    required this.weekday,
    required this.hour,
    required this.firstDinner,
    this.everyWeeks = 1,
    this.invited = const <String, CircleInvite>{},
    this.gone = const <String, int>{},
    this.prefs = const <String, String>{},
    this.diets = const <String, Set<CircleDiet>>{},
    this.items = const <String, Map<String, String>>{},
    this.open = false,
    this.guests = const <String, Map<String, CircleGuest>>{},
    this.pairs = false,
    this.kitty = const <KittyEntry>[],
    this.rsvp = const <String, Map<String, CircleMark<CircleAttendance>>>{},
    this.spent = const <String, Map<String, CircleMark<int>>>{},
    this.settled = const <String, Map<String, int>>{},
    this.how = const <String, Map<String, CircleMark<CircleHow>>>{},
    this.updatedAt = 0,
  });

  final String id;
  final String name;

  /// Those who said "Dołączam", in hosting order ([CircleMember.pos]).
  final List<CircleMember> members;

  /// Invitations not answered yet, by address.
  final Map<String, CircleInvite> invited;

  /// Who left, declined or was removed, and when: an older membership or
  /// invitation of theirs no longer counts.
  final Map<String, int> gone;

  /// 1 = Monday … 7 = Sunday.
  final int weekday;
  final int hour;

  /// The first dinner (local midnight of its day).
  final int firstDinner;
  final int everyWeeks;

  /// Preferences and allergies, per member address.
  final Map<String, String> prefs;

  /// What each member does not eat (for the cook's count).
  final Map<String, Set<CircleDiet>> diets;

  /// Per dinner (yyyy-mm-dd): item → who brings it ('' = nobody yet).
  final Map<String, Map<String, String>> items;

  /// "Kółko otwarte": once a month every member may bring one person from
  /// outside the circle.
  final bool open;

  /// Guests brought along: month (yyyy-mm) → member address → guest.
  final Map<String, Map<String, CircleGuest>> guests;

  /// Every member stands for a pair (two people at the table).
  final bool pairs;

  /// Shared kitty for ingredients: who paid in what.
  final List<KittyEntry> kitty;

  /// "Kto będzie?": per dinner, per member.
  final Map<String, Map<String, CircleMark<CircleAttendance>>> rsvp;

  /// "Wydałem(-am) na zakupy": per dinner, per member, in grosze.
  final Map<String, Map<String, CircleMark<int>>> spent;

  /// "Rozliczone ✓": per dinner, [CircleTransfer.key] → when.
  final Map<String, Map<String, int>> settled;

  /// "Jak było?": per dinner, per member.
  final Map<String, Map<String, CircleMark<CircleHow>>> how;
  final int updatedAt;

  /// Whether [count] members (the host included) make a valid circle.
  static bool validSize(int count) =>
      count >= kCircleMinMembers && count <= kCircleMaxMembers;

  /// Members and open invitations together may not exceed this.
  bool get full => members.length + invited.length >= kCircleMaxMembers;

  /// Fewer members than a circle should have (people declined or left).
  bool get small => members.length < kCircleMinMembers;

  /// People at the table: twice the members for a circle of pairs.
  int get headcount => members.length * (pairs ? 2 : 1);

  /// Total in the kitty, in grosze.
  int get kittyTotal => kitty.fold(0, (int s, KittyEntry e) => s + e.cents);

  /// What [member] has put into the kitty, in grosze.
  int paidBy(String member) => kitty
      .where((KittyEntry e) => PeerShareCodec.addressesEqual(e.by, member))
      .fold(0, (int s, KittyEntry e) => s + e.cents);

  /// An even share of the kitty per member, in grosze (rounded down).
  int get kittyShare => members.isEmpty ? 0 : kittyTotal ~/ members.length;

  static String dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static String monthKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  /// Whether [key] looks like a [dayKey].
  static bool isDayKey(Object? key) =>
      key is String && _dayPattern.hasMatch(key);

  /// Members in hosting order: by position, then address (the same order on
  /// every phone).
  static List<CircleMember> ordered(Iterable<CircleMember> members) =>
      List<CircleMember>.of(members)..sort((CircleMember a, CircleMember b) {
        final int byPos = a.pos.compareTo(b.pos);
        return byPos != 0 ? byPos : a.address.compareTo(b.address);
      });

  /// The guest [member] brings in the month of [day], if any.
  CircleGuest? guestOf(String member, DateTime day) =>
      guests[monthKey(day)]?[_n(member)];

  /// Whether [member] may still bring someone in the month of [day].
  bool canBringGuest(String member, DateTime day) =>
      open && hasMember(member) && guestOf(member, day) == null;

  /// Guests coming to the dinner on [day]: (who brings them, the guest).
  List<(String, CircleGuest)> guestsOn(DateTime day) {
    final String key = dayKey(day);
    return <(String, CircleGuest)>[
      for (final MapEntry<String, CircleGuest> e
          in (guests[monthKey(day)] ?? const <String, CircleGuest>{}).entries)
        if (e.value.day == key) (e.key, e.value),
    ];
  }

  DateTime get _first {
    final DateTime start = DateTime.fromMillisecondsSinceEpoch(firstDinner);
    return DateTime(start.year, start.month, start.day, hour);
  }

  /// The [k]th dinner (0 = the first).
  DateTime dinnerAt(int k) {
    final DateTime first = _first;
    return DateTime(
      first.year,
      first.month,
      first.day + k * 7 * everyWeeks,
      hour,
    );
  }

  /// Who hosts the [k]th dinner.
  CircleMember? hostOf(int k) =>
      members.isEmpty ? null : members[k % members.length];

  /// The [count] next dinners from [now] (today's included) with their
  /// hosts. The queue follows the members as they are now: when someone
  /// joins or leaves, it is worked out again.
  List<(DateTime, CircleMember)> schedule(int now, {int count = 6}) {
    if (members.isEmpty) {
      return const <(DateTime, CircleMember)>[];
    }
    final DateTime today = DateTime.fromMillisecondsSinceEpoch(now);
    final DateTime midnight = DateTime(today.year, today.month, today.day);
    int n = 0;
    while (dinnerAt(n).isBefore(midnight)) {
      n++;
    }
    return <(DateTime, CircleMember)>[
      for (int i = 0; i < count; i++) (dinnerAt(n + i), hostOf(n + i)!),
    ];
  }

  /// The last dinner that started at or before [now], with its host.
  (DateTime, CircleMember)? lastDinner(int now) {
    if (members.isEmpty || dinnerAt(0).millisecondsSinceEpoch > now) {
      return null;
    }
    int n = 0;
    while (dinnerAt(n + 1).millisecondsSinceEpoch <= now) {
      n++;
    }
    return (dinnerAt(n), hostOf(n)!);
  }

  bool hasMember(String address) => members.any(
    (CircleMember m) => PeerShareCodec.addressesEqual(m.address, address),
  );

  CircleMember? member(String address) => members
      .where(
        (CircleMember m) => PeerShareCodec.addressesEqual(m.address, address),
      )
      .firstOrNull;

  bool isInvited(String address) => invited.containsKey(_n(address));

  /// A name for [address]: a member's or an invited person's.
  String? nameIn(String address) =>
      member(address)?.name ?? invited[_n(address)]?.name;

  /// [address]'s answer for the dinner on [day].
  CircleAttendance? attendanceOf(String address, String day) =>
      rsvp[day]?[_n(address)]?.value;

  /// The cook's count for the dinner on [day].
  CircleHeadcount headcountOn(DateTime day) {
    final String key = dayKey(day);
    final Map<String, CircleMark<CircleAttendance>> answers =
        rsvp[key] ?? const <String, CircleMark<CircleAttendance>>{};
    int yes = 0;
    int maybe = 0;
    int no = 0;
    int unanswered = 0;
    final Map<CircleDiet, int> counts = <CircleDiet, int>{};
    for (final CircleMember m in members) {
      switch (answers[m.address]?.value) {
        case CircleAttendance.yes:
          yes++;
          for (final CircleDiet d in diets[m.address] ?? const <CircleDiet>{}) {
            counts[d] = (counts[d] ?? 0) + 1;
          }
        case CircleAttendance.maybe:
          maybe++;
        case CircleAttendance.no:
          no++;
        case null:
          unanswered++;
      }
    }
    final int brought = guestsOn(day).length;
    return CircleHeadcount(
      people: yes * (pairs ? 2 : 1) + brought,
      yes: yes,
      maybe: maybe,
      no: no,
      unanswered: unanswered,
      guests: brought,
      diets: counts,
    );
  }

  /// People at the dinner on [day] that [me] may meet for the first time
  /// ("Spotkani?"): members who did not say "Nie dam rady" and guests
  /// brought with their address, apart from [me] and whoever [known] says
  /// is a friend already. (address, name), in table order.
  List<(String, String)> newPeopleOn(
    DateTime day, {
    required String me,
    required bool Function(String address) known,
  }) {
    final String key = dayKey(day);
    final Set<String> seen = <String>{_n(me)};
    return <(String, String)>[
      for (final CircleMember m in members)
        if (attendanceOf(m.address, key) != CircleAttendance.no &&
            !known(m.address) &&
            seen.add(m.address))
          (m.address, m.name),
      for (final (String _, CircleGuest g) in guestsOn(day))
        if (g.address case final String a when !known(a) && seen.add(a))
          (a, g.name),
    ];
  }

  /// Who shares the shopping of the dinner on [day]: the members who said
  /// "Będę" (all members when nobody answered) and whoever paid.
  List<String> sharersOn(String day) {
    final Map<String, CircleMark<CircleAttendance>> answers =
        rsvp[day] ?? const <String, CircleMark<CircleAttendance>>{};
    final Set<String> coming = <String>{
      for (final CircleMember m in members)
        if (answers[m.address]?.value == CircleAttendance.yes) m.address,
    };
    final Set<String> all = <String>{
      if (coming.isEmpty)
        for (final CircleMember m in members) m.address
      else
        ...coming,
      for (final MapEntry<String, CircleMark<int>> e
          in (spent[day] ?? const <String, CircleMark<int>>{}).entries)
        if (e.value.value > 0) e.key,
    };
    return all.toList()..sort();
  }

  /// What was spent on the shopping of the dinner on [day], in grosze.
  int spentOn(String day) => (spent[day] ?? const <String, CircleMark<int>>{})
      .values
      .fold(0, (int s, CircleMark<int> m) => s + max(0, m.value));

  /// "Kto komu ile" after the dinner on [day]: everyone who shares pays an
  /// equal part of what was spent; those who paid less give the difference
  /// to those who paid more, in as few transfers as this simple pairing
  /// gives (the largest debt to the largest credit first). No money moves
  /// through Zen.
  List<CircleTransfer> settleUp(String day) {
    final List<String> who = sharersOn(day);
    final int total = spentOn(day);
    if (who.length < 2 || total <= 0) {
      return const <CircleTransfer>[];
    }
    final int share = total ~/ who.length;
    final int rest = total % who.length;
    final Map<String, int> balance = <String, int>{
      for (int i = 0; i < who.length; i++)
        who[i]:
            max(0, spent[day]?[who[i]]?.value ?? 0) -
            share -
            (i < rest ? 1 : 0),
    };
    int byAmount(MapEntry<String, int> a, MapEntry<String, int> b) {
      final int c = b.value.abs().compareTo(a.value.abs());
      return c != 0 ? c : a.key.compareTo(b.key);
    }

    final List<MapEntry<String, int>> owed = <MapEntry<String, int>>[
      for (final MapEntry<String, int> e in balance.entries)
        if (e.value > 0) e,
    ]..sort(byAmount);
    final List<MapEntry<String, int>> owing = <MapEntry<String, int>>[
      for (final MapEntry<String, int> e in balance.entries)
        if (e.value < 0) e,
    ]..sort(byAmount);
    final List<CircleTransfer> out = <CircleTransfer>[];
    int i = 0;
    int j = 0;
    int credit = owed.isEmpty ? 0 : owed.first.value;
    int debt = owing.isEmpty ? 0 : -owing.first.value;
    while (i < owed.length && j < owing.length) {
      final int amount = min(credit, debt);
      if (amount > 0) {
        out.add(CircleTransfer(owing[j].key, owed[i].key, amount));
      }
      credit -= amount;
      debt -= amount;
      if (credit == 0 && ++i < owed.length) {
        credit = owed[i].value;
      }
      if (debt == 0 && ++j < owing.length) {
        debt = -owing[j].value;
      }
    }
    return out;
  }

  /// Whether [transfer] of the dinner on [day] is marked "Rozliczone ✓".
  bool isSettled(String day, CircleTransfer transfer) =>
      settled[day]?.containsKey(transfer.key) ?? false;

  DinnerCircle copyWith({
    List<CircleMember>? members,
    Map<String, CircleInvite>? invited,
    Map<String, int>? gone,
    Map<String, String>? prefs,
    Map<String, Set<CircleDiet>>? diets,
    Map<String, Map<String, String>>? items,
    bool? open,
    Map<String, Map<String, CircleGuest>>? guests,
    List<KittyEntry>? kitty,
    Map<String, Map<String, CircleMark<CircleAttendance>>>? rsvp,
    Map<String, Map<String, CircleMark<int>>>? spent,
    Map<String, Map<String, int>>? settled,
    Map<String, Map<String, CircleMark<CircleHow>>>? how,
    int? updatedAt,
  }) => DinnerCircle(
    id: id,
    name: name,
    members: members == null ? this.members : ordered(members),
    invited: invited ?? this.invited,
    gone: gone ?? this.gone,
    weekday: weekday,
    hour: hour,
    firstDinner: firstDinner,
    everyWeeks: everyWeeks,
    prefs: prefs ?? this.prefs,
    diets: diets ?? this.diets,
    items: items ?? this.items,
    open: open ?? this.open,
    guests: guests ?? this.guests,
    pairs: pairs,
    kitty: kitty ?? this.kitty,
    rsvp: rsvp ?? this.rsvp,
    spent: spent ?? this.spent,
    settled: settled ?? this.settled,
    how: how ?? this.how,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  /// This circle with one member's per-dinner value set.
  static Map<String, Map<String, CircleMark<T>>> withMark<T>(
    Map<String, Map<String, CircleMark<T>>> marks,
    String day,
    String who,
    CircleMark<T>? mark,
  ) {
    final Map<String, CircleMark<T>> forDay = <String, CircleMark<T>>{
      ...?marks[day],
    };
    if (mark == null) {
      forDay.remove(who);
    } else {
      forDay[who] = mark;
    }
    return <String, Map<String, CircleMark<T>>>{...marks, day: forDay};
  }

  /// Two copies of the same circle made one ([a] the one kept, [b] the one
  /// that came). The newer copy gives the settings (name, items, kitty, guests, preferences); membership merges:
  /// the newer joining of each person counts unless they left after it,
  /// invitations stand until answered or outdated, and the per-dinner
  /// answers keep each member's newest. The same on every phone, whatever
  /// order the copies come in.
  static DinnerCircle merge(DinnerCircle a, DinnerCircle b) {
    // Equal dates: the copy that came ([b]) gives the settings.
    final bool bNewer = b.updatedAt >= a.updatedAt;
    final DinnerCircle base = bNewer ? b : a;
    final DinnerCircle other = bNewer ? a : b;
    final Map<String, int> gone = <String, int>{...a.gone};
    b.gone.forEach((String k, int v) {
      if (v > (gone[k] ?? -1)) {
        gone[k] = v;
      }
    });
    final Map<String, CircleMember> members = <String, CircleMember>{};
    void addMember(CircleMember m, {required bool fromBase}) {
      final CircleMember? had = members[m.address];
      if (had == null || m.at > had.at || (m.at == had.at && fromBase)) {
        members[m.address] = m;
      }
    }

    for (final CircleMember m in other.members) {
      addMember(m, fromBase: false);
    }
    for (final CircleMember m in base.members) {
      addMember(m, fromBase: true);
    }
    members.removeWhere((String k, CircleMember m) => m.at <= (gone[k] ?? -1));
    final Map<String, CircleInvite> invited = <String, CircleInvite>{
      ...other.invited,
    };
    base.invited.forEach((String k, CircleInvite v) {
      final CircleInvite? had = invited[k];
      if (had == null || v.at >= had.at) {
        invited[k] = v;
      }
    });
    invited.removeWhere(
      (String k, CircleInvite v) =>
          v.at <= (gone[k] ?? -1) || (members[k]?.at ?? -1) >= v.at,
    );
    return base.copyWith(
      members: members.values.toList(),
      invited: invited,
      gone: gone,
      rsvp: _mergeMarks(base.rsvp, other.rsvp),
      spent: _mergeMarks(base.spent, other.spent),
      how: _mergeMarks(base.how, other.how),
      settled: <String, Map<String, int>>{
        for (final String day in <String>{
          ...base.settled.keys,
          ...other.settled.keys,
        })
          day: <String, int>{...?other.settled[day], ...?base.settled[day]},
      },
      updatedAt: max(a.updatedAt, b.updatedAt),
    );
  }

  static _DayMarks<T> _mergeMarks<T>(_DayMarks<T> a, _DayMarks<T> b) {
    final _DayMarks<T> out = <String, Map<String, CircleMark<T>>>{};
    for (final String day in <String>{...a.keys, ...b.keys}) {
      final Map<String, CircleMark<T>> merged = <String, CircleMark<T>>{
        ...?b[day],
      };
      a[day]?.forEach((String who, CircleMark<T> m) {
        final CircleMark<T>? had = merged[who];
        if (had == null || m.at >= had.at) {
          merged[who] = m;
        }
      });
      out[day] = merged;
    }
    return out;
  }

  /// No date later than [latest] (a phone whose clock runs ahead must not
  /// freeze a membership or an answer against everyone else's later ones).
  DinnerCircle clampedTo(int latest) {
    int c(int v) => min(v, latest);
    _DayMarks<T> marks<T>(
      _DayMarks<T> m,
    ) => <String, Map<String, CircleMark<T>>>{
      for (final MapEntry<String, Map<String, CircleMark<T>>> d in m.entries)
        d.key: <String, CircleMark<T>>{
          for (final MapEntry<String, CircleMark<T>> e in d.value.entries)
            e.key: CircleMark<T>(e.value.value, c(e.value.at)),
        },
    };
    return copyWith(
      members: <CircleMember>[
        for (final CircleMember m in members)
          CircleMember(m.address, m.name, pos: m.pos, at: c(m.at)),
      ],
      invited: <String, CircleInvite>{
        for (final MapEntry<String, CircleInvite> e in invited.entries)
          e.key: CircleInvite(
            name: e.value.name,
            by: e.value.by,
            at: c(e.value.at),
          ),
      },
      gone: <String, int>{
        for (final MapEntry<String, int> e in gone.entries) e.key: c(e.value),
      },
      rsvp: marks(rsvp),
      spent: marks(spent),
      how: marks(how),
      updatedAt: c(updatedAt),
    );
  }

  /// Without the per-dinner answers of dinners before [cutoff].
  DinnerCircle prunedBefore(int cutoff) {
    final String oldest = dayKey(DateTime.fromMillisecondsSinceEpoch(cutoff));
    bool keep(String day) => day.compareTo(oldest) >= 0;
    Map<String, V> recent<V>(Map<String, V> m) => <String, V>{
      for (final MapEntry<String, V> e in m.entries)
        if (keep(e.key)) e.key: e.value,
    };
    return copyWith(
      rsvp: recent(rsvp),
      spent: recent(spent),
      settled: recent(settled),
      how: recent(how),
      items: recent(items),
    );
  }

  static Map<String, dynamic> _marksJson<T>(
    _DayMarks<T> marks,
    Object Function(T) encode,
  ) => <String, dynamic>{
    for (final MapEntry<String, Map<String, CircleMark<T>>> d in marks.entries)
      d.key: <String, dynamic>{
        for (final MapEntry<String, CircleMark<T>> e in d.value.entries)
          e.key: <Object>[encode(e.value.value), e.value.at],
      },
  };

  static _DayMarks<T> _marksFrom<T>(Object? json, T? Function(Object?) decode) {
    final _DayMarks<T> out = <String, Map<String, CircleMark<T>>>{};
    if (json is! Map) {
      return out;
    }
    for (final MapEntry<dynamic, dynamic> d in json.entries.take(120)) {
      if (!isDayKey(d.key) || d.value is! Map) {
        continue;
      }
      final Map<String, CircleMark<T>> day = <String, CircleMark<T>>{};
      for (final MapEntry<dynamic, dynamic> e in (d.value as Map).entries.take(
        kCircleMaxMembers * 2,
      )) {
        final Object? v = e.value;
        if (e.key is! String || v is! List || v.length != 2 || v[1] is! int) {
          continue;
        }
        final T? value = decode(v[0]);
        if (value != null) {
          day[_n(e.key as String)] = CircleMark<T>(value, v[1] as int);
        }
      }
      out[d.key as String] = day;
    }
    return out;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'members': <Map<String, dynamic>>[
      for (final CircleMember m in members) m.toJson(),
    ],
    if (invited.isNotEmpty)
      'inv': <String, dynamic>{
        for (final MapEntry<String, CircleInvite> e in invited.entries)
          e.key: e.value.toJson(),
      },
    if (gone.isNotEmpty) 'gone': gone,
    'wd': weekday,
    'h': hour,
    'first': firstDinner,
    'every': everyWeeks,
    'prefs': prefs,
    if (diets.isNotEmpty)
      'diet': <String, List<String>>{
        for (final MapEntry<String, Set<CircleDiet>> e in diets.entries)
          e.key: <String>[for (final CircleDiet d in e.value) d.code],
      },
    'items': items,
    if (open) 'open': true,
    if (pairs) 'pairs': true,
    if (kitty.isNotEmpty)
      'kitty': <Map<String, dynamic>>[
        for (final KittyEntry e in kitty) e.toJson(),
      ],
    if (guests.isNotEmpty)
      'guests': <String, dynamic>{
        for (final MapEntry<String, Map<String, CircleGuest>> m
            in guests.entries)
          m.key: <String, dynamic>{
            for (final MapEntry<String, CircleGuest> g in m.value.entries)
              g.key: g.value.toJson(),
          },
      },
    if (rsvp.isNotEmpty)
      'rsvp': _marksJson<CircleAttendance>(
        rsvp,
        (CircleAttendance a) => a.code,
      ),
    if (spent.isNotEmpty) 'spent': _marksJson<int>(spent, (int c) => c),
    if (settled.isNotEmpty) 'settled': settled,
    if (how.isNotEmpty)
      'how': _marksJson<CircleHow>(how, (CircleHow h) => h.code),
    'upd': updatedAt,
  };

  static DinnerCircle? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['name'] is! String ||
        json['members'] is! List ||
        json['first'] is! int) {
      return null;
    }
    final Map<String, CircleMember> members = <String, CircleMember>{
      for (final Object? m in (json['members'] as List).take(20))
        if (CircleMember.fromJson(m) case final CircleMember member)
          member.address: member,
    };
    final Object? inv = json['inv'];
    final Object? gone = json['gone'];
    final Object? prefs = json['prefs'];
    final Object? diets = json['diet'];
    final Object? items = json['items'];
    final Object? guests = json['guests'];
    final Object? kitty = json['kitty'];
    final Object? settled = json['settled'];
    return DinnerCircle(
      id: json['id'] as String,
      name: _clip(json['name'], 60),
      members: ordered(members.values),
      invited: <String, CircleInvite>{
        if (inv is Map)
          for (final MapEntry<dynamic, dynamic> e in inv.entries.take(20))
            if (e.key is String)
              if (CircleInvite.fromJson(e.value) case final CircleInvite i)
                _n(e.key as String): i,
      },
      gone: <String, int>{
        if (gone is Map)
          for (final MapEntry<dynamic, dynamic> e in gone.entries.take(200))
            if (e.key is String && e.value is int)
              _n(e.key as String): e.value as int,
      },
      pairs: json['pairs'] == true,
      kitty: <KittyEntry>[
        if (kitty is List)
          for (final Object? e in kitty.take(kCircleKittyMax))
            if (KittyEntry.fromJson(e) case final KittyEntry k) k,
      ],
      weekday: json['wd'] is int ? (json['wd'] as int).clamp(1, 7) : 4,
      hour: json['h'] is int ? (json['h'] as int).clamp(0, 23) : 19,
      firstDinner: json['first'] as int,
      everyWeeks: json['every'] is int ? (json['every'] as int).clamp(1, 8) : 1,
      prefs: <String, String>{
        if (prefs is Map)
          for (final MapEntry<dynamic, dynamic> e in prefs.entries)
            if (e.key is String && e.value is String)
              e.key as String: _clip(e.value, 300),
      },
      diets: <String, Set<CircleDiet>>{
        if (diets is Map)
          for (final MapEntry<dynamic, dynamic> e in diets.entries.take(20))
            if (e.key is String && e.value is List)
              _n(e.key as String): <CircleDiet>{
                for (final Object? c in (e.value as List).take(8))
                  if (CircleDiet.byCode(c) case final CircleDiet d) d,
              },
      },
      items: <String, Map<String, String>>{
        if (items is Map)
          for (final MapEntry<dynamic, dynamic> d in items.entries)
            if (d.key is String && d.value is Map)
              d.key as String: <String, String>{
                for (final MapEntry<dynamic, dynamic> i
                    in (d.value as Map).entries)
                  if (i.key is String && i.value is String)
                    _clip(i.key, 60): i.value as String,
              },
      },
      open: json['open'] == true,
      guests: <String, Map<String, CircleGuest>>{
        if (guests is Map)
          for (final MapEntry<dynamic, dynamic> m in guests.entries.take(36))
            if (m.key is String && m.value is Map)
              m.key as String: <String, CircleGuest>{
                for (final MapEntry<dynamic, dynamic> g
                    in (m.value as Map).entries)
                  if (g.key is String)
                    if (CircleGuest.fromJson(g.value)
                        case final CircleGuest guest)
                      _n(g.key as String): guest,
              },
      },
      rsvp: _marksFrom<CircleAttendance>(json['rsvp'], CircleAttendance.byCode),
      spent: _marksFrom<int>(
        json['spent'],
        (Object? c) => c is int && c >= 0 && c <= 100000000 ? c : null,
      ),
      settled: <String, Map<String, int>>{
        if (settled is Map)
          for (final MapEntry<dynamic, dynamic> d in settled.entries.take(120))
            if (isDayKey(d.key) && d.value is Map)
              d.key as String: <String, int>{
                for (final MapEntry<dynamic, dynamic> e
                    in (d.value as Map).entries.take(64))
                  if (e.key is String &&
                      (e.key as String).length <= 300 &&
                      e.value is int)
                    e.key as String: e.value as int,
              },
      },
      how: _marksFrom<CircleHow>(json['how'], CircleHow.byCode),
      updatedAt: json['upd'] is int ? json['upd'] as int : 0,
    );
  }
}
