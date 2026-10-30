import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/encounters.dart';

/// Which part of the "Mijani" list a moment belongs to.
enum EncounterDay { today, yesterday, older }

/// The part of the list [at] (milliseconds) goes in, seen from [now]
/// (local days).
EncounterDay encounterDayOf(int at, DateTime now) {
  final DateTime day = DateTime.fromMillisecondsSinceEpoch(at);
  final DateTime today = DateTime(now.year, now.month, now.day);
  final DateTime that = DateTime(day.year, day.month, day.day);
  if (!that.isBefore(today)) {
    return EncounterDay.today;
  }
  if (!that.isBefore(DateTime(now.year, now.month, now.day - 1))) {
    return EncounterDay.yesterday;
  }
  return EncounterDay.older;
}

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(int at) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(at);
  return '${_two(d.hour)}:${_two(d.minute)}';
}

String _date(int at) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(at);
  return '${d.day}.${_two(d.month)}';
}

/// "14:05–14:30" (with the date in front for older days).
String encounterSpan(int start, int end, {bool withDate = false}) {
  final String from = _clock(start);
  final String to = _clock(end);
  final String span = from == to ? from : '$from–$to';
  return withDate ? '${_date(start)}, $span' : span;
}

/// One row per person and local day: the [encounters] of one friend on
/// one day joined (from the first start to the last end, the newest
/// place), each with how many passes it holds. A friend who walks in and
/// out of range is one person, not a row per pass.
List<(Encounter, int)> encountersByDay(List<Encounter> encounters) {
  final Map<(String, int, int, int), (Encounter, int)> joined =
      <(String, int, int, int), (Encounter, int)>{};
  for (final Encounter e in encounters) {
    final DateTime day = DateTime.fromMillisecondsSinceEpoch(e.start);
    final (String, int, int, int) key = (
      e.friend,
      day.year,
      day.month,
      day.day,
    );
    final (Encounter, int)? had = joined[key];
    if (had == null) {
      joined[key] = (e, 1);
      continue;
    }
    final Encounter was = had.$1;
    final bool newer = e.end >= was.end;
    joined[key] = (
      Encounter(
        friend: e.friend,
        start: e.start < was.start ? e.start : was.start,
        end: newer ? e.end : was.end,
        place: (newer ? e.place ?? was.place : was.place ?? e.place),
      ),
      had.$2 + 1,
    );
  }
  return joined.values.toList();
}

/// "Mijani" in the "W pobliżu" screen: friends passed and how many
/// others, kept only on this phone.
class EncountersSection extends StatelessWidget {
  const EncountersSection({
    required this.log,
    required this.nameOf,
    required this.hasMet,
    required this.onOpen,
    required this.onMet,
    required this.onPlace,
    this.friendOf,
    this.lookingInBackground = false,
    this.now,
    super.key,
  });

  final EncounterLog log;
  final String Function(String friend) nameOf;

  /// The friend an encounter's address is now (one of their other devices,
  /// an address they had before): one person is one row, under one name.
  final String Function(String address)? friendOf;

  /// Whether "met in person" is already signed for [friend].
  final bool Function(String friend) hasMet;

  /// Opens [friend]'s profile.
  final void Function(String friend) onOpen;

  /// The explicit "met in person" question for [friend].
  final void Function(String friend) onMet;
  final void Function(EncounterPlace place) onPlace;

  /// "Rozglądaj się też w tle" is on (passing people is then noted also
  /// with the screen closed).
  final bool lookingInBackground;

  /// The clock (tests).
  final DateTime Function()? now;

