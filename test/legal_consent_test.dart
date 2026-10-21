import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/about/legal_documents.dart';
import 'package:zen/src/features/about/presentation/legal_document_screen.dart';
import 'package:zen/src/features/about/presentation/legal_markdown.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

const String _terms = '''
# Zen - Terms of Use

*Version for Zen 1.11.0 - last updated 20 October 2026.*

By using Zen you agree. Read the [Privacy Policy](PRIVACY.md) and the
[NOTICE](../NOTICE).

## 1. What Zen is

- No **server**.
- No operator,
  no ads.
''';

const String _privacy = '''
# Zen - Privacy Policy

*Version for Zen 1.11.0 - last updated 21 October 2026.*

| You do this | Who receives what |
|---|---|
| Chat | The recipient. |
''';

const String _notice = 'Zen\nCopyright (C) 2026 Robert Ostrowski-Jagoda\n';

LegalTexts _texts({String terms = _terms}) =>
    LegalTexts(<LegalDocument, String>{
      LegalDocument.terms: terms,
      LegalDocument.privacy: _privacy,
      LegalDocument.licence: _notice,
    });

Widget _gatedApp({
  required MemoryAppSettingsStore store,
  required LegalTexts texts,
  AppSettings initial = const AppSettings(),
}) => ProviderScope(
  overrides: [
    ...buildAppSettingsProviderOverrides(
      store: store,
      initialState: initial,
      hydrationEnabled: false,
    ),
    legalConsentRequiredProvider.overrideWithValue(true),
    legalTextsProvider.overrideWith((Ref ref) async => texts),
  ],
  child: MaterialApp(
    theme: ZenTheme.dark(),
    builder: (BuildContext context, Widget? child) =>
        AppSecurityGate(child: child!),
    home: const Scaffold(body: Text('aplikacja')),
  ),
);

