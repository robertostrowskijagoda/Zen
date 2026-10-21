import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/public_peers.dart';
import 'package:zen/src/features/settings/presentation/public_peers_section.dart';

final class _Bridge implements PublicPeersBridge {
  final List<List<String>?> applied = <List<String>?>[];

  @override
  List<PublicPeer> builtIn() => const <PublicPeer>[
    PublicPeer(uri: 'tls://203.0.113.1:443', country: 'Poland'),
  ];

  @override
  void apply(List<String>? uris) => applied.add(uris);

  @override
  Future<Map<String, PublicPeerProbe>> probe(List<String> uris) async =>
      <String, PublicPeerProbe>{
        'tls://203.0.113.1:443': const PublicPeerProbe(
          reachable: true,
          latencyMs: 12,
        ),
        'tcp://203.0.113.5:1514': const PublicPeerProbe(reachable: false),
      };
}

final class _Store implements PublicPeersStore {
  PublicPeerList? kept;

  @override
  Future<PublicPeerList?> load() async => kept;

  @override
  Future<void> save(PublicPeerList list) async {
    kept = list.custom ? list : null;
  }
}

void main() {
  testWidgets('add, check, switch off and restore public peers', (
    WidgetTester tester,
  ) async {
    final _Bridge bridge = _Bridge();
    final _Store store = _Store();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          publicPeersBridgeProvider.overrideWithValue(bridge),
          publicPeersStoreProvider.overrideWithValue(store),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: PublicPeersSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lista domyślna'), findsOneWidget);
    expect(find.text('tls://203.0.113.1:443'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('public-peers-input')),
      'http://example.org',
    );
    await tester.tap(find.byKey(const Key('public-peers-add')));
    await tester.pumpAndSettle();
    expect(
      find.text('Obsługiwane są tls://, quic://, tcp://, ws:// i wss://.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const Key('public-peers-input')),
      'tcp://203.0.113.5:1514',
    );
    await tester.tap(find.byKey(const Key('public-peers-add')));
    await tester.pumpAndSettle();
    expect(find.text('tcp://203.0.113.5:1514'), findsOneWidget);
    expect(find.text('Twoja lista: 2 włączone węzły'), findsOneWidget);
    expect(bridge.applied.last, <String>[
      'tls://203.0.113.1:443',
      'tcp://203.0.113.5:1514',
    ]);
    expect(find.text('Łącze bez szyfrowania'), findsOneWidget);

    await tester.tap(find.byKey(const Key('public-peers-check')));
    await tester.pumpAndSettle();
    expect(find.text('Poland · 12 ms'), findsOneWidget);
    expect(find.text('Nie odpowiada · Łącze bez szyfrowania'), findsOneWidget);

    final Finder tcpRow = find.byKey(
      const ValueKey<String>('public-peer-tcp://203.0.113.5:1514'),
    );
    await tester.tap(
      find.descendant(of: tcpRow, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(bridge.applied.last, <String>['tls://203.0.113.1:443']);

    // The last peer on cannot be switched off.
    final Finder tlsRow = find.byKey(
      const ValueKey<String>('public-peer-tls://203.0.113.1:443'),
    );
    await tester.tap(
      find.descendant(of: tlsRow, matching: find.byType(Switch)),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Zostaw włączony co najmniej jeden węzeł.'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.byKey(const Key('public-peers-restore')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('public-peers-restore')));
    await tester.pumpAndSettle();
    expect(find.text('Lista domyślna'), findsOneWidget);
    expect(find.text('tcp://203.0.113.5:1514'), findsNothing);
    expect(bridge.applied.last, isNull);
    expect(store.kept, isNull);
  });
}
