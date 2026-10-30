import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pebbles/design/pebble_card_look.dart';
import 'package:zen/src/features/qr_sticker/qr_digits.dart';

export 'package:zen/src/features/pebbles/design/pebble_card_look.dart'
    show PebbleCardLook, PebbleLookSource;

/// The version byte of the full card: the pebble as its author signed it
/// (format v1 below). It travels with the design and in profiles; the
/// first test builds also put it in the QR code, and those codes are still
/// read.
const int kPebbleCardVersion = 1;

/// The version byte of the QR card (format v2, [PebbleCard.qrCard]): only
/// what the web page and the first contact need, so the printed code has
/// large modules. The note, the date, the painted preview and the
/// signature come with the full card, fetched with the design.
const int kPebbleQrCardVersion = 2;

/// The longest full card made here (every text at its limit, with the
/// thumbnail): the texts are cut to their limits, nothing else is left
/// out.
const int kPebbleCardMaxBytes = kPebbleCardFormatMaxBytes;

/// The longest well-formed card of format v1 (every text at its limit in
/// letters of several bytes, with a thumbnail).
const int kPebbleCardFormatMaxBytes =
    1 + 16 + 32 + 4 + 12 + 3 + 160 + 255 + 128 + 1 + 176 + 64;

/// The longest name and author's name in a QR card, in UTF-8 bytes.
const int kPebbleQrNameMaxBytes = 24;
const int kPebbleQrAuthorMaxBytes = 16;

/// The longest well-formed QR card (format v2).
const int kPebbleQrCardMaxBytes =
    1 + 16 + 32 + 12 + 1 + kPebbleQrNameMaxBytes + 1 + kPebbleQrAuthorMaxBytes;

/// The longest name, note and author's name, in characters.
const int kPebbleNameMaxChars = 40;
const int kPebbleNoteMaxChars = 100;
const int kPebbleAuthorNameMaxChars = 32;

/// The painted top view in a card: 16 colours (RGB), then 16 × 16 pixels of
/// 4 bits (palette index 0 is transparent).
const int kPebbleThumbnailBytes = 16 * 3 + 16 * 16 ~/ 2;

/// The longest full design anyone keeps or sends.
const int kPebbleDesignMaxBytes = 64 * 1024;

const int _idBytes = 16;
const int _keyBytes = 32;
const int _signatureBytes = 64;

/// A pebble's identity: the first 16 bytes of SHA-256 over the pebble as
/// its author signed it (see [PebbleId.of]); written in base32 in links
/// and file names.
@immutable
final class PebbleId {
  PebbleId(List<int> bytes) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != _idBytes) {
      throw ArgumentError('A pebble id has 16 bytes.');
    }
  }

  final Uint8List bytes;

  static const String _alphabet = 'abcdefghijklmnopqrstuvwxyz234567';

  /// The id of the pebble [design] that the account [author] made at
  /// [createdSeconds]: SHA-256 over "zen-pebble/1", the author's key, the
  /// time (u32, big-endian) and the design, cut to 16 bytes. A copy of the
  /// design from anyone is checked against it.
  static PebbleId of({
    required List<int> author,
    required int createdSeconds,
    required List<int> design,
  }) {
    final BytesBuilder b = BytesBuilder(copy: false)
      ..add(utf8.encode('zen-pebble/1'))
      ..add(author)
      ..add(_u32(createdSeconds))
      ..add(design);
    return PebbleId(crypto.sha256.convert(b.takeBytes()).bytes.sublist(0, 16));
  }

  /// Base32 (RFC 4648, lower case, no padding): 26 characters.
  String get text {
    final StringBuffer out = StringBuffer();
    int buffer = 0;
    int bits = 0;
    for (final int byte in bytes) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_alphabet[(buffer >> bits) & 31]);
      }
    }
    if (bits > 0) {
      out.write(_alphabet[(buffer << (5 - bits)) & 31]);
    }
    return out.toString();
  }

  /// The id written as [text], or `null`.
  static PebbleId? parse(Object? text) {
    if (text is! String || text.length != 26) {
      return null;
    }
    final List<int> out = <int>[];
    int buffer = 0;
    int bits = 0;
    for (final int unit in text.toLowerCase().codeUnits) {
      final int v = _alphabet.indexOf(String.fromCharCode(unit));
      if (v < 0) {
        return null;
      }
      buffer = ((buffer << 5) | v) & 0xFFFF;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xFF);
      }
    }
    return out.length == _idBytes ? PebbleId(out) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is PebbleId && listEquals(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => text;
}

