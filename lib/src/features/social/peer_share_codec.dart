import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

@immutable
final class PeerShareProfile {
  const PeerShareProfile({
    required this.shareId,
    required this.displayName,
    required this.address,
    required this.inviteCode,
  });

  final String shareId;
  final String displayName;
  final String address;

  /// The one invitation code (see [PeerShareCodec.inviteCodeForAddress]):
  /// what the user copies, reads out, and what the QR code holds.
  final String inviteCode;

  /// What to hand out.
  String get shareText => inviteCode;

  /// The QR code: the same code as a link, so the phone's camera opens the
  /// app with it.
  String get qrData => PeerShareCodec.qrDataForInviteCode(inviteCode);
}

@immutable
final class PeerDialTarget {
  const PeerDialTarget({
    required this.shareId,
    required this.displayName,
    required this.address,
    required this.rawInput,
    required this.isToken,
  });

  final String shareId;
  final String displayName;
  final String address;
  final String rawInput;
  final bool isToken;
}

final class PeerShareCodec {
  /// The project's page on GitHub (downloads, instructions, the code).
  static const String repositoryUrl =
      'https://github.com/robertostrowskijagoda/Zen';

  /// Where a QR code points: a one-file page on GitHub Pages
  /// (`tool/pages/index.html`) that opens Zen with the code — or, without
  /// Zen, shows the downloads. The invitation code travels in the part after
  /// `#`, which a browser never sends to a server, so nobody can log who
  /// invited whom. Zen itself answers this link once the person lets it
  /// ("Otwieraj obsługiwane linki"), and its scanner reads the code from it
  /// directly.
  static const String invitePageUrl =
      'https://robertostrowskijagoda.github.io/Zen/';

  /// A full invitation link for [code] (the universal QR / shareable link).
  static String inviteLinkForCode(String code) =>
      '$invitePageUrl#${code.replaceAll('-', '')}';

  /// Pulls an invitation code out of an invite link — [invitePageUrl] or
  /// [repositoryUrl] with `#CODE` — or null when [input] is not one.
  static String? inviteCodeFromLink(String input) {
    final Uri? uri = Uri.tryParse(input.trim());
    if (uri == null || uri.scheme != 'https' || !_isInvitePage(uri)) {
      return null;
    }
    final String raw = uri.fragment.trim();
    if (raw.isEmpty) {
      return null;
    }
    return addressFromInviteCode(raw) == null ? null : raw;
  }

  /// Whether [uri] is the invitation page or the project page.
  static bool _isInvitePage(Uri uri) {
    String page(Uri u) =>
        '${u.host.toLowerCase()}'
        '${u.path.toLowerCase().replaceFirst(RegExp(r'/+$'), '')}';
    final String target = page(uri);
    return target == page(Uri.parse(invitePageUrl)) ||
        target == page(Uri.parse(repositoryUrl));
  }

  static const int _shareIdLength = 12;
  static const int _shareIdGroupSize = 4;

