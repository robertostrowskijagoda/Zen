import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/thanks_model.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('a card needs a reason and has a length limit', () {
    expect(() => thanksBody('acc', '  '), throwsArgumentError);
    expect(
      () => thanksBody('acc', 'x' * (kMaxThanksChars + 1)),
      throwsArgumentError,
    );
    expect(thanksBody('acc', ' Za lodówkę '), <String, dynamic>{
      'to': 'acc',
      'text': 'Za lodówkę',
    });
  });

  test('cards reach friends, are capped per month and never to self', () async {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final Map<String, _Linked> nodes = <String, _Linked>{};
    final _Linked ta = nodes[ada] = _Linked(ada, nodes);
    final _Linked tb = nodes[bob] = _Linked(bob, nodes);
    await ta.start();
    await tb.start();
    final LedgerNode a = LedgerNode(
      transport: ta,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[bob],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    final LedgerNode b = LedgerNode(
      transport: tb,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[ada],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.start();
    await b.start();
    await _settle();

    final int now = DateTime.now().millisecondsSinceEpoch;
    expect(thanksLeft(b, a.account, nowMillis: now), kThanksPerWindow);
    for (int i = 0; i < kThanksPerWindow + 2; i++) {
      await b.publish(
        kThanksKind,
        thanksBody(a.account, 'Dzięki $i'),
        spaceKind: 'acts',
      );
    }
    // Thanking yourself does not count.
    await a.publish(
      kThanksKind,
      thanksBody(a.account, 'Jestem super'),
      spaceKind: 'acts',
    );
    await _settle();

    expect(thanksLeft(b, a.account, nowMillis: now + 1000), 0);
    final List<ThanksCard> cards = thanksFor(
      a,
      a.account,
      nameOf: (String address) => address == bob ? 'Bob' : '?',
    );
    expect(cards, hasLength(kThanksPerWindow));
    expect(cards.every((ThanksCard c) => c.fromLabel == 'Bob'), isTrue);
    expect(
      cards.map((ThanksCard c) => c.text),
      containsAll(<String>['Dzięki 0', 'Dzięki 1', 'Dzięki 2']),
    );
    // A month later the limit is free again.
    expect(
      thanksLeft(
        b,
        a.account,
        nowMillis: now + kThanksWindow.inMilliseconds + 60000,
      ),
      kThanksPerWindow,
    );
  });

  testWidgets('own profile shows posts and the edit button', (
    WidgetTester tester,
  ) async {
    // A phone-tall screen: the profile header sits above the posts.
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
        ],
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(ProfileScreen)),
    );
    final LedgerNode node = container.read(ledgerNodeProvider)!;
    // Start mixes real async (keys, disk) and the fake clock.
    for (int i = 0; i < 20 && !node.isReady; i++) {
      await tester.runAsync(() => _settle());
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(node.isReady, isTrue);
    await tester.runAsync(() async {
      await node.publish(kPostKind, newPostBody('Mój pierwszy'));
      await _settle();
    });
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const Key('profile-edit')), findsOneWidget);
    expect(find.text('Mój pierwszy'), findsOneWidget);

    await tester.tap(find.text('Podziękowania'));
    await tester.pumpAndSettle();
    expect(find.text('Jeszcze nikt nie podziękował.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });
}