/// A pebble's card, in one of two forms (all integers big-endian),
/// docs/PROTOCOL.md "Pebbles":
///
/// The full card (format v1), signed by the author: what travels with the
/// design, in profiles and to keepers.
///
/// * u8 version = 1, 16 bytes [PebbleId], 32 bytes author account id
///   (Ed25519 public key), u32 created (Unix seconds);
/// * u8 shape preset, u32 shape seed, u8 material, 3 bytes main colour,
///   3 bytes second colour;
/// * u8 length + UTF-8 name, u8 length + UTF-8 note, u8 length + UTF-8
///   author's display name;
/// * u8 thumbnail length (0 or [kPebbleThumbnailBytes]) + thumbnail;
/// * 64 bytes Ed25519 signature over everything before it, by the author's
///   account key.
///
/// The QR card (format v2, [qrCard]): what the printed code and the link
/// carry, not signed. A finder saves it at once and asks for the design;
/// the full card that comes with it must have the same id and author, hold
/// the author's signature and match the design, and then takes its place.
///
/// * u8 version = 2, 16 bytes [PebbleId], 32 bytes author account id;
/// * the same 12 bytes of shape, seed, material and colours;
/// * u8 length + UTF-8 name (at most [kPebbleQrNameMaxBytes]), u8 length +
///   UTF-8 author's display name (at most [kPebbleQrAuthorMaxBytes]).
@immutable
final class PebbleCard implements PebbleLookSource {
  const PebbleCard._({
    required this.id,
    required this.author,
    required this.createdSeconds,
    required this.look,
    required this.name,
    required this.note,
    required this.authorName,
    required this.thumbnail,
    required this.signature,
    required this.bytes,
  });

  final PebbleId id;

  /// The author's account key (Ed25519 public key, 32 bytes).
  final Uint8List author;

  /// When the author made it; 0 on a QR card (not known before the full
  /// card comes).
  final int createdSeconds;
  @override
  final PebbleCardLook look;
  final String name;

  /// Empty on a QR card.
  final String note;
  final String authorName;

  /// [kPebbleThumbnailBytes] bytes, or `null` when the card has none (a QR
  /// card never has one).
  @override
  final Uint8List? thumbnail;

  /// Empty on a QR card.
  final Uint8List signature;

  /// The card as it travels (what [decode] read or [sign] made).
  final Uint8List bytes;

  /// The format of this card: [kPebbleCardVersion] or
  /// [kPebbleQrCardVersion].
  int get version => bytes.first;

  /// Whether this is the full card, signed by the author (otherwise the
  /// QR card, until the full one comes with the design).
  bool get isFull => version == kPebbleCardVersion;

  /// The author's account as the ledger names accounts (base64url of the
  /// key).
  String get authorAccount => b64(author);

  /// When the author made it; `null` on a QR card.
  DateTime? get created => isFull
      ? DateTime.fromMillisecondsSinceEpoch(createdSeconds * 1000)
      : null;

  /// The bytes the signature covers.
  Uint8List get signedBytes =>
      Uint8List.sublistView(bytes, 0, bytes.length - signature.length);

  /// Whether the author's key signed this card (never for a QR card: it
  /// carries no signature).
  Future<bool> verify() async =>
      isFull &&
      await verifyClassicalSignature(
        publicKey: authorAccount,
        message: signedBytes,
        signature: b64(signature),
      );

