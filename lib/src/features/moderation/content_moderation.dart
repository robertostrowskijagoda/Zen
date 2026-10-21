import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// How much of a post or message goes into a report as evidence.
const int kReportEvidenceMax = 2000;

/// Placeholder shown instead of a post whose content the pyramid banned.
String get kHiddenByPyramidLabel => t('Treść ukryta decyzją piramidy');

/// Placeholder shown instead of content the person hid after reporting it.
String get kHiddenByMeLabel => t('Ukryte po Twoim zgłoszeniu');

/// The pyramid key of the member whose device has [address], or '' when
/// nobody in [members] uses it — or when more than one active member
/// claims it. A member writes their device address into the pyramid
/// themselves and the record proves nothing, so an address two members
/// claim belongs to neither here; points are paid "to an address" only
/// once the device there proved it holds the key
/// (`PyramidService.provenKeyAt`).
String pyramidKeyForAddress(Iterable<PyrMember> members, String address) {
  final String a = PeerShareCodec.normalizeAddress(address);
  if (a.isEmpty) {
    return '';
  }
  String found = '';
  bool foundActive = false;
  for (final PyrMember m in members) {
    if (m.addr.trim().isEmpty ||
        PeerShareCodec.normalizeAddress(m.addr) != a ||
        m.key == found) {
      continue;
    }
    if (found.isEmpty || (m.active && !foundActive)) {
      found = m.key;
      foundActive = m.active;
    } else if (m.active) {
      return '';
    }
  }
  return found;
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

/// Whether content is banned by the pyramid: [banned] holds the ids of
/// banned entries (`PyramidState.bannedEntries`). An entry stays
/// banned whatever its text.
bool isContentBanned(Set<String> banned, {String id = ''}) =>
    id.isNotEmpty && banned.contains(id);

/// Whether a post with [text] (id [id]) is hidden behind the placeholder:
/// banned by the pyramid, or hidden by this person after a report ([mine]),
/// and not revealed by a tap ([revealed] holds such ids; what was shown
/// anyway is in [mine] itself).
bool isContentHidden(
  Set<String> banned,
  String text, {
  String id = '',
  Set<String> revealed = const <String>{},
  HiddenByMe? mine,
}) =>
    !revealed.contains(id) &&
    (isContentBanned(banned, id: id) ||
        (mine?.hides(id: id, text: text) ?? false));
