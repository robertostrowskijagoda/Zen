import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/presentation/events_screen.dart'
    show eventDate;
import 'package:zen/src/features/meet/presentation/meet_thread_sheet.dart';

/// An invitation to a circle: what it is, who is in, "Dołączam" / "Nie,
/// dziękuję".
class CircleInviteCard extends StatelessWidget {
  const CircleInviteCard({
    required this.circle,
    required this.service,
    required this.me,
    this.onJoined,
    super.key,
  });

  final DinnerCircle circle;
  final CircleService service;
  final String me;
  final VoidCallback? onJoined;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 3);
    final DinnerCircle c = circle;
    final String by = c.nameIn(c.invited[me]?.by ?? '') ?? t('ktoś z kółka');
    final List<(DateTime, CircleMember)> next = c.schedule(
      service.now,
      count: 1,
    );
    return ZenCard(
      key: Key('circle-invite-${c.id}'),
      tone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ZenIconBadge(
                icon: Icons.soup_kitchen_rounded,
                tone: tone,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t('{name} zaprasza Cię do kółka „{circle}”', {
                    'name': by,
                    'circle': c.name,
                  }),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            <String>[
              if (next.isNotEmpty)
                t('Pierwszy obiad: {date}', {
                  'date': eventDate(next.first.$1.millisecondsSinceEpoch),
                }),
              t('W kółku: {names}', {
                'names': c.members.map((CircleMember m) => m.name).join(', '),
              }),
              if (c.invited.length > 1)
                t('Zaproszonych: {n}', {'n': c.invited.length}),
            ].join('\n'),
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: Key('circle-join-${c.id}'),
                onPressed: () async {
                  await service.answerInvite(c.id, true);
                  onJoined?.call();
                },
                icon: const Icon(Icons.check_rounded),
                label: Text(t('Dołączam')),
              ),
              OutlinedButton(
                key: Key('circle-decline-${c.id}'),
                onPressed: () => unawaited(service.answerInvite(c.id, false)),
                child: Text(t('Nie, dziękuję')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The next dinner: who cooks, "Będę / Nie dam rady / Może", the count for
/// the cook and the dinner's small chat.
class CircleNextDinnerCard extends StatelessWidget {
  const CircleNextDinnerCard({
    required this.circle,
    required this.service,
    required this.at,
    required this.cook,
    required this.me,
    super.key,
  });

  final DinnerCircle circle;
  final CircleService service;
  final DateTime at;
  final CircleMember cook;
  final String me;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 3);
    final DinnerCircle c = circle;
    final String day = DinnerCircle.dayKey(at);
    final CircleAttendance? mine = c.attendanceOf(me, day);
    final CircleHeadcount count = c.headcountOn(at);
    final bool cooking = cook.address == me;
    final int unread = service.unread(c.id, at);
    return ZenCard(
      key: const Key('circle-next'),
      tone: cooking ? tone : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t('Kto będzie · {date}', {
              'date': eventDate(at.millisecondsSinceEpoch),
            }),
            style: TextStyle(
              color: zen.textPrimary,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            cooking
                ? t('Gotujesz Ty')
                : t('gotuje {name}', {'name': cook.name}),
            style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final CircleAttendance a in CircleAttendance.values)
                ChoiceChip(
                  key: Key('circle-rsvp-${a.code}'),
                  label: Text(a.label),
                  selected: mine == a,
                  onSelected: (_) => unawaited(service.rsvp(c.id, at, a)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.groups_rounded, size: 20, color: zen.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  circleCountText(count),
                  key: const Key('circle-count'),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('circle-chat'),
              onPressed: () => unawaited(
                showMeetThreadSheet(
                  context,
                  title: t('Czat obiadu · {date}', {
                    'date': eventDate(at.millisecondsSinceEpoch),
                  }),
                  listenable: service,
                  messages: () => service.thread(c.id, at),
                  nameOf: (String a) => c.nameIn(a) ?? t('ktoś'),
                  send: (String text) => service.sendChat(c.id, at, text),
                  empty: t('Np. „Spóźnię się 10 min” albo „Kupić chleb?”.'),
                  onSeen: () => unawaited(service.markRead(c.id, at)),
                ),
              ),
              icon: Badge(
                isLabelVisible: unread > 0,
                label: Text('$unread'),
                child: const Icon(Icons.chat_bubble_outline_rounded),
              ),
              label: Text(t('Czat obiadu')),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Jak było?" after a dinner, and what comes next.
class CircleHowCard extends StatelessWidget {
  const CircleHowCard({
    required this.circle,
    required this.service,
    required this.day,
    super.key,
  });

  final DinnerCircle circle;
  final CircleService service;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 3);
    final List<(DateTime, CircleMember)> next = circle.schedule(
      service.now,
      count: 1,
    );
    return ZenCard(
      key: const Key('circle-how'),
      tone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t('Jak było?'),
            style: TextStyle(
              color: zen.textPrimary,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final CircleHow h in CircleHow.values)
                ActionChip(
                  key: Key('circle-how-${h.code}'),
                  label: Text(h.label),
                  onPressed: () => unawaited(service.rate(circle.id, day, h)),
                ),
            ],
          ),
          if (next.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              t('Następny obiad: {date} · gotuje {name}', {
                'date': eventDate(next.first.$1.millisecondsSinceEpoch),
                'name': next.first.$2.name,
              }),
              style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
            ),
          ],
        ],
      ),
    );
  }
}

/// What the members said after a dinner, for everyone ("4× Super").
String circleHowSummary(DinnerCircle c, String day) {
  final Map<CircleHow, int> counts = <CircleHow, int>{};
  for (final CircleMark<CircleHow> m
      in (c.how[day] ?? const <String, CircleMark<CircleHow>>{}).values) {
    counts[m.value] = (counts[m.value] ?? 0) + 1;
  }
  return <String>[
    for (final CircleHow h in CircleHow.values)
      if ((counts[h] ?? 0) > 0) '${counts[h]}× ${h.label}',
  ].join(' · ');
}

