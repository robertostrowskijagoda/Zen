import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_decisions.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// What a verdict says, as a judge picks it: its kind, a text, an end.
typedef PyrVerdictDraft = ({String kind, String text, int? until});

/// Picks a verdict kind and its text (and an end in days, empty: for
/// good); null when the judge gives up.
Future<PyrVerdictDraft?> askVerdict(
  BuildContext context, {
  required String title,
  String kind = 'fraud',
  int now = 0,
}) async {
  String picked = kind;
  final TextEditingController text = TextEditingController();
  final TextEditingController days = TextEditingController();
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final String k in kPyrVerdictKinds)
                PyrOption(
                  key: Key('verdict-kind-$k'),
                  text: pyrVerdictLabel(k),
                  selected: picked == k,
                  onTap: () => set(() => picked = k),
                ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('verdict-text'),
                controller: text,
                minLines: 2,
                maxLines: 5,
                maxLength: kPyrCourtTextChars,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('Treść (widoczna w profilu tej osoby)'),
                ),
              ),
              TextField(
                key: const Key('verdict-days'),
                controller: days,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t('Ważny przez dni (puste: bez końca)'),
                  prefixIcon: const Icon(Icons.event_rounded),
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
            key: const Key('verdict-give'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Wydaj wyrok')),
          ),
        ],
      ),
    ),
  );
  final String body = text.text.trim();
  final int? d = int.tryParse(days.text.trim());
  disposeLater(<TextEditingController>[text, days]);
  if (ok != true || (picked == 'other' && body.isEmpty)) {
    return null;
  }
  return (
    kind: picked,
    text: body,
    until: d != null && d > 0 ? now + d * 24 * 3600 * 1000 : null,
  );
}

/// "Złóż skargę": a complaint against [accused] to the court of the
/// pyramid; first the head of their cell decides.
Future<void> showComplaintDialog(
  BuildContext context,
  PyramidService pyr,
  PyramidState s,
  String accused,
) async {
  final String? judge = pyr.firstJudgeOf(accused);
  if (judge == null) {
    snack(context, t('Nie ma kto rozpatrzyć tej skargi.'));
    return;
  }
  String kind = 'fraud';
  final TextEditingController text = TextEditingController();
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) => AlertDialog(
        title: Text(
          t('Skarga przeciw {name}', <String, Object?>{
            'name': s.members[accused]?.name ?? '?',
          }),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ZenInfo(
                icon: Icons.balance_rounded,
                text: t(
                  'Rozpatrzy: {judge}, w ciągu 3 dni. Wyrok to ostrzeżenie '
                  'dla innych, widoczne w profilu tej osoby. Skarga jest '
                  'jawna dla członków piramidy.',
                  <String, Object?>{'judge': pyrJudgeName(s, judge)},
                ),
              ),
              const SizedBox(height: 8),
              for (final String k in kPyrVerdictKinds)
                PyrOption(
                  key: Key('suit-kind-$k'),
                  text: pyrVerdictLabel(k),
                  selected: kind == k,
                  onTap: () => set(() => kind = k),
                ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('suit-text'),
                controller: text,
                minLines: 3,
                maxLines: 6,
                maxLength: kPyrCourtTextChars,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: t('Co się stało?')),
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
            key: const Key('suit-send'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Złóż skargę')),
          ),
        ],
      ),
    ),
  );
  final String body = text.text.trim();
  disposeLater(text);
  if (ok != true || body.isEmpty) {
    return;
  }
  final bool sent = await pyr.sue(accused, kind, body) != null;
  if (context.mounted) {
    snack(
      context,
      sent ? t('Skarga złożona.') : t('Nie udało się złożyć skargi.'),
    );
  }
}

/// What waits for this person's word as a judge: complaints against the
/// people of their cell (first instance) and appeals that came up to
/// their level, each with its end.
class CourtDuties extends StatelessWidget {
  const CourtDuties({required this.pyr, required this.s, super.key});

  final PyramidService pyr;
  final PyramidState s;

  String _name(String key) => s.members[key]?.name ?? '?';

