import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// Longest reason in an appeal typed here (the service takes more).
const int kAppealReasonChars = 500;

/// A name for a kind of ban, as the person under it reads it.
String banKindLabel(String kind) => switch (kind) {
  'perm' => t('Ban stały'),
  'pause' => t('Przerwa'),
  'content' => t('Ban treści'),
  'noadmit' => t('Zakaz przyjmowania do piramidy'),
  'dating' => t('Wyłączony profil randkowy'),
  _ => kind,
};

/// The bans against [me] that can still be appealed, or whose end is
/// worth showing: the active ones, and the lifted ones that were appealed.
List<PyrBan> bansAgainst(PyramidService pyr, PyramidState s, String me) {
  final int now = pyr.now;
  return <PyrBan>[
    for (final PyrBan b in s.bans.values)
      if (b.target == me &&
          (b.activeAt(now) || (b.lifted && pyr.sentAppeals.containsKey(b.id))))
        b,
  ]..sort((PyrBan a, PyrBan b) => b.at.compareTo(a.at));
}

/// "Decyzje wobec Ciebie" (§21.4): the bans the pyramid put on this
/// person, each with "Odwołaj się" (once, with a short reason, to the
/// top) and, after that, where the appeal stands.
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

  Future<void> _appeal(BuildContext context, PyrBan ban) async {
    final String? reason = await _askReason(context);
    if (reason == null) {
      return;
    }
    final bool sent = await pyr.appeal(ban.id, reason);
    if (context.mounted) {
      snack(
        context,
        sent
            ? t('Odwołanie wysłane do szczytu.')
            : t('Nie udało się wysłać odwołania.'),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<PyrBan> bans = bansAgainst(pyr, s, me);
    if (bans.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Column(
      key: const Key('decisions-against-me'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenSection(t('Decyzje wobec Ciebie')),
        for (final PyrBan b in bans)
          ZenCard(
            key: Key('decision-${b.id}'),
            tone: b.lifted ? zen.success : zen.danger,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    ZenIconBadge(
                      icon: b.lifted
                          ? Icons.check_circle_outline_rounded
                          : Icons.block_rounded,
                      tone: b.lifted ? zen.success : zen.danger,
                      size: 40,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            banKindLabel(b.kind),
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            <String>[
                              pyrDate(b.at),
                              if (b.reason.isNotEmpty) b.reason,
                              if (b.until != null)
                                t('do {date}', <String, Object?>{
                                  'date': pyrDate(b.until!),
                                }),
                            ].join(' · '),
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
                const SizedBox(height: 10),
                _status(context, zen, b),
              ],
            ),
          ),
      ],
    );
  }

  /// "Odwołaj się", or where the appeal stands.
  Widget _status(BuildContext context, ZenColors zen, PyrBan b) {
    final int? sentAt = pyr.sentAppeals[b.id];
    if (b.lifted) {
      return Text(
        t('Szczyt uchylił ten ban.'),
        key: Key('decision-lifted-${b.id}'),
        style: TextStyle(
          color: zen.success,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      );
    }
    if (sentAt != null) {
      return Row(
        key: Key('decision-appealed-${b.id}'),
        children: <Widget>[
          Icon(Icons.hourglass_top_rounded, size: 18, color: zen.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t(
                'Odwołanie wysłane {date}. Czeka na decyzję szczytu.',
                <String, Object?>{'date': pyrDate(sentAt)},
              ),
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 13.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: OutlinedButton.icon(
        key: Key('decision-appeal-${b.id}'),
        onPressed: () => unawaited(_appeal(context, b)),
        icon: const Icon(Icons.replay_rounded, size: 18),
        label: Text(t('Odwołaj się')),
      ),
    );
  }
}

/// Asks for the reason of an appeal; null when the person gives up or
/// writes nothing.
Future<String?> _askReason(BuildContext context) async {
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
                'Odwołanie trafi do szczytu. Można je wysłać tylko raz, '
                'więc napisz, dlaczego ta decyzja jest błędna.',
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
