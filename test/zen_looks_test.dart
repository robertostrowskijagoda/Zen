import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_backdrop.dart';
import 'package:zen/src/app/theme/zen_concept.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_palettes.dart';
import 'package:zen/src/app/theme/zen_retro.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Every kit piece and Material component that changes with the look, on
/// one screen.
Widget _kitScreen() {
  return DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: const ZenSectionBar(
        title: 'Tablica',
        bottom: TabBar(
          tabs: <Widget>[
            Tab(text: 'Karta A'),
            Tab(text: 'Karta B'),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {},
        child: const Icon(Icons.add),
      ),
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
          const ZenDivider(),
          const ZenInfo(text: 'Informacja'),
          const Wrap(
            children: <Widget>[
              ZenPill(text: 'pigułka'),
              ZenPill(text: 'pełna', filled: true),
              ZenCountBadge(7),
              ZenCountBadge(120),
              ZenBlobAvatar(name: 'Ada', online: true),
              ZenBadge('znak'),
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
          const FilledButton(onPressed: null, child: Text('Wyłączony')),
          ElevatedButton(onPressed: () {}, child: const Text('Uniesiony')),
          OutlinedButton(onPressed: () {}, child: const Text('Drugi')),
          TextButton(onPressed: () {}, child: const Text('Tekst')),
          const TextField(decoration: InputDecoration(labelText: 'Pole')),
          Chip(label: const Text('Chip'), onDeleted: () {}),
          FilterChip(
            label: const Text('Filtr'),
            selected: true,
            onSelected: (_) {},
          ),
          Switch(value: true, onChanged: (_) {}),
          Checkbox(value: true, onChanged: (_) {}),
          Slider(value: 0.4, onChanged: (_) {}),
          const LinearProgressIndicator(value: 0.5),
          const ZenEmpty(
            icon: Icons.inbox,
            title: 'Pusto',
            text: 'Nic tu nie ma',
          ),
        ],
      ),
    ),
  );
}