  Future<void> _decide(BuildContext context, PyrCase c) async {
    final bool? guilty = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(
          t('Skarga {name} przeciw {other}', <String, Object?>{
            'name': _name(c.plaintiff),
            'other': _name(c.accused),
          }),
        ),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: SelectableText('${pyrVerdictLabel(c.kind)}\n${c.text}'),
          ),
          SimpleDialogOption(
            key: const Key('case-guilty'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Wydaj wyrok')),
          ),
          SimpleDialogOption(
            key: const Key('case-dismiss'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Oddal skargę')),
          ),
        ],
      ),
    );
    if (guilty == null || !context.mounted) {
      return;
    }
    if (guilty) {
      final PyrVerdictDraft? v = await askVerdict(
        context,
        title: t('Wyrok wobec {name}', <String, Object?>{
          'name': _name(c.accused),
        }),
        kind: c.kind,
        now: pyr.now,
      );
      if (v == null) {
        return;
      }
      await pyr.decideCase(
        c.id,
        guilty: true,
        kind: v.kind,
        text: v.text,
        until: v.until,
      );
    } else {
      final String? why = await askText(
        context,
        title: t('Dlaczego oddalasz skargę?'),
        maxLines: 3,
      );
      await pyr.decideCase(c.id, guilty: false, why: why ?? '');
    }
    if (context.mounted && c.judge.isEmpty) {
      snack(context, t('Potrzebny podpis drugiej osoby ze szczytu.'));
    }
  }

  Future<void> _answer(BuildContext context, PyrAppeal a) async {
    final PyrMatter m = s.matters[a.matter]!;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(
          t('Odwołanie {name}', <String, Object?>{'name': _name(a.by)}),
        ),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: SelectableText('${_matterText(m)}\n\n${a.why}'),
          ),
          SimpleDialogOption(
            key: const Key('appeal-accept'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(
              m.kind == PyrMatterKind.complaint
                  ? t('Przyjmij i wydaj wyrok')
                  : t('Przyjmij (uchyl decyzję)'),
            ),
          ),
          SimpleDialogOption(
            key: const Key('appeal-refuse'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Odrzuć')),
          ),
        ],
      ),
    );
    if (ok == null || !context.mounted) {
      return;
    }
    PyrVerdictDraft? v;
    if (ok && m.kind == PyrMatterKind.complaint) {
      final PyrCase? c = s.cases[m.id];
      v = await askVerdict(
        context,
        title: t('Wyrok wobec {name}', <String, Object?>{
          'name': _name(c?.accused ?? ''),
        }),
        kind: c?.kind ?? 'other',
        now: pyr.now,
      );
      if (v == null) {
        return;
      }
    }
    if (!context.mounted) {
      return;
    }
    final String? why = await askText(
      context,
      title: t('Uzasadnienie (jawne)'),
      maxLines: 3,
    );
    await pyr.answerAppeal(
      a.id,
      ok: ok,
      why: why ?? '',
      kind: v?.kind ?? 'other',
      text: v?.text ?? '',
      until: v?.until,
    );
    if (context.mounted && a.judge.isEmpty) {
      snack(context, t('Potrzebny podpis drugiej osoby ze szczytu.'));
    }
  }

  /// What [m] was, in a line.
  String _matterText(PyrMatter m) => switch (m.kind) {
    PyrMatterKind.ban =>
      t('Ban ({kind}) dla {name}: {reason}', <String, Object?>{
        'kind': banKindLabel(s.bans[m.id]?.kind ?? ''),
        'name': _name(m.party),
        'reason': s.bans[m.id]?.reason ?? '',
      }),
    PyrMatterKind.remove => t('Usunięcie {name} z piramidy', <String, Object?>{
      'name': _name(m.party),
    }),
    PyrMatterKind.verdict =>
      t('Wyrok wobec {name}: {kind} — {text}', <String, Object?>{
        'name': _name(m.party),
        'kind': pyrVerdictLabel(s.verdicts[m.id]?.kind ?? ''),
        'text': s.verdicts[m.id]?.text ?? '',
      }),
    PyrMatterKind.complaint =>
      t('Skarga {name} przeciw {other}: {text}', <String, Object?>{
        'name': _name(m.party),
        'other': _name(s.cases[m.id]?.accused ?? ''),
        'text': s.cases[m.id]?.text ?? '',
      }),
  };

  @override
  Widget build(BuildContext context) {
    final List<PyrCase> cases = pyr.casesToDecide();
    final List<PyrAppeal> appeals = pyr.appealsToAnswer();
    if (cases.isEmpty && appeals.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Column(
      key: const Key('court-duties'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenSection(t('Do rozpatrzenia')),
        for (final PyrCase c in cases)
          ZenCard(
            key: Key('case-${c.id}'),
            tone: zen.warning,
            onTap: () => unawaited(_decide(context, c)),
            child: _row(
              zen,
              Icons.balance_rounded,
              t('Skarga przeciw {name}', <String, Object?>{
                'name': _name(c.accused),
              }),
              t(
                '{kind} · od {plaintiff} · decyzja do {date}',
                <String, Object?>{
                  'kind': pyrVerdictLabel(c.kind),
                  'plaintiff': _name(c.plaintiff),
                  'date': pyrDate(c.deadline),
                },
              ),
            ),
          ),
        for (final PyrAppeal a in appeals)
          ZenCard(
            key: Key('appeal-${a.id}'),
            tone: zen.warning,
            onTap: () => unawaited(_answer(context, a)),
            child: _row(
              zen,
              Icons.replay_rounded,
              t('Odwołanie {name}', <String, Object?>{'name': _name(a.by)}),
              t('{what} · odpowiedź do {date}', <String, Object?>{
                'what': _matterText(s.matters[a.matter]!),
                'date': pyrDate(a.deadline),
              }),
            ),
          ),
      ],
    );
  }

  Widget _row(ZenColors zen, IconData icon, String title, String subtitle) =>
      Row(
        children: <Widget>[
          ZenIconBadge(icon: icon, tone: zen.warning, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: zen.textMuted),
        ],
      );
}

