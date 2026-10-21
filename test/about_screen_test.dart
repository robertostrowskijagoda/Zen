import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/about/legal_documents.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/update/own_copy.dart';

void main() {
  Future<void> pumpAbout(
    WidgetTester tester,
    ThemeData theme, {
    bool storeBuild = false,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ownCopyCheckProvider.overrideWith(
            (Ref ref) async => const OwnCopyCheck(OwnCopyState.unknown),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          home: AboutScreen(storeBuild: storeBuild),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the direct build does not call itself anything else', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.dark());
    expect(find.byKey(const Key('about-store-build')), findsNothing);
  });

  testWidgets('only the info screen says it is the store build', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.dark(), storeBuild: true);
    expect(find.byKey(const Key('about-store-build')), findsOneWidget);
    expect(find.text('Wersja ze sklepu'), findsOneWidget);
  });

  testWidgets('the logo is black on light in the light theme', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.light());
    expect(find.byKey(const Key('about-logo-light')), findsOneWidget);
    expect(find.byKey(const Key('about-logo-dark')), findsNothing);
  });

  testWidgets('the logo is white on graphite in the dark theme', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.dark());
    expect(find.byKey(const Key('about-logo-dark')), findsOneWidget);
    expect(find.byKey(const Key('about-logo-light')), findsNothing);
  });

  Future<void> openSection(WidgetTester tester, String name) async {
    final Finder tile = find.byKey(Key('about-section-$name'));
    await tester.scrollUntilVisible(
      tile,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await tester.tap(tile);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('about-page')), findsOneWidget);
  }

  Finder pageList() => find
      .descendant(
        of: find.byKey(const Key('about-page-body')),
        matching: find.byType(Scrollable),
      )
      .first;

  testWidgets('a header, a short description and the sections — no wall of '
      'text', (WidgetTester tester) async {
    await pumpAbout(tester, ZenTheme.dark());
    expect(find.byKey(const Key('about-description')), findsOneWidget);
    // The author attribution notice (NOTICE 1.2) on the About screen itself.
    expect(find.byKey(const Key('about-attribution')), findsOneWidget);
    expect(
      find.textContaining('Zen by Robert Ostrowski-Jagoda'),
      findsOneWidget,
    );
    expect(find.textContaining(kDonationUrl), findsOneWidget);
    // Every section has its row (the list builds them as they scroll in).
    for (final AboutSection section in AboutSection.values) {
      await tester.scrollUntilVisible(
        find.byKey(Key('about-section-${section.name}')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.byKey(Key('about-section-${section.name}')),
        findsOneWidget,
        reason: section.name,
      );
    }
    expect(
      AboutSection.values.map((AboutSection s) => s.name),
      containsAllInOrder(<String>[
        'updates',
        'security',
        'licences',
        'documents',
        'contact',
        'support',
      ]),
    );
    // The long texts are on the section pages, not here.
    expect(find.text('JAK UŻYWAĆ'), findsNothing);
    expect(find.byKey(const Key('about-donate')), findsNothing);
    // Content is selectable.
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('"Czym jest Zen" tells how to use Zen', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.dark());
    await openSection(tester, 'intro');
    await tester.scrollUntilVisible(
      find.text('Dodaj znajomego'),
      300,
      scrollable: pageList(),
    );
    expect(find.text('JAK UŻYWAĆ'), findsOneWidget);
    expect(find.byType(SelectionArea), findsWidgets);
  });

  testWidgets('"Wersja i aktualizacje" shows the build and passes Zen on', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.dark());
    await openSection(tester, 'updates');
    expect(find.byKey(const Key('about-version')), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const Key('about-share-app')),
      300,
      scrollable: pageList(),
    );
    expect(find.text('Podaj Zen dalej'), findsOneWidget);
  });

  testWidgets('"Czym jest Zen" explains an own Yggdrasil bridge, with links', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.light());
    await openSection(tester, 'intro');
    await tester.scrollUntilVisible(
      find.byKey(const Key('about-public-peers')),
      300,
      scrollable: pageList(),
    );
    expect(
      find.byKey(const Key('about-own-bridge'), skipOffstage: false),
      findsOneWidget,
    );
    expect(kYggdrasilUrl, startsWith('https://yggdrasil-network.github.io'));
  });

  testWidgets('"Dokumenty" opens the privacy policy and the terms in the app', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.light());
    await openSection(tester, 'documents');
    expect(find.byKey(const Key('about-terms')), findsOneWidget);
    expect(find.byKey(const Key('about-privacy-policy')), findsOneWidget);
    expect(find.byKey(const Key('about-licence')), findsOneWidget);
    expect(
      kPrivacyPolicyUrl,
      'https://github.com/robertostrowskijagoda/Zen/blob/main/docs/PRIVACY.md',
    );
    expect(
      kTermsOfUseUrl,
      'https://github.com/robertostrowskijagoda/Zen/blob/main/docs/TERMS.md',
    );
    expect(LegalDocument.privacy.url, kPrivacyPolicyUrl);
    expect(LegalDocument.terms.url, kTermsOfUseUrl);
  });

  testWidgets('"Bezpieczeństwo i prywatność" says whether this copy is the '
      'official one', (WidgetTester tester) async {
    await pumpAbout(tester, ZenTheme.dark());
    await openSection(tester, 'security');
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('own-copy-unknown')),
      300,
      scrollable: pageList(),
    );
    expect(find.text('Nie można sprawdzić'), findsOneWidget);
  });

  testWidgets('"Wesprzyj Zen" has the collection', (WidgetTester tester) async {
    await pumpAbout(tester, ZenTheme.dark());
    await openSection(tester, 'support');
    expect(find.byKey(const Key('about-donate')), findsOneWidget);
  });

  testWidgets('"Licencje i podziękowania" opens the licences and the notice', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.dark());
    await openSection(tester, 'licences');
    expect(find.byKey(const Key('about-licenses')), findsOneWidget);
    expect(find.byKey(const Key('about-licence-notice')), findsOneWidget);
  });

  testWidgets('"Kontakt" says where to report a bug', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.dark());
    await openSection(tester, 'contact');
    expect(find.byKey(const Key('about-issues')), findsOneWidget);
    expect(kIssuesUrl, endsWith('/issues'));
  });
}
