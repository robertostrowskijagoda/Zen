import 'dart:io';
import 'dart:typed_data';

import 'package:zen/src/app/zen_web.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The page of the project's pages that shows a pebble from its card
/// (tool/pages/k/).
const String kPebblePagePath = 'k';

/// The most keepers a pebble's QR code names (16 bytes each; three keep
/// the printed code easy to scan).
const int kPebbleQrKeepersMax = 3;

/// What a pebble link carries: the card and, on a QR code, the keepers
/// the author put in it ([kPebbleQrKeepersMax] at most): whom a finder
/// asks for the full design even when nobody they know knows the author.
/// Not signed: only whom to ask; what comes back must match the card.
typedef PebbleLink = ({PebbleCard card, List<String> keepers});

/// The link a pebble's QR code carries: `https://…/Zen/k/#<digits>`, the
/// QR card ([PebbleCard.qrCard]) and the [keepers] after it
/// ([pebbleLinkDigits]). It is in the fragment, which the browser never
/// sends to the server.
String pebbleWebLink(
  PebbleCard card, {
  List<String> keepers = const <String>[],
}) => '${zenPageUrl('$kPebblePagePath/')}#${pebbleLinkDigits(card, keepers)}';

/// The link to share a pebble in a message (Kopiuj link): the whole signed
/// card in base64url ([PebbleCard.text]), with its 16 x 16 preview, so the
/// page shows the painted top and checks the author's signature. Longer
/// than the QR code's [pebbleWebLink], which has no room for the preview.
String pebbleShareLink(PebbleCard card) =>
    '${zenPageUrl('$kPebblePagePath/')}#${card.text}';

/// The link that opens the pebble straight in Zen:
/// `zen://pebble#<digits>` (the page's "Zbierz w Zen").
String pebbleAppLink(
  PebbleCard card, {
  List<String> keepers = const <String>[],
}) => 'zen://pebble#${pebbleLinkDigits(card, keepers)}';

/// The digits after `#` in a QR code's link: the QR card's bytes, then,
/// when there are [keepers], u8 count and the 16 bytes of each address
/// (the first [kPebbleQrKeepersMax] that are network addresses), as one
/// number in decimal ([pebbleDigits]). A Zen before 1.15.3 reads no code
/// with keepers.
String pebbleLinkDigits(PebbleCard card, List<String> keepers) {
  final List<Uint8List> raw = <Uint8List>[
    for (final String k in keepers)
      if (_addressBytes(k) case final Uint8List b) b,
  ].take(kPebbleQrKeepersMax).toList();
  final BytesBuilder b = BytesBuilder(copy: false)..add(card.qrCard.bytes);
  if (raw.isNotEmpty) {
    b.addByte(raw.length);
    raw.forEach(b.add);
  }
  return pebbleDigits(b.takeBytes());
}

Uint8List? _addressBytes(String address) {
  final InternetAddress? ip = InternetAddress.tryParse(
    PeerShareCodec.normalizeAddress(address),
  );
  return ip != null && ip.type == InternetAddressType.IPv6
      ? ip.rawAddress
      : null;
}

/// The card and keepers a pebble link carries (either form: the digits of
/// a QR code, with or without keepers, or the base64url of any card, as
/// the first test builds printed), or `null` when [text] is no pebble
/// link. The signature is not checked here ([PebbleCard.verify]).
PebbleLink? pebbleFromLink(String? text) {
  final String? trimmed = text?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null || uri.fragment.isEmpty) {
    return null;
  }
  final bool ours = switch (uri.scheme) {
    'zen' => uri.host == 'pebble',
    'https' || 'http' => isZenPage(uri, path: kPebblePagePath),
    _ => false,
  };
  return ours ? _fromFragment(uri.fragment) : null;
}

PebbleLink? _fromFragment(String fragment) {
  final String t = fragment.trim();
  if (_digits.hasMatch(t)) {
    final Uint8List? raw = pebbleBytesFromDigits(t);
    final int? length = raw == null ? null : pebbleQrCardLength(raw);
    if (raw == null || length == null) {
      return null;
    }
    final PebbleCard? card = PebbleCard.decode(
      Uint8List.sublistView(raw, 0, length),
    );
    final List<String>? keepers = _keepers(Uint8List.sublistView(raw, length));
    return card == null || keepers == null
        ? null
        : (card: card, keepers: keepers);
  }
  final PebbleCard? card = PebbleCard.fromText(t);
  return card == null ? null : (card: card, keepers: const <String>[]);
}

final RegExp _digits = RegExp(r'^[0-9]+$');

/// The keepers after a QR card: none, or u8 count and 16 bytes each.
List<String>? _keepers(Uint8List rest) {
  if (rest.isEmpty) {
    return const <String>[];
  }
  final int n = rest.first;
  if (n < 1 || n > kPebbleQrKeepersMax || rest.length != 1 + 16 * n) {
    return null;
  }
  return <String>[
    for (int i = 0; i < n; i++)
      PeerShareCodec.normalizeAddress(
        InternetAddress.fromRawAddress(
          Uint8List.fromList(rest.sublist(1 + 16 * i, 17 + 16 * i)),
          type: InternetAddressType.IPv6,
        ).address,
      ),
  ];
}

/// The card a pebble link carries ([pebbleFromLink]), or `null`.
PebbleCard? pebbleCardFromLink(String? text) => pebbleFromLink(text)?.card;

/// Whether [text] is a pebble link (a well-formed card in it).
bool isPebbleLink(String? text) => pebbleFromLink(text) != null;
