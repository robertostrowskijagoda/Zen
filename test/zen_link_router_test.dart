import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_link.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/zen_link_router.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

// Every QR code scanned in the app goes through one router: Zen's links
// (which keep the github.io address for a phone's own camera) open their
// screen in the app, never the browser; anything else is left to the
// screen that scanned it.

const String _ada = '200:1234:5678:9abc:def0:1234:5678:9abc';
const String _base = 'https://robertostrowskijagoda.github.io/Zen/';

final class _Scanner implements PeerQrScanner {
  _Scanner(this.text);

  final String text;

  @override
  bool get isSupported => true;

  @override
  Future<String?> scan(BuildContext context) async => text;
}

void main() {
  late PebbleCard pebble;
  late FlatDoorCode door;
  late String invite;

  setUpAll(() async {
    pebble = await PebbleCard.sign(
      key: await LedgerKeyPair.generate(),
      design: Uint8List.fromList(List<int>.filled(500, 4)),
      createdSeconds: 1790000000,
      look: const PebbleCardLook(
        shape: 2,
        seed: 9,
        material: 1,
        mainColour: 0x224466,
        secondColour: 0xEEDDCC,
      ),
      name: 'Sowa',
      note: 'w parku',
      authorName: 'Kasia',
    );
    door = FlatDoorCode(
      key: base64Url.encode(List<int>.filled(32, 7)),
      door: 'abc',
      inbox: _ada,
      name: 'Nowakowie, m. 12',
    );
    invite = PeerShareCodec.buildLocalProfile(address: _ada)!.qrData;
  });

  RuntimeRouteTarget? target(String text) => zenLinkIntent(text)?.target;

  test('an invitation in every form: adding the friend', () {
    final String code = PeerShareCodec.inviteCodeForAddress(_ada)!;
    for (final String link in <String>[
      invite,
      '$_base#${code.replaceAll('-', '')}',
      'https://github.com/robertostrowskijagoda/Zen#$code',
      'zen://c/$code',
      '  $invite  ',
    ]) {
      expect(target(link), RuntimeRouteTarget.addFriend, reason: link);
    }
  });

  test('a door sticker in every form: knocking', () {
    for (final String link in <String>[
      door.toLink(),
      door.toQr(),
      'zen://m/${door.encode()}',
    ]) {
      final RuntimeRouteIntent? intent = zenLinkIntent(link);
      expect(intent?.target, RuntimeRouteTarget.flatDoor, reason: link);
      expect(FlatDoorCode.parse(intent!.rawInput!)?.name, 'Nowakowie, m. 12');
    }
  });

  test('a pebble in every form: collecting', () {
    for (final String link in <String>[
      pebbleWebLink(pebble),
      pebbleAppLink(pebble),
      // The first test builds' stickers: the whole card in base64url.
      '${_base}k/#${pebble.text}',
      'zen://pebble#${pebble.text}',
      pebbleWebLink(pebble).replaceFirst('/k/#', '/k#'),
    ]) {
      final RuntimeRouteIntent? intent = zenLinkIntent(link);
      expect(intent?.target, RuntimeRouteTarget.pebble, reason: link);
      expect(pebbleCardFromLink(intent!.rawInput)?.id, pebble.id);
    }
  });

  test('the install and the other pages: their screens in the app', () {
    expect(target('${_base}install/'), RuntimeRouteTarget.installGuide);
    for (final String system in <String>[
      'android',
      'iphone',
      'windows',
      'macos',
      'linux',
    ]) {
      final RuntimeRouteIntent? intent = zenLinkIntent(
        '${_base}install/$system/',
      );
      expect(intent?.target, RuntimeRouteTarget.installGuide);
      expect(intent!.rawInput, system);
    }
    for (final String page in <String>[
      _base,
      'https://robertostrowskijagoda.github.io/Zen',
      '${_base}about/',
      '${_base}features/',
      '${_base}guide/',
      '${_base}support/',
      '${_base}promo/',
      '$_base#get',
      'https://github.com/robertostrowskijagoda/Zen',
    ]) {
      expect(target(page), RuntimeRouteTarget.about, reason: page);
    }
  });

  test('zen:// links lead where they lead', () {
    expect(target('zen://pebbles'), RuntimeRouteTarget.pebbles);
    expect(target('zen://updates'), RuntimeRouteTarget.updates);
    expect(target('zen://feed?f=pyramid'), RuntimeRouteTarget.feed);
    // A scanned call link never answers a call.
    final RuntimeRouteIntent? call = zenLinkIntent(
      'zen://call/200:1::1?accept=1',
    );
    expect(call?.target, RuntimeRouteTarget.call);
    expect(call!.autoAcceptCall, isFalse);
  });

  test('anything else is no Zen link: the screen keeps its own answer', () {
    for (final String text in <String>[
      '',
      'hello',
      'https://example.com/',
      'https://example.com/Zen/k/#${pebble.linkText}',
      '${_base}k/',
      '${_base}m',
      '${_base}k/#123',
      'zen://pebble#zzz',
      'zen-home:abc',
      'zen-key:ABCD',
      'mailto:a@b.c',
    ]) {
      expect(zenLinkIntent(text), isNull, reason: text);
    }
  });

  group('a scanner on any screen', () {
    Future<(String?, RuntimeRouteIntent?)> scan(
      WidgetTester tester,
      String scanned, {
      required bool Function(String) accepts,
    }) async {
      String? got;
      final ProviderContainer container = ProviderContainer(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          peerQrScannerProvider.overrideWithValue(_Scanner(scanned)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Consumer(
              builder: (BuildContext context, WidgetRef ref, _) => TextButton(
                onPressed: () async {
                  got = await scanZenCode(context, ref, accepts: accepts);
                },
                child: const Text('scan'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('scan'));
      await tester.pumpAndSettle();
      return (
        got,
        container.read(socialHubControllerProvider).pendingLaunchIntent,
      );
    }

    testWidgets('what the screen wants comes back to it', (
      WidgetTester tester,
    ) async {
      final String link = pebbleWebLink(pebble);
      final (String? got, RuntimeRouteIntent? launched) = await scan(
        tester,
        link,
        accepts: isPebbleLink,
      );
      expect(got, link);
      expect(launched, isNull);
    });

    testWidgets('another Zen link opens its screen in the app instead', (
      WidgetTester tester,
    ) async {
      // A door sticker scanned in the pebbles' scanner.
      final (String? got, RuntimeRouteIntent? launched) = await scan(
        tester,
        door.toLink(),
        accepts: isPebbleLink,
      );
      expect(got, isNull);
      expect(launched?.target, RuntimeRouteTarget.flatDoor);
    });

    testWidgets('anything else comes back for the screen\'s own message', (
      WidgetTester tester,
    ) async {
      final (String? got, RuntimeRouteIntent? launched) = await scan(
        tester,
        'https://example.com/',
        accepts: isPebbleLink,
      );
      expect(got, 'https://example.com/');
      expect(launched, isNull);
    });
  });
}
