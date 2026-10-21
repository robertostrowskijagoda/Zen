import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_concept.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_retro.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Every kit piece that changes with the look, on one screen.
Widget _kitScreen() {
  return Scaffold(
    appBar: const ZenSectionBar(title: 'Tablica'),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: <Widget>[
        const ZenSection('Sekcja', action: 'Więcej'),
        const ZenHero(title: 'Hero', text: 'Tekst', icon: Icons.bolt),
        const ZenTile(icon: Icons.chat, title: 'Kafelek', badge: '3'),
        const ZenTile(icon: Icons.chat, title: 'Kafelek', badge: 'nowe'),
        const ZenCard(child: Text('Karta')),
        const ZenCard(tone: Colors.pink, child: Text('Wyróżniona')),
        const ZenGroup(
          children: <Widget>[
            ListTile(title: Text('A')),
            ListTile(title: Text('B')),
          ],
        ),
        const ZenInfo(text: 'Informacja'),
        const Row(
          children: <Widget>[
            ZenPill(text: 'pigułka'),
            ZenPill(text: 'pełna', filled: true),
            ZenCountBadge(7),
            ZenCountBadge(120),
            ZenBlobAvatar(name: 'Ada', online: true),
          ],
        ),
        const ZenRailTabFrame(
          selected: true,
          padding: EdgeInsets.all(10),
          child: Icon(Icons.home),
        ),
        const ZenRailTabFrame(
          selected: false,
          danger: true,
          child: Icon(Icons.warning),
        ),
        ZenBreathingGlow(
          child: IconButton.filled(
            onPressed: () {},
            icon: const Icon(Icons.send),
          ),
        ),
        FilledButton(onPressed: () {}, child: const Text('Główny')),
        OutlinedButton(onPressed: () {}, child: const Text('Drugi')),
        const TextField(),
        const ZenEmpty(
          icon: Icons.inbox,
          title: 'Pusto',
          text: 'Nic tu nie ma',
        ),
      ],
    ),
  );
}

Future<void> _pumpLook(WidgetTester tester, AppPalette palette) async {
  tester.view.physicalSize = const Size(412 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
      ],
      child: MaterialApp(
        theme: ZenTheme.dark(AppSettings.defaultAccentTheme, palette),
        home: _kitScreen(),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  test('each palette carries its component character', () {
    for (final AppPalette palette in AppPalette.values) {
      final ThemeData theme = ZenTheme.dark(
        AppSettings.defaultAccentTheme,
        palette,
      );
      final ZenLook? look = theme.extension<ZenLook>();
      expect(look, ZenLook.forPalette(palette), reason: '$palette');
    }
    expect(ZenLook.forPalette(AppPalette.classic), ZenLook.classic);
    expect(ZenLook.forPalette(AppPalette.neon).outlined, isTrue);
    expect(ZenLook.forPalette(AppPalette.winamp).bevelled, isTrue);
    expect(ZenLook.forPalette(AppPalette.winamp).numbers, ZenNumberStyle.led);
    expect(AppPalette.winamp.darkOnly, isTrue);
    expect(AppPalette.neon.darkOnly, isFalse);

    PageTransitionsBuilder? pageOf(AppPalette palette) => ZenTheme.dark(
      AppSettings.defaultAccentTheme,
      palette,
    ).pageTransitionsTheme.builders[TargetPlatform.android];
    expect(pageOf(AppPalette.neon), isA<ZenNeonWipeTransitionsBuilder>());
    expect(pageOf(AppPalette.winamp), isA<ZenSteppedPageTransitionsBuilder>());
    expect(pageOf(AppPalette.calm), isA<ZenSoftPageTransitionsBuilder>());
    // Klasyczny keeps the platform transitions.
    expect(
      pageOf(AppPalette.classic),
      isNot(isA<ZenSoftPageTransitionsBuilder>()),
    );
  });

  test('Neon is black with one cyan and one magenta, few colours', () {
    final ZenColors neon = ZenColors.forPalette(
      AppPalette.neon,
      AppSettings.defaultAccentTheme,
      Brightness.dark,
    );
    expect(neon.background, const Color(0xFF000000));
    expect(neon.gradient, 0);
    expect(neon.duotone, isTrue);
    final Set<Color> tones = <Color>{
      for (int i = 0; i < 16; i++) zenTone(neon, i),
    };
    expect(tones, <Color>{neon.accent, neon.accentSecondary});
  });

  test('the bevel frame lerps, scales and keeps its square shape', () {
    const ZenBevelBorder a = ZenBevelBorder(
      light: Color(0xFFFFFFFF),
      dark: Color(0xFF000000),
    );
    const ZenBevelBorder b = ZenBevelBorder(
      light: Color(0xFF000000),
      dark: Color(0xFFFFFFFF),
      width: 3,
      sunken: true,
    );
    final ZenBevelBorder mid = b.lerpFrom(a, 0.5)! as ZenBevelBorder;
    expect(mid.width, 2);
    expect(mid.sunken, isTrue);
    expect((a.scale(2) as ZenBevelBorder).width, 2);
    expect(a.copyWith(), a);
    const Rect rect = Rect.fromLTWH(0, 0, 40, 20);
    expect(a.getOuterPath(rect).getBounds(), rect);
    expect(a.getInnerPath(rect).getBounds(), rect.deflate(1));
  });

  for (final AppPalette palette in <AppPalette>[
    AppPalette.classic,
    AppPalette.neon,
    AppPalette.winamp,
  ]) {
    testWidgets('the kit builds in ${palette.name}', (
      WidgetTester tester,
    ) async {
      await _pumpLook(tester, palette);
      expect(find.byKey(const Key('section-title')), findsOneWidget);
      expect(find.text('Kafelek'), findsNWidgets(2));
      expect(
        find.byType(ZenSpectrumStrip),
        palette == AppPalette.winamp ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(ZenLedNumber),
        palette == AppPalette.winamp ? findsWidgets : findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the neon and retro motion runs and ends without leftovers', (
    WidgetTester tester,
  ) async {
    final bool previous = ZenMotion.enabled;
    ZenMotion.enabled = true;
    addTearDown(() => ZenMotion.enabled = previous);
    for (final AppPalette palette in <AppPalette>[
      AppPalette.neon,
      AppPalette.winamp,
    ]) {
      await _pumpLook(tester, palette);
      // Flicker-on, breathing glow, the drifting field and the sweep.
      for (int frame = 0; frame < 90; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(
        find.byType(ZenFlickerOn),
        palette == AppPalette.neon ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('the neon wipe pushes and pops a screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(AppSettings.defaultAccentTheme, AppPalette.neon),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Drugi ekran')),
                ),
              ),
              child: const Text('Dalej'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Dalej'));
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Drugi ekran'), findsOneWidget);
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('Drugi ekran'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('LED digits paint every character they know', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: ZenLedNumber('0123456789+- ', color: Colors.green),
        ),
      ),
    );
    final Size size = tester.getSize(find.byType(ZenLedNumber));
    expect(size.height, 14);
    expect(size.width, greaterThan(ZenLedNumber.widthOf(12, 14)));
    expect(tester.takeException(), isNull);
  });
}
