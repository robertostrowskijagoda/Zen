import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_backdrop.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_palettes.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_theme_picker.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The themes known by their frames, and the backdrops of every theme.
const List<AppPalette> _framed = <AppPalette>[
  AppPalette.herbarium,
  AppPalette.sweets,
  AppPalette.cinema,
  AppPalette.blueprint,
  AppPalette.leather,
];

double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

ZenColors _colors(AppPalette p, Brightness b) =>
    ZenColors.forPalette(p, AppSettings.defaultAccentTheme, b);

/// Whether [path] runs inside [rect] (the bounds of a curve are only its
/// control points, so the line itself is sampled).
bool _stays(Path path, Rect rect) {
  final Rect slack = rect.inflate(0.6);
  for (final ui.PathMetric metric in path.computeMetrics()) {
    for (double d = 0; d <= metric.length; d += 0.5) {
      if (!slack.contains(metric.getTangentForOffset(d)!.position)) {
        return false;
      }
    }
  }
  return true;
}

/// A backdrop of [kind] at time [t], as pixels.
Future<Uint8List> _pixels(ZenBackdrop kind, double t) async {
  const Size size = Size(160, 320);
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ZenBackdropPainter(
    kind: kind,
    colors: _colors(AppPalette.neon, Brightness.dark),
    clock: ZenBackdropClock(t),
  ).paint(Canvas(recorder), size);
  final ui.Image image = await recorder.endRecording().toImage(160, 320);
  final ByteData? data = await image.toByteData();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the new themes are registered, named and in a picker group', () {
    expect(AppPalette.values, containsAll(_framed));
    final Set<String> labels = <String>{};
    final Set<String> taglines = <String>{};
    for (final AppPalette p in _framed) {
      expect(p.label, isNotEmpty, reason: '$p');
      expect(p.tagline, isNotEmpty, reason: '$p');
      expect(labels.add(p.label), isTrue, reason: '$p label is unique');
      expect(taglines.add(p.tagline), isTrue, reason: '$p tagline is unique');
      expect(
        ZenPalettes.categoryOf(p).palettes,
        contains(p),
        reason: '$p is listed in its group',
      );
    }
    // No other theme took one of their names.
    expect(<String>{
      for (final AppPalette p in AppPalette.values) p.label,
    }, hasLength(AppPalette.values.length));
    // What is saved is the name: new ones never shift the old ones.
    expect(AppPalette.values.take(27).last, AppPalette.volcano);
  });

  test('each new theme has frames or corners of its own', () {
    final Set<ZenBorderStyle> frames = <ZenBorderStyle>{};
    for (final AppPalette p in _framed) {
      final ZenLook look = ZenLook.forPalette(p);
      expect(frames.add(look.borders), isTrue, reason: '$p frame is its own');
      final ZenColors c = _colors(p, Brightness.dark);
      final ShapeBorder panel = look.panelShape(c);
      expect(panel, isNot(isA<RoundedRectangleBorder>()), reason: '$p');
      expect(look.floatingShape(c), isNot(isA<RoundedRectangleBorder>()));
    }
    expect(frames, hasLength(_framed.length));
    // The corners differ too: sharp, tight and very round all appear.
    final Set<double> corners = <double>{
      for (final AppPalette p in _framed) ZenLook.forPalette(p).corner,
    };
    expect(corners.length, greaterThanOrEqualTo(4));
    // At least one of them has no backdrop and at least four do.
    expect(
      _framed
          .where(
            (AppPalette p) =>
                ZenLook.forPalette(p).backdrop != ZenBackdrop.none,
          )
          .length,
      greaterThanOrEqualTo(4),
    );
  });

  test('every frame draws and clips inside its panel, however small', () {
    for (final AppPalette p in _framed) {
      final ZenLook look = ZenLook.forPalette(p);
      final ZenColors c = _colors(p, Brightness.light);
      for (final Size size in const <Size>[
        Size(6, 6),
        Size(24, 14),
        Size(60, 40),
        Size(120, 60),
        Size(300, 220),
      ]) {
        final Rect rect = Offset.zero & size;
        for (final ShapeBorder shape in <ShapeBorder>[
          look.panelShape(c),
          look.panelShape(c, radius: 26, tone: Colors.red),
          look.floatingShape(c),
          look.floatingShape(c, topOnly: true),
        ]) {
          expect(
            _stays(shape.getOuterPath(rect), rect),
            isTrue,
            reason: '$p $size $shape stays inside',
          );
          expect(shape.getInnerPath(rect), isA<Path>());
          final ui.PictureRecorder recorder = ui.PictureRecorder();
          shape.paint(Canvas(recorder), rect);
          recorder.endRecording().dispose();
        }
      }
    }
  });

  test('the frames compare, copy and scale', () {
    for (final AppPalette p in _framed) {
      final ZenLook look = ZenLook.forPalette(p);
      final ZenColors c = _colors(p, Brightness.dark);
      final ShapeBorder a = look.panelShape(c);
      final ShapeBorder b = look.panelShape(c);
      expect(a, b, reason: '$p');
      expect(a.hashCode, b.hashCode, reason: '$p');
      expect(look.panelShape(c, tone: Colors.red), isNot(a), reason: '$p');
      final OutlinedBorder frame = a as OutlinedBorder;
      const BorderSide side = BorderSide(color: Color(0xFF123456), width: 2);
      expect(frame.copyWith(side: side).side, side, reason: '$p');
      expect(frame.copyWith(), frame, reason: '$p');
      expect(frame.scale(2), isNot(frame), reason: '$p');
      expect(frame.scale(1), frame, reason: '$p');
    }
  });

  test('every new theme keeps its text readable in both modes', () {
    for (final AppPalette p in _framed) {
      final ZenLook look = ZenLook.forPalette(p);
      for (final Brightness brightness in Brightness.values) {
        final ZenColors c = _colors(p, brightness);
        final String where = '$p / $brightness';
        expect(
          ThemeData.estimateBrightnessForColor(c.background),
          brightness,
          reason: where,
        );
        final Map<String, Color> grounds = <String, Color>{
          'background': c.background,
          'surface': c.surface,
          'surfaceRaised': c.surfaceRaised,
          'surfaceMuted': c.surfaceMuted,
          'surfaceSunk': c.surfaceSunk,
          'accentSoft': c.accentSoft,
          'panel': Color.alphaBlend(look.panelColor(c), c.background),
        };
        for (final MapEntry<String, Color> g in grounds.entries) {
          expect(
            _contrast(c.textPrimary, g.value),
            greaterThanOrEqualTo(4.5),
            reason: '$where text on ${g.key}',
          );
          expect(
            _contrast(c.textSecondary, g.value),
            greaterThanOrEqualTo(4.5),
            reason: '$where secondary text on ${g.key}',
          );
        }
        expect(
          _contrast(c.textMuted, c.surface),
          greaterThanOrEqualTo(3.0),
          reason: '$where muted text',
        );
        expect(
          _contrast(c.accent, c.onAccent),
          greaterThanOrEqualTo(4.5),
          reason: '$where label on the accent',
        );
        // Status colours read against the panel they sit on.
        for (final Color status in <Color>[c.success, c.warning, c.danger]) {
          expect(
            _contrast(status, c.surface),
            greaterThanOrEqualTo(3.0),
            reason: '$where status colour',
          );
        }
        // The strongest mark of the backdrop under the text.
        if (look.backdrop != ZenBackdrop.none) {
          final double a = ZenBackdropPainter.maxAlpha(look.backdrop);
          for (final Color mark in ZenBackdropPainter.marks(look.backdrop, c)) {
            final Color under = Color.alphaBlend(
              mark.withValues(alpha: a),
              c.background,
            );
            expect(
              _contrast(c.textPrimary, under),
              greaterThanOrEqualTo(4.5),
              reason: '$where text over the backdrop',
            );
            expect(
              _contrast(c.textSecondary, under),
              greaterThanOrEqualTo(4.5),
              reason: '$where secondary text over the backdrop',
            );
          }
        }
      }
    }
  });

  test(
    'a backdrop that animates changes its picture, a still one does not',
    () async {
      for (final ZenBackdrop kind in ZenBackdrop.values) {
        if (kind == ZenBackdrop.none) {
          continue;
        }
        final Uint8List first = (await _pixels(kind, 7.3));
        final Uint8List later = (await _pixels(kind, 11.3));
        final Uint8List again = (await _pixels(kind, 7.3));
        expect(again, first, reason: '$kind is a pure picture of the time');
        if (ZenBackdropLayer.framesPerSecond(kind) > 0) {
          expect(later, isNot(first), reason: '$kind moves');
        } else {
          expect(later, first, reason: '$kind stands still');
        }
      }
    },
  );

  group('the backdrop clock', () {
    late bool motionWas;

    setUp(() {
      motionWas = ZenMotion.enabled;
      ZenMotion.enabled = true;
    });

    tearDown(() => ZenMotion.enabled = motionWas);

    Widget app(
      ZenBackdrop kind, {
      bool shown = true,
      bool reduced = false,
      Brightness brightness = Brightness.dark,
    }) => MaterialApp(
      theme: ZenTheme.forPalette(
        AppPalette.neon,
        AppSettings.defaultAccentTheme,
        brightness,
      ),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: Scaffold(
        body: TickerMode(
          enabled: shown,
          child: Builder(
            builder: (BuildContext context) =>
                ZenBackdropLayer(kind: kind, colors: ZenColors.of(context)),
          ),
        ),
      ),
    );

    ZenBackdropClock clockOf(WidgetTester tester) {
      final CustomPaint paint = tester.widget<CustomPaint>(
        find.byKey(const Key('zen-backdrop-live')),
      );
      return (paint.painter! as ZenBackdropPainter).clock;
    }

    testWidgets('ticks while shown, stops in a hidden tab and under reduced '
        'motion, and goes on when shown again', (WidgetTester tester) async {
      await tester.pumpWidget(app(ZenBackdrop.rain));
      await tester.pump();
      expect(ZenBackdropLayer.running, 1);
      final ZenBackdropClock clock = clockOf(tester);
      int ticks = 0;
      clock.addListener(() => ticks++);
      final double start = clock.seconds;

      await tester.pump(const Duration(seconds: 1));
      expect(ticks, greaterThanOrEqualTo(8), reason: '12 a second');
      expect(clock.seconds, greaterThan(start));

      // A tab in the background: tickers off, no timer.
      await tester.pumpWidget(app(ZenBackdrop.rain, shown: false));
      await tester.pump();
      expect(ZenBackdropLayer.running, 0);
      final int stopped = ticks;
      await tester.pump(const Duration(seconds: 2));
      expect(ticks, stopped, reason: 'nothing ticks in a hidden tab');
      expect(find.byKey(const Key('zen-backdrop-still')), findsOneWidget);

      // Shown again: the same clock goes on from where it stood.
      await tester.pumpWidget(app(ZenBackdrop.rain));
      await tester.pump();
      expect(ZenBackdropLayer.running, 1);
      await tester.pump(const Duration(seconds: 1));
      expect(ticks, greaterThan(stopped));

      // The system asks for less motion.
      await tester.pumpWidget(app(ZenBackdrop.rain, reduced: true));
      await tester.pump();
      expect(ZenBackdropLayer.running, 0);
      final int still = ticks;
      await tester.pump(const Duration(seconds: 2));
      expect(ticks, still);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(ZenBackdropLayer.running, 0);
    });

    testWidgets('stops while the app is in the background, for every '
        'animated backdrop', (WidgetTester tester) async {
      for (final ZenBackdrop kind in ZenBackdrop.values) {
        if (ZenBackdropLayer.framesPerSecond(kind) == 0) {
          continue;
        }
        await tester.pumpWidget(app(kind));
        await tester.pump();
        expect(ZenBackdropLayer.running, 1, reason: '$kind runs');
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(ZenBackdropLayer.running, 0, reason: '$kind pauses');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(ZenBackdropLayer.running, 1, reason: '$kind resumes');
        await tester.pumpWidget(const SizedBox.shrink());
        expect(ZenBackdropLayer.running, 0, reason: '$kind is gone');
      }
    });

    testWidgets('a still backdrop never starts a timer', (
      WidgetTester tester,
    ) async {
      for (final ZenBackdrop kind in <ZenBackdrop>[
        ZenBackdrop.halftone,
        ZenBackdrop.brushed,
      ]) {
        await tester.pumpWidget(app(kind));
        await tester.pump();
        expect(ZenBackdropLayer.running, 0, reason: '$kind');
        expect(find.byKey(const Key('zen-backdrop-still')), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  testWidgets('the picker lists the new themes in their groups', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(412 * 3, 2400 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ZenThemePicker(
              selected: AppPalette.sweets,
              accent: AppSettings.defaultAccentTheme,
              brightness: Brightness.dark,
              onSelect: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    for (final AppPalette p in _framed) {
      expect(
        find.descendant(
          of: find.byKey(
            Key('settings-palette-category-${ZenPalettes.categoryOf(p).name}'),
          ),
          matching: find.byKey(Key('settings-palette-${p.name}')),
        ),
        findsOneWidget,
        reason: '$p',
      );
    }
    expect(tester.takeException(), isNull);
  });
}
