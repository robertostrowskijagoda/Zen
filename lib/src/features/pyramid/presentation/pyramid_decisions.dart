import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// Longest reason typed in an appeal here (the record takes as much).
const int kAppealReasonChars = kPyrCourtTextChars;

/// A name for a kind of ban, as the person under it reads it.
String banKindLabel(String kind) => switch (kind) {
  'perm' => t('Ban stały'),
  'pause' => t('Przerwa'),
  'content' => t('Ban treści'),
  'noadmit' => t('Zakaz przyjmowania do piramidy'),
  'dating' => t('Wyłączony profil randkowy'),
  _ => kind,
};

/// Who judges at [path] ('' = the top cell), in words.
String pyrJudgeName(PyramidState s, String path) => path.isEmpty
    ? t('szczyt (2 z 3)')
    : t('{name} (poziom {level})', <String, Object?>{
        'name': s.members[s.occupant[path]]?.name ?? '?',
        'level': path.length + 1,
      });

/// The decisions about [me] worth showing: bans in force or appealed, a
/// removal, verdicts in force or appealed, and their own complaints.
List<PyrMatter> mattersShown(PyramidService pyr, PyramidState s) {
  final int now = pyr.now;
  return <PyrMatter>[
    for (final PyrMatter m in pyr.myMatters())
      if (switch (m.kind) {
        PyrMatterKind.ban =>
          (s.bans[m.id]?.activeAt(now) ?? false) || m.appeals.isNotEmpty,
        PyrMatterKind.verdict =>
          (s.verdicts[m.id]?.activeAt(now) ?? false) || m.appeals.isNotEmpty,
        PyrMatterKind.remove || PyrMatterKind.complaint => true,
      })
        m,
  ];
}

/// "Decyzje wobec Ciebie": bans, a removal, verdicts of the court and this
/// person's own complaints, each with the way of its appeals — one level
/// up each time, twice as long each time, up to the top — and
/// "Odwołaj się" while a level is left.
class DecisionsAgainstMe extends StatelessWidget {
  const DecisionsAgainstMe({
    required this.pyr,
    required this.s,
    required this.me,
    super.key,
  });

  final PyramidService pyr;
  final PyramidState s;
  final String me;

  Future<void> _appeal(BuildContext context, PyrMatter m) async {
    final String? next = s.nextJudge(m);
    if (next == null) {
      return;
    }
    final String? reason = await askAppealReason(
      context,
      to: pyrJudgeName(s, next),
    );
    if (reason == null) {
      return;
    }
    final bool sent = await pyr.appealDecision(m.id, reason) != null;
    if (context.mounted) {
      snack(
        context,
        sent ? t('Odwołanie złożone.') : t('Nie udało się złożyć odwołania.'),
      );
    }
  }

