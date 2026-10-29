import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_locales.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/about/legal_documents.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/about/presentation/legal_consent_stage.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/update/own_copy.dart';
import 'package:zen/src/features/update/presentation/install_guide_screen.dart';

/// The harness of test/ui_text_fit_*_test.dart and test/large_text_test.dart:
/// the screens to check, how to pump them, and how to find a cut text.
///
/// To check another screen, add a [TextFitScreen] to [textFitScreens]: a
/// name, the window size, and how to get to it (pump the app or the screen,
/// tap through to it). Lists are checked whole when the window is tall
/// enough for all their rows to be laid out.

/// The narrowest phone Zen supports.
const double kNarrowestPhoneWidth = 320;

/// One screen to check: [open] pumps it (inside [TextFitHost]) and goes to
/// it.
@immutable
final class TextFitScreen {
  const TextFitScreen(
    this.name, {
    required this.open,
    this.height = 3000,
    this.check,
  });

  final String name;

  /// The window's height: tall, so a long list is laid out whole (the
  /// width is always [kNarrowestPhoneWidth]).
  final double height;

  final Future<void> Function(WidgetTester tester) open;

  /// More to check on this screen (besides cut texts and overflows).
  final void Function(WidgetTester tester)? check;
}

/// The rail shows every place without scrolling.
void railFits(WidgetTester tester) {
  final ScrollableState scroll = tester.state<ScrollableState>(
    find.descendant(
      of: find.byKey(const Key('side-tabs-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  expect(scroll.position.maxScrollExtent, lessThan(1), reason: 'rail');
}

/// The screens checked, in every language.
final List<TextFitScreen> textFitScreens = <TextFitScreen>[
  // The rail and the chats on a small phone: every button on screen.
  TextFitScreen(
    'shell',
    height: 568,
    open: (WidgetTester tester) => pumpShellForFit(tester),
    check: railFits,
  ),
  // The rail with another tab open (its name under the icon).
  TextFitScreen(
    'shell, films open',
    height: 568,
    check: railFits,
    open: (WidgetTester tester) async {
      await pumpShellForFit(tester);
      await tester.tap(find.byKey(const Key('side-tab-films')));
      await pumpFrames(tester);
    },
  ),
  TextFitScreen(
    'settings',
    open: (WidgetTester tester) async {
      await pumpShellForFit(tester);
      await tester.tap(find.byKey(const Key('chats-status-chip')));
      await pumpFrames(tester);
    },
  ),
  TextFitScreen(
    'about',
    open: (WidgetTester tester) => pumpAboutForFit(tester),
  ),
  for (final AboutSection section in AboutSection.values)
    TextFitScreen(
      'about: ${section.name}',
      open: (WidgetTester tester) async {
        await pumpAboutForFit(tester);
        await tester.tap(find.byKey(Key('about-section-${section.name}')));
        await pumpFrames(tester);
      },
    ),
  for (final InstallSystem system in InstallSystem.values)
    TextFitScreen(
      'install guide: ${system.name}',
      open: (WidgetTester tester) =>
          pumpTextFitHost(tester, InstallGuideScreen(initial: system)),
    ),
  TextFitScreen(
    'first start: the documents',
    open: (WidgetTester tester) => pumpTextFitHost(
      tester,
      const LegalConsentStage(),
      overrides: [
        legalTextsProvider.overrideWith(
          (Ref ref) async => LegalTexts(<LegalDocument, String>{
            for (final LegalDocument d in LegalDocument.values)
              d: File(d.path).readAsStringSync(),
          }),
        ),
      ],
    ),
  ),
];

Future<void> pumpFrames(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> settleAsync() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The app's frame for a screen: the theme, and the locale and text
/// direction of the language under test.
class TextFitHost extends StatelessWidget {
  const TextFitHost({required this.child, required this.overrides, super.key});

  final Widget child;
  final List overrides;

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [...overrides],
      child: MaterialApp(
        theme: ZenTheme.dark(),
        locale: zenLocaleOf(ZenI18n.code),
        supportedLocales: zenSupportedLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: child,
      ),
    );
  }
}

Future<void> pumpTextFitHost(
  WidgetTester tester,
  Widget child, {
  List overrides = const <Object>[],
}) async {
  await tester.pumpWidget(TextFitHost(overrides: overrides, child: child));
  await tester.runAsync(settleAsync);
  await pumpFrames(tester);
}

Future<void> pumpShellForFit(WidgetTester tester) => pumpTextFitHost(
  tester,
  const AppShellScreen(),
  overrides: [
    socialHubAutoHydrateProvider.overrideWithValue(false),
    signalTransportProvider.overrideWithValue(MemorySignalTransport()),
    ledgerNodeEnabledProvider.overrideWithValue(true),
    ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
  ],
);

Future<void> pumpAboutForFit(WidgetTester tester) => pumpTextFitHost(
  tester,
  const AboutScreen(),
  overrides: [
    ownCopyCheckProvider.overrideWith(
      (Ref ref) async => const OwnCopyCheck(OwnCopyState.unknown),
    ),
  ],
);

/// The texts on screen that were cut: a paragraph with more lines than its
/// `maxLines` (shown with "…" or clipped).
///
/// The app's typefaces cover Latin only. Arabic, Cyrillic, Devanagari and
/// the like fall back to the test font, which draws every letter a full
/// square wide — about 1.7 times wider than a phone's own font. Such a text
/// counts as cut only if it would not fit even at a realistic width
/// ([kFallbackWidthRatio]); Chinese, Japanese and Korean are square on a
/// phone too, so they are checked as they are.
List<String> truncatedTexts(WidgetTester tester) {
  final List<String> cut = <String>[];
  for (final RenderObject object in tester.allRenderObjects) {
    if (object is RenderParagraph &&
        object.didExceedMaxLines &&
        !_fitsWithRealGlyphs(object)) {
      cut.add(object.text.toPlainText());
    }
  }
  return cut;
}

/// How wide a phone's own letters of the scripts the test font stands in
/// for are, against the test font's full squares.
const double kFallbackWidthRatio = 0.6;

/// Whether [text] has letters the app's (Latin) typefaces lack, other than
/// the square East Asian ones.
bool usesNarrowFallbackScript(String text) {
  for (final int rune in text.runes) {
    final bool latin =
        rune <= 0x024F ||
        (rune >= 0x1E00 && rune <= 0x1EFF) ||
        (rune >= 0x2000 && rune <= 0x2BFF);
    final bool eastAsian =
        (rune >= 0x2E80 && rune <= 0x9FFF) ||
        (rune >= 0xAC00 && rune <= 0xD7AF) ||
        (rune >= 0xF900 && rune <= 0xFAFF) ||
        (rune >= 0xFF00 && rune <= 0xFFEF);
    if (!latin && !eastAsian) {
      return true;
    }
  }
  return false;
}

/// [paragraph] was cut only because the test font is too wide: laid out
/// at [kFallbackWidthRatio] of its size, it fits.
bool _fitsWithRealGlyphs(RenderParagraph paragraph) {
  if (!usesNarrowFallbackScript(paragraph.text.toPlainText()) ||
      !paragraph.constraints.hasBoundedWidth) {
    return false;
  }
  final TextPainter painter = TextPainter(
    text: paragraph.text,
    textAlign: paragraph.textAlign,
    textDirection: paragraph.textDirection,
    locale: paragraph.locale,
    maxLines: paragraph.maxLines,
    ellipsis: paragraph.overflow == TextOverflow.ellipsis ? '\u2026' : null,
    strutStyle: paragraph.strutStyle,
    textWidthBasis: paragraph.textWidthBasis,
    textScaler: TextScaler.linear(
      paragraph.textScaler.scale(1) * kFallbackWidthRatio,
    ),
  )..layout(maxWidth: paragraph.constraints.maxWidth);
  final bool fits = !painter.didExceedMaxLines;
  painter.dispose();
  return fits;
}

/// The app's typefaces, so texts take their real width (the test font
/// draws every letter a full square wide).
Future<void> loadAppFonts() async {
  final Map<String, List<String>> families = <String, List<String>>{
    'Baloo 2': <String>['assets/fonts/Baloo2-Variable.ttf'],
    'Quicksand': <String>['assets/fonts/pebbles/Quicksand-Variable.ttf'],
    'Hanken Grotesk': <String>['assets/fonts/HankenGrotesk-Variable.ttf'],
    'JetBrains Mono': <String>['assets/fonts/JetBrainsMono-Variable.ttf'],
    'Space Mono': <String>[
      'assets/fonts/SpaceMono-Regular.ttf',
      'assets/fonts/SpaceMono-Bold.ttf',
    ],
    'DM Sans': <String>['assets/fonts/DMSans-Variable.ttf'],
  };
  for (final MapEntry<String, List<String>> family in families.entries) {
    final FontLoader loader = FontLoader(family.key);
    for (final String path in family.value) {
      final File file = File(path);
      if (file.existsSync()) {
        final Uint8List bytes = file.readAsBytesSync();
        loader.addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      }
    }
    await loader.load();
  }
}

/// Every text of a screen fits a 320 dp wide phone in every language Zen
/// speaks: no text ends cut ("…" or clipped after its last line) and no row
/// or column overflows. The screens are listed in [textFitScreens].
///
/// All of it takes minutes, and the tests of one file run one after
/// another, so the languages are spread over [parts] files
/// (test/ui_text_fit_1_test.dart, …) that run at the same time; this is
/// part [part] (from 0): every [parts]-th language of [textFitLanguages].
void textFitTests({required int part, required int parts}) {
  setUpAll(loadAppFonts);
  tearDown(ZenI18n.debugReset);

  final List<String> languages = textFitLanguages();
  for (int i = part; i < languages.length; i += parts) {
    final String code = languages[i];
    group('in "$code"', () {
      setUpAll(() async {
        if (code != 'pl') {
          await initializeDateFormatting(code);
        }
      });

      for (final TextFitScreen screen in textFitScreens) {
        testWidgets('${screen.name}: nothing cut at $kNarrowestPhoneWidth dp', (
          WidgetTester tester,
        ) async {
          ZenI18n.debugUse(code, textFitStrings(code));
          tester.view.physicalSize = Size(kNarrowestPhoneWidth, screen.height);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          await screen.open(tester);

          final Object? overflow = tester.takeException();
          expect(overflow, isNull, reason: '${screen.name} ($code): $overflow');
          expect(
            truncatedTexts(tester),
            isEmpty,
            reason: '${screen.name} ($code): texts cut',
          );
          screen.check?.call(tester);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(settleAsync);
        });
      }
    });
  }
}

/// Every language of `assets/i18n`, and Polish (the texts of the code).
List<String> textFitLanguages() {
  final List<String> codes = <String>[
    for (final FileSystemEntity f in Directory('assets/i18n').listSync())
      if (f.path.endsWith('.json'))
        f.uri.pathSegments.last.replaceAll('.json', ''),
  ]..sort();
  return <String>['pl', ...codes];
}

Map<String, Object?> textFitStrings(String code) {
  if (code == 'pl') {
    return const <String, Object?>{};
  }
  final Object? json = jsonDecode(
    File('assets/i18n/$code.json').readAsStringSync(),
  );
  return json is Map<String, Object?> ? json : const <String, Object?>{};
}
