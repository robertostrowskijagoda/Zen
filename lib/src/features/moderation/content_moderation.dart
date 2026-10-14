import 'package:zen/src/features/pyramid/pyramid_service.dart' show contentHash;
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// How much of a post or message goes into a report as evidence (§21.4).
const int kReportEvidenceMax = 2000;

/// Placeholder shown instead of a post whose content the pyramid banned.
const String kHiddenByPyramidLabel = 'Treść ukryta decyzją piramidy';

/// The pyramid key of the member whose device has [address], or '' when
/// nobody in [members] uses it.
String pyramidKeyForAddress(Iterable<PyrMember> members, String address) {
  final String a = PeerShareCodec.normalizeAddress(address);
  if (a.isEmpty) {
    return '';
  }
  for (final PyrMember m in members) {
    if (m.addr.trim().isNotEmpty &&
        PeerShareCodec.normalizeAddress(m.addr) == a) {
      return m.key;
    }
  }
  return '';
}

/// Evidence for a report: an optional [header] line ("Post na tablicy —
/// Ada") and the [text], cut to [max] characters.
String reportEvidence(
  String text, {
  String header = '',
  int max = kReportEvidenceMax,
}) {
  final String body = text.trim();
  final String cut = body.length > max ? '${body.substring(0, max)}…' : body;
  final String h = header.trim();
  return h.isEmpty ? cut : '$h\n$cut';
}

/// Whether [text] is content the pyramid banned ([banned] are the hashes
/// from `PyramidState.bannedContent`).
bool isContentBanned(Set<String> banned, String text) =>
    banned.isNotEmpty && text.isNotEmpty && banned.contains(contentHash(text));

/// Whether a post with [text] (id [id]) is hidden behind the placeholder:
/// banned, and not revealed by a tap ([revealed] holds such ids).
bool isContentHidden(
  Set<String> banned,
  String text, {
  String id = '',
  Set<String> revealed = const <String>{},
}) => !revealed.contains(id) && isContentBanned(banned, text);
