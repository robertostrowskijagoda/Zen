import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';

void main() {
  Future<void> pumpAbout(WidgetTester tester, ThemeData theme) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: theme, home: const AboutScreen()),
    );
    await tester.pump();
  }

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

  testWidgets('about tells how to use Zen and how to pass it on', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.dark());
    final Finder list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('JAK UŻYWAĆ'),
      300,
      scrollable: list,
    );
    await tester.scrollUntilVisible(
      find.text('Dodaj znajomego'),
      300,
      scrollable: list,
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('about-share-app')),
      300,
      scrollable: list,
    );
    expect(find.byKey(const Key('about-share-app')), findsOneWidget);
    expect(find.text('Podaj Zen dalej'), findsOneWidget);
  });

  testWidgets('about explains running an own Yggdrasil bridge, with links', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.light());
    final Finder list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('about-public-peers')),
      300,
      scrollable: list,
    );
    await tester.pump();
    expect(
      find.byKey(const Key('about-own-bridge'), skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byKey(const Key('about-public-peers')), findsOneWidget);
    expect(kYggdrasilUrl, startsWith('https://yggdrasil-network.github.io'));
  });

  testWidgets('about links the privacy policy and the terms', (
    WidgetTester tester,
  ) async {
    await pumpAbout(tester, ZenTheme.light());
    final Finder list = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('about-privacy-policy')),
      300,
      scrollable: list,
    );
    expect(find.byKey(const Key('about-privacy-policy')), findsOneWidget);
    await tester.pump();
    expect(
      find.byKey(const Key('about-terms'), skipOffstage: false),
      findsOneWidget,
    );
    expect(
      kPrivacyPolicyUrl,
      'https://github.com/robertostrowskijagoda/Zen/blob/main/docs/PRIVACY.md',
    );
    expect(
      kTermsOfUseUrl,
      'https://github.com/robertostrowskijagoda/Zen/blob/main/docs/TERMS.md',
    );
  });
}
