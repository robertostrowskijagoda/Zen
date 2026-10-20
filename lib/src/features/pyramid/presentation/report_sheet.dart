import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// "Zgłoś" (§21.4): a reason and the evidence go to the delegates of this
/// person's branch (or the top); the reported person never learns who.
/// [entryId] names the reported entry for a content ban and [entry] is its
/// signed original when the screen has one (S36).
///
/// What was reported is hidden on this phone at once (a post, comment or
/// message by [contentId], else by [contentHash] (local only); a dating profile by
/// [datingKey]); the hiding can be undone with "Pokaż mimo to" where the
/// content would have been. With [deleteLocal] the person may also remove
/// the local copy ("Usuń z mojego urządzenia"): pass it only where the
/// store can really delete it.
///
/// Without a pyramid nobody can decide anything: the sheet then offers
/// just hiding and deleting on this phone.
Future<void> showReportSheet(
  BuildContext context,
  PyramidService pyr, {
  String target = '',
  String evidence = '',
  String? datingKey,
  String? contentHash,
  String? onlyReason,
  String contentId = '',
  String? entryId,
  Map<String, dynamic>? entry,
  Future<void> Function()? deleteLocal,
}) async {
  final HiddenByMeNotifier? hidden = hiddenByMeOf(context);
  final List<String> hideKeys = HiddenByMe.keysFor(
    id: contentId,
    textHash: contentHash,
    datingKey: datingKey,
  );
  if (!pyr.isMember) {
    await _withoutPyramid(context, hidden, hideKeys, deleteLocal);
    return;
  }
  String? reason = onlyReason;
  bool alsoDelete = false;
  if (reason == null) {
    final ({String reason, bool delete})? picked =
        await showModalBottomSheet<({String reason, bool delete})>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (BuildContext context) => _ReasonSheet(
            canHide: hideKeys.isNotEmpty,
            canDelete: deleteLocal != null,
          ),
        );
    if (picked == null) {
      return;
    }
    reason = picked.reason;
    alsoDelete = picked.delete;
  }
  await pyr.report(
    reason: reason,
    target: target,
    evidence: evidence,
    datingKey: datingKey,
    // The entry itself (S36): a ban names it.
    entryId: entryId,
    entry: entry,
  );
  // The person asked for it, so it happens even when the screen is gone.
  await hidden?.hide(hideKeys);
  bool deleted = false;
  if (alsoDelete && deleteLocal != null) {
    deleted = await _deleteLocal(deleteLocal);
  }
  if (context.mounted) {
    final String message = deleted
        ? t(
            'Zgłoszone i usunięte z Twojego urządzenia. Decyzja będzie jawna; Ty pozostajesz anonimowy(-a) dla zgłoszonego.',
          )
        : (hideKeys.isNotEmpty && hidden != null
              ? t(
                  'Zgłoszone i ukryte u Ciebie. Decyzja będzie jawna; Ty pozostajesz anonimowy(-a) dla zgłoszonego.',
                )
              : t(
                  'Zgłoszone. Decyzja będzie jawna; Ty pozostajesz anonimowy(-a) dla zgłoszonego.',
                ));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Runs [deleteLocal]; false when it failed (the failure is logged).
Future<bool> _deleteLocal(Future<void> Function() deleteLocal) async {
  try {
    await deleteLocal();
    return true;
  } on Object catch (error, stackTrace) {
    logZenError('Usuwanie zgłoszonej treści', error, stackTrace);
    return false;
  }
}

/// A person outside the pyramid: nobody to report to, so only what works
/// on this phone.
Future<void> _withoutPyramid(
  BuildContext context,
  HiddenByMeNotifier? hidden,
  List<String> hideKeys,
  Future<void> Function()? deleteLocal,
) async {
  final bool canHide = hidden != null && hideKeys.isNotEmpty;
  if (!canHide && deleteLocal == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          t(
            'Zgłoszenia rozpatruje piramida — bez niej możesz tylko zablokować tę osobę.',
          ),
        ),
      ),
    );
    return;
  }
  final String? choice = await showModalBottomSheet<String>(
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
                    t('Zgłoszenia rozpatruje piramida'),
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
              t(
                'Nie jesteś w piramidzie, więc nie ma komu przekazać zgłoszenia. '
                'Na tym telefonie możesz jednak zadbać o siebie.',
              ),
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 13.5,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            ZenGroup(
              children: <Widget>[
                if (canHide)
                  ListTile(
                    key: const Key('report-hide-local'),
                    leading: Icon(
                      Icons.visibility_off_outlined,
                      color: zen.textSecondary,
                    ),
                    title: Text(t('Ukryj u mnie')),
                    subtitle: Text(
                      t(
                        'Zniknie z Twoich ekranów; możesz je pokazać z powrotem.',
                      ),
                    ),
                    onTap: () => Navigator.of(context).pop('hide'),
                  ),
                if (deleteLocal != null)
                  ListTile(
                    key: const Key('report-delete-local'),
                    leading: Icon(
                      Icons.delete_outline_rounded,
                      color: zen.danger,
                    ),
                    title: Text(t('Usuń z mojego urządzenia')),
                    subtitle: Text(
                      t('Kopia na tym telefonie zostanie usunięta.'),
                    ),
                    onTap: () => Navigator.of(context).pop('delete'),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
  if (choice == null) {
    return;
  }
  if (choice == 'delete') {
    if (!context.mounted || !await _confirmDelete(context)) {
      return;
    }
    // Deleted for good, but hidden too, in case a copy comes back.
    await hidden?.hide(hideKeys);
    final bool deleted = await _deleteLocal(deleteLocal!);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            deleted
                ? t('Usunięto z Twojego urządzenia.')
                : t('Nie udało się usunąć.'),
          ),
        ),
      );
    }
    return;
  }
  await hidden?.hide(hideKeys);
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t('Ukryte u Ciebie.'))));
  }
}

