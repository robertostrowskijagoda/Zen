import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/zen_web.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/qr_sticker/presentation/sticker_designer_screen.dart';
import 'package:zen/src/features/qr_sticker/qr_matrix.dart';
import 'package:zen/src/features/qr_sticker/sticker_design.dart';
import 'package:zen/src/features/qr_sticker/sticker_files.dart';
import 'package:zen/src/features/qr_sticker/sticker_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/update/own_copy.dart';

import 'support/text_fit.dart'
    show kNarrowestPhoneWidth, loadAppFonts, truncatedTexts;

/// Keeps what would be saved, shared and printed.
final class _Outlet implements StickerOutlet {
  final List<(String, Uint8List, String)> saved =
      <(String, Uint8List, String)>[];
  final List<(String, String)> shared = <(String, String)>[];
  final List<String> printed = <String>[];

  @override
  bool get canShare => true;

  @override
  bool get canPrint => true;

  @override
  bool get canOpen => false;

  @override
  Future<String?> save(String name, Uint8List bytes, String mime) async {
    saved.add((name, bytes, mime));
    return 'Pobrane/$name';
  }

  @override
  Future<bool> share(String name, Uint8List bytes, String mime) async {
    shared.add((name, mime));
    return true;
  }

  @override
  Future<bool> printPdf(String name, Uint8List pdf) async {
    expect(latin1.decode(pdf.sublist(0, 8)), '%PDF-1.4');
    printed.add(name);
    return true;
  }

  @override
  Future<bool> open(String saved) async => false;
}

final PeerShareProfile _ada = PeerShareCodec.buildLocalProfile(
  address: PeerShareCodec.normalizeAddress('201:5d1a:9c2e::7f3b'),
  displayName: 'Ada',
)!;

StickerSubject _door() => const StickerSubject(
  kind: StickerKind.door,
  data:
      'https://robertostrowskijagoda.github.io/Zen/m#eyJ2IjozLCJrIjoiQndjSEJ3'
      'Y0hCd2NIQndjSEJ3Y0hCd2NIQndjSEJ3Y0hCd2NIQndjSEJ3Yz0iLCJkIjoiYWJjIiwi'
      'YSI6IjIwMDo6RDEiLCJuIjoiTm93YWtvd2llLCBtLiAxMiJ9',
  label: 'Kod na drzwi',
  name: 'Dom Kowalskich',
);

StickerSubject _pebble() => StickerSubject.pebble(
  link: '${zenPageUrl('k/')}#AQtWtfhZ6kf4qYWb1mhj_pXOjzVowyj8sFECCexfVGU7yY7c',
  name: ' Sowa ',
  author: 'Ola',
);

