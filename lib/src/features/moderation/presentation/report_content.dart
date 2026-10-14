import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/pyramid/presentation/report_sheet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// "Zgłoś" for a post, comment or message (§21.4): the author is found in
/// the pyramid by their device [authorAddress], [text] goes in as evidence
/// (under [header]) and, with [hashContent], its hash so the delegate can
/// ban the content itself. Without a pyramid the sheet explains why not.
Future<void> reportContent(
  BuildContext context,
  WidgetRef ref, {
  String authorAddress = '',
  String text = '',
  String header = '',
  bool hashContent = true,
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
  );
}

/// Hashes of content the pyramid banned, now. Empty when the pyramid has
/// not started (it is never started just for this).
Set<String> bannedContentNow(WidgetRef ref) {
  if (!ref.exists(pyramidServiceProvider)) {
    return const <String>{};
  }
  final PyramidService pyr = ref.read(pyramidServiceProvider);
  return pyr.state?.bannedContent(pyr.now) ?? const <String>{};
}

/// The running pyramid service, when there is one (to listen for bans).
PyramidService? runningPyramid(WidgetRef ref) =>
    ref.exists(pyramidServiceProvider)
    ? ref.read(pyramidServiceProvider)
    : null;

/// Stands in for a post whose content the pyramid banned; a tap shows it
/// anyway.
class HiddenContentPlaceholder extends StatelessWidget {
  const HiddenContentPlaceholder({required this.onShow, super.key});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      onTap: onShow,
      child: Row(
        children: <Widget>[
          Icon(Icons.visibility_off_outlined, size: 20, color: zen.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              kHiddenByPyramidLabel,
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
            'Pokaż',
            style: TextStyle(
              color: zen.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
