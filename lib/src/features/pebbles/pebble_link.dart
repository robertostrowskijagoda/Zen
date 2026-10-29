import 'package:zen/src/app/zen_web.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';

/// The page of the project's pages that shows a pebble from its card
/// (tool/pages/k/).
const String kPebblePagePath = 'k';

/// The link a pebble's QR code carries:
/// `https://…/Zen/k/#<base64url(card)>`. The card is in the fragment, which
/// the browser never sends to the server.
String pebbleWebLink(PebbleCard card) =>
    '${zenPageUrl('$kPebblePagePath/')}#${card.text}';

/// The link that opens the pebble straight in Zen: `zen://pebble#<card>`
/// (the page's "Zbierz w Zen").
String pebbleAppLink(PebbleCard card) => 'zen://pebble#${card.text}';

/// The card a pebble link carries (either form, or the bare base64url of a
/// card), or `null` when [text] is no pebble link. The signature is not
/// checked here ([PebbleCard.verify]).
PebbleCard? pebbleCardFromLink(String? text) {
  final String? trimmed = text?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null) {
    return null;
  }
  if (uri.scheme == 'zen') {
    return uri.host == 'pebble' && uri.fragment.isNotEmpty
        ? PebbleCard.fromText(uri.fragment)
        : null;
  }
  if (uri.scheme == 'https' || uri.scheme == 'http') {
    return isZenPage(uri, path: kPebblePagePath) && uri.fragment.isNotEmpty
        ? PebbleCard.fromText(uri.fragment)
        : null;
  }
  return null;
}

/// Whether [text] is a pebble link (a well-formed card in it).
bool isPebbleLink(String? text) => pebbleCardFromLink(text) != null;