  /// Whether [design] is the design this card was made for (a QR card
  /// cannot tell: it has no date).
  bool matchesDesign(List<int> design) =>
      isFull &&
      design.length <= kPebbleDesignMaxBytes &&
      PebbleId.of(
            author: author,
            createdSeconds: createdSeconds,
            design: design,
          ) ==
          id;

  /// Whether [full] is a card of this same pebble by the same author (its
  /// signature is checked by the caller).
  bool isSamePebble(PebbleCard full) =>
      full.id == id && listEquals(full.author, author);

  /// The QR card of this pebble (format v2): the name and the author's
  /// name cut to [kPebbleQrNameMaxBytes] and [kPebbleQrAuthorMaxBytes]
  /// (with "…" when cut).
  PebbleCard get qrCard {
    if (!isFull) {
      return this;
    }
    final BytesBuilder b = BytesBuilder(copy: false)
      ..addByte(kPebbleQrCardVersion)
      ..add(id.bytes)
      ..add(author)
      ..add(look.toBytes());
    for (final (String s, int max) in <(String, int)>[
      (name, kPebbleQrNameMaxBytes),
      (authorName, kPebbleQrAuthorMaxBytes),
    ]) {
      final List<int> raw = utf8.encode(clipPebbleTextBytes(s, max));
      b
        ..addByte(raw.length)
        ..add(raw);
    }
    return decode(b.takeBytes())!;
  }

  /// Makes and signs the card of [design] with the account [key]. The texts
  /// are cut to their limits.
  static Future<PebbleCard> sign({
    required LedgerKeyPair key,
    required Uint8List design,
    required int createdSeconds,
    required PebbleCardLook look,
    required String name,
    required String note,
    required String authorName,
    Uint8List? thumbnail,
  }) async {
    if (design.isEmpty || design.length > kPebbleDesignMaxBytes) {
      throw ArgumentError('A pebble design has 1 byte to 64 KB.');
    }
    final PebbleId id = PebbleId.of(
      author: key.publicKey,
      createdSeconds: createdSeconds,
      design: design,
    );
    final PebbleCardText text = fitPebbleCardText(
      name: name,
      note: note,
      authorName: authorName,
      thumbnail: thumbnail,
    );
    final Uint8List body = _encodeBody(
      id: id,
      author: key.publicKey,
      createdSeconds: createdSeconds,
      look: look,
      name: text.name,
      note: text.note,
      authorName: text.authorName,
      thumbnail: text.thumbnail,
    );
    final Uint8List signature = await key.signClassical(body);
    final Uint8List bytes = Uint8List.fromList(<int>[...body, ...signature]);
    return decode(bytes)!;
  }

  /// An unsigned card for showing a stone before it is published (its id,
  /// author and signature are zeros: nobody takes it as a pebble).
  static PebbleCard preview({
    required PebbleCardLook look,
    Uint8List? thumbnail,
    String name = '',
    String note = '',
    String authorName = '',
  }) {
    final PebbleCardText text = fitPebbleCardText(
      name: name,
      note: note,
      authorName: authorName,
      thumbnail: thumbnail,
    );
    final Uint8List body = _encodeBody(
      id: PebbleId(Uint8List(_idBytes)),
      author: Uint8List(_keyBytes),
      createdSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      look: look,
      name: text.name,
      note: text.note,
      authorName: text.authorName,
      thumbnail: text.thumbnail,
    );
    return decode(
      Uint8List.fromList(<int>[...body, ...Uint8List(_signatureBytes)]),
    )!;
  }