Future<bool> _confirmDelete(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Usunąć z urządzenia?')),
        content: Text(t('Tej kopii nie da się przywrócić.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('report-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Usuń')),
          ),
        ],
      ),
    ) ??
    false;

/// The reasons, and (where the store can) the choice to delete the local
/// copy too.
class _ReasonSheet extends StatefulWidget {
  const _ReasonSheet({required this.canHide, required this.canDelete});

  /// What is reported gets hidden on this phone.
  final bool canHide;

  /// The local copy can be deleted too.
  final bool canDelete;

  @override
  State<_ReasonSheet> createState() => _ReasonSheetState();
}

class _ReasonSheetState extends State<_ReasonSheet> {
  bool _delete = false;

  @override
  Widget build(BuildContext context) {
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
                  t('Zgłoś — dlaczego?'),
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
            widget.canHide
                ? t(
                    'Zgłoszenie trafi do osób, które rozpatrują sprawy w tej gałęzi. '
                    'Zgłoszony nie dowie się, kto to był. Zgłoszone od razu '
                    'znika z Twoich ekranów.',
                  )
                : t(
                    'Zgłoszenie trafi do osób, które rozpatrują sprawy w tej gałęzi. Zgłoszony nie dowie się, kto to był.',
                  ),
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          if (widget.canDelete)
            ZenGroup(
              children: <Widget>[
                CheckboxListTile(
                  key: const Key('report-delete-local'),
                  value: _delete,
                  onChanged: (bool? v) => setState(() => _delete = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: Text(t('Usuń z mojego urządzenia')),
                  subtitle: Text(t('Kopia na tym telefonie zniknie na stałe.')),
                ),
              ],
            ),
          ZenGroup(
            children: <Widget>[
              for (final MapEntry<String, String> r in kReportReasons.entries)
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
                  onTap: () => Navigator.of(
                    context,
                  ).pop((reason: r.key, delete: _delete)),
                ),
            ],
          ),
        ],
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
