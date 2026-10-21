import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/plan/plan_model.dart';
import 'package:zen/src/features/meet/plan/plan_providers.dart';
import 'package:zen/src/features/meet/plan/plan_service.dart';
import 'package:zen/src/features/meet/presentation/events_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The colour of "Plan na weekend".
Color planTone(ZenColors zen) => zenTone(zen, 5);

/// "Plan na weekend".
class PlanScreen extends ConsumerStatefulWidget {
  const PlanScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const PlanScreen(),
    ),
  );

  @override
  ConsumerState<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends ConsumerState<PlanScreen> {
  @override
  void initState() {
    super.initState();
    // What the background service took in while the app was away.
    final PlanService plans = ref.read(planServiceProvider);
    unawaitedLogged(
      plans.load().then((_) => plans.checkThresholds()),
      context: 'Odczyt planów',
    );
  }

  @override
  Widget build(BuildContext context) => PlanBoard(
    plans: ref.watch(planServiceProvider),
    events: ref.watch(eventServiceProvider),
  );
}

/// The plans: this person's own, and friends' ones to answer.
class PlanBoard extends StatelessWidget {
  const PlanBoard({required this.plans, this.events, super.key});

  final PlanService plans;

  /// For opening the event a plan became (`null`: no such button).
  final EventService? events;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = planTone(zen);
    final EventService? ev = events;
    return Scaffold(
      key: const Key('plan-screen'),
      appBar: AppBar(title: Text(t('Plan na weekend'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('plan-new'),
        onPressed: () => unawaited(showPlanSheet(context, plans)),
        icon: const Icon(Icons.add_rounded),
        label: Text(t('Nowy plan')),
      ),
      body: ListenableBuilder(
        listenable: ev == null
            ? plans
            : Listenable.merge(<Listenable>[plans, ev]),
        builder: (BuildContext context, Widget? _) {
          final int now = plans.now;
          final List<WeekendPlan> all = plans.plans;
          final List<WeekendPlan> mine = all
              .where((WeekendPlan p) => p.isMine)
              .toList();
          final List<WeekendPlan> others = all
              .where((WeekendPlan p) => !p.isMine)
              .toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: <Widget>[
              ZenHero(
                title: t('Kto chętny?'),
                icon: Icons.wb_sunny_rounded,
                tone: tone,
                text: t(
                  'Rzuć luźny plan. Gdy dołączy dość osób, sam zamieni się '
                  'w wydarzenie z czatem. Bez chętnych zgaśnie po terminie.',
                ),
              ),
              if (all.isEmpty)
                ZenEmpty(
                  key: const Key('plan-empty'),
                  icon: Icons.wb_sunny_rounded,
                  tone: tone,
                  title: t('Na razie żadnych planów'),
                  text: t(
                    'Zaproponuj coś na weekend — znajomi odpowiedzą '
                    '„Dołączam” albo „Może”.',
                  ),
                  action: FilledButton.icon(
                    key: const Key('plan-empty-new'),
                    onPressed: () => unawaited(showPlanSheet(context, plans)),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(t('Zaproponuj plan')),
                  ),
                ),
              if (mine.isNotEmpty) ...<Widget>[
                ZenSection(t('Twoje plany'), top: 12),
                for (final WeekendPlan p in mine)
                  PlanCard(
                    key: Key('plan-${p.id}'),
                    plan: p,
                    plans: plans,
                    events: ev,
                    now: now,
                  ),
              ],
              if (others.isNotEmpty) ...<Widget>[
                ZenSection(t('Od znajomych'), top: 12),
                for (final WeekendPlan p in others)
                  PlanCard(
                    key: Key('plan-${p.id}'),
                    plan: p,
                    plans: plans,
                    events: ev,
                    now: now,
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// One plan: when and what, who is in (and through whom), how far to the
/// event, and the answers.
class PlanCard extends StatelessWidget {
  const PlanCard({
    required this.plan,
    required this.plans,
    required this.now,
    this.events,
    super.key,
  });

  final WeekendPlan plan;
  final PlanService plans;
  final EventService? events;
  final int now;

  Future<void> _cancel(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Odwołać plan?')),
        content: Text(t('Znajomi zobaczą, że plan jest nieaktualny.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Nie')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Odwołaj')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await plans.cancel(plan.id);
    }
  }

  Future<void> _convert(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool made = await plans.convertNow(plan.id) != null;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          made
              ? t('Jest wydarzenie. Zaproszenia poszły.')
              : t('Nie udało się zrobić wydarzenia.'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final WeekendPlan p = plan;
    final Color tone = planTone(zen);
    final String me = PeerShareCodec.normalizeAddress(plans.host.ownAddress());
    final String? via = plans.viaOf(p.id);
    final String who = p.isMine
        ? t('Twój plan')
        : via == null
        ? p.organizerName
        : t('{name}, przez {via}', {
            'name': p.organizerName,
            'via': plans.host.nameOf(via),
          });
    final bool over = p.startsAt <= now;
    final String? eventId = p.eventId;
    final List<PlanAnswer> joined = p.joined;
    final List<PlanAnswer> maybe = p.maybe;
    return ZenCard(
      tone: p.isEvent ? tone : null,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ZenIconBadge(
                icon: p.isEvent
                    ? Icons.celebration_rounded
                    : Icons.wb_sunny_rounded,
                tone: tone,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      planWhen(p.startsAt, now),
                      style: zen.label(color: tone),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      p.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    if (p.place.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.place_outlined,
                            size: 15,
                            color: zen.textMuted,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              p.place,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: zen.textSecondary,
                                fontSize: 13.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        ZenPill(
                          text: who,
                          tone: p.isMine ? tone : zen.textSecondary,
                          icon: Icons.person_rounded,
                        ),
                        ZenPill(
                          text: p.reach.label,
                          tone: zen.textSecondary,
                          icon: switch (p.reach) {
                            PlanReach.close => Icons.favorite_rounded,
                            PlanReach.friends => Icons.group_rounded,
                            PlanReach.friendsOfFriends =>
                              Icons.diversity_3_rounded,
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (p.isEvent)
            Row(
              children: <Widget>[
                Icon(Icons.celebration_rounded, color: tone, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t('Jest ekipa! Plan jest już wydarzeniem.'),
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            )
          else ...<Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t('Chętnych: {count} z {threshold}', {
                      'count': p.joinCount,
                      'threshold': p.threshold,
                    }),
                    style: TextStyle(
                      color: tone,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (maybe.isNotEmpty)
                  Text(
                    t('może: {count}', {'count': maybe.length}),
                    style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: context.zenRadius(99),
              child: LinearProgressIndicator(
                value: (p.joinCount / p.threshold).clamp(0.0, 1.0),
                minHeight: 8,
                color: tone,
                backgroundColor: tone.withValues(alpha: 0.15),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tn(
                p.threshold,
                one: 'Wydarzenie powstanie przy {n} chętnym.',
                few: 'Wydarzenie powstanie przy {n} chętnych.',
                many: 'Wydarzenie powstanie przy {n} chętnych.',
              ),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 12),
          if (joined.isEmpty && maybe.isEmpty)
            Text(
              p.isMine
                  ? t('Nikt jeszcze nie odpowiedział.')
                  : t('Nikt jeszcze nie odpowiedział — bądź pierwszy(-a)!'),
              style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final PlanAnswer a in joined)
                  _PersonChip(answer: a, isMe: a.address == me, tone: tone),
                for (final PlanAnswer a in maybe)
                  _PersonChip(answer: a, isMe: a.address == me, tone: tone),
              ],
            ),
          if (p.isCause) ...<Widget>[
            const SizedBox(height: 14),
            _NeedsList(
              plan: p,
              plans: plans,
              me: me,
              tone: tone,
              canClaim: !p.isMine && !p.isEvent && !over,
            ),
          ],
          const SizedBox(height: 12),
          if (eventId != null && events?.event(eventId) != null)
            OutlinedButton.icon(
              key: Key('plan-open-event-${p.id}'),
              onPressed: () => unawaited(EventScreen.open(context, eventId)),
              icon: const Icon(Icons.event_rounded),
              label: Text(t('Otwórz wydarzenie')),
            )
          else if (p.isEvent && !p.isMine)
            Text(
              t('Zaproszenie przyjdzie od organizatora.'),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
          if (!p.isMine && !p.isEvent && !over)
            _AnswerButtons(plan: p, plans: plans, tone: tone),
          if (p.isMine && !p.isEvent && !over)
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: <Widget>[
                if (p.answers.isNotEmpty)
                  TextButton.icon(
                    key: Key('plan-convert-${p.id}'),
                    onPressed: () => unawaited(_convert(context)),
                    icon: const Icon(Icons.celebration_rounded, size: 18),
                    label: Text(t('Zrób wydarzenie już teraz')),
                  ),
                TextButton.icon(
                  key: Key('plan-cancel-${p.id}'),
                  style: TextButton.styleFrom(foregroundColor: zen.danger),
                  onPressed: () => unawaited(_cancel(context)),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: Text(t('Odwołaj')),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// "Wspólna sprawa": what is needed, how much is taken, by whom, and a
/// "Biorę" button per line.
class _NeedsList extends StatelessWidget {
  const _NeedsList({
    required this.plan,
    required this.plans,
    required this.me,
    required this.tone,
    required this.canClaim,
  });

  final WeekendPlan plan;
  final PlanService plans;
  final String me;
  final Color tone;
  final bool canClaim;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      key: Key('plan-needs-${plan.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t('CZEGO POTRZEBA'), style: zen.label(color: zen.textMuted)),
        const SizedBox(height: 6),
        for (final PlanNeed n in plan.needs)
          Builder(
            builder: (BuildContext context) {
              final int taken = plan.claimed(n.key);
              final int mine =
                  plan.answers[me]?.claims[n.key] ??
                  plans.myClaims(plan.id)[n.key] ??
                  0;
              final List<String> who = <String>[
                for (final PlanAnswer a in plan.answers.values)
                  if ((a.claims[n.key] ?? 0) > 0)
                    a.address == me ? t('Ty') : a.name,
              ];
              final bool full = taken >= n.wanted;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Icon(
                      full
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      size: 20,
                      color: full ? zen.success : zen.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '${n.label} · $taken/${n.wanted}',
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (who.isNotEmpty)
                            Text(
                              who.join(', '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: zen.textSecondary,
                                fontSize: 12.5,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (canClaim && mine > 0)
                      TextButton(
                        key: Key('plan-unclaim-${plan.id}-${n.key}'),
                        onPressed: () =>
                            unawaited(plans.setClaim(plan.id, n.key, 0)),
                        child: Text(t('Rezygnuję')),
                      )
                    else if (canClaim && !full)
                      FilledButton.tonal(
                        key: Key('plan-claim-${plan.id}-${n.key}'),
                        onPressed: () =>
                            unawaited(plans.setClaim(plan.id, n.key, 1)),
                        child: Text(t('Biorę')),
                      ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

/// Someone who answered: their initial, name, and through whom.
class _PersonChip extends StatelessWidget {
  const _PersonChip({
    required this.answer,
    required this.isMe,
    required this.tone,
  });

  final PlanAnswer answer;
  final bool isMe;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool joined = answer.kind == PlanAnswerKind.join;
    final String name = isMe ? t('Ty') : answer.name;
    final String label = <String>[
      name,
      if (answer.via != null && answer.viaName.isNotEmpty)
        t('przez {name}', {'name': answer.viaName}),
      if (!joined) t('może'),
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
      decoration: BoxDecoration(
        color: joined ? tone.withValues(alpha: 0.14) : zen.surfaceRaised,
        borderRadius: context.zenRadius(999),
        border: Border.all(
          color: joined ? tone.withValues(alpha: 0.35) : zen.outlineSoft,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ZenBlobAvatar(name: answer.name, size: 24, showStatus: false),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: joined ? zen.textPrimary : zen.textSecondary,
                fontSize: 13,
                fontWeight: joined ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Dołączam" / "Może" for someone else's plan; the chosen one again takes
/// the answer back.
class _AnswerButtons extends StatelessWidget {
  const _AnswerButtons({
    required this.plan,
    required this.plans,
    required this.tone,
  });

  final WeekendPlan plan;
  final PlanService plans;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final PlanAnswerKind? mine = plans.myAnswer(plan.id);
    Widget choice(PlanAnswerKind kind, IconData icon) {
      final bool on = mine == kind;
      final Key buttonKey = Key('plan-${kind.name}-${plan.id}');
      final Widget label = Text(
        on && kind == PlanAnswerKind.join ? t('Dołączasz') : kind.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
      void tap() => unawaited(plans.answer(plan.id, on ? null : kind));
      if (on) {
        return FilledButton.icon(
          key: buttonKey,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            backgroundColor: tone,
            foregroundColor: ZenColors.foregroundFor(tone),
          ),
          onPressed: tap,
          icon: const Icon(Icons.check_rounded),
          label: label,
        );
      }
      return OutlinedButton.icon(
        key: buttonKey,
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: tap,
        icon: Icon(icon),
        label: label,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: choice(PlanAnswerKind.join, Icons.how_to_reg_rounded),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: choice(PlanAnswerKind.maybe, Icons.help_outline_rounded),
            ),
          ],
        ),
        if (mine != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            t('Stuknij jeszcze raz, żeby się wycofać.'),
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ZenColors.of(context).textMuted,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}

/// The days to pick from: the next week, from today.
List<DateTime> _nextDays(DateTime now) => <DateTime>[
  for (int i = 0; i < 7; i++) DateTime(now.year, now.month, now.day + i),
];

/// The coming Saturday (today on a Saturday morning), else Sunday, else
/// the next Saturday.
DateTime _defaultDay(DateTime now) {
  final DateTime today = DateTime(now.year, now.month, now.day);
  if (now.weekday < DateTime.saturday) {
    return DateTime(
      now.year,
      now.month,
      now.day + DateTime.saturday - now.weekday,
    );
  }
  if (now.hour < 9) {
    return today;
  }
  if (now.weekday == DateTime.saturday) {
    return DateTime(now.year, now.month, now.day + 1);
  }
  return DateTime(now.year, now.month, now.day + 6);
}

String _dayLabel(DateTime day, DateTime now) {
  final int days =
      (day.difference(DateTime(now.year, now.month, now.day)).inHours / 24)
          .round();
  if (days == 0) {
    return t('Dziś');
  }
  if (days == 1) {
    return t('Jutro');
  }
  if (days > 1 && days < 7) {
    // Weekdays short, the weekend in full (the usual days for plans).
    return day.weekday >= DateTime.saturday
        ? ZenFormat.weekdayLong(day, capitalized: true)
        : ZenFormat.weekdayShort(day, capitalized: true);
  }
  return ZenFormat.dayMonth(day, padDay: false);
}

/// Putting out a plan: what, when, where, who sees it, and from how many
/// people it becomes an event.
Future<void> showPlanSheet(BuildContext context, PlanService plans) {
  final TextEditingController title = TextEditingController();
  final TextEditingController place = TextEditingController();
  final TextEditingController needsText = TextEditingController();
  final DateTime now = DateTime.fromMillisecondsSinceEpoch(plans.now);
  DateTime day = _defaultDay(now);
  TimeOfDay time = const TimeOfDay(hour: 10, minute: 0);
  PlanReach reach = PlanReach.friends;
  int threshold = kPlanDefaultThreshold;
  bool cause = false;
  bool busy = false;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setSheet) {
        final ZenColors zen = ZenColors.of(context);
        final Color tone = planTone(zen);
        final List<DateTime> days = _nextDays(now);
        final DateTime at = DateTime(
          day.year,
          day.month,
          day.day,
          time.hour,
          time.minute,
        );
        final bool past = at.millisecondsSinceEpoch <= plans.now;
        final bool ready =
            title.text.trim().isNotEmpty &&
            !past &&
            !busy &&
            (!cause || parsePlanNeeds(needsText.text).isNotEmpty);
        Future<void> pickDay() async {
          final DateTime? d = await showDatePicker(
            context: context,
            initialDate: day,
            firstDate: DateTime(now.year, now.month, now.day),
            lastDate: DateTime(now.year, now.month, now.day + 59),
          );
          if (d != null && context.mounted) {
            setSheet(() => day = DateTime(d.year, d.month, d.day));
          }
        }

        Future<void> pickTime() async {
          final TimeOfDay? t = await showTimePicker(
            context: context,
            initialTime: time,
          );
          if (t != null && context.mounted) {
            setSheet(() => time = t);
          }
        }

        Future<void> create() async {
          setSheet(() => busy = true);
          await plans.create(
            title: title.text,
            startsAt: at.millisecondsSinceEpoch,
            place: place.text,
            reach: reach,
            threshold: threshold,
            needs: cause ? parsePlanNeeds(needsText.text) : const <PlanNeed>[],
          );
          if (context.mounted) {
            Navigator.of(context).pop();
          }
        }

        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ZenIconBadge(icon: Icons.wb_sunny_rounded, tone: tone),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('Nowy plan'),
                      style: zen.display(
                        color: zen.textPrimary,
                        size: 22,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('plan-title'),
                controller: title,
                autofocus: true,
                maxLength: kPlanMaxTitle,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setSheet(() {}),
                decoration: InputDecoration(
                  labelText: t('Co robimy?'),
                  hintText: t('np. Rower nad Wisłą'),
                  prefixIcon: const Icon(Icons.edit_rounded),
                ),
              ),
              ZenSection(t('Kiedy'), top: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final DateTime d in days)
                    ChoiceChip(
                      key: Key('plan-day-${d.weekday}'),
                      label: Text(_dayLabel(d, now)),
                      selected: d == day,
                      onSelected: (_) => setSheet(() => day = d),
                    ),
                  if (!days.contains(day))
                    ChoiceChip(
                      label: Text(_dayLabel(day, now)),
                      selected: true,
                      onSelected: (_) {},
                    ),
                  ActionChip(
                    key: const Key('plan-day-other'),
                    avatar: const Icon(Icons.edit_calendar_rounded, size: 18),
                    label: Text(t('Inny dzień')),
                    onPressed: () => unawaited(pickDay()),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('plan-time'),
                  onPressed: () => unawaited(pickTime()),
                  icon: const Icon(Icons.schedule_rounded),
                  label: Text(
                    t('Godzina {time}', {
                      'time': ZenFormat.time(
                        DateTime(2026, 1, 1, time.hour, time.minute),
                      ),
                    }),
                  ),
                ),
              ),
              if (past) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  t('Ta godzina już minęła — wybierz późniejszą.'),
                  style: TextStyle(color: zen.danger, fontSize: 13),
                ),
              ],
              const SizedBox(height: 14),
              TextField(
                key: const Key('plan-place'),
                controller: place,
                maxLength: kPlanMaxPlace,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('Gdzie (nie trzeba)'),
                  prefixIcon: const Icon(Icons.place_outlined),
                ),
              ),
              ZenSection(t('Kto zobaczy'), top: 4),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final PlanReach r in PlanReach.values)
                    ChoiceChip(
                      key: Key('plan-reach-${r.name}'),
                      label: Text(r.label),
                      selected: reach == r,
                      onSelected: (_) => setSheet(() => reach = r),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                switch (reach) {
                  PlanReach.close => t('Tylko przyjaciele.'),
                  PlanReach.friends => t('Wszyscy Twoi znajomi.'),
                  PlanReach.friendsOfFriends => t(
                    'Znajomi i ich znajomi. Każdy zobaczy, kto przez kogo '
                    'dołącza.',
                  ),
                },
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.35,
                ),
              ),
              SwitchListTile(
                key: const Key('plan-cause'),
                contentPadding: EdgeInsets.zero,
                value: cause,
                title: Text(t('Wspólna sprawa')),
                subtitle: Text(
                  t(
                    'Zbiórka sąsiedzka, sprzątanie, pomoc sąsiadowi: lista '
                    'tego, co potrzebne, a każdy mówi, co bierze. Bez pieniędzy.',
                  ),
                ),
                onChanged: (bool v) => setSheet(() => cause = v),
              ),
              if (cause)
                TextField(
                  key: const Key('plan-needs'),
                  controller: needsText,
                  minLines: 3,
                  maxLines: 8,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setSheet(() {}),
                  decoration: InputDecoration(
                    labelText: t('Czego potrzeba (każde w osobnej linii)'),
                    hintText: t('np. Grabie x4'),
                    prefixIcon: const Icon(Icons.checklist_rounded),
                  ),
                ),
              ZenSection(t('Ilu chętnych do wydarzenia')),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final int n in const <int>[2, 3, 4, 5, 6, 8])
                    ChoiceChip(
                      key: Key('plan-threshold-$n'),
                      label: Text('$n'),
                      selected: threshold == n,
                      onSelected: (_) => setSheet(() => threshold = n),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('plan-create'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  backgroundColor: tone,
                  foregroundColor: ZenColors.foregroundFor(tone),
                ),
                onPressed: ready ? () => unawaited(create()) : null,
                icon: const Icon(Icons.send_rounded),
                label: Text(t('Zapytaj, kto chętny')),
              ),
            ],
          ),
        );
      },
    ),
  ).whenComplete(
    () => disposeLater(<TextEditingController>[title, place, needsText]),
  );
}