  /// The card in [bytes] (either format), or `null` for anything
  /// malformed (the signature is not checked here: [verify]).
  static PebbleCard? decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      return null;
    }
    try {
      return switch (bytes.first) {
        kPebbleCardVersion => _decodeFull(bytes),
        kPebbleQrCardVersion => _decodeQr(bytes),
        _ => null,
      };
    } on RangeError {
      return null;
    } on FormatException {
      return null;
    }
  }

  static PebbleCard? _decodeFull(Uint8List bytes) {
    if (bytes.length > kPebbleCardFormatMaxBytes ||
        bytes.length <
            pebbleCardSize(
              nameBytes: 0,
              noteBytes: 0,
              authorBytes: 0,
              thumbnail: false,
            )) {
      return null;
    }
    final _Reader r = _Reader(bytes)..u8();
    final PebbleId id = PebbleId(r.take(_idBytes));
    final Uint8List author = r.take(_keyBytes);
    final int created = r.u32();
    final PebbleCardLook look = PebbleCardLook.fromBytes(
      r.take(PebbleCardLook.byteLength),
    );
    final String? name = r.text(kPebbleNameMaxChars);
    final String? note = r.text(kPebbleNoteMaxChars);
    final String? authorName = r.text(kPebbleAuthorNameMaxChars);
    if (name == null || note == null || authorName == null) {
      return null;
    }
    final int thumbLength = r.u8();
    if (thumbLength != 0 && thumbLength != kPebbleThumbnailBytes) {
      return null;
    }
    final Uint8List? thumbnail = thumbLength == 0 ? null : r.take(thumbLength);
    final Uint8List signature = r.take(_signatureBytes);
    if (!r.done) {
      return null;
    }
    return PebbleCard._(
      id: id,
      author: author,
      createdSeconds: created,
      look: look,
      name: name,
      note: note,
      authorName: authorName,
      thumbnail: thumbnail,
      signature: signature,
      bytes: Uint8List.fromList(bytes),
    );
  }

  static PebbleCard? _decodeQr(Uint8List bytes) {
    if (bytes.length > kPebbleQrCardMaxBytes ||
        bytes.length <
            kPebbleQrCardMaxBytes -
                kPebbleQrNameMaxBytes -
                kPebbleQrAuthorMaxBytes) {
      return null;
    }
    final _Reader r = _Reader(bytes)..u8();
    final PebbleId id = PebbleId(r.take(_idBytes));
    final Uint8List author = r.take(_keyBytes);
    final PebbleCardLook look = PebbleCardLook.fromBytes(
      r.take(PebbleCardLook.byteLength),
    );
    final String? name = r.textBytes(kPebbleQrNameMaxBytes);
    final String? authorName = r.textBytes(kPebbleQrAuthorMaxBytes);
    if (name == null || authorName == null || !r.done) {
      return null;
    }
    return PebbleCard._(
      id: id,
      author: author,
      createdSeconds: 0,
      look: look,
      name: name,
      note: '',
      authorName: authorName,
      thumbnail: null,
      signature: Uint8List(0),
      bytes: Uint8List.fromList(bytes),
    );
  }

  /// The card in base64url [text] (padding optional), or `null`.
  static PebbleCard? fromText(String text) {
    final String t = text.trim();
    // Links carry it without padding, in the URL-safe alphabet only.
    if (!_base64Url.hasMatch(t)) {
      return null;
    }
    final Uint8List? raw = unb64(t);
    return raw == null ? null : decode(raw);
  }

  /// The card in a link's [text]: the digits of a QR card ([linkText]) or
  /// the base64url of any card ([text], the first test builds' links);
  /// `null` for anything else.
  static PebbleCard? fromLinkText(String text) {
    final String t = text.trim();
    if (_digits.hasMatch(t)) {
      final Uint8List? raw = pebbleBytesFromDigits(t);
      return raw == null ? null : decode(raw);
    }
    return fromText(t);
  }

  static final RegExp _base64Url = RegExp(r'^[A-Za-z0-9_-]+$');
  static final RegExp _digits = RegExp(r'^[0-9]+$');

  /// base64url without padding (how cards are stored and sent).
  String get text => base64Url.encode(bytes).replaceAll('=', '');

  /// What a link carries after `#`: the QR card in decimal digits
  /// ([pebbleDigits]), which a QR code writes in its numeric mode at 3.3
  /// bits a digit (base64url takes 8 bits per 6). A full card's link
  /// carries its QR card.
  String get linkText => pebbleDigits(qrCard.bytes);

  @override
  bool operator ==(Object other) =>
      other is PebbleCard && listEquals(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);
}

