import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
      'sticker-crop-marks',
      'sticker-format-svg',
      'sticker-save',
      'sticker-share',
      'sticker-print',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    // The preview says what is on it.
    expect(previewLabel(tester), contains('Prywatny komunikator bez serwerów'));
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
        'Prywatny komunikator bez serwerów — zeskanuj',
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