void main() {
  setUpAll(loadAppFonts);

  late MemoryLedgerDisk disk;
  late _Outlet outlet;

  setUp(() {
    disk = MemoryLedgerDisk();
    outlet = _Outlet();
  });

  List<Override> overrides({PeerShareProfile? me}) => <Override>[
    ledgerDiskProvider.overrideWithValue(disk),
    stickerOutletProvider.overrideWithValue(outlet),
    myShareProfileProvider.overrideWithValue(me),
    ownCopyCheckProvider.overrideWith(
      (Ref ref) async => const OwnCopyCheck(OwnCopyState.unknown),
    ),
  ];

  Future<void> pumpDesigner(
    WidgetTester tester,
    List<StickerSubject> subjects, {
    Size size = const Size(400, 3200),
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: StickerDesignerScreen(subjects: subjects),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  /// Lets the export (drawing, compressing off the UI thread) finish.
  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (int i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  String previewLabel(WidgetTester tester) => tester
      .getSemantics(
        find
            .ancestor(
              of: find.byKey(const Key('sticker-preview')),
              matching: find.byType(Semantics),
            )
            .first,
      )
      .label;

  /// The chips' labels cut short: a chip keeps its label to one line and
  /// clips the rest (which [truncatedTexts] does not see).
  List<String> clippedChipLabels(WidgetTester tester) => <String>[
    for (final Element e
        in find
            .descendant(
              of: find.byType(ChoiceChip),
              matching: find.byType(Text),
            )
            .evaluate())
      if (e.renderObject case final RenderParagraph p
          when p.getMaxIntrinsicWidth(double.infinity) > p.size.width + 0.5)
        p.text.toPlainText(),
  ];

  test('an invitation sticker carries the person\'s name, never the '
      '"Zen 1A2B" of a profile without one', () {
    expect(StickerSubject.invite(_ada).name, 'Ada');
    expect(StickerSubject.invite(_ada).data, _ada.qrData);
    final PeerShareProfile nameless = PeerShareCodec.buildLocalProfile(
      address: PeerShareCodec.normalizeAddress('201:5d1a:9c2e::7f3b'),
    )!;
    expect(nameless.displayName, startsWith('Zen '));
    expect(StickerSubject.invite(nameless).name, '');
  });

  test('each pebble starts from its own ready texts, keeping the remembered '
      'look; other kinds keep their texts too', () {
    final StickerSubject sowa = _pebble();
    const StickerDesign kept = StickerDesign(
      texts: StickerTexts(bottom: 'Kamyczek Biedronka — zeskanuj i zbierz'),
      style: QrStyle.dots,
      theme: StickerTheme.forest,
    );
    expect(
      sowa.remembered(kept),
      kept.copyWith(
        texts: const StickerTexts(
          top: 'Znalazłeś kamyczek!',
          bottom: 'Zeskanuj, żeby go zebrać',
        ),
      ),
    );
    expect(_door().remembered(kept), kept);
    expect(sowa.kind, StickerKind.pebble);
    expect((sowa.name, sowa.author), ('Sowa', 'Ola'));
  });

  testWidgets('a pebble\'s sticker: the stone and its label instead of the '
      'signature, its own texts, saved as zen-kamyczek', (
    WidgetTester tester,
  ) async {
    // The last pebble's texts are not this one's.
    await tester.runAsync(
      () => StickerStore(disk).save(
        StickerKind.pebble,
        const StickerDesign(
          texts: StickerTexts(bottom: 'Kamyczek Biedronka — zeskanuj i zbierz'),
          style: QrStyle.rounded,
        ),
      ),
    );
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpDesigner(tester, <StickerSubject>[_pebble()]);
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sticker-bottom')))
          .controller!
          .text,
      'Zeskanuj, żeby go zebrać',
    );
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('sticker-style-rounded')))
          .selected,
      isTrue,
    );
    expect(find.byKey(const Key('sticker-signature')), findsNothing);
    expect(previewLabel(tester), contains('Znalazłeś kamyczek!'));
    await tapVisible(tester, find.byKey(const Key('sticker-presets-open')));
    await tester.pumpAndSettle();
    expect(find.text('Kamyczek Sowa — zeskanuj i zbierz'), findsOneWidget);
    await tester.tap(find.text('Ola zostawił(a) tu kamyczek'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sticker-bottom')))
          .controller!
          .text,
      'Ola zostawił(a) tu kamyczek',
    );
    await tapVisible(tester, find.byKey(const Key('sticker-save')));
    await settleUntil(tester, () => outlet.saved.isNotEmpty);
    expect(outlet.saved.single.$1, 'zen-kamyczek.pdf');
    semantics.dispose();
  });

  testWidgets('fits the narrowest phone with text twice as large', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpDesigner(
      tester,
      <StickerSubject>[StickerSubject.zenAbout(), StickerSubject.invite(_ada)],
      size: const Size(kNarrowestPhoneWidth, 9000),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(truncatedTexts(tester), isEmpty);
    // Every choice is there and can be reached.
    for (final String key in <String>[
      'sticker-subject-zenAbout',
      'sticker-subject-friendInvite',
      'sticker-presets-open',
      'sticker-top',
      'sticker-caption',
      'sticker-bottom',
      'sticker-signature',
      'sticker-style-dots',
      'sticker-logo',
      'sticker-theme-forest',
      'sticker-pattern-butterflies',
      'sticker-page-a4',
      'sticker-landscape-true',
      'sticker-size-0',
      'sticker-size-150',
      'sticker-module-size',
      'sticker-sheet-preview',
      'sticker-crop-marks',
      'sticker-format-svg',
      'sticker-save',
      'sticker-share',
      'sticker-print',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    expect(clippedChipLabels(tester), isEmpty);
    // The preview says what is on it.
    expect(previewLabel(tester), contains('Prywatna sieć społecznościowa'));
    semantics.dispose();
  });

  testWidgets('the size: chosen in cm on the narrowest phone with text twice '
      'as large, the dot size and its warning, several on a page, all '
      'remembered for the kind', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpDesigner(
      tester,
      <StickerSubject>[_door()],
      size: const Size(kNarrowestPhoneWidth, 9000),
      textScale: 2,
    );
    Finder key(String k) => find.byKey(Key(k));
    String textOf(String k) => tester.widget<Text>(key(k)).data!;
    bool selected(String k) => tester.widget<ChoiceChip>(key(k)).selected;
    String sheetLabel() => tester
        .getSemantics(
          find
              .descendant(
                of: key('sticker-sheet-preview'),
                matching: find.byType(Semantics),
              )
              .first,
        )
        .label;

    // A4: the largest as today, with its size, and each size it holds.
    expect(textOf('sticker-module-size'), isNotEmpty);
    expect(selected('sticker-size-0'), isTrue);
    expect(
      find.descendant(
        of: key('sticker-size-0'),
        matching: find.text('Największy'),
      ),
      findsOneWidget,
    );
    expect(textOf('sticker-module-size'), startsWith('Bok naklejki: 18,6 cm.'));
    for (final int mm in <int>[40, 50, 60, 80, 100, 120, 150]) {
      expect(key('sticker-size-$mm'), findsOneWidget, reason: '$mm');
    }
    expect(key('sticker-size-200'), findsNothing);
    final int grid = QrMatrix.encode(_door().data).size;
    expect(textOf('sticker-module-size'), contains('kod $grid × $grid'));
    expect(key('sticker-module-warning'), findsNothing);
    expect(key('sticker-tile'), findsNothing);
    expect(sheetLabel(), 'Podgląd strony A4: 1 × naklejka 18,6 cm');

    // 4 cm: the dots get too small to read surely.
    await tapVisible(tester, key('sticker-size-40'));
    expect(selected('sticker-size-40'), isTrue);
    expect(
      textOf('sticker-module-size'),
      matches(RegExp(r'^Bok naklejki: 4 cm\. Jedna kropka kodu: 0,[0-4]\d mm')),
    );
    expect(key('sticker-module-warning'), findsOneWidget);
    expect(
      textOf('sticker-module-warning'),
      'Kropki kodu będą bardzo małe — wybierz większy rozmiar, żeby każdy '
      'aparat go odczytał.',
    );
    expect(sheetLabel(), 'Podgląd strony A4: 1 × naklejka 4 cm');

    // Several on the page.
    expect(
      find.descendant(
        of: key('sticker-tile'),
        matching: find.text(
          '24 naklejki na jednej stronie, z odstępami do cięcia',
        ),
      ),
      findsOneWidget,
    );
    await tapVisible(tester, key('sticker-tile'));
    expect(sheetLabel(), 'Podgląd strony A4: 24 × naklejka 4 cm');

    // 8 cm: a gentle note; the largest: nothing to say.
    await tapVisible(tester, key('sticker-size-80'));
    expect(key('sticker-module-warning'), findsNothing);
    expect(key('sticker-module-note'), findsOneWidget);
    expect(sheetLabel(), 'Podgląd strony A4: 6 × naklejka 8 cm');
    await tapVisible(tester, key('sticker-size-60'));
    await tapVisible(tester, key('sticker-size-0'));
    expect(key('sticker-module-warning'), findsNothing);
    expect(key('sticker-module-note'), findsNothing);
    expect(key('sticker-tile'), findsNothing);
    await tapVisible(tester, key('sticker-size-60'));

    // The 10 × 10 cm sticker: the whole of it, or smaller in its middle.
    await tapVisible(tester, key('sticker-page-sticker'));
    expect(key('sticker-size-100'), findsNothing);
    expect(key('sticker-size-80'), findsOneWidget);
    expect(selected('sticker-size-60'), isTrue);
    expect(key('sticker-tile'), findsNothing);
    // A wallpaper fills its screen.
    await tapVisible(tester, key('sticker-page-wallpaper'));
    expect(key('sticker-size-0'), findsNothing);
    expect(key('sticker-module-size'), findsNothing);
    await tapVisible(tester, key('sticker-page-a4'));
    expect(selected('sticker-size-60'), isTrue);

    expect(tester.takeException(), isNull);
    expect(truncatedTexts(tester), isEmpty);
    expect(clippedChipLabels(tester), isEmpty);

    // Remembered for doors, not for the other kinds.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final StickerDesign? kept = await tester.runAsync<StickerDesign?>(
      () => StickerStore(disk).load(StickerKind.door),
    );
    expect((kept!.sizeMm, kept.tile), (60, true));
    expect(
      await tester.runAsync(
        () => StickerStore(disk).load(StickerKind.zenAbout),
      ),
      isNull,
    );
    await pumpDesigner(tester, <StickerSubject>[_door()]);
    expect(selected('sticker-size-60'), isTrue);
    expect(tester.widget<SwitchListTile>(key('sticker-tile')).value, isTrue);
    semantics.dispose();
  });

  testWidgets('a ready text goes on the sticker and stays editable, and '
      'every choice is remembered per kind', (WidgetTester tester) async {
    await pumpDesigner(tester, <StickerSubject>[_door()]);
    // The door starts with the flat's name and its first text.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sticker-top')))
          .controller!
          .text,
      'Dom Kowalskich',
    );
    await tapVisible(tester, find.byKey(const Key('sticker-presets-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dom Kowalskich — zeskanuj QR, aby nas poznać'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sticker-bottom')))
          .controller!
          .text,
      'Dom Kowalskich — zeskanuj QR, aby nas poznać',
    );
    await tester.enterText(
      find.byKey(const Key('sticker-caption')),
      'Dzwonek nie działa',
    );
    await tapVisible(tester, find.byKey(const Key('sticker-style-dots')));
    await tapVisible(tester, find.byKey(const Key('sticker-pattern-leaves')));
    await tapVisible(tester, find.byKey(const Key('sticker-theme-ocean')));
    await tapVisible(tester, find.byKey(const Key('sticker-signature')));
    await tapVisible(tester, find.byKey(const Key('sticker-page-a5')));
    await tapVisible(tester, find.byKey(const Key('sticker-format-png')));
    // The logo is offered only where the code can carry it.
    expect(
      tester
              .widget<SwitchListTile>(find.byKey(const Key('sticker-logo')))
              .onChanged ==
          null,
      QrMatrix.encode(_door().data, robust: true).logoHole == null,
    );

    // Leaving saves it; coming back shows it again.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final StickerDesign? kept = await tester.runAsync<StickerDesign?>(
      () => StickerStore(disk).load(StickerKind.door),
    );
    expect(kept, isNotNull);
    expect(kept!.texts.caption, 'Dzwonek nie działa');
    expect(kept.texts.bottom, 'Dom Kowalskich — zeskanuj QR, aby nas poznać');
    expect(
      (kept.style, kept.pattern, kept.theme, kept.signature, kept.page),
      (
        QrStyle.dots,
        StickerPattern.leaves,
        StickerTheme.ocean,
        false,
        StickerPage.a5,
      ),
    );
    expect(kept.format, StickerFormat.png);
    expect(
      await tester.runAsync(
        () => StickerStore(disk).load(StickerKind.zenAbout),
      ),
      isNull,
    );

    await pumpDesigner(tester, <StickerSubject>[_door()]);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('sticker-caption')))
          .controller!
          .text,
      'Dzwonek nie działa',
    );
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('sticker-style-dots')))
          .selected,
      isTrue,
    );
  });

  testWidgets('a code too dense for a logo offers none, and a remembered '
      'logo is left out of it', (WidgetTester tester) async {
    final StickerSubject dense = StickerSubject(
      kind: StickerKind.door,
      data: 'https://robertostrowskijagoda.github.io/Zen/m#${'x' * 460}',
      label: 'Kod na drzwi',
    );
    expect(QrMatrix.encode(dense.data, robust: true).logoHole, isNull);
    await tester.runAsync(
      () => StickerStore(
        disk,
      ).save(StickerKind.door, const StickerDesign(logo: true)),
    );
    await pumpDesigner(tester, <StickerSubject>[dense]);
    final SwitchListTile logo = tester.widget<SwitchListTile>(
      find.byKey(const Key('sticker-logo')),
    );
    expect(logo.onChanged, isNull);
    expect(logo.value, isFalse);
    expect(find.textContaining('za gęsty na logo'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('sticker-save')));
    await settleUntil(tester, () => outlet.saved.isNotEmpty);
  });

  testWidgets('saves, shares and prints the chosen file', (
    WidgetTester tester,
  ) async {
    await pumpDesigner(tester, <StickerSubject>[StickerSubject.zenAbout()]);
    // The short link carries the logo.
    await tapVisible(tester, find.byKey(const Key('sticker-logo')));
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('sticker-logo')))
          .value,
      isTrue,
    );
    await tapVisible(tester, find.byKey(const Key('sticker-save')));
    await settleUntil(tester, () => outlet.saved.isNotEmpty);
    final (String name, Uint8List bytes, String mime) = outlet.saved.single;
    expect(name, 'zen-naklejka.pdf');
    expect(mime, 'application/pdf');
    expect(latin1.decode(bytes.sublist(0, 8)), '%PDF-1.4');
    await tester.pump();
    expect(find.text('Zapisano: Pobrane/zen-naklejka.pdf'), findsOneWidget);

    await tapVisible(tester, find.byKey(const Key('sticker-format-jpg')));
    expect(find.text('Zapisz jako JPG'), findsOneWidget);
    await tapVisible(tester, find.byKey(const Key('sticker-share')));
    await settleUntil(tester, () => outlet.shared.isNotEmpty);
    expect(outlet.shared.single, ('zen-naklejka.jpg', 'image/jpeg'));

    // Printing always takes the PDF.
    await tapVisible(tester, find.byKey(const Key('sticker-print')));
    await settleUntil(tester, () => outlet.printed.isNotEmpty);
    expect(outlet.printed.single, 'zen-naklejka.pdf');
  });

  testWidgets('"O aplikacji" offers a promotional sticker: the page about '
      'Zen or the own invitation', (WidgetTester tester) async {
    for (final PeerShareProfile? me in <PeerShareProfile?>[_ada, null]) {
      tester.view.physicalSize = const Size(400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey<Object?>(me),
          overrides: overrides(me: me),
          child: MaterialApp(theme: ZenTheme.dark(), home: const AboutScreen()),
        ),
      );
      await tester.pump();
      final Finder button = find.byKey(const Key('about-promo-sticker'));
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Naklejka promująca Zen'), findsOneWidget);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sticker-designer')), findsOneWidget);
      final TextField bottom = tester.widget<TextField>(
        find.byKey(const Key('sticker-bottom')),
      );
      expect(
        bottom.controller!.text,
        'Prywatna sieć społecznościowa — zeskanuj',
      );
      if (me == null) {
        // No address yet: only the page about Zen.
        expect(
          find.byKey(const Key('sticker-subject-friendInvite')),
          findsNothing,
        );
        continue;
      }
      await tapVisible(
        tester,
        find.byKey(const Key('sticker-subject-friendInvite')),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('sticker-top')))
            .controller!
            .text,
        'Ada',
      );
      await tapVisible(tester, find.byKey(const Key('sticker-save')));
      await settleUntil(tester, () => outlet.saved.isNotEmpty);
      expect(outlet.saved.single.$1, 'zen-zaproszenie.pdf');
      expect(
        zenPageUrl('about/'),
        'https://robertostrowskijagoda.github.io/Zen/about/',
      );
    }
  });
}