  /// Canonical mesh identity. Compressed and expanded IPv6, plus the
  /// upper/lower forms used by QR vs the node, all collapse onto one key.
  /// Non-IPv6 test/legacy identifiers are left unchanged.
  static String normalizeAddress(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty || !trimmed.contains(':')) {
      return trimmed;
    }
    final Uint8List? bytes = _tryIpv6ToBytes(trimmed);
    if (bytes == null) {
      return trimmed.toUpperCase();
    }
    return _bytesToCanonicalIpv6(bytes);
  }

  static bool addressesEqual(String left, String right) {
    return normalizeAddress(left) == normalizeAddress(right);
  }

  /// Who is behind [address], for rate limits and caps on what strangers
  /// can send.
  ///
  /// A node address (`2xx:`, first byte 0x02) is one key, so one identity.
  /// A subnet address (`3xx:`, first byte 0x03) belongs to a node that owns
  /// the whole /64 and can use any of its 2^64 addresses, so those count
  /// by their /64 prefix. Anything that is not an IPv6 address is its own
  /// key.
  static String identityKeyForAddress(String address) {
    final String normalized = normalizeAddress(address);
    final Uint8List? bytes = _tryIpv6ToBytes(normalized);
    if (bytes == null || bytes[0] != 0x03) {
      return normalized;
    }
    final Uint8List prefix = Uint8List(16)..setRange(0, 8, bytes);
    return '${_bytesToCanonicalIpv6(prefix)}/64';
  }

  static String shareIdForAddress(String address) {
    final String normalized = normalizeAddress(address);
    final String digest = _hexFromBytes(
      sha256.convert(utf8.encode(normalized)).bytes,
    );
    return _formatShareId(digest.substring(0, _shareIdLength));
  }

  static String displayNameForAddress(String address) {
    return shareIdForAddress(address);
  }

  static PeerShareProfile? buildLocalProfile({
    required String address,
    String? displayName,
  }) {
    final String normalized = normalizeAddress(address);
    if (!_looksLikeYggAddress(normalized)) {
      return null;
    }
    final String? code = inviteCodeForAddress(normalized);
    if (code == null) {
      return null;
    }
    final String shareId = shareIdForAddress(normalized);
    return PeerShareProfile(
      shareId: shareId,
      displayName: _normalizedLabel(displayName) ?? 'Zen $shareId',
      address: normalized,
      inviteCode: code,
    );
  }

  /// The QR code is the universal invite link (works with and without Zen
  /// installed).
  static String qrDataForInviteCode(String code) => inviteLinkForCode(code);

  /// Crockford base32: no I, L, O, U - nothing to misread or mistype.
  static const String _inviteAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const int _inviteBodyLength = 24;

  /// A short invite code for a node address: `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX`.
  ///
  /// Node addresses always start with the byte 0x02; the other 15 bytes go
  /// into 24 base32 characters, plus one checksum character that catches a
  /// typo. Unlike [shareIdForAddress] (a hash) the code carries the whole
  /// address, so it is enough to send an invitation.
  static String? inviteCodeForAddress(String address) {
    final Uint8List? bytes = _tryIpv6ToBytes(normalizeAddress(address));
    if (bytes == null || bytes[0] != 0x02) {
      return null;
    }
    final Uint8List body = Uint8List.sublistView(bytes, 1);
    final StringBuffer out = StringBuffer();
    int buffer = 0;
    int bits = 0;
    for (final int byte in body) {
      buffer = (buffer << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        out.write(_inviteAlphabet[(buffer >> bits) & 0x1F]);
      }
      buffer &= (1 << bits) - 1;
    }
    // 120 bits are exactly 24 characters.
    out.write(_inviteAlphabet[_inviteChecksum(body)]);
    final String raw = out.toString();
    return <String>[
      for (int i = 0; i < raw.length; i += 5) raw.substring(i, i + 5),
    ].join('-');
  }

  static int _inviteChecksum(Uint8List body) {
    return sha256.convert(body).bytes.first & 0x1F;
  }

  /// The address an invite code stands for, or `null` when [input] is not a
  /// (valid) invite code.
  static String? addressFromInviteCode(String input) {
    final String cleaned = input
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll(RegExp('[IL]'), '1');
    if (cleaned.length != _inviteBodyLength + 1) {
      return null;
    }
    final Uint8List body = Uint8List(15);
    int buffer = 0;
    int bits = 0;
    int index = 0;
    for (int i = 0; i < _inviteBodyLength; i++) {
      final int value = _inviteAlphabet.indexOf(cleaned[i]);
      if (value < 0) {
        return null;
      }
      buffer = (buffer << 5) | value;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        body[index++] = (buffer >> bits) & 0xFF;
        buffer &= (1 << bits) - 1;
      }
    }
    final int check = _inviteAlphabet.indexOf(cleaned[_inviteBodyLength]);
    if (check != _inviteChecksum(body)) {
      return null;
    }
    return _bytesToCanonicalIpv6(Uint8List.fromList(<int>[0x02, ...body]));
  }

  static String normalizeManualInput(String input) {
    final String trimmed = input.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    if (trimmed.toLowerCase().startsWith('zen://')) {
      return trimmed;
    }
    // A universal invite link (`https://…#CODE`): take the code out of it.
    final String? linkCode = inviteCodeFromLink(trimmed);
    if (linkCode != null) {
      return inviteCodeForAddress(addressFromInviteCode(linkCode)!)!;
    }
    final String? invited = addressFromInviteCode(trimmed);
    if (invited != null) {
      return inviteCodeForAddress(invited)!;
    }
    if (_looksLikePotentialShareId(trimmed)) {
      return _formatShareId(trimmed);
    }
    return normalizeAddress(trimmed);
  }

  /// The person an invitation code, an invitation link (see
  /// [inviteCodeFromLink]), a `zen://c/CODE` link or a node address stands
  /// for. None of them carries a name: the friend request brings theirs.
  static PeerDialTarget parseTarget(String input) {
    final String trimmed = normalizeManualInput(input);
    if (trimmed.isEmpty) {
      throw const FormatException('Wklej kod znajomego albo zeskanuj QR.');
    }
    if (trimmed.toLowerCase().startsWith('zen://c/')) {
      return _parseQrDeepLink(trimmed);
    }
    final String? invited = addressFromInviteCode(trimmed);
    if (invited != null) {
      return PeerDialTarget(
        shareId: shareIdForAddress(invited),
        // The code carries no name; the request brings theirs along.
        displayName: '',
        address: invited,
        rawInput: trimmed,
        isToken: true,
      );
    }
    if (_looksLikeShareId(trimmed)) {
      throw const FormatException(
        'Sam kod nie wystarczy. Wklej zaproszenie albo zeskanuj QR.',
      );
    }
    final String canonical = normalizeAddress(trimmed);
    if (trimmed.contains('://') || _tryIpv6ToBytes(canonical) == null) {
      // Other links are not taken: a link must never suggest a name for a
      // stranger.
      throw const FormatException('Nieprawidłowe zaproszenie.');
    }
    return PeerDialTarget(
      shareId: shareIdForAddress(canonical),
      displayName: displayNameForAddress(canonical),
      address: canonical,
      rawInput: trimmed,
      isToken: false,
    );
  }

  static PeerDialTarget _parseQrDeepLink(String rawInput) {
    final String? invited = addressFromInviteCode(
      rawInput.substring('zen://c/'.length),
    );
    if (invited == null) {
      throw const FormatException('Nieprawidłowy kod QR.');
    }
    return PeerDialTarget(
      shareId: shareIdForAddress(invited),
      displayName: '',
      address: invited,
      rawInput: rawInput,
      isToken: true,
    );
  }

  static String? _normalizedLabel(String? value) {
    final String? trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return trimmed;
  }

  static bool _looksLikeYggAddress(String value) {
    return value.isNotEmpty && value != 'N/A' && value.contains(':');
  }

  static bool _looksLikeShareId(String value) {
    return RegExp(
      '^[A-Z0-9]{$_shareIdLength}\$',
    ).hasMatch(_normalizeShareId(value));
  }

  static bool _looksLikePotentialShareId(String value) {
    if (value.contains(':') || value.contains('/') || value.contains('#')) {
      return false;
    }
    final String normalized = _normalizeShareId(value);
    if (normalized.isEmpty || normalized.length > _shareIdLength) {
      return false;
    }
    return RegExp(r'^[A-Z0-9- ]+$').hasMatch(value.toUpperCase());
  }

  static String _normalizeShareId(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
  }

  static String _formatShareId(String value) {
    final String normalized = _normalizeShareId(value);
    if (normalized.isEmpty) {
      return normalized;
    }
    final List<String> groups = <String>[];
    for (int index = 0; index < normalized.length; index += _shareIdGroupSize) {
      final int end = index + _shareIdGroupSize > normalized.length
          ? normalized.length
          : index + _shareIdGroupSize;
      groups.add(normalized.substring(index, end));
    }
    return groups.join('-');
  }

  static String _hexFromBytes(List<int> bytes) {
    final StringBuffer buffer = StringBuffer();
    for (final int value in bytes) {
      buffer.write(value.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString().toUpperCase();
  }

  static Uint8List? _tryIpv6ToBytes(String address) {
    if (!address.contains(':')) {
      return null;
    }
    final List<String> left;
    final List<String> right;
    final int gap = address.indexOf('::');
    if (gap >= 0) {
      if (address.indexOf('::', gap + 2) >= 0) {
        return null;
      }
      left = gap == 0 ? const <String>[] : address.substring(0, gap).split(':');
      right = gap + 2 >= address.length
          ? const <String>[]
          : address.substring(gap + 2).split(':');
    } else {
      left = address.split(':');
      right = const <String>[];
    }
    if (left.any((String part) => part.isEmpty) ||
        right.any((String part) => part.isEmpty)) {
      return null;
    }
    final int missing = 8 - left.length - right.length;
    if (missing < 0 || (gap < 0 && missing != 0)) {
      return null;
    }
    final List<String> groups = <String>[
      ...left,
      ...List<String>.filled(missing, '0'),
      ...right,
    ];
    if (groups.length != 8) {
      return null;
    }
    final Uint8List bytes = Uint8List(16);
    for (int index = 0; index < 8; index += 1) {
      final int? value = int.tryParse(groups[index], radix: 16);
      if (value == null || value < 0 || value > 0xFFFF) {
        return null;
      }
      bytes[index * 2] = (value >> 8) & 0xFF;
      bytes[index * 2 + 1] = value & 0xFF;
    }
    return bytes;
  }

  static String _bytesToCanonicalIpv6(Uint8List bytes) {
    final List<int> groups = <int>[];
    for (int index = 0; index < 8; index += 1) {
      groups.add((bytes[index * 2] << 8) | bytes[index * 2 + 1]);
    }
    int bestStart = -1;
    int bestLength = 0;
    int runStart = -1;
    for (int index = 0; index <= 8; index += 1) {
      if (index < 8 && groups[index] == 0) {
        if (runStart < 0) {
          runStart = index;
        }
      } else if (runStart >= 0) {
        final int length = index - runStart;
        if (length > bestLength) {
          bestStart = runStart;
          bestLength = length;
        }
        runStart = -1;
      }
    }
    if (bestLength < 2) {
      bestStart = -1;
    }
    final StringBuffer out = StringBuffer();
    int index = 0;
    while (index < 8) {
      if (index == bestStart) {
        out.write('::');
        index += bestLength;
        continue;
      }
      if (out.isNotEmpty && !out.toString().endsWith(':')) {
        out.write(':');
      }
      out.write(groups[index].toRadixString(16).toUpperCase());
      index += 1;
    }
    final String rendered = out.toString();
    return rendered.isEmpty ? '::' : rendered;
  }
}
