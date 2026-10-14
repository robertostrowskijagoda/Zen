import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

void main() {
  const String address = '200:1111:2222:3333:4444:5555:6666:7777';

  test('there is one code: the QR holds the same short code', () {
    final PeerShareProfile? profile = PeerShareCodec.buildLocalProfile(
      address: address,
      displayName: 'Ada',
    );

    expect(profile, isNotNull);
    expect(profile!.address, address);
    expect(profile.shareId.replaceAll('-', '').length, 12);
    final String code = profile.inviteCode;
    // The QR code is a universal invite link: a page that opens Zen with
    // the code (or shows the downloads); the code sits after '#', so a
    // server never sees it.
    expect(
      profile.qrData,
      'https://robertostrowskijagoda.github.io/Zen/#${code.replaceAll('-', '')}',
    );
    // A link to the project page with the code works as well.
    expect(
      PeerShareCodec.inviteCodeFromLink(
        'https://github.com/robertostrowskijagoda/Zen#${code.replaceAll('-', '')}',
      ),
      isNotNull,
    );
    expect(profile.qrData, PeerShareCodec.inviteLinkForCode(code));

    final PeerDialTarget qrTarget = PeerShareCodec.parseTarget(profile.qrData);
    expect(qrTarget.address, address);
    expect(qrTarget.displayName, isEmpty, reason: 'the request brings it');
    expect(qrTarget.isToken, isTrue);
    // The code can be pulled back out of the link.
    expect(PeerShareCodec.inviteCodeFromLink(profile.qrData), isNotNull);
    expect(
      PeerShareCodec.inviteCodeFromLink('https://example.com/x#notacode'),
      isNull,
    );
    expect(
      PeerShareCodec.inviteCodeFromLink(PeerShareCodec.repositoryUrl),
      isNull,
    );

    // A link to another site with a code after '#' is not an invitation.
    expect(
      PeerShareCodec.inviteCodeFromLink(
        'https://example.com/zen#${code.replaceAll('-', '')}',
      ),
      isNull,
    );

    // 'zen://c/CODE' works; the old address+name form does not.
    final String qrLink = 'zen://c/${code.replaceAll('-', '')}';
    expect(PeerShareCodec.parseTarget(qrLink).address, address);
    expect(PeerShareCodec.parseTarget(qrLink).displayName, isEmpty);
    final String legacy =
        'zen://c/${base64Url.encode(utf8.encode('$address|Ada')).replaceAll('=', '')}';
    expect(
      () => PeerShareCodec.parseTarget(legacy),
      throwsA(isA<FormatException>()),
    );
  });

  test('the invite code is short and enough on its own', () {
    final String code = PeerShareCodec.inviteCodeForAddress(address)!;
    expect(
      RegExp(r'^[0-9A-Z]{5}(-[0-9A-Z]{5}){4}$').hasMatch(code),
      isTrue,
      reason: code,
    );
    final PeerDialTarget target = PeerShareCodec.parseTarget(code);
    expect(target.address, address);
    expect(target.displayName, isEmpty);

    // Typed by hand: lower case, spaces, O for 0 - all fine.
    final String sloppy = code
        .toLowerCase()
        .replaceAll('-', ' ')
        .replaceAll('0', 'o');
    expect(PeerShareCodec.parseTarget(sloppy).address, address);
    expect(PeerShareCodec.normalizeManualInput(sloppy), code);

    final PeerShareProfile profile = PeerShareCodec.buildLocalProfile(
      address: address,
      displayName: 'Ada',
    )!;
    expect(profile.inviteCode, code);
    expect(profile.shareText, code);
  });

  test('a mistyped invite code is caught instead of reaching a stranger', () {
    final String code = PeerShareCodec.inviteCodeForAddress(address)!;
    int typos = 0;
    int caught = 0;
    for (int i = 0; i < code.length; i++) {
      if (code[i] == '-') {
        continue;
      }
      final String swapped = code[i] == 'A' ? 'B' : 'A';
      final String typo = code.replaceRange(i, i + 1, swapped);
      typos++;
      if (PeerShareCodec.addressFromInviteCode(typo) == null) {
        caught++;
      }
    }
    // One checksum character: about 31 of every 32 slips are caught.
    expect(caught, greaterThanOrEqualTo(typos - 2));
  });

  test('every node address survives the invite code', () {
    for (final String a in <String>[
      '200::1',
      '201:ffff:ffff:ffff:ffff:ffff:ffff:ffff',
      '2ab:cd:ef:1:2:3:4:5',
    ]) {
      final String code = PeerShareCodec.inviteCodeForAddress(a)!;
      expect(
        PeerShareCodec.addressFromInviteCode(code),
        PeerShareCodec.normalizeAddress(a),
      );
    }
    // Subnet (0x03..) and non-mesh addresses have no code.
    expect(PeerShareCodec.inviteCodeForAddress('300::1'), isNull);
    expect(PeerShareCodec.inviteCodeForAddress('ada.ygg'), isNull);
  });

  test('friend code has exactly 12 characters in groups of 4', () {
    final String shareId = PeerShareCodec.shareIdForAddress(address);
    expect(shareId.contains('#'), isFalse);
    expect(shareId.replaceAll('-', '').length, 12);
    expect(
      RegExp(r'^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$').hasMatch(shareId),
      isTrue,
    );
  });

  test('normalizeAddress folds IPv6 case without touching fake ids', () {
    expect(
      PeerShareCodec.normalizeAddress('200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001'),
      '200:AAAA:BBBB:CCCC:DDDD:EEEE:FFFF:1',
    );
    expect(PeerShareCodec.normalizeAddress('ada.ygg'), 'ada.ygg');
    expect(
      PeerShareCodec.addressesEqual(
        '200:aaaa:bbbb:cccc:dddd:eeee:ffff:1',
        '200:AAAA:BBBB:CCCC:DDDD:EEEE:FFFF:1',
      ),
      isTrue,
    );
  });

  test('parseTarget accepts raw addresses and normalizes casing', () {
    final PeerDialTarget target = PeerShareCodec.parseTarget(
      '200:1111:2222:3333:4444:5555:6666:7777',
    );

    expect(target.address, address);
    expect(target.isToken, isFalse);
    expect(target.displayName, PeerShareCodec.shareIdForAddress(address));
  });

  test('older links that carry a name are refused', () {
    final String encodedPayload = base64Url
        .encode(
          utf8.encode(
            jsonEncode(<String, dynamic>{'v': 1, 'a': address, 'n': 'Ada'}),
          ),
        )
        .replaceAll('=', '');
    final String shareId = PeerShareCodec.shareIdForAddress(address);

    for (final String legacy in <String>[
      'zen://peer?d=$encodedPayload',
      '$shareId#$encodedPayload',
    ]) {
      expect(
        () => PeerShareCodec.parseTarget(legacy),
        throwsA(isA<FormatException>()),
        reason: legacy,
      );
    }
  });

  test('normalizeManualInput formats share ids with hyphens', () {
    expect(
      PeerShareCodec.normalizeManualInput('abcd1234efgh'),
      'ABCD-1234-EFGH',
    );
  });

  test('parseTarget rejects invalid values', () {
    expect(
      () => PeerShareCodec.parseTarget('not-a-peer'),
      throwsA(isA<FormatException>()),
    );
  });
}
