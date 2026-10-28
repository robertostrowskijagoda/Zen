import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/meet/graph/graph_insights.dart';
import 'package:zen/src/features/meet/graph/graph_model.dart';
import 'package:zen/src/features/meet/graph/graph_notes.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/graph/graph_snapshot.dart';
import 'package:zen/src/features/meet/graph/trust_map.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// The parts of "Graf" around the picture: the timeline's controls, whom it
// may be worth meeting, bridges and lone circles, friends not seen for a
// long time, private names of circles, the trust map on a person's card and
// the picture of the graph without personal data.

const int _dayMs = 24 * 3600 * 1000;

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// A day as people read it.
String graphDate(int ms) =>
    ZenFormat.date(DateTime.fromMillisecondsSinceEpoch(ms));

/// "2 tyg. temu", "5 mies. temu", for a long time ago.
String longAgo(int ms, int now) {
  final int days = ((now - ms) / _dayMs).floor();
  if (days < 14) {
    return tn(
      days < 1 ? 1 : days,
      one: '{n} dzień temu',
      few: '{n} dni temu',
      many: '{n} dni temu',
    );
  }
  if (days < 60) {
    return t('{n} tyg. temu', {'n': days ~/ 7});
  }
  return t('{n} mies. temu', {'n': days ~/ 30});
}

/// A section title with a short line under it.
class _Head extends StatelessWidget {
  const _Head(this.title, this.text, {this.icon});

  final String title;
  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 20, color: zen.accent),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  text,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- "Oś czasu" ----

/// How fast the timeline can play (times its normal pace).
const List<int> kGraphTimeSpeeds = <int>[1, 2, 4];

/// The whole story plays in this long at the normal pace.
const Duration kGraphTimePlay = Duration(seconds: 12);

/// With the animations off, the timeline steps from one event to the next
/// this often at the normal pace.
const Duration kGraphTimeStep = Duration(milliseconds: 900);

/// The timeline's controls, in every mode: play and pause, a slider to any
/// day (the date and what the graph had then under it), the speed, and
/// closing it (outside "Oś czasu").
class GraphTimeBar extends StatelessWidget {
  const GraphTimeBar({
    required this.clock,
    required this.timeline,
    required this.nodes,
    required this.baseline,
    required this.playing,
    required this.onPlay,
    required this.onScrub,
    required this.speed,
    required this.onSpeed,
    this.onClose,
    super.key,
  });

  /// Where on the [timeline] the picture is (0…1).
  final Animation<double> clock;
  final GraphTimeline? timeline;
  final List<GraphNode> nodes;

  /// Since when dates are kept on this phone (0: not yet).
  final int baseline;

  final bool playing;

  /// Plays from where the slider is (from the start when at the end), or
  /// pauses.
  final VoidCallback onPlay;

  /// The slider was moved to this point of the span.
  final ValueChanged<double> onScrub;

  /// One of [kGraphTimeSpeeds].
  final int speed;

  /// The next speed.
  final VoidCallback onSpeed;

