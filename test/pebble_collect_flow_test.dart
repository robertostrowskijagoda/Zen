import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_hosting.dart';
import 'package:zen/src/features/pebbles/pebble_link.dart';
import 'package:zen/src/features/pebbles/pebble_service.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_code_screen.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_collect_flow.dart';
import 'package:zen/src/features/qr_sticker/presentation/zen_qr_view.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/qr_frame_decoder.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

// Collecting a pebble: from its link to the collection, saved at once from
// the card while the design is still on its way.

final class _NoPeers implements PebblePeers {
  @override
  String? accountOf(String address) => null;

  @override
  List<String> addressesOfAccount(String account) => const <String>[];

  @override
  List<String> friends() => const <String>[];

  @override
  bool isBlocked(String address) => false;

  @override
  bool isFriend(String address) => false;

  @override
  List<PebbleKeeperCandidate> keeperCandidates() =>
      const <PebbleKeeperCandidate>[];
}

void main() {
  late PebbleCard card;
  late PebbleCard forged;

  setUpAll(() async {
    final LedgerKeyPair kasia = await LedgerKeyPair.generate();
    card = await PebbleCard.sign(
      key: kasia,
      design: Uint8List.fromList(List<int>.filled(1000, 5)),
      createdSeconds: 1767225600,
      look: const PebbleCardLook(
        shape: 3,
        seed: 77,
        material: 4,
        mainColour: 0xCC2222,
        secondColour: 0x111111,
      ),
      name: 'Biedronka',
      note: 'niedaleko Wisły w Warszawie',
      authorName: 'Kasia',
    );
    final Uint8List bad = Uint8List.fromList(card.bytes);
    bad[bad.length - 1] ^= 1;
    forged = PebbleCard.decode(bad)!;
  });

  Future<PebbleService> pumpCollect(WidgetTester tester, PebbleCard c) async {
    final PebbleStore store = PebbleStore(MemoryLedgerDisk());
    final PebbleService service = PebbleService(
      store: store,
      hosting: PebbleHosting(
        transport: MemorySignalTransport(),
        store: store,
        peers: _NoPeers(),
        accountKey: () => null,
        serveCollected: () => true,
      ),
    );
    await tester.runAsync(service.start);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          pebbleServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => PebbleCollectScreen.open(context, c),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // The signature is checked off the frame clock.
    await tester.runAsync(() => c.verify());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('"Zbierz" saves the pebble at once with the finder\'s note', (
    WidgetTester tester,
  ) async {
    final PebbleService service = await pumpCollect(tester, card);
    expect(find.byKey(const Key('pebble-collect-screen')), findsOneWidget);
    expect(find.text('Biedronka'), findsOneWidget);
    expect(find.text('niedaleko Wisły w Warszawie'), findsOneWidget);
    expect(find.textContaining('Kasia'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('pebble-collect-note')),
      'pod mostem na bulwarach',
    );
    await tester.tap(find.byKey(const Key('pebble-collect-button')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final PebbleEntry? e = service.store.entry(card.id);
    expect(e, isNotNull);
    expect(e!.collected, isTrue);
    expect(e.findNote, 'pod mostem na bulwarach');
    expect(e.hasDesign, isFalse, reason: 'the design comes later');
    expect(e.foundAtMillis, isNotNull);
    // The stone's own screen, waiting for the full design.
    expect(find.byKey(const Key('pebble-detail-screen')), findsOneWidget);
    expect(find.byKey(const Key('pebble-detail-waiting')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.stop);
  });

  testWidgets('a sticker\'s QR card is collected at once; the note, the '
      'date and the signature come with the design', (
    WidgetTester tester,
  ) async {
    final PebbleCard qr = card.qrCard;
    final PebbleService service = await pumpCollect(tester, qr);
    expect(find.text('Biedronka'), findsOneWidget);
    expect(find.text('Kasia'), findsOneWidget, reason: 'no date yet');
    expect(find.text('niedaleko Wisły w Warszawie'), findsNothing);
    expect(find.byKey(const Key('pebble-collect-later')), findsOneWidget);
    expect(find.byKey(const Key('pebble-collect-invalid')), findsNothing);
    await tester.ensureVisible(find.byKey(const Key('pebble-collect-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pebble-collect-button')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final PebbleEntry? e = service.store.entry(card.id);
    expect(e!.collected, isTrue);
    expect(e.card, qr);
    expect(find.byKey(const Key('pebble-detail-screen')), findsOneWidget);
    // Not shown to friends until the signed card came.
    expect(
      pebbleProfileBody(
        created: const <PebbleEntry>[],
        collected: <PebbleEntry>[e],
      )['k'],
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.stop);
  });

  testWidgets('"Pokaż kod" shows the pebble\'s code on white, and the app\'s '
      'scanner reads it from the screen like a printed one', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final PebbleService service = await pumpCollect(tester, card);
    await tester.tap(find.byKey(const Key('pebble-collect-button')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pebble-show-code-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pebble-code-screen')), findsOneWidget);
    final ZenQrView view = tester.widget<ZenQrView>(
      find.byKey(const Key('pebble-code-qr')),
    );
    expect(view.data, pebbleWebLink(card));
    // Large: most of the screen's width.
    expect(
      tester.getSize(find.byKey(const Key('pebble-code-qr'))).width,
      greaterThan(300),
    );
    final RenderRepaintBoundary boundary = tester.renderObject(
      find.descendant(
        of: find.byKey(const Key('pebble-code-qr')),
        matching: find.byType(RepaintBoundary),
      ),
    );
    final String? read = await tester.runAsync<String?>(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 3);
      final ByteData rgba = (await image.toByteData())!;
      final Uint8List px = rgba.buffer.asUint8List();
      final Uint8List gray = Uint8List(image.width * image.height);
      for (int i = 0; i < gray.length; i++) {
        gray[i] =
            (px[4 * i] * 77 + px[4 * i + 1] * 150 + px[4 * i + 2] * 29) >> 8;
      }
      final LumaFrame frame = LumaFrame(
        width: image.width,
        height: image.height,
        bytes: gray,
      );
      image.dispose();
      return decodeQrLuma(frame);
    });
    expect(read, pebbleWebLink(card));
    // What the scanner read opens the same pebble.
    expect(pebbleCardFromLink(read), card.qrCard);
    final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
      id: 'scan',
      routeKey: read,
    );
    expect(intent?.target, RuntimeRouteTarget.pebble);
    expect(PebbleCodeScreen(card: card).card, card);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.stop);
  });

  testWidgets('a forged card cannot be collected', (WidgetTester tester) async {
    final PebbleService service = await pumpCollect(tester, forged);
    expect(find.byKey(const Key('pebble-collect-invalid')), findsOneWidget);
    expect(find.byKey(const Key('pebble-collect-button')), findsNothing);
    expect(service.store.entry(forged.id), isNull);
    expect(
      await tester.runAsync(() => service.collect(forged)),
      PebbleCollectResult.invalid,
    );
    expect(service.store.entry(forged.id), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(service.stop);
  });

  test('pebble links open the collecting screen', () {
    for (final String link in <String>[
      pebbleWebLink(card),
      pebbleAppLink(card),
    ]) {
      final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
        id: 'x',
        routeKey: link,
      );
      expect(intent?.target, RuntimeRouteTarget.pebble, reason: link);
      expect(pebbleCardFromLink(intent!.rawInput), card.qrCard);
    }
    expect(
      runtimeRouteIntentFromRouteKey(id: 'x', routeKey: 'zen://pebble#zzz'),
      isNull,
    );
    expect(
      runtimeRouteIntentFromRouteKey(
        id: 'x',
        routeKey: buildPebblesRouteKey(),
      )?.target,
      RuntimeRouteTarget.pebbles,
    );
    // The invitation page is still an invitation, not a pebble.
    expect(
      runtimeRouteIntentFromRouteKey(
        id: 'x',
        routeKey: 'https://robertostrowskijagoda.github.io/Zen/k/',
      ),
      isNull,
    );
  });
}
