import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// "Zgłoś" (§21.4): a reason and the evidence go to the delegates of this
/// person's branch (or the top); the reported person never learns who.
Future<void> showReportSheet(
  BuildContext context,
  PyramidService pyr, {
  String target = '',
  String evidence = '',
  String? datingKey,
  String? contentHash,
  String? onlyReason,
}) async {
  if (!pyr.isMember) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Zgłoszenia rozpatruje piramida — bez niej zostaje Twoja blokada i „Usuń z mojego urządzenia”.',
        ),
      ),
    );
    return;
  }
  final String? reason =
      onlyReason ??
      await showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (BuildContext context) {
          final ZenColors zen = ZenColors.of(context);
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    ZenIconBadge(
                      icon: Icons.flag_rounded,
                      tone: zen.danger,
                      size: 40,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Zgłoś — dlaczego?',
                        style: zen.display(
                          color: zen.textPrimary,
                          size: 22,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Zgłoszenie trafi do osób, które rozpatrują sprawy w tej gałęzi. Zgłoszony nie dowie się, kto to był.',
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                ZenGroup(
                  children: <Widget>[
                    for (final MapEntry<String, String> r
                        in kReportReasons.entries)
                      ListTile(
                        key: Key('report-${r.key}'),
                        leading: Icon(
                          _reasonIcon(r.key),
                          color: r.key == 'illegal' || r.key == 'minor'
                              ? zen.danger
                              : zen.textSecondary,
                        ),
                        title: Text(r.value),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          color: zen.textMuted,
                        ),
                        onTap: () => Navigator.of(context).pop(r.key),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      );
  if (reason == null) {
    return;
  }
  await pyr.report(
    reason: reason,
    target: target,
    evidence: evidence,
    datingKey: datingKey,
    contentHash: contentHash,
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Zgłoszone. Decyzja będzie jawna; Ty pozostajesz anonimowy(-a) dla zgłoszonego.',
        ),
      ),
    );
  }
}

IconData _reasonIcon(String reason) => switch (reason) {
  'illegal' => Icons.gavel_rounded,
  'fake' => Icons.person_off_outlined,
  'farm' => Icons.groups_outlined,
  'harass' => Icons.sentiment_very_dissatisfied_outlined,
  'fraud' => Icons.money_off_rounded,
  'spam' => Icons.mark_email_unread_outlined,
  'minor' => Icons.child_care_rounded,
  _ => Icons.more_horiz_rounded,
};