/// "Kto komu ile" for one dinner: "Wydałem(-am) na zakupy", the transfers
/// and "Rozliczone ✓".
class CircleSettleUp extends StatelessWidget {
  const CircleSettleUp({
    required this.circle,
    required this.service,
    required this.day,
    required this.me,
    required this.format,
    required this.parse,
    super.key,
  });

  final DinnerCircle circle;
  final CircleService service;
  final DateTime day;
  final String me;
  final String Function(int cents) format;
  final int? Function(String? text) parse;

  Future<void> _spent(BuildContext context) async {
    final String key = DinnerCircle.dayKey(day);
    final int had = circle.spent[key]?[me]?.value ?? 0;
    final TextEditingController input = TextEditingController(
      text: had > 0 ? format(had) : '',
    );
    final String? v = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Ile wydałeś(-aś) na zakupy (zł)?')),
        content: TextField(
          key: const Key('circle-spent-input'),
          controller: input,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('circle-spent-save'),
            onPressed: () => Navigator.of(context).pop(input.text),
            child: Text(t('Zapisz')),
          ),
        ],
      ),
    );
    disposeLater(input);
    if (v == null) {
      return;
    }
    final int? cents = v.trim().isEmpty ? 0 : parse(v);
    if (cents == null || cents < 0) {
      return;
    }
    await service.setSpent(circle.id, day, cents);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final DinnerCircle c = circle;
    final String key = DinnerCircle.dayKey(day);
    final List<CircleTransfer> transfers = c.settleUp(key);
    final int total = c.spentOn(key);
    String nameOf(String a) => a == me ? t('Ty') : c.nameIn(a) ?? t('ktoś');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenSection(
          t('Kto komu ile · {date}', {
            'date': eventDate(day.millisecondsSinceEpoch),
          }),
          action: t('Wydałem(-am)'),
          onAction: () => unawaited(_spent(context)),
        ),
        if (total == 0)
          ZenInfo(
            icon: Icons.receipt_long_rounded,
            tone: zenTone(zen, 3),
            text: t(
              'Kto robił zakupy, wpisuje, ile wydał. Zen policzy, kto komu '
              'ile odda — pieniądze rozliczacie sami.',
            ),
          )
        else
          ZenCard(
            key: const Key('circle-settle'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t('Zakupy razem: {total} zł', {'total': format(total)}),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (transfers.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      t('Nikt nikomu nic nie oddaje.'),
                      style: TextStyle(color: zen.textSecondary),
                    ),
                  ),
                for (final CircleTransfer x in transfers)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            t('{from} oddaje {to} {amount} zł', {
                              'from': nameOf(x.from),
                              'to': nameOf(x.to),
                              'amount': format(x.cents),
                            }),
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (c.isSettled(key, x))
                          Text(
                            t('Rozliczone ✓'),
                            style: TextStyle(
                              color: zen.success,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        else if (x.from == me || x.to == me)
                          TextButton(
                            key: Key('circle-settled-${x.from}-${x.to}'),
                            onPressed: () =>
                                unawaited(service.markSettled(c.id, day, x)),
                            child: Text(t('Rozliczone')),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Czego nie jesz" for the cook's count: a few ticks.
Future<Set<CircleDiet>?> showCircleDietsDialog(
  BuildContext context,
  Set<CircleDiet> initial,
) {
  final Set<CircleDiet> chosen = Set<CircleDiet>.of(initial);
  return showDialog<Set<CircleDiet>>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) => AlertDialog(
        title: Text(t('Twoja dieta')),
        content: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final CircleDiet d in CircleDiet.values)
              FilterChip(
                key: Key('circle-diet-${d.code}'),
                label: Text(d.label),
                selected: chosen.contains(d),
                onSelected: (bool on) =>
                    set(() => on ? chosen.add(d) : chosen.remove(d)),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('circle-diet-save'),
            onPressed: () => Navigator.of(context).pop(chosen),
            child: Text(t('Zapisz')),
          ),
        ],
      ),
    ),
  );
}

/// "Spotkani?" after a dinner: the people at the table who are not friends
/// yet. [onMet] sends the invitation and asks how close (each side confirms
/// on its own phone).
class CircleNewPeopleCard extends StatefulWidget {
  const CircleNewPeopleCard({
    required this.people,
    required this.onMet,
    super.key,
  });

  /// (address, name).
  final List<(String, String)> people;
  final Future<void> Function(String address, String name) onMet;

  @override
  State<CircleNewPeopleCard> createState() => _CircleNewPeopleCardState();
}

class _CircleNewPeopleCardState extends State<CircleNewPeopleCard> {
  final Set<String> _done = <String>{};

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<(String, String)> left = <(String, String)>[
      for (final (String, String) p in widget.people)
        if (!_done.contains(p.$1)) p,
    ];
    if (left.isEmpty) {
      return const SizedBox.shrink();
    }
    return ZenCard(
      key: const Key('circle-new-people'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t('Nowi przy stole'),
            style: TextStyle(
              color: zen.textPrimary,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t(
              'Poznaliście się osobiście? Potwierdź tylko, jeśli byliście razem.',
            ),
            style: TextStyle(color: zen.textSecondary, fontSize: 13),
          ),
          for (final (String address, String name) in left)
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: zen.textPrimary),
                  ),
                ),
                TextButton(
                  key: Key('circle-met-$address'),
                  onPressed: () async {
                    setState(() => _done.add(address));
                    await widget.onMet(address, name);
                  },
                  child: Text(t('Spotkani?')),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