Future<void> _pumpLook(
  WidgetTester tester,
  AppPalette palette, {
  Brightness brightness = Brightness.dark,
}) async {
  tester.view.physicalSize = const Size(412 * 3, 2800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
      ],
      child: MaterialApp(
        theme: ZenTheme.forPalette(
          palette,
          AppSettings.defaultAccentTheme,
          brightness,
        ),
        builder: (BuildContext context, Widget? child) =>
            ZenBackdropHost(child: child ?? const SizedBox.shrink()),
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
    expect(ZenLook.forPalette(AppPalette.player).bevelled, isTrue);
    expect(ZenLook.forPalette(AppPalette.player).numbers, ZenNumberStyle.led);

    PageTransitionsBuilder? pageOf(AppPalette palette) => ZenTheme.dark(
      AppSettings.defaultAccentTheme,
      palette,
    ).pageTransitionsTheme.builders[TargetPlatform.android];
    expect(pageOf(AppPalette.neon), isA<ZenNeonWipeTransitionsBuilder>());
    // The player sits on brushed metal now: its stepped fade, with the page
    // below fading out.
    expect(
      (pageOf(AppPalette.player)! as ZenFadeBehindTransitionsBuilder).inner,
      isA<ZenSteppedPageTransitionsBuilder>(),
    );
    PageTransitionsBuilder? innerOf(AppPalette p) =>
        (pageOf(p)! as ZenFadeBehindTransitionsBuilder).inner;
    expect(innerOf(AppPalette.cipher), isA<ZenGlitchPageTransitionsBuilder>());
    expect(
      innerOf(AppPalette.lightcycle),
      isA<ZenStreakPageTransitionsBuilder>(),
    );
    expect(innerOf(AppPalette.deepSea), isA<ZenBubblePageTransitionsBuilder>());
    expect(pageOf(AppPalette.calm), isA<ZenSoftPageTransitionsBuilder>());
    // Pages over a backdrop fade the page below out.
    expect(pageOf(AppPalette.rain), isA<ZenFadeBehindTransitionsBuilder>());
    expect(pageOf(AppPalette.grid), isA<ZenFadeBehindTransitionsBuilder>());
    // Klasyczny keeps the platform transitions.
    expect(
      pageOf(AppPalette.classic),
      isNot(isA<ZenSoftPageTransitionsBuilder>()),
    );
  });

  test('every category has several palettes, every palette one category', () {
    final Set<AppPalette> seen = <AppPalette>{};
    for (final ZenThemeCategory category in ZenThemeCategory.values) {
      expect(
        category.palettes.length,
        greaterThanOrEqualTo(3),
        reason: '$category',
      );
      expect(category.label, isNotEmpty);
      seen.addAll(category.palettes);
    }
    expect(seen, AppPalette.values.toSet());
    expect(
      ZenThemeCategory.cool.palettes,
      containsAll(<AppPalette>[
        AppPalette.player,
        AppPalette.rain,
        AppPalette.grid,
      ]),
    );
    expect(
      ZenPalettes.categoryOf(AppSettings.defaultPalette),
      ZenThemeCategory.classic,
    );
    expect(AppSettings.defaultPalette, AppPalette.classic);
  });

  test('the looks differ in more than colour', () {
    final ZenLook grid = ZenLook.forPalette(AppPalette.grid);
    final ZenLook rain = ZenLook.forPalette(AppPalette.rain);
    final ZenLook player = ZenLook.forPalette(AppPalette.player);
    final ZenLook onyx = ZenLook.forPalette(AppPalette.onyx);
    final ZenLook pearl = ZenLook.forPalette(AppPalette.pearl);
    final ZenLook mist = ZenLook.forPalette(AppPalette.mist);
    // Sharp neon grid: square corners, glowing lines, a floor grid.
    expect(grid.sharp, isTrue);
    expect(grid.borders, ZenBorderStyle.glow);
    expect(grid.backdrop, ZenBackdrop.grid);
    expect(grid.buttons, ZenButtonShape.square);
    // Digital rain: a terminal.
    expect(rain.backdrop, ZenBackdrop.rain);
    expect(rain.header, ZenHeaderStyle.prompt);
    expect(rain.fields, ZenFieldStyle.underline);
    // The player: bevelled chrome.
    expect(player.borders, ZenBorderStyle.bevel);
    expect(player.buttons, ZenButtonShape.bevel);
    expect(player.nav, ZenNavStyle.bevel);
    // Elegant: double lines, glass.
    expect(onyx.borders, ZenBorderStyle.doubleLine);
    expect(pearl.surfaces, ZenSurfaceStyle.glass);
    expect(pearl.backdrop, ZenBackdrop.aurora);
    // Toned down: round and borderless.
    expect(mist.borders, ZenBorderStyle.none);
    expect(mist.corner, greaterThan(1));

    // Shapes follow the corner scale.
    final ZenColors c = ZenColors.forPalette(
      AppPalette.grid,
      AppSettings.defaultAccentTheme,
      Brightness.dark,
    );
    expect(grid.br(22), BorderRadius.zero);
    expect(ZenLook.classic.br(22), BorderRadius.circular(22));
    expect(player.panelShape(c), isA<ZenBevelBorder>());
    expect(onyx.panelShape(c), isA<ZenDoubleBorder>());
    expect(player.buttonBorder(c, pressed: true), isA<ZenBevelBorder>());
    expect(
      (player.buttonBorder(c, pressed: true) as ZenBevelBorder).sunken,
      isTrue,
    );
    expect(grid.lift(c), isNotNull);
    expect(onyx.lift(c), isNull);
    expect(player.duration(1000), const Duration(milliseconds: 800));
  });

  test('the Material components take their shape from the look', () {
    ThemeData themeOf(AppPalette p) =>
        ZenTheme.dark(AppSettings.defaultAccentTheme, p);
    // Klasyczny keeps its rounded cards and capsule buttons.
    final ThemeData classic = themeOf(AppPalette.classic);
    expect(
      (classic.cardTheme.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(22),
    );
    expect(classic.scaffoldBackgroundColor, isNot(Colors.transparent));
    // The player: chrome cards, dialogs, chips and keys.
    final ThemeData player = themeOf(AppPalette.player);
    expect(player.cardTheme.shape, isA<ZenBevelBorder>());
    expect(player.dialogTheme.shape, isA<ZenBevelBorder>());
    expect(player.chipTheme.shape, isA<ZenBevelBorder>());
    expect(player.floatingActionButtonTheme.shape, isA<ZenBevelBorder>());
    expect(
      player.filledButtonTheme.style!.shape!.resolve(<WidgetState>{
        WidgetState.pressed,
      }),
      isA<ZenBevelBorder>(),
    );
    expect(player.sliderTheme.thumbShape, isA<ZenSquareThumbShape>());
    // Onyks: double lines on dialogs, underlined fields.
    final ThemeData onyx = themeOf(AppPalette.onyx);
    expect(onyx.dialogTheme.shape, isA<ZenDoubleBorder>());
    expect(
      onyx.inputDecorationTheme.enabledBorder,
      isA<UnderlineInputBorder>(),
    );
    // The grid: square buttons, sharp everything, see-through pages.
    final ThemeData grid = themeOf(AppPalette.grid);
    final OutlinedBorder gridButton = grid.filledButtonTheme.style!.shape!
        .resolve(<WidgetState>{})!;
    expect(
      (gridButton as RoundedRectangleBorder).borderRadius,
      BorderRadius.zero,
    );
    expect(grid.scaffoldBackgroundColor.a, 0);
    expect(grid.tooltipTheme.decoration, isA<BoxDecoration>());
    expect(
      (grid.tooltipTheme.decoration! as BoxDecoration).borderRadius,
      BorderRadius.zero,
    );
    expect(grid.navigationBarTheme.indicatorShape, isNotNull);
    expect(grid.progressIndicatorTheme.color, grid.colorScheme.primary);
  });

  test('the wild looks are many, each with its own effect', () {
    final List<AppPalette> wild = ZenThemeCategory.wild.palettes;
    expect(wild.length, greaterThanOrEqualTo(10));
    expect(<String>{
      for (final AppPalette p in AppPalette.values) p.label,
    }, hasLength(AppPalette.values.length));
    final Set<ZenBackdrop> effects = <ZenBackdrop>{};
    for (final AppPalette p in wild) {
      final ZenLook look = ZenLook.forPalette(p);
      expect(look.backdrop, isNot(ZenBackdrop.none), reason: '$p');
      // More than a recolour: its own frames or its own header.
      expect(
        look.borders != ZenBorderStyle.hairline ||
            look.header != ZenHeaderStyle.bar,
        isTrue,
        reason: '$p',
      );
      effects.add(look.backdrop);
    }
    expect(effects, hasLength(wild.length));
    // The player has no stray analyzer by its section titles any more.
    expect(
      ZenLook.forPalette(AppPalette.player).header,
      isNot(ZenHeaderStyle.spectrum),
    );
  });

  test('every theme has its own light and dark variant', () {
    for (final AppPalette p in AppPalette.values) {
      final ZenColors light = ZenColors.forPalette(
        p,
        AppSettings.defaultAccentTheme,
        Brightness.light,
      );
      final ZenColors dark = ZenColors.forPalette(
        p,
        AppSettings.defaultAccentTheme,
        Brightness.dark,
      );
      expect(
        ThemeData.estimateBrightnessForColor(light.background),
        Brightness.light,
        reason: '$p light',
      );
      expect(
        ThemeData.estimateBrightnessForColor(dark.background),
        Brightness.dark,
        reason: '$p dark',
      );
      // Same identity: the same look (shapes, frames, effect) in both.
      expect(
        ZenTheme.light(AppSettings.defaultAccentTheme, p).extension<ZenLook>(),
        ZenTheme.dark(AppSettings.defaultAccentTheme, p).extension<ZenLook>(),
        reason: '$p',
      );
      expect(light.duotone, dark.duotone, reason: '$p restricted in both');
    }
  });

  test('the new frames keep their shape and take a button outline', () {
    const Rect rect = Rect.fromLTWH(0, 0, 120, 60);
    final List<OutlinedBorder> frames = <OutlinedBorder>[
      const ZenCutBorder(cut: 10, pads: true),
      const ZenPixelBorder(),
      ZenWindowBorder(borderRadius: BorderRadius.circular(6)),
      ZenSheenBorder(borderRadius: BorderRadius.circular(10)),
      const ZenBevelBorder(
        light: Color(0xFFFFFFFF),
        dark: Color(0xFF000000),
        rivets: true,
      ),
      ZenDoubleBorder(borderRadius: BorderRadius.circular(8), ornaments: true),
    ];
    const BorderSide side = BorderSide(color: Color(0xFF123456), width: 2);
    for (final OutlinedBorder f in frames) {
      expect(f.getOuterPath(rect).getBounds(), rect, reason: '$f');
      expect(f.copyWith(side: side).side, side, reason: '$f');
      expect(f.copyWith(), f, reason: '$f');
      expect(f.scale(1), isA<ShapeBorder>());
    }
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
    // Its feature colours are shades of those few colours (the tone map
    // of a restricted palette), never a rainbow.
    final Set<Color> tones = <Color>{
      for (int i = 0; i < 16; i++) zenTone(neon, i),
    };
    expect(ZenTones.of(neon).toSet().containsAll(tones), isTrue);
    for (final Color c in tones) {
      final double hue = HSLColor.fromColor(c).hue;
      final bool cyan = (hue - HSLColor.fromColor(neon.accent).hue).abs() < 15;
      final bool magenta =
          (hue - HSLColor.fromColor(neon.accentSecondary).hue).abs() < 15;
      expect(cyan || magenta, isTrue, reason: '$c');
    }
  });

  test('one font for every look', () {
    for (final AppPalette palette in AppPalette.values) {
      final ThemeData theme = ZenTheme.dark(
        AppSettings.defaultAccentTheme,
        palette,
      );
      final ZenColors zen = theme.extension<ZenColors>()!;
      expect(zen.typeface, same(ZenTypefaces.zen), reason: '$palette');
      expect(theme.textTheme.bodyMedium?.fontFamily, ZenText.sansFamily);
    }
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

  test('the double frame lerps, scales and insets its content', () {
    final ZenDoubleBorder a = ZenDoubleBorder(
      borderRadius: BorderRadius.circular(8),
      color: const Color(0xFFD4B26A),
    );
    final ZenDoubleBorder b = ZenDoubleBorder(
      borderRadius: BorderRadius.circular(16),
      color: const Color(0xFF000000),
      gap: 4,
    );
    final ZenDoubleBorder mid = b.lerpFrom(a, 0.5)! as ZenDoubleBorder;
    expect(mid.borderRadius, BorderRadius.circular(12));
    expect(mid.gap, 3);
    expect((a.scale(2) as ZenDoubleBorder).gap, 4);
    expect(a.copyWith(), a);
    expect(a.dimensions, const EdgeInsets.all(4));
    const Rect rect = Rect.fromLTWH(0, 0, 40, 20);
    expect(a.getOuterPath(rect).getBounds(), rect);
    expect(a.getInnerPath(rect).getBounds(), rect.deflate(4));
  });

  for (final AppPalette palette in AppPalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets('the kit builds in ${palette.name} ${brightness.name}', (
        WidgetTester tester,
      ) async {
        final ZenLook look = ZenLook.forPalette(palette);
        await _pumpLook(tester, palette, brightness: brightness);
        expect(find.byKey(const Key('section-title')), findsOneWidget);
        expect(find.text('Kafelek'), findsNWidgets(2));
        expect(
          find.byType(ZenSpectrumStrip),
          look.header == ZenHeaderStyle.spectrum
              ? findsOneWidget
              : findsNothing,
        );
        expect(
          find.byType(ZenLedNumber),
          look.numbers == ZenNumberStyle.led ? findsWidgets : findsNothing,
        );
        expect(
          find.byType(ZenBlinkingCursor),
          look.header == ZenHeaderStyle.prompt ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const Key('zen-backdrop-still')),
          look.backdrop == ZenBackdrop.none ? findsNothing : findsOneWidget,
        );
        // Motion is off in tests: no backdrop animates.
        expect(find.byKey(const Key('zen-backdrop-live')), findsNothing);
        await tester.tap(find.text('Karta B'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the lit, terminal and retro motion runs and ends cleanly', (
    WidgetTester tester,
  ) async {
    final bool previous = ZenMotion.enabled;
    ZenMotion.enabled = true;
    addTearDown(() => ZenMotion.enabled = previous);
    for (final AppPalette palette in <AppPalette>[
      AppPalette.neon,
      AppPalette.grid,
      AppPalette.rain,
      AppPalette.player,
      AppPalette.phosphor,
      AppPalette.pearl,
      AppPalette.herbarium,
      AppPalette.blueprint,
      AppPalette.leather,
      // The wild looks: every effect, header and transition style.
      for (final AppPalette p in ZenThemeCategory.wild.palettes) p,
    ]) {
      final ZenLook look = ZenLook.forPalette(palette);
      // A fresh tree for each: the tab rail would otherwise tween from the
      // previous look's decoration (a rounded one to an underline).
      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpLook(tester, palette);
      // Flicker-on, breathing glow, the drifting field, the sweep, the
      // cursor and the backdrop.
      for (int frame = 0; frame < 90; frame++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(
        find.byType(ZenFlickerOn),
        look.header == ZenHeaderStyle.neonTube ||
                look.header == ZenHeaderStyle.brackets
            ? findsOneWidget
            : findsNothing,
        reason: '$palette',
      );
      final bool animated = ZenBackdropLayer.framesPerSecond(look.backdrop) > 0;
      expect(
        find.byKey(const Key('zen-backdrop-live')),
        animated ? findsOneWidget : findsNothing,
        reason: '$palette',
      );
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('reduced motion and the background stop the backdrop', (
    WidgetTester tester,
  ) async {
    final bool previous = ZenMotion.enabled;
    ZenMotion.enabled = true;
    addTearDown(() => ZenMotion.enabled = previous);
    Widget app({required bool reduced}) => MaterialApp(
      theme: ZenTheme.dark(AppSettings.defaultAccentTheme, AppPalette.rain),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: ZenBackdropHost(child: child ?? const SizedBox.shrink()),
      ),
      home: const Scaffold(
        appBar: ZenSectionBar(title: 'Czaty'),
        body: Text('Treść'),
      ),
    );

    await tester.pumpWidget(app(reduced: false));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('zen-backdrop-live')), findsOneWidget);
    expect(ZenBackdropLayer.running, 1);

    // Reduced motion: a still frame, no timer.
    await tester.pumpWidget(app(reduced: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const Key('zen-backdrop-live')), findsNothing);
    expect(find.byKey(const Key('zen-backdrop-still')), findsOneWidget);
    expect(ZenBackdropLayer.running, 0);

    // In the background it stands still too.
    await tester.pumpWidget(app(reduced: false));
    await tester.pump();
    expect(ZenBackdropLayer.running, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(ZenBackdropLayer.running, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(ZenBackdropLayer.running, 1);
    await tester.pump();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(ZenBackdropLayer.running, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('switching themes keeps the screens below', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<AppPalette> palette = ValueNotifier<AppPalette>(
      AppPalette.classic,
    );
    addTearDown(palette.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<AppPalette>(
        valueListenable: palette,
        builder: (BuildContext context, AppPalette p, Widget? _) => MaterialApp(
          theme: ZenTheme.dark(AppSettings.defaultAccentTheme, p),
          builder: (BuildContext context, Widget? child) =>
              ZenBackdropHost(child: child ?? const SizedBox.shrink()),
          home: const Scaffold(body: _Counter()),
        ),
      ),
    );
    await tester.tap(find.text('0'));
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
    for (final AppPalette p in <AppPalette>[
      AppPalette.rain,
      AppPalette.pearl,
      AppPalette.classic,
    ]) {
      palette.value = p;
      await tester.pumpAndSettle();
      // The counter's state survived the new backdrop.
      expect(find.text('1'), findsOneWidget, reason: '$p');
    }
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

  testWidgets('a page over a backdrop hides the page below once covered', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(AppSettings.defaultAccentTheme, AppPalette.grid),
        builder: (BuildContext context, Widget? child) =>
            ZenBackdropHost(child: child ?? const SizedBox.shrink()),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Drugi ekran')),
                ),
              ),
              child: const Text('Pierwszy ekran'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pierwszy ekran'));
    await tester.pumpAndSettle();
    expect(find.text('Drugi ekran'), findsOneWidget);
    // The first page is offstage now (covered and faded out).
    expect(find.text('Pierwszy ekran'), findsNothing);
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('Pierwszy ekran'), findsOneWidget);
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

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _n = 0;

  @override
  Widget build(BuildContext context) =>
      TextButton(onPressed: () => setState(() => _n++), child: Text('$_n'));
}