/// How many of [bytes] the QR card at their start takes (the keepers a
/// QR code names may follow, pebble_link.dart), or `null` when they start
/// with no well-formed QR card.
int? pebbleQrCardLength(Uint8List bytes) {
  const int fixed = 1 + 16 + 32 + 12;
  if (bytes.length < fixed + 2 || bytes.first != kPebbleQrCardVersion) {
    return null;
  }
  final int name = bytes[fixed];
  if (name > kPebbleQrNameMaxBytes || bytes.length < fixed + 1 + name + 1) {
    return null;
  }
  final int author = bytes[fixed + 1 + name];
  final int length = fixed + 1 + name + 1 + author;
  return author > kPebbleQrAuthorMaxBytes || bytes.length < length
      ? null
      : length;
}

/// [bytes] as one big-endian number in decimal, padded with zeros to the
/// digits of the largest number of that many bytes (so the length tells
/// how many bytes there are: [pebbleBytesFromDigits]).
String pebbleDigits(List<int> bytes) => qrDigits(bytes);

/// The bytes [digits] stand for ([pebbleDigits]), or `null` when no
/// number of bytes is written with that many digits.
Uint8List? pebbleBytesFromDigits(String digits) =>
    qrBytesFromDigits(digits, maxBytes: 255);

/// [s] cut to at most [maxBytes] bytes of UTF-8 on a whole letter, ending
/// in "…" when anything was cut.
String clipPebbleTextBytes(String s, int maxBytes) {
  final String t = s.trim();
  if (utf8.encode(t).length <= maxBytes) {
    return t;
  }
  final List<int> runes = t.runes.toList();
  final int room = maxBytes - utf8.encode('…').length;
  int used = 0;
  int take = 0;
  while (take < runes.length) {
    final int len = utf8.encode(String.fromCharCode(runes[take])).length;
    if (used + len > room) {
      break;
    }
    used += len;
    take++;
  }
  return '${String.fromCharCodes(runes.take(take)).trimRight()}…';
}

/// The texts and thumbnail of a card as they fit ([PebbleCard.sign]).
typedef PebbleCardText = ({
  String name,
  String note,
  String authorName,
  Uint8List? thumbnail,
});

/// [name], [note] and [authorName] cut to their limits (and to 255 bytes
/// each: a length is one byte), with the thumbnail when it is well formed.
PebbleCardText fitPebbleCardText({
  required String name,
  required String note,
  required String authorName,
  Uint8List? thumbnail,
}) {
  String fit(String s, int max) {
    String out = _clipChars(s.trim(), max);
    while (utf8.encode(out).length > 255) {
      out = _dropLast(out);
    }
    return out;
  }

  return (
    name: fit(name, kPebbleNameMaxChars),
    note: fit(note, kPebbleNoteMaxChars),
    authorName: fit(authorName, kPebbleAuthorNameMaxChars),
    thumbnail: thumbnail != null && thumbnail.length == kPebbleThumbnailBytes
        ? thumbnail
        : null,
  );
}

/// How long a full card with texts of these UTF-8 lengths is.
int pebbleCardSize({
  required int nameBytes,
  required int noteBytes,
  required int authorBytes,
  required bool thumbnail,
}) =>
    1 +
    _idBytes +
    _keyBytes +
    4 +
    1 +
    4 +
    1 +
    3 +
    3 +
    3 +
    nameBytes +
    noteBytes +
    authorBytes +
    1 +
    (thumbnail ? kPebbleThumbnailBytes : 0) +
    _signatureBytes;

