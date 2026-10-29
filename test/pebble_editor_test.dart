import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pebbles/design/pebble_card_look.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_fonts.dart';
import 'package:zen/src/features/pebbles/design/pebble_ready_designs.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_editor_screen.dart';
import 'package:zen/src/features/pebbles/render/pebble_renderer.dart';
import 'package:zen/src/features/pebbles/render/pebble_thumbnail.dart';
import 'package:zen/src/features/pebbles/render/pebble_view.dart';

import 'support/text_fit.dart' show kNarrowestPhoneWidth;

final class _Host {
  PebbleEditorResult? result;
  bool closed = false;
}

Future<_Host> _pumpEditor(
  WidgetTester tester, {
  Size size = const Size(420, 860),
  double textScale = 1,
  bool still = false,
  Uint8List? startFrom,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final _Host host = _Host();
  await tester.pumpWidget(
    MaterialApp(
      theme: ZenTheme.dark(),
      builder: (BuildContext context, Widget? child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: still,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const Key('open'),
              onPressed: () async {
                host.result = await PebbleEditorScreen.open(
                  context,
                  startFrom: startFrom,
                );
                host.closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pumpAndSettle();
  return host;
}

PebbleEditorState _state(WidgetTester tester) =>
    tester.state<PebbleEditorState>(find.byType(PebbleEditorScreen));

Future<void> _tapKey(WidgetTester tester, String key) async {
  final Finder f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

/// The middle of the drawn stone (it sits a little above the box's middle).
Offset _stoneCentre(WidgetTester tester) {
  final Rect box = tester.getRect(find.byKey(const Key('pebble-stage')));
  return box.center.translate(0, -box.shortestSide * 0.03);
}

void main() {
  testWidgets('paint on the top, turn the stone, paint on the bottom, undo, '
      'redo, and finish with the design, look and thumbnail', (
    WidgetTester tester,
  ) async {
    final _Host host = await _pumpEditor(tester);
    final PebbleEditorState state = _state(tester);
    expect(state.design.ops, isEmpty);

    await _tapKey(tester, 'pebble-face-top');
    expect(
      state.stage.rotation.distance(
        PebbleRotation.facing(PebbleFace.top.index),
      ),
      lessThan(0.01),
    );
    await _tapKey(tester, 'pebble-tool-brush');
    await tester.dragFrom(_stoneCentre(tester), const Offset(70, 40));
    await tester.pumpAndSettle();
    expect(state.design.ops, hasLength(1));
    final PebbleStroke top = state.design.ops.single as PebbleStroke;
    expect(top.face, PebbleFace.top.index);
    expect(top.pointCount, greaterThan(1));
    expect(top.tool, PebbleStrokeTool.brush);

    // Turning: the rotation changes and nothing is painted.
    await _tapKey(tester, 'pebble-tool-rotate');
    final PebbleRotation before = state.stage.rotation;
    await tester.dragFrom(_stoneCentre(tester), const Offset(-90, 60));
    await tester.pumpAndSettle();
    expect(state.stage.rotation.distance(before), greaterThan(0.3));
    expect(state.design.ops, hasLength(1));

    // The bottom.
    await _tapKey(tester, 'pebble-face-bottom');
    await _tapKey(tester, 'pebble-tool-brush');
    await tester.dragFrom(_stoneCentre(tester), const Offset(-60, 20));
    await tester.pumpAndSettle();
    expect(state.design.ops, hasLength(2));
    expect(state.design.ops.last.face, PebbleFace.bottom.index);

    await _tapKey(tester, 'pebble-undo');
    expect(state.design.ops, hasLength(1));
    expect(state.design.ops.single.face, PebbleFace.top.index);
    await _tapKey(tester, 'pebble-redo');
    expect(state.design.ops, hasLength(2));
    await _tapKey(tester, 'pebble-undo');
    expect(state.design.ops, hasLength(1));

    final PebbleDesign kept = state.design;
    await tester.tap(find.byKey(const Key('pebble-done')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pumpAndSettle();
    expect(host.closed, isTrue);
    final PebbleEditorResult result = host.result!;
    expect(PebbleDesign.decode(result.$1), kept);
    expect(result.$3.length, PebbleThumbnail.bytes);
    expect(result.$2.shape, kept.shape);
    expect(result.$2.seed, kept.seed);
    expect((
      result.$2.mainColour,
      result.$2.secondColour,
    ), thumbnailColours(result.$3));
  });

  testWidgets('stamps, text, fills, patterns, ready designs and Losuj', (
    WidgetTester tester,
  ) async {
    await _pumpEditor(tester);
    final PebbleEditorState state = _state(tester);
    await _tapKey(tester, 'pebble-face-top');

    await _tapKey(tester, 'pebble-tool-stamp');
    await _tapKey(tester, 'pebble-stamp-pick');
    await _tapKey(tester, 'pebble-stamp-${PebbleStampIds.ladybird}');
    await tester.tapAt(_stoneCentre(tester));
    await tester.pumpAndSettle();
    final PebbleStampOp stamp = state.design.ops.last as PebbleStampOp;
    expect(stamp.stamp, PebbleStampIds.ladybird);
    expect(stamp.face, PebbleFace.top.index);
    expect(PebbleQ.value(stamp.s).abs(), lessThan(0.2));

    await _tapKey(tester, 'pebble-tool-text');
    await tester.enterText(find.byKey(const Key('pebble-text')), 'Kasia');
    await tester.pumpAndSettle();
    // Every typeface shows the words typed; the chosen one goes on the
    // stone.
    final Text preview = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const Key('pebble-font-preview')),
        matching: find.byType(Text),
      ),
    );
    expect(preview.data, 'Kasia');
    await _tapKey(tester, 'pebble-font-${PebbleFont.bangers.index}');
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('pebble-font-preview')),
              matching: find.byType(Text),
            ),
          )
          .style
          ?.fontFamily,
      'Bangers',
    );
    await tester.tapAt(_stoneCentre(tester).translate(0, 30));
    await tester.pumpAndSettle();
    final PebbleTextOp text = state.design.ops.last as PebbleTextOp;
    expect(text.text, 'Kasia');
    expect(text.face, PebbleFace.top.index);
    expect(text.font, PebbleFont.bangers.index);

    await _tapKey(tester, 'pebble-tool-pattern');
    await _tapKey(tester, 'pebble-face-sides');
    await _tapKey(tester, 'pebble-pattern-stripes');
    await _tapKey(tester, 'pebble-pattern-apply');
    final List<PebbleOp> last4 = state.design.ops.sublist(
      state.design.ops.length - 4,
    );
    expect(last4.every((PebbleOp o) => o is PebblePatternOp), isTrue);
    expect(last4.map((PebbleOp o) => o.face).toSet(), <int>{2, 3, 4, 5});
    // The four faces are one step.
    await _tapKey(tester, 'pebble-undo');
    expect(state.design.ops.last, isA<PebbleTextOp>());

    await _tapKey(tester, 'pebble-face-top');
    await _tapKey(tester, 'pebble-tool-fill');
    await tester.tapAt(_stoneCentre(tester).translate(-40, -40));
    await tester.pumpAndSettle();
    expect(state.design.ops.last, isA<PebbleRegionFill>());

    await _tapKey(tester, 'pebble-tool-ready');
    await _tapKey(tester, 'pebble-ready-ladybird');
    expect(state.design, PebbleReadyDesign.ladybird.build());

    final PebbleDesign ladybird = state.design;
    await _tapKey(tester, 'pebble-random');
    expect(state.design, isNot(ladybird));
    await _tapKey(tester, 'pebble-undo');
    expect(state.design, ladybird);

    await _tapKey(tester, 'pebble-tool-stone');
    await _tapKey(tester, 'pebble-shape-flatOval');
    expect(state.design.shape, 3);
    await _tapKey(tester, 'pebble-material-gold');
    expect(state.design.materialPreset.name, 'gold');
    // The paint stays when the stone changes.
    expect(state.design.ops, ladybird.ops);
  });

  testWidgets('a stroke over a seam goes on onto the next face', (
    WidgetTester tester,
  ) async {
    await _pumpEditor(tester);
    final PebbleEditorState state = _state(tester);
    // Looking at the front, paint from the middle up over the top edge.
    await _tapKey(tester, 'pebble-face-front');
    await _tapKey(tester, 'pebble-tool-brush');
    final Offset c = _stoneCentre(tester);
    final TestGesture g = await tester.startGesture(c);
    for (int i = 1; i <= 24; i++) {
      await g.moveTo(c.translate(0, -i * 8.0));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(state.design.ops, isNotEmpty);
    final PebbleStroke first = state.design.ops.first as PebbleStroke;
    expect(first.face, PebbleFace.front.index);
    // Points past the front's top edge are kept in the front's coordinates
    // (drawn onto the top through the seam), or a new part starts there.
    final bool overEdge =
        state.design.ops.length > 1 ||
        <double>[
          for (int i = 1; i < first.points.length; i += 2)
            PebbleQ.value(first.points[i]),
        ].any((double t) => t > 1);
    expect(overEdge, isTrue);
  });

  testWidgets('fits the narrowest phone with text twice as large', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await _pumpEditor(
      tester,
      size: const Size(kNarrowestPhoneWidth, 568),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Kamyczek do malowania'), findsOneWidget);
    for (final PebbleTool tool in PebbleTool.values) {
      await _tapKey(tester, 'pebble-tool-${tool.name}');
      expect(tester.takeException(), isNull, reason: tool.name);
      expect(
        tester.getSize(find.byKey(const Key('pebble-stage'))).height,
        greaterThanOrEqualTo(100),
      );
    }
    for (final String key in <String>[
      'pebble-face-sides',
      'pebble-random',
      'pebble-undo',
      'pebble-done',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget);
    }
    semantics.dispose();
  });

  testWidgets('with less motion: no turntable, faces turn at once', (
    WidgetTester tester,
  ) async {
    await _pumpEditor(tester, still: true);
    expect(find.byKey(const Key('pebble-turntable')), findsNothing);
    final PebbleEditorState state = _state(tester);
    await tester.tap(find.byKey(const Key('pebble-face-bottom')));
    await tester.pump();
    expect(
      state.stage.rotation.distance(
        PebbleRotation.facing(PebbleFace.bottom.index),
      ),
      lessThan(1e-9),
    );
    expect(state.stage.animating, isFalse);
  });

  testWidgets('the turntable spins the stone', (WidgetTester tester) async {
    await _pumpEditor(tester);
    final PebbleEditorState state = _state(tester);
    await _tapKey(tester, 'pebble-face-front');
    final PebbleRotation before = state.stage.rotation;
    await tester.tap(find.byKey(const Key('pebble-turntable')));
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(state.stage.rotation.distance(before), greaterThan(0.1));
    await tester.tap(find.byKey(const Key('pebble-turntable')));
    await tester.pumpAndSettle();
  });

  testWidgets('starts from a given design', (WidgetTester tester) async {
    final PebbleDesign owl = PebbleReadyDesign.owl.build();
    await _pumpEditor(tester, startFrom: owl.encode());
    expect(_state(tester).design, owl);
  });

  testWidgets('a stone view draws from the design or from the card alone, '
      'and turns when interactive', (WidgetTester tester) async {
    final PebbleDesign bee = PebbleReadyDesign.bee.build();
    final Uint8List thumb =
        await tester.runAsync(() => pebbleThumbnail(bee)) as Uint8List;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: <Widget>[
            PebbleView(
              design: bee.encode(),
              card: bee.look,
              size: 150,
              interactive: true,
            ),
            PebbleView(
              design: null,
              card: bee.look.withThumbnail(thumb),
              size: 90,
            ),
            PebbleView(
              design: Uint8List.fromList(<int>[9, 9, 9]),
              card: const PebbleCardLook(
                shape: 200,
                seed: 1,
                material: 250,
                mainColour: 0xFF0000,
                secondColour: 0,
              ),
              size: 90,
            ),
          ],
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final PebbleStageState stage = tester.state<PebbleStageState>(
      find.byType(PebbleStage).first,
    );
    final PebbleRotation before = PebbleRotation.resting;
    await tester.drag(find.byType(PebbleView).first, const Offset(50, 0));
    await tester.pumpAndSettle();
    expect(stage.renderer.visibleTriangles, greaterThan(500));
    final PebbleStageController controller = (tester.widget<PebbleStage>(
      find.byType(PebbleStage).first,
    )).controller;
    expect(controller.rotation.distance(before), greaterThan(0.2));
  });
}