  (String, String, IconData) _what(PyrMatter m) {
    switch (m.kind) {
      case PyrMatterKind.ban:
        final PyrBan? b = s.bans[m.id];
        return (
          banKindLabel(b?.kind ?? ''),
          <String>[
            pyrDate(m.at),
            if (b != null && b.reason.isNotEmpty) b.reason,
            if (b?.until != null)
              t('do {date}', <String, Object?>{'date': pyrDate(b!.until!)}),
          ].join(' · '),
          Icons.block_rounded,
        );
      case PyrMatterKind.remove:
        return (
          t('Usunięcie z piramidy'),
          pyrDate(m.at),
          Icons.person_remove_rounded,
        );
      case PyrMatterKind.verdict:
        final PyrVerdict? v = s.verdicts[m.id];
        return (
          t('Wyrok: {kind}', <String, Object?>{
            'kind': pyrVerdictLabel(v?.kind ?? ''),
          }),
          <String>[
            pyrDate(m.at),
            if (v != null && v.text.isNotEmpty) v.text,
            if (v?.until != null)
              t('do {date}', <String, Object?>{'date': pyrDate(v!.until!)}),
          ].join(' · '),
          Icons.gavel_rounded,
        );
      case PyrMatterKind.complaint:
        final PyrCase? c = s.cases[m.id];
        return (
          t('Twoja skarga przeciw {name}', <String, Object?>{
            'name': s.members[c?.accused]?.name ?? '?',
          }),
          <String>[
            pyrDate(m.at),
            pyrVerdictLabel(c?.kind ?? ''),
            switch (c?.status) {
              PyrCaseStatus.guilty => t('wyrok zapadł'),
              PyrCaseStatus.dismissed => t('oddalona'),
              _ when c != null && c.expiredAt(pyr.now) => t(
                'bez decyzji w terminie',
              ),
              _ => t('czeka na decyzję do {date}', <String, Object?>{
                'date': pyrDate(c?.deadline ?? 0),
              }),
            },
          ].join(' · '),
          Icons.balance_rounded,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<PyrMatter> shown = mattersShown(pyr, s);
    if (shown.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Column(
      key: const Key('decisions-against-me'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenSection(t('Decyzje wobec Ciebie')),
        for (final PyrMatter m in shown) _card(context, zen, m),
      ],
    );
  }

  Widget _card(BuildContext context, ZenColors zen, PyrMatter m) {
    final (String title, String subtitle, IconData icon) = _what(m);
    final Color tone = m.overturned
        ? zen.success
        : m.kind == PyrMatterKind.complaint
        ? zen.warning
        : zen.danger;
    return ZenCard(
      key: Key('decision-${m.id}'),
      tone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ZenIconBadge(
                icon: m.overturned ? Icons.check_circle_outline_rounded : icon,
                tone: tone,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SelectableText(
                      subtitle,
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 12.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final String id in m.appeals)
            if (s.appeals[id] case final PyrAppeal a) _appealRow(zen, a),
          _status(context, zen, m),
        ],
      ),
    );
  }

  /// One step of the way up: where it went and how it ended.
  Widget _appealRow(ZenColors zen, PyrAppeal a) {
    final int now = pyr.now;
    final (String text, Color tone, IconData icon) = switch (a.ok) {
      true => (
        t('Przyjęte przez: {judge}', <String, Object?>{
          'judge': pyrJudgeName(s, a.judge),
        }),
        zen.success,
        Icons.check_rounded,
      ),
      false => (
        t('Odrzucone przez: {judge}', <String, Object?>{
          'judge': pyrJudgeName(s, a.judge),
        }),
        zen.danger,
        Icons.close_rounded,
      ),
      null when a.expiredAt(now) => (
        t('Bez odpowiedzi w terminie: {judge}', <String, Object?>{
          'judge': pyrJudgeName(s, a.judge),
        }),
        zen.textMuted,
        Icons.timer_off_outlined,
      ),
      null => (
        t('Czeka: {judge}, do {date}', <String, Object?>{
          'judge': pyrJudgeName(s, a.judge),
          'date': pyrDate(a.deadline),
        }),
        zen.warning,
        Icons.hourglass_top_rounded,
      ),
    };
    return Padding(
      key: Key('appeal-step-${a.id}'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 17, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: SelectableText(
              a.answerWhy.isEmpty ? text : '$text\n${a.answerWhy}',
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 13,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// "Odwołaj się" (to where it goes), or why not.
  Widget _status(BuildContext context, ZenColors zen, PyrMatter m) {
    if (m.overturned) {
      return Text(
        t('Decyzja uchylona.'),
        key: Key('decision-overturned-${m.id}'),
        style: TextStyle(
          color: zen.success,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    final int now = pyr.now;
    final String? problem = s.appealProblem(m, me, now);
    final String? next = s.nextJudge(m);
    if (problem == null && next != null) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: OutlinedButton.icon(
          key: Key('decision-appeal-${m.id}'),
          onPressed: () => unawaited(_appeal(context, m)),
          icon: const Icon(Icons.replay_rounded, size: 18),
          label: Text(
            m.appeals.isEmpty ? t('Odwołaj się') : t('Odwołaj się wyżej'),
          ),
        ),
      );
    }
    final PyrAppeal? last = s.lastAppeal(m);
    if (next == null && last != null && last.ok == false) {
      return Text(
        t('Decyzja ostateczna.'),
        key: Key('decision-final-${m.id}'),
        style: TextStyle(color: zen.textMuted, fontSize: 13),
      );
    }
    return const SizedBox.shrink();
  }
}

/// Asks for the reason of an appeal going to [to]; null when the person
/// gives up or writes nothing.
Future<String?> askAppealReason(
  BuildContext context, {
  required String to,
}) async {
  final TextEditingController reason = TextEditingController();
  final String? out = await showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(t('Odwołaj się')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZenInfo(
              icon: Icons.info_outline_rounded,
              text: t(
                'Odwołanie rozpatrzy: {judge}. Jest jawne dla członków '
                'piramidy. Gdy zostanie odrzucone albo bez odpowiedzi w '
                'terminie, możesz odwołać się poziom wyżej — aż do szczytu.',
                <String, Object?>{'judge': to},
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('appeal-reason'),
              controller: reason,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              maxLength: kAppealReasonChars,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: t('Dlaczego?')),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('appeal-send'),
          onPressed: () => Navigator.of(context).pop(reason.text.trim()),
          child: Text(t('Wyślij')),
        ),
      ],
    ),
  );
  disposeLater(reason);
  return out == null || out.isEmpty ? null : out;
}