/// The thumbnail's palette (16 colours 0xRRGGBB, index 0 transparent) and
/// its 256 pixels (row by row, palette indexes); `null` for a malformed one.
({List<int> palette, List<int> pixels})? decodePebbleThumbnail(
  Uint8List? thumbnail,
) {
  if (thumbnail == null || thumbnail.length != kPebbleThumbnailBytes) {
    return null;
  }
  final List<int> palette = <int>[
    for (int i = 0; i < 16; i++)
      (thumbnail[i * 3] << 16) |
          (thumbnail[i * 3 + 1] << 8) |
          thumbnail[i * 3 + 2],
  ];
  final List<int> pixels = <int>[
    for (int i = 48; i < kPebbleThumbnailBytes; i++) ...<int>[
      thumbnail[i] >> 4,
      thumbnail[i] & 15,
    ],
  ];
  return (palette: palette, pixels: pixels);
}

Uint8List _encodeBody({
  required PebbleId id,
  required List<int> author,
  required int createdSeconds,
  required PebbleCardLook look,
  required String name,
  required String note,
  required String authorName,
  required Uint8List? thumbnail,
}) {
  final BytesBuilder b = BytesBuilder(copy: false)
    ..addByte(kPebbleCardVersion)
    ..add(id.bytes)
    ..add(author)
    ..add(_u32(createdSeconds))
    ..add(look.toBytes());
  for (final String s in <String>[name, note, authorName]) {
    final List<int> raw = utf8.encode(s);
    b
      ..addByte(raw.length)
      ..add(raw);
  }
  if (thumbnail == null) {
    b.addByte(0);
  } else {
    b
      ..addByte(thumbnail.length)
      ..add(thumbnail);
  }
  return b.takeBytes();
}

List<int> _u32(int v) {
  final int x = v & 0xFFFFFFFF;
  return <int>[(x >> 24) & 0xFF, (x >> 16) & 0xFF, (x >> 8) & 0xFF, x & 0xFF];
}

String _clipChars(String s, int max) {
  final List<int> runes = s.runes.toList();
  return runes.length <= max ? s : String.fromCharCodes(runes.take(max));
}

String _dropLast(String s) {
  final List<int> runes = s.runes.toList();
  return runes.isEmpty
      ? s
      : String.fromCharCodes(runes.take(runes.length - 1)).trimRight();
}

/// The most keepers a keeper list names.
const int kPebbleMaxKeepers = 16;

/// The author's signed list of a pebble's keepers (the devices that agreed
/// to keep and serve it), newest [version] wins. With [retired] the author
/// took the pebble back: keepers stop offering it, collectors keep their
/// copy. Signed with the same account key as the card (Ed25519, 64
/// bytes), so whoever holds the card can check it.
@immutable
final class PebbleKeeperList {
  const PebbleKeeperList._({
    required this.id,
    required this.version,
    required this.retired,
    required this.keepers,
    required this.signature,
  });

  final PebbleId id;

  /// When the author made this version (milliseconds).
  final int version;
  final bool retired;

  /// The keepers' addresses (normalised).
  final List<String> keepers;
  final Uint8List signature;

  static List<int> _signed(
    PebbleId id,
    int version,
    bool retired,
    List<String> keepers,
  ) => utf8.encode(
    'zen-pebble-keepers/1\n${id.text}\n$version\n${retired ? 1 : 0}\n'
    '${keepers.join(',')}',
  );

  static Future<PebbleKeeperList> sign({
    required LedgerKeyPair key,
    required PebbleId id,
    required int version,
    required List<String> keepers,
    bool retired = false,
  }) async {
    final List<String> list = retired
        ? const <String>[]
        : keepers.take(kPebbleMaxKeepers).toList(growable: false);
    return PebbleKeeperList._(
      id: id,
      version: version,
      retired: retired,
      keepers: list,
      signature: await key.signClassical(_signed(id, version, retired, list)),
    );
  }

