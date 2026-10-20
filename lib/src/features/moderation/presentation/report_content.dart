import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/pyramid/presentation/report_sheet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// "Zgłoś" for a post, comment or message (§21.4): the author is found in
/// the pyramid by their device [authorAddress], [text] goes in as evidence
/// (under [header]) and, with [hashContent], the entry so the delegate can
/// ban the content itself. Once reported, the content is hidden on this
/// phone ([contentId] is what it is hidden by, else the hash of [text]).
/// With [deleteLocal] the person may also remove the local copy; leave it
/// out where the store cannot. Without a pyramid the sheet offers only
/// what works on this phone: hiding and deleting.
///
/// [contentId] also names the reported entry for a content ban (S36), and
/// [entry] — the signed original, where the screen has it — goes in as
/// evidence nobody can make up.
Future<void> reportContent(
  BuildContext context,
  WidgetRef ref, {
  String authorAddress = '',
  String text = '',
  String header = '',
  bool hashContent = true,
  String contentId = '',
  LogEntry? entry,
  Future<void> Function()? deleteLocal,
}) async {
  final PyramidService pyr = ref.read(pyramidServiceProvider);
  final PyramidState? s = pyr.state;
  final String target = s == null
      ? ''
      : pyramidKeyForAddress(s.members.values, authorAddress);
  await showReportSheet(
    context,
    pyr,
    target: target,
    evidence: reportEvidence(text, header: header),
    contentHash: hashContent && text.isNotEmpty ? contentHash(text) : null,
    contentId: contentId,
    entryId: !hashContent
        ? null
        : (contentId.isNotEmpty ? contentId : entry?.id),
    entry: hashContent ? entry?.toJson() : null,
    deleteLocal: deleteLocal,
  );
}

/// Shows the content with this [id] / [text] anyway (what the person hid
/// after reporting it) until the app is closed.
void showHiddenAnyway(
  WidgetRef ref, {
  String id = '',
  String text = '',
  String datingKey = '',
}) => ref
    .read(hiddenByMeProvider.notifier)
    .showContent(id: id, text: text, datingKey: datingKey);

/// Content the pyramid banned, now: ids of banned entries (S36), for
/// [isContentBanned]. Empty when the pyramid has not started (it is never
/// started just for this).
Set<String> bannedContentNow(WidgetRef ref) {
  if (!ref.exists(pyramidServiceProvider)) {
    return const <String>{};
  }
  final PyramidService pyr = ref.read(pyramidServiceProvider);
  final PyramidState? s = pyr.state;
  if (s == null) {
    return const <String>{};
  }
  return s.bannedEntries(pyr.now);
}

/// The running pyramid service, when there is one (to listen for bans).
PyramidService? runningPyramid(WidgetRef ref) =>
    ref.exists(pyramidServiceProvider)
    ? ref.read(pyramidServiceProvider)
    : null;

/// Stands in for a post whose content the pyramid banned, or that the
/// person hid after reporting it ([byMe]); a tap shows it anyway. With
/// [compact] it is a line between messages or comments, not a card.
class HiddenContentPlaceholder extends StatelessWidget {
  const HiddenContentPlaceholder({
    required this.onShow,
    this.byMe = false,
    this.compact = false,
    super.key,
  });

  final VoidCallback onShow;
  final bool byMe;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Widget row = Row(
      children: <Widget>[
        Icon(Icons.visibility_off_outlined, size: 20, color: zen.textMuted),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            byMe ? kHiddenByMeLabel : kHiddenByPyramidLabel,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          byMe ? t('Pokaż mimo to') : t('Pokaż'),
          style: TextStyle(
            color: zen.accent,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
    if (compact) {
      return InkWell(
        onTap: onShow,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: row,
        ),
      );
    }
    return ZenCard(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: onShow,
      child: row,
    );
  }
}