/// The verdicts of the pyramid's court about whoever uses [address] (null:
/// this person), as their profile shows them — to members and to anybody
/// a member friend passed them on to. Nothing when there are none.
class PyrVerdictList extends StatelessWidget {
  const PyrVerdictList({required this.pyr, this.address, super.key});

  final PyramidService pyr;
  final String? address;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: pyr,
    builder: (BuildContext context, Widget? _) {
      final List<PyrVerdictView> list = pyr.verdictsAt(address);
      if (list.isEmpty) {
        return const SizedBox.shrink();
      }
      final ZenColors zen = ZenColors.of(context);
      return ZenCard(
        key: const Key('pyr-verdicts'),
        tone: zen.danger,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                ZenIconBadge(
                  key: const Key('pyr-verdict-badge'),
                  icon: Icons.gavel_rounded,
                  tone: zen.danger,
                  size: 34,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tn(
                      list.length,
                      one: 'Wyrok sądu piramidy',
                      few: '{n} wyroki sądu piramidy',
                      many: '{n} wyroków sądu piramidy',
                    ),
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            for (final PyrVerdictView v in list) ...<Widget>[
              const SizedBox(height: 10),
              ZenPill(
                text: pyrVerdictLabel(v.kind),
                tone: zen.danger,
                icon: Icons.warning_amber_rounded,
              ),
              if (v.text.isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                SelectableText(
                  v.text,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 14,
                    height: 1.35,
                  ),
                ),
              ],
              const SizedBox(height: 2),
              Text(
                <String>[
                  if (v.name.isNotEmpty)
                    t('w piramidzie: {name}', <String, Object?>{
                      'name': v.name,
                    }),
                  pyrDate(v.at),
                  if (v.until != null)
                    t('do {date}', <String, Object?>{
                      'date': pyrDate(v.until!),
                    }),
                ].join(' · '),
                style: TextStyle(color: zen.textMuted, fontSize: 12),
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// [PyrVerdictList] for the profile screens: the pyramid of this app.
class PyrProfileVerdicts extends ConsumerWidget {
  const PyrProfileVerdicts({this.address, super.key});

  /// The profile's address; null: this person's own profile.
  final String? address;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The pyramid runs with the app; a profile never starts it.
    if (!ref.exists(pyramidServiceProvider)) {
      return const SizedBox.shrink();
    }
    return PyrVerdictList(
      pyr: ref.read(pyramidServiceProvider),
      address: address,
    );
  }
}