  /// Whether the author of [card] signed this list for that pebble.
  Future<bool> verifyFor(PebbleCard card) async =>
      card.id == id &&
      await verifyClassicalSignature(
        publicKey: card.authorAccount,
        message: _signed(id, version, retired, keepers),
        signature: b64(signature),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id.text,
    'v': version,
    if (retired) 'r': true,
    'k': keepers,
    's': b64(signature),
  };

  /// The list in [json], or `null` for anything malformed (not checked:
  /// [verifyFor]).
  static PebbleKeeperList? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final PebbleId? id = PebbleId.parse(json['id']);
    final Object? v = json['v'];
    final Object? k = json['k'];
    final Uint8List? s = unb64(json['s'], length: _signatureBytes);
    if (id == null || v is! int || k is! List || s == null) {
      return null;
    }
    final List<String> keepers = <String>[
      for (final Object? a in k.take(kPebbleMaxKeepers))
        if (a is String && a.isNotEmpty && a.length <= 100 && !a.contains(','))
          a,
    ];
    if (keepers.length != k.length) {
      return null;
    }
    return PebbleKeeperList._(
      id: id,
      version: v,
      retired: json['r'] == true,
      keepers: keepers,
      signature: s,
    );
  }
}

/// A finder's signed "znaleziono" note for a pebble's author: who found it
/// (their account) and when. Best effort; the author counts finders.
@immutable
final class PebbleFoundNote {
  const PebbleFoundNote._({
    required this.id,
    required this.finder,
    required this.atSeconds,
    required this.signature,
  });

  final PebbleId id;

  /// The finder's account (base64url of the Ed25519 key).
  final String finder;
  final int atSeconds;
  final Uint8List signature;

  static List<int> _signed(PebbleId id, String finder, int at) =>
      utf8.encode('zen-pebble-found/1\n${id.text}\n$finder\n$at');

  static Future<PebbleFoundNote> sign({
    required LedgerKeyPair key,
    required PebbleId id,
    required int atSeconds,
  }) async => PebbleFoundNote._(
    id: id,
    finder: key.id,
    atSeconds: atSeconds,
    signature: await key.signClassical(_signed(id, key.id, atSeconds)),
  );

  Future<bool> verify() => verifyClassicalSignature(
    publicKey: finder,
    message: _signed(id, finder, atSeconds),
    signature: b64(signature),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id.text,
    'f': finder,
    'at': atSeconds,
    's': b64(signature),
  };

  static PebbleFoundNote? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final PebbleId? id = PebbleId.parse(json['id']);
    final Object? f = json['f'];
    final Object? at = json['at'];
    final Uint8List? s = unb64(json['s'], length: _signatureBytes);
    if (id == null ||
        f is! String ||
        unb64(f, length: _keyBytes) == null ||
        at is! int ||
        s == null) {
      return null;
    }
    return PebbleFoundNote._(id: id, finder: f, atSeconds: at, signature: s);
  }
}

final class _Reader {
  _Reader(this._bytes);

  final Uint8List _bytes;
  int _at = 0;

  bool get done => _at == _bytes.length;

  int u8() {
    if (_at >= _bytes.length) {
      throw RangeError('past the end');
    }
    return _bytes[_at++];
  }

  int u32() => (u8() << 24) | (u8() << 16) | (u8() << 8) | u8();

  Uint8List take(int n) {
    if (_at + n > _bytes.length) {
      throw RangeError('past the end');
    }
    final Uint8List out = Uint8List.fromList(
      Uint8List.sublistView(_bytes, _at, _at + n),
    );
    _at += n;
    return out;
  }

  /// A length-prefixed UTF-8 text of at most [maxChars] characters; `null`
  /// when it is longer.
  String? text(int maxChars) {
    final String s = utf8.decode(take(u8()));
    return s.runes.length > maxChars ? null : s;
  }

  /// A length-prefixed UTF-8 text of at most [maxBytes] bytes; `null` when
  /// it is longer.
  String? textBytes(int maxBytes) {
    final int n = u8();
    return n > maxBytes ? null : utf8.decode(take(n));
  }
}