  /// Hides the timeline (null: it belongs to the mode).
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final GraphTimeline? tl = timeline;
    return Padding(
      key: const Key('graph-time-bar'),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              IconButton.filledTonal(
                key: const Key('graph-time-play'),
                tooltip: playing ? t('Pauza') : t('Pokaż, jak rósł graf'),
                onPressed: tl == null ? null : onPlay,
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                ),
              ),
              Expanded(
                child: AnimatedBuilder(
                  animation: clock,
                  builder: (BuildContext context, Widget? _) => Slider(
                    key: const Key('graph-time-slider'),
                    value: clock.value.clamp(0.0, 1.0),
                    semanticFormatterCallback: (double v) =>
                        tl == null ? '' : graphDate(tl.timeAt(v)),
                    onChanged: tl == null ? null : onScrub,
                  ),
                ),
              ),
              TextButton(
                key: const Key('graph-time-speed'),
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onPressed: onSpeed,
                child: Text(
                  t('{n}×', {'n': speed}),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (onClose != null)
                IconButton(
                  key: const Key('graph-time-close'),
                  tooltip: t('Zamknij'),
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
            ],
          ),
          AnimatedBuilder(
            animation: clock,
            builder: (BuildContext context, Widget? _) {
              if (tl == null) {
                return const SizedBox.shrink();
              }
              final double phase = clock.value;
              final ({int people, int met}) c = tl.countAt(phase, nodes);
              return Text(
                t(
                  'Stan na {date}: znajomi {people}, spotkani osobiście {met}',
                  {
                    'date': graphDate(tl.timeAt(phase)),
                    'people': c.people,
                    'met': c.met,
                  },
                ),
                key: const Key('graph-time-state'),
                style: TextStyle(color: zen.textSecondary, fontSize: 13),
              );
            },
          ),
          if (baseline > 0 && tl != null && baseline > tl.from)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                t(
                  'Daty zapisuje ten telefon od {date} (wcześniejsze — z '
                  'rozmów i spotkań, jeśli są).',
                  {'date': graphDate(baseline)},
                ),
                style: TextStyle(color: zen.textMuted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}

// ---- "Kogo warto poznać" ----

/// Friends of friends it may be worth meeting, each with one tap to ask
/// for an introduction (and one to send a friend request).
class MeetSuggestionsSection extends StatelessWidget {
  const MeetSuggestionsSection({
    required this.items,
    required this.nameOf,
    required this.onAsk,
    required this.onAdd,
    required this.onOpen,
    super.key,
  });

  final List<MeetSuggestion> items;
  final String Function(String address) nameOf;
  final void Function(MeetSuggestion s) onAsk;
  final void Function(MeetSuggestion s) onAdd;
  final void Function(MeetSuggestion s) onOpen;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      key: const Key('graph-who-to-meet'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Head(
            t('Kogo warto poznać'),
            t(
              'Znajomi znajomych z wieloma wspólnymi znajomymi albo z tym '
              'samym statusem czy zamiarem co Ty.',
            ),
            icon: Icons.diversity_3_rounded,
          ),
          for (final MeetSuggestion s in items)
            ZenCard(
              key: Key('graph-meet-${s.node.address}'),
              onTap: () => onOpen(s),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      CircleAvatar(
                        backgroundColor: zen.accent.withValues(alpha: 0.16),
                        foregroundColor: zen.accent,
                        child: Text(initialsOf(s.node.name)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              s.node.name,
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              <String>[
                                tn(
                                  s.mutual,
                                  one: '{n} wspólny znajomy',
                                  few: '{n} wspólnych znajomych',
                                  many: '{n} wspólnych znajomych',
                                ),
                                if (s.match) t('pasuje do Ciebie'),
                              ].join(' · '),
                              style: TextStyle(
                                color: zen.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              t('Przez: {names}', {
                                'names': s.node.via.map(nameOf).join(', '),
                              }),
                              style: TextStyle(
                                color: zen.textMuted,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      OutlinedButton.icon(
                        key: Key('graph-meet-add-${s.node.address}'),
                        onPressed: () => onAdd(s),
                        icon: const Icon(Icons.person_add_alt_rounded),
                        label: Text(t('Dodaj do znajomych')),
                      ),
                      FilledButton.tonalIcon(
                        key: Key('graph-meet-ask-${s.node.address}'),
                        onPressed: () => onAsk(s),
                        icon: const Icon(Icons.waving_hand_rounded),
                        label: Text(t('Poproś o przedstawienie')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---- "Mosty i samotne wyspy" ----

/// Who alone connects the circles, the circles standing alone, and whom
/// it may be worth introducing to each other.
class BridgesSection extends StatelessWidget {
  const BridgesSection({
    required this.report,
    required this.nameOf,
    required this.circleName,
    required this.onIntroduce,
    super.key,
  });

  final BridgeReport report;
  final String Function(String address) nameOf;
  final String Function(int cluster) circleName;
  final void Function(String a, String b) onIntroduce;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<String> bridges = report.bridges.map(nameOf).toList()..sort();
    final List<String> islands = <String>[
      for (final int c in report.islands.toList()..sort()) circleName(c),
    ];
    return Padding(
      key: const Key('graph-bridges'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (report.isEmpty)
            ZenInfo(
              icon: Icons.device_hub_rounded,
              tone: zen.textSecondary,
              text: t(
                'Nie widać jeszcze grup znajomych do połączenia. Pojawią się, gdy '
                'znajomi pokażą Ci swoje listy znajomych.',
              ),
            ),
          if (bridges.isNotEmpty)
            ZenInfo(
              key: const Key('graph-bridges-list'),
              icon: Icons.device_hub_rounded,
              tone: zen.accent,
              title: t('Mosty'),
              text: t(
                'Tylko przez te osoby łączą się Twoje grupy znajomych: {names}.',
                {'names': bridges.join(', ')},
              ),
            ),
          if (islands.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            ZenInfo(
              key: const Key('graph-islands-list'),
              icon: Icons.landscape_rounded,
              tone: zenTone(zen, 5),
              title: t('Samotne wyspy'),
              text: t('Grupy znajomych bez połączeń z innymi: {names}.', {
                'names': islands.join(', '),
              }),
            ),
          ],
          for (final (String a, String b) in report.hints)
            ZenCard(
              key: Key('graph-hint-$a-$b'),
              child: Row(
                children: <Widget>[
                  Icon(Icons.handshake_rounded, color: zen.accent),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t('Przedstawić sobie: {a} i {b}?', {
                        'a': nameOf(a),
                        'b': nameOf(b),
                      }),
                      style: TextStyle(color: zen.textPrimary, fontSize: 14.5),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: Key('graph-hint-go-$a-$b'),
                    onPressed: () => onIntroduce(a, b),
                    child: Text(t('Przedstaw')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// "Przedstaw": one message to each of two friends; the words can be
/// changed. Whether it went.
Future<bool> introduceFriends(
  BuildContext context,
  WidgetRef ref, {
  required String a,
  required String b,
  required String nameA,
  required String nameB,
}) async {
  final TextEditingController text = TextEditingController(
    text: t(
      'Hej! Chcę Was sobie przedstawić: {a} i {b}. Myślę, że warto się '
      'poznać.',
      {'a': nameA, 'b': nameB},
    ),
  );
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      key: const Key('graph-introduce-dialog'),
      title: Text(t('Przedstaw: {a} i {b}', {'a': nameA, 'b': nameB})),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            TextField(
              key: const Key('graph-introduce-text'),
              controller: text,
              minLines: 3,
              maxLines: 6,
              maxLength: 1000,
              textCapitalization: TextCapitalization.sentences,
            ),
            ZenInfo(
              icon: Icons.lock_outline_rounded,
              text: t(
                'Zwykła wiadomość do każdego z nich. Nikt poza Wami jej nie '
                'zobaczy.',
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('graph-introduce-send'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t('Wyślij obojgu')),
        ),
      ],
    ),
  );
  final String message = text.text.trim();
  disposeLater(text);
  if (ok != true || message.isEmpty) {
    return false;
  }
  final SocialHubController social = ref.read(
    socialHubControllerProvider.notifier,
  );
  final SocialHubState people = ref.read(socialHubControllerProvider);
  try {
    for (final String to in <String>[a, b]) {
      await social.sendLocalMessage(
        peerAddress: people.friendByAddress(to)?.address ?? to,
        text: message,
      );
    }
  } on Object {
    if (context.mounted) {
      _snack(context, t('Nie udało się wysłać.'));
    }
    return false;
  }
  if (context.mounted) {
    _snack(context, t('Wysłano do: {a} i {b}.', {'a': nameA, 'b': nameB}));
  }
  return true;
}

// ---- "Dawno się nie widzieliście" ----

/// Friends not talked to or met for a long time, with a gentle nudge:
/// write, or later. Only this person sees it; nothing is counted anywhere.
class NeglectSection extends StatelessWidget {
  const NeglectSection({
    required this.items,
    required this.weeks,
    required this.onWeeks,
    required this.now,
    required this.onWrite,
    required this.onLater,
    super.key,
  });

  final List<NeglectedFriend> items;
  final int weeks;
  final ValueChanged<int> onWeeks;
  final int now;
  final void Function(GraphNode n) onWrite;
  final void Function(GraphNode n) onLater;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      key: const Key('graph-neglect'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _Head(
            t('Dawno się nie widzieliście'),
            t(
              'Ostatnia rozmowa albo spotkanie dawniej niż wybrany czas. '
              'Widzisz to tylko Ty.',
            ),
            icon: Icons.hourglass_bottom_rounded,
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final int w in kNeglectWeekChoices)
                ChoiceChip(
                  key: Key('graph-neglect-weeks-$w'),
                  showCheckmark: false,
                  label: Text(t('ponad {n} tyg.', {'n': w})),
                  selected: weeks == w,
                  onSelected: (_) => onWeeks(w),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (items.isEmpty)
            ZenInfo(
              icon: Icons.favorite_border_rounded,
              tone: zen.success,
              text: t('Z nikim nie było tak długiej przerwy. Pięknie!'),
            ),
          for (final NeglectedFriend f in items.take(12))
            ZenCard(
              key: Key('graph-neglect-${f.node.address}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    f.node.name,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    f.last > 0
                        ? t('Ostatnio: {ago}. Może napiszesz?', {
                            'ago': longAgo(f.last, now),
                          })
                        : t('Jeszcze nie rozmawialiście. Może napiszesz?'),
                    style: TextStyle(color: zen.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      TextButton(
                        key: Key('graph-neglect-later-${f.node.address}'),
                        onPressed: () => onLater(f.node),
                        child: Text(t('Przypomnij później')),
                      ),
                      FilledButton.tonalIcon(
                        key: Key('graph-neglect-write-${f.node.address}'),
                        onPressed: () => onWrite(f.node),
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                        label: Text(t('Napisz')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---- private names of circles ----

/// A circle on the graph, as the list of circles shows it.
typedef GraphCircle = ({
  int id,
  String name,
  CircleLabel? label,
  Set<String> members,
});

/// "Twoje kręgi": the circles found on the graph, each with its automatic
/// name or the one this person gave it (only they see it).
class CirclesSection extends StatelessWidget {
  const CirclesSection({
    required this.circles,
    required this.onRename,
    super.key,
  });

  final List<GraphCircle> circles;
  final void Function(GraphCircle c) onRename;

  @override
  Widget build(BuildContext context) {
    if (circles.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: ZenGroup(
        children: <Widget>[
          ExpansionTile(
            key: const Key('graph-circles'),
            leading: Icon(Icons.bubble_chart_rounded, color: zen.accent),
            title: Text(t('Twoje grupy znajomych')),
            subtitle: Text(
              t('Nadaj grupom własne nazwy — widzisz je tylko Ty.'),
            ),
            children: <Widget>[
              for (final GraphCircle c in circles)
                ListTile(
                  key: Key('graph-circle-${c.id}'),
                  leading: Icon(
                    Icons.circle,
                    size: 16,
                    color: zenTone(zen, c.id % 6),
                  ),
                  title: Text(c.label?.name ?? c.name),
                  subtitle: Text(
                    <String>[
                      tn(
                        c.members.length,
                        one: '{n} osoba',
                        few: '{n} osoby',
                        many: '{n} osób',
                      ),
                      if (c.label != null) t('nazwa tylko dla Ciebie'),
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => onRename(c),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks for a private name of a circle: the new name, '' to go back to
/// the automatic one, null when cancelled.
Future<String?> askCircleName(
  BuildContext context, {
  required String current,
  required bool named,
}) async {
  final TextEditingController text = TextEditingController(
    text: named ? current : '',
  );
  final String? out = await showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      scrollable: true,
      key: const Key('graph-circle-dialog'),
      title: Text(t('Nazwa grupy znajomych')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            key: const Key('graph-circle-name'),
            controller: text,
            autofocus: true,
            maxLength: kCircleLabelMaxChars,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: t('Twoja nazwa'),
              hintText: t('np. Wspinaczka, Studia'),
            ),
          ),
          ZenInfo(
            icon: Icons.lock_outline_rounded,
            text: t('Tylko Ty widzisz tę nazwę. Nie wychodzi z telefonu.'),
          ),
        ],
      ),
      actions: <Widget>[
        if (named)
          TextButton(
            key: const Key('graph-circle-clear'),
            onPressed: () => Navigator.of(context).pop(''),
            child: Text(t('Nazwa automatyczna')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('graph-circle-save'),
          onPressed: () => Navigator.of(context).pop(text.text),
          child: Text(t('Zapisz')),
        ),
      ],
    ),
  );
  disposeLater(text);
  return out;
}

// ---- "Mapa zaufania" ----

/// The trust map on a person's card: facts, one line each, no scores.
class TrustMapView extends StatelessWidget {
  const TrustMapView({required this.map, super.key});

  final TrustMap map;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<(IconData, String)> rows = <(IconData, String)>[
      if (map.metByMe != null)
        (
          Icons.verified_rounded,
          t('Spotkaliście się osobiście ({date})', {
            'date': graphDate(map.metByMe!),
          }),
        ),
      if (map.friendsWhoMet.isNotEmpty)
        (
          Icons.people_alt_rounded,
          t('Spotkali osobiście: {names}', {
            'names': map.friendsWhoMet.join(', '),
          }),
        ),
      if (map.thanks > 0)
        (
          Icons.volunteer_activism_rounded,
          tn(
            map.thanks,
            one: '{n} kartka wdzięczności · od: {names}',
            few: '{n} kartki wdzięczności · od: {names}',
            many: '{n} kartek wdzięczności · od: {names}',
            args: {'names': map.thanksFrom.join(', ')},
          ),
        ),
      if (map.pyramidSince != null)
        (
          Icons.change_history_rounded,
          t('W piramidzie od: {date}', {'date': graphDate(map.pyramidSince!)}),
        ),
      if (map.sharedEvents.isNotEmpty)
        (
          Icons.celebration_rounded,
          tn(
            map.sharedEvents.length,
            one: 'Wspólne wydarzenie: {names}',
            few: 'Wspólne wydarzenia ({n}): {names}',
            many: 'Wspólne wydarzenia ({n}): {names}',
            args: {
              'names': map.sharedEvents
                  .take(3)
                  .map((SharedEvent e) => e.title)
                  .join(', '),
            },
          ),
        ),
    ];
    return Container(
      key: const Key('graph-trust-map'),
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: zen.surfaceRaised,
        borderRadius: context.zenRadius(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t('Mapa zaufania'), style: zen.label(color: zen.textSecondary)),
          const SizedBox(height: 6),
          if (rows.isEmpty)
            Text(
              t(
                'Jeszcze nic: bez wspólnych spotkań, kartek wdzięczności '
                'i wydarzeń, które widzi ten telefon.',
              ),
              style: TextStyle(color: zen.textMuted, fontSize: 13),
            ),
          for (final (IconData icon, String text) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(icon, size: 18, color: zen.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      text,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 13.5,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---- "Zrzut grafu bez danych osobowych" ----

/// The picture of [scene] without personal data, to look at, save or send
/// to a friend as a photo.
Future<void> showGraphSnapshot(
  BuildContext context,
  WidgetRef ref, {
  required GraphScene scene,
  required Map<String, int> clusters,
}) async {
  final ZenColors zen = ZenColors.of(context);
  final Uint8List? png = await graphSnapshotPng(scene, clusters, zen);
  if (!context.mounted) {
    return;
  }
  if (png == null) {
    _snack(context, t('Nie udało się zrobić obrazka.'));
    return;
  }
  final String name =
      'graf-${DateTime.now().toIso8601String().substring(0, 10)}.png';
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheet) {
      final ZenColors zen = ZenColors.of(sheet);
      return SingleChildScrollView(
        key: const Key('graph-snapshot-sheet'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t('Zrzut grafu'),
              style: zen.display(
                color: zen.textPrimary,
                size: 20,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              t(
                'Tylko inicjały i kolory grup znajomych — bez imion, nazwisk i '
                'adresów.',
              ),
              style: TextStyle(color: zen.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: sheet.zenRadius(18),
              child: AspectRatio(
                aspectRatio: 1,
                child: Image.memory(png, fit: BoxFit.contain),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const Key('graph-snapshot-send'),
                  onPressed: () => unawaited(
                    _sendSnapshot(sheet, ref, png: png, name: name),
                  ),
                  icon: const Icon(Icons.send_rounded),
                  label: Text(t('Wyślij znajomemu')),
                ),
                FilledButton.icon(
                  key: const Key('graph-snapshot-save'),
                  onPressed: () => unawaited(() async {
                    final String? path = await ref
                        .read(graphImageSaverProvider)
                        .save(name, png);
                    if (sheet.mounted && path != null) {
                      _snack(sheet, t('Zapisano: {path}', {'path': path}));
                    }
                  }()),
                  icon: const Icon(Icons.download_rounded),
                  label: Text(t('Zapisz')),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}

Future<void> _sendSnapshot(
  BuildContext context,
  WidgetRef ref, {
  required Uint8List png,
  required String name,
}) async {
  final SocialHubState people = ref.read(socialHubControllerProvider);
  final List<FriendProfile> friends = people.acceptedFriends.toList()
    ..sort(
      (FriendProfile a, FriendProfile b) =>
          people.nameFor(a).compareTo(people.nameFor(b)),
    );
  final FriendProfile? to = await showDialog<FriendProfile>(
    context: context,
    builder: (BuildContext context) => SimpleDialog(
      key: const Key('graph-snapshot-pick'),
      title: Text(t('Komu wysłać?')),
      children: <Widget>[
        if (friends.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(t('Nie masz jeszcze znajomych.')),
          ),
        for (final FriendProfile f in friends)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(f),
            child: Text(people.nameFor(f)),
          ),
      ],
    ),
  );
  if (to == null) {
    return;
  }
  try {
    await ref
        .read(socialHubControllerProvider.notifier)
        .sendLocalAttachment(
          peerAddress: to.address,
          bytes: png,
          fileName: name,
          mimeType: 'image/png',
          type: ChatMessageType.image,
        );
  } on Object {
    if (context.mounted) {
      _snack(context, t('Nie udało się wysłać.'));
    }
    return;
  }
  if (context.mounted) {
    _snack(context, t('Wysłano do: {name}.', {'name': people.nameFor(to)}));
  }
}