/// A pushed route has finished coming in (or going away).
Future<void> _route(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

const Map<String, int> _englishMonths = <String, int>{
  'January': 1, 'February': 2, 'March': 3, 'April': 4, 'May': 5, 'June': 6, //
  'July': 7, 'August': 8, 'September': 9, 'October': 10, 'November': 11, //
  'December': 12,
};

const Map<String, int> _polishMonths = <String, int>{
  'stycznia': 1, 'lutego': 2, 'marca': 3, 'kwietnia': 4, 'maja': 5, //
  'czerwca': 6, 'lipca': 7, 'sierpnia': 8, 'września': 9, //
  'października': 10, 'listopada': 11, 'grudnia': 12,
};

void main() {
  tearDown(ZenI18n.debugReset);

  group('translations', () {
    test('every translation the app carries exists and is of the same '
        'version as its English source', () {
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      for (final String code in kLegalTranslations) {
        for (final LegalDocument doc in LegalDocument.values) {
          final String path = doc.translationPath(code)!;
          expect(File(path).existsSync(), isTrue, reason: path);
          expect(pubspec, contains('    - $path\n'), reason: path);
        }
      }
      // The Polish date of the last change is the English one.
      for (final LegalDocument doc in <LegalDocument>[
        LegalDocument.terms,
        LegalDocument.privacy,
      ]) {
        final RegExpMatch en = RegExp(
          r'last updated (\d+) (\w+) (\d{4})',
        ).firstMatch(File(doc.path).readAsStringSync())!;
        final RegExpMatch pl = RegExp(
          r'ostatnia zmiana (\d+) (\S+) (\d{4})',
        ).firstMatch(File(doc.translationPath('pl')!).readAsStringSync())!;
        expect(pl.group(1), en.group(1), reason: doc.name);
        expect(_polishMonths[pl.group(2)], _englishMonths[en.group(2)]);
        expect(pl.group(3), en.group(3), reason: doc.name);
      }
    });

    test('the version comes from the English sources only', () {
      final LegalTexts english = _texts();
      final LegalTexts withPolish = LegalTexts(
        english.texts,
        <String, Map<LegalDocument, String>>{
          'pl': <LegalDocument, String>{LegalDocument.terms: '# Regulamin'},
        },
      );
      expect(withPolish.version, english.version);
      expect(withPolish.inLanguage(LegalDocument.terms, 'pl'), '# Regulamin');
      // Not translated: English.
      expect(withPolish.inLanguage(LegalDocument.privacy, 'pl'), _privacy);
      expect(withPolish.inLanguage(LegalDocument.terms, 'de'), _terms);
      // A link to a translation opens the same document.
      expect(
        resolveLegalLink(LegalDocument.terms, 'PRIVACY.pl.md'),
        const LegalLinkTarget.document(LegalDocument.privacy),
      );
      expect(LegalDocument.terms.pathFor('pl'), 'docs/TERMS.pl.md');
      expect(LegalDocument.terms.pathFor('de'), 'docs/TERMS.md');
      expect(LegalDocument.licence.pathFor('pl'), 'docs/NOTICE.pl.md');
    });

    Future<void> pumpDocument(WidgetTester tester) async {
      final LegalTexts texts = LegalTexts(
        _texts().texts,
        <String, Map<LegalDocument, String>>{
          'pl': <LegalDocument, String>{
            LegalDocument.terms: '# Zen - Regulamin\n\nTreść.\n',
          },
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            legalTextsProvider.overrideWith((Ref ref) async => texts),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: const LegalDocumentScreen(document: LegalDocument.terms),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('in Polish the Polish document is shown', (
      WidgetTester tester,
    ) async {
      await pumpDocument(tester);
      expect(find.text('Zen - Regulamin'), findsOneWidget);
      expect(find.text('Zen - Terms of Use'), findsNothing);
      expect(find.textContaining('Dokument jest po angielsku'), findsNothing);
    });

    testWidgets('in a language without a translation: English, and it says '
        'so', (WidgetTester tester) async {
      ZenI18n.debugUse('de', const <String, Object?>{});
      await pumpDocument(tester);
      expect(find.text('Zen - Terms of Use'), findsOneWidget);
      expect(find.textContaining('Dokument jest po angielsku'), findsOneWidget);
    });
  });

  group('the documents and their version', () {
    test('the version is the "last updated" dates, and a digest of the '
        'notice', () {
      final String version = _texts().version;
      expect(version, startsWith('terms:20 October 2026;'));
      expect(version, contains('privacy:21 October 2026;'));
      expect(version, matches(RegExp(r'licence:[0-9a-f]{12}$')));
      // A new date of a document is a new version.
      final String newer = _texts(
        terms: _terms.replaceFirst('20 October', '2 November'),
      ).version;
      expect(newer, isNot(version));
      // The same texts: the same version.
      expect(_texts().version, version);
    });

    test('the documents the app carries have dated versions', () {
      final Map<LegalDocument, String> texts = <LegalDocument, String>{
        for (final LegalDocument d in LegalDocument.values)
          d: File(d.path).readAsStringSync(),
      };
      final String version = legalDocumentsVersion(texts);
      expect(version, matches(RegExp(r'^terms:\d+ \w+ \d{4};')));
      expect(version, contains(RegExp(r';privacy:\d+ \w+ \d{4};')));
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      for (final LegalDocument d in LegalDocument.values) {
        expect(pubspec, contains('    - ${d.path}\n'), reason: d.path);
      }
    });

    test('links lead to the other documents or to the web', () {
      expect(
        resolveLegalLink(LegalDocument.terms, 'PRIVACY.md'),
        const LegalLinkTarget.document(LegalDocument.privacy),
      );
      expect(
        resolveLegalLink(LegalDocument.terms, '../NOTICE'),
        const LegalLinkTarget.document(LegalDocument.licence),
      );
      expect(
        resolveLegalLink(LegalDocument.terms, '../LICENSE'),
        const LegalLinkTarget.url(
          'https://github.com/robertostrowskijagoda/Zen/blob/main/LICENSE',
        ),
      );
      expect(
        resolveLegalLink(LegalDocument.privacy, 'https://example.org/a'),
        const LegalLinkTarget.url('https://example.org/a'),
      );
      expect(resolveLegalLink(LegalDocument.privacy, '#section'), isNull);
      expect(resolveLegalLink(LegalDocument.privacy, 'mailto:a@b.c'), isNull);
    });

    test('the Markdown of the documents comes apart into blocks', () {
      final List<LegalBlock> blocks = parseLegalMarkdown(_terms);
      expect(blocks.first.kind, LegalBlockKind.heading);
      expect(blocks.first.level, 1);
      expect(blocks.first.text, 'Zen - Terms of Use');
      final List<LegalBlock> bullets = blocks
          .where((LegalBlock b) => b.kind == LegalBlockKind.bullet)
          .toList();
      expect(bullets, hasLength(2));
      // A continuation line belongs to its item.
      expect(bullets[1].text, 'No operator, no ads.');
      final LegalBlock paragraph = blocks.firstWhere(
        (LegalBlock b) =>
            b.kind == LegalBlockKind.paragraph && b.text.startsWith('By'),
      );
      expect(paragraph.text, contains('Policy](PRIVACY.md) and the [NOTICE]'));

      final List<LegalBlock> rows = parseLegalMarkdown(
        _privacy,
      ).where((LegalBlock b) => b.kind == LegalBlockKind.tableRow).toList();
      expect(rows, hasLength(2));
      expect(rows[0].header, isTrue);
      expect(rows[1].cells, <String>['Chat', 'The recipient.']);

      final List<LegalSpan> spans = parseLegalInline(
        'See the [Privacy Policy](PRIVACY.md), **bold** and https://x.org/y.',
      );
      expect(
        spans
            .where((LegalSpan s) => s.link != null)
            .map((LegalSpan s) => s.link),
        <String>['PRIVACY.md', 'https://x.org/y'],
      );
      expect(spans.firstWhere((LegalSpan s) => s.bold).text, 'bold');
    });
  });

  testWidgets('first start: the documents come first, are read in the app, '
      'and their acceptance is recorded with its version and date', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore();
    await tester.pumpWidget(_gatedApp(store: store, texts: _texts()));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('legal-consent')), findsOneWidget);
    expect(find.text('aplikacja'), findsNothing);
    expect(find.text('Zanim zaczniesz'), findsOneWidget);
    // Nothing goes on before the box is ticked.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('legal-consent-accept')))
          .onPressed,
      isNull,
    );

    // The terms, in the app: selectable text.
    await tester.tap(find.byKey(const Key('legal-consent-open-terms')));
    await _route(tester);
    expect(find.byKey(const Key('legal-document-terms')), findsOneWidget);
    expect(find.text('Zen - Terms of Use'), findsOneWidget);
    expect(find.byType(SelectionArea), findsWidgets);
    await tester.pageBack();
    await _route(tester);

    await tester.ensureVisible(find.byKey(const Key('legal-consent-agree')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('legal-consent-agree')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('legal-consent-accept')));
    await tester.pump();
    final DateTime before = DateTime.now();
    await tester.tap(find.byKey(const Key('legal-consent-accept')));
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('legal-consent')), findsNothing);
    expect(find.text('aplikacja'), findsOneWidget);
    final AppSettings saved = (await store.load())!;
    expect(saved.legalAcceptedVersion, _texts().version);
    expect(
      saved.legalAcceptedAtMillis,
      greaterThanOrEqualTo(before.millisecondsSinceEpoch - 1000),
    );
    // It survives the settings round-trip.
    final AppSettings round = AppSettings.fromJson(saved.toJson());
    expect(round.legalAcceptedVersion, saved.legalAcceptedVersion);
    expect(round.legalAcceptedAtMillis, saved.legalAcceptedAtMillis);
  });

  testWidgets('accepted documents are not asked again; a new version is', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final AppSettings accepted = AppSettings(
      legalAcceptedVersion: _texts().version,
      legalAcceptedAtMillis: DateTime(2026, 10, 21).millisecondsSinceEpoch,
    );
    await tester.pumpWidget(
      _gatedApp(
        store: MemoryAppSettingsStore(accepted),
        texts: _texts(),
        initial: accepted,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('aplikacja'), findsOneWidget);
    expect(find.byKey(const Key('legal-consent')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _gatedApp(
        store: MemoryAppSettingsStore(accepted),
        texts: _texts(terms: _terms.replaceFirst('20 October', '2 November')),
        initial: accepted,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('legal-consent')), findsOneWidget);
    expect(find.text('Dokumenty się zmieniły'), findsOneWidget);
    expect(find.text('aplikacja'), findsNothing);
  });

  testWidgets('without the requirement (tests, previews) nothing is asked', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: ZenTheme.dark(),
          builder: (BuildContext context, Widget? child) =>
              AppSecurityGate(child: child!),
          home: const Scaffold(body: Text('aplikacja')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('aplikacja'), findsOneWidget);
  });
}