  Future<void> _clear(BuildContext context) async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(t('Wyczyścić „Mijani”?')),
        content: Text(
          t('Cała lista zniknie z tego telefonu. Nie da się tego cofnąć.'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('encounters-clear-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Wyczyść')),
          ),
        ],
      ),
    );
    if (sure == true) {
      await log.clear();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: log,
    builder: (BuildContext context, Widget? _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    List<Encounter> encounters = log.encounters;
    final String Function(String address)? friendOf = this.friendOf;
    if (friendOf != null) {
      List<Encounter> joined = <Encounter>[];
      for (final Encounter e in encounters) {
        joined = mergeEncounter(
          joined,
          Encounter(
            friend: friendOf(e.friend),
            start: e.start,
            end: e.end,
            place: e.place,
          ),
        );
      }
      encounters = joined;
    }
    final List<EncounterCrowd> crowds = log.crowds;
    final bool empty = encounters.isEmpty && crowds.isEmpty;
    final DateTime today = (now ?? DateTime.now)();
    // Friends (one row a day each) and counts together, newest first.
    final List<(int, (Encounter, int)?, EncounterCrowd?)> rows =
        <(int, (Encounter, int)?, EncounterCrowd?)>[
          for (final (Encounter, int) e in encountersByDay(encounters))
            (e.$1.end, e, null),
          for (final EncounterCrowd c in crowds) (c.windowEnd - 1, null, c),
        ]..sort(
          (
            (int, (Encounter, int)?, EncounterCrowd?) a,
            (int, (Encounter, int)?, EncounterCrowd?) b,
          ) => b.$1.compareTo(a.$1),
        );
    final List<Widget> list = <Widget>[];
    EncounterDay? shown;
    for (final (int at, (Encounter, int)? e, EncounterCrowd? c) in rows) {
      final EncounterDay day = encounterDayOf(at, today);
      if (day != shown) {
        shown = day;
        list.add(
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(4, 12, 0, 4),
            child: Text(
              switch (day) {
                EncounterDay.today => t('Dziś'),
                EncounterDay.yesterday => t('Wczoraj'),
                EncounterDay.older => t('Wcześniej'),
              },
              style: TextStyle(
                color: zen.textMuted,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        );
      }
      final bool older = day == EncounterDay.older;
      if (e != null) {
        list.add(_encounterTile(e.$1, zen, older, passes: e.$2));
      } else if (c != null) {
        list.add(_crowdTile(c, zen, older));
      }
    }
    return Column(
      key: const Key('encounters'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenSection(
          t('Mijani'),
          action: empty ? null : t('Wyczyść'),
          onAction: empty ? null : () => unawaited(_clear(context)),
        ),
        ZenGroup(
          children: <Widget>[
            SwitchListTile(
              key: const Key('encounters-recording'),
              value: log.recording,
              title: Text(t('Zapisuj, kogo mijam')),
              subtitle: Text(
                lookingInBackground
                    ? t(
                        'Gdy telefon i tak rozgląda się w pobliżu: na tym '
                        'ekranie i co 5 minut w tle. Bez dodatkowego '
                        'szukania.',
                      )
                    : t(
                        'Tylko gdy ten ekran jest otwarty. Włącz „Rozglądaj '
                        'się też w tle”, żeby zapisywało się też z telefonem '
                        'w kieszeni.',
                      ),
              ),
              onChanged: (bool v) => unawaited(log.setRecording(v)),
            ),
          ],
        ),
        ZenInfo(
          key: const Key('encounters-privacy'),
          icon: Icons.lock_outline_rounded,
          text: t(
            'Zapisane tylko na tym telefonie — nigdy nigdzie nie wysyłane. '
            'Znajomych widać z imieniem; innych ludzi z Zen (także '
            'znajomych znajomych) tylko jako liczbę, bez śledzenia. Miejsce, '
            'w przybliżeniu, tylko gdy Zen ma zgodę na położenie (tę od '
            'alarmu). Po 30 dniach wpisy znikają same.',
          ),
        ),
        if (empty)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Text(
              log.recording
                  ? t('Jeszcze nikogo nie minięto.')
                  : t('Zapisywanie jest wyłączone.'),
              key: const Key('encounters-empty'),
              style: TextStyle(color: zen.textMuted, fontSize: 13.5),
            ),
          ),
        ...list,
      ],
    );
  }

  Widget _encounterTile(
    Encounter e,
    ZenColors zen,
    bool older, {
    int passes = 1,
  }) {
    final String friend = e.friend;
    final EncounterPlace? place = e.place;
    final bool met = hasMet(friend);
    // Confirmed only within a week of passing.
    final bool mayConfirm = encounterMayConfirm(
      e,
      (now ?? DateTime.now)().millisecondsSinceEpoch,
    );
    final String span = encounterSpan(e.start, e.end, withDate: older);
    final String when = passes < 2
        ? span
        : '$span · ${tn(passes, one: '{n} raz', few: '{n} razy', many: '{n} razy')}';
    return ZenTile(
      key: Key('encounter-$friend-${e.start}'),
      icon: Icons.directions_walk_rounded,
      tone: zen.success,
      title: nameOf(friend),
      subtitle: place == null
          ? when
          : t('{time} · miejsce w przybliżeniu', {'time': when}),
      onTap: () => onOpen(friend),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (place != null)
            IconButton(
              key: Key('encounter-place-$friend-${e.start}'),
              tooltip: t('Pokaż na mapie'),
              icon: const Icon(Icons.map_outlined),
              onPressed: () => onPlace(place),
            ),
          if (met)
            Icon(Icons.verified_rounded, color: zen.success)
          else if (mayConfirm)
            // Being near is only a hint: the meeting is signed when
            // confirmed.
            TextButton(
              key: Key('encounter-met-$friend-${e.start}'),
              onPressed: () => onMet(friend),
              child: Text(t('Spotkani?')),
            ),
        ],
      ),
    );
  }

  Widget _crowdTile(EncounterCrowd c, ZenColors zen, bool older) => ZenTile(
    key: Key('encounter-crowd-${c.windowStart}'),
    icon: Icons.groups_outlined,
    tone: zen.textMuted,
    title: tn(
      c.count,
      one: '{n} inna osoba z Zen',
      few: '{n} inne osoby z Zen',
      many: '{n} innych osób z Zen',
    ),
    subtitle: t('{time} · bez imion', {
      'time': encounterSpan(c.windowStart, c.windowEnd, withDate: older),
    }),
  );
}
