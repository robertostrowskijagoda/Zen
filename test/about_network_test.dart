import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/census/census_providers.dart';
import 'package:zen/src/features/census/network_census.dart';
import 'package:zen/src/features/update/own_copy.dart';

void main() {
  Future<ProviderContainer> pumpAbout(
    WidgetTester tester, {
    NetworkCensus? census,
  }) async {
    final ProviderContainer container = ProviderContainer(
      overrides: [
        ownCopyCheckProvider.overrideWith(
          (Ref ref) async => const OwnCopyCheck(OwnCopyState.unknown),
        ),
        if (census != null) networkCensusProvider.overrideWithValue(census),
      ],
    );
    addTearDown(container.dispose);
    if (census != null) {
      // The census runs (it starts with the ledger in the app).
      container.read(networkCensusProvider);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AboutScreen(storeBuild: false)),
      ),
    );
    await tester.pump();
    return container;
  }

  testWidgets('nothing about the network while the census does not run', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester);
    expect(find.byKey(const Key('about-network')), findsNothing);
  });

  testWidgets('the estimate of people in the network is shown', (
    WidgetTester tester,
  ) async {
    final NetworkCensus census = NetworkCensus(
      disk: MemoryLedgerDisk(),
      send: (String to, Map<String, dynamic> payload) async {},
      isFriend: (String address) => false,
      secret: () => Uint8List.fromList(List<int>.filled(32, 3)),
      now: () => DateTime.utc(2026, 10, 15).millisecondsSinceEpoch,
    );
    addTearDown(census.dispose);
    await census.load();
    await pumpAbout(tester, census: census);
    expect(find.byKey(const Key('about-network')), findsOneWidget);
    expect(find.text('Sieć Zen'), findsOneWidget);
    expect(find.text('Ok. 1 osoba w sieci Zen (szacunek)'), findsOneWidget);
    expect(find.byKey(const Key('about-network-pyramid')), findsNothing);
  });
}
