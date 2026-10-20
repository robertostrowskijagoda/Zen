import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_language_controller.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/presentation/language_screen.dart';

/// Ustawienia → Język: "automatically" and every language; a choice is
/// remembered and the screen speaks it at once.
void main() {
  // Back to Polish, the text of the code, with nothing loaded.
  tearDown(ZenI18n.debugReset);

  testWidgets('lists "automatically" and every language by its own name', (
    WidgetTester tester,
  ) async {
    await _pumpLanguageScreen(
      tester,
      store: MemoryZenLanguageStore(),
      loaded: <String>[],
    );
    final Finder automatic = find.byKey(
      const ValueKey<String>('language-option-auto'),
    );
    expect(automatic, findsOneWidget);
    expect(
      find.descendant(of: automatic, matching: find.text('Automatycznie')),
      findsOneWidget,
    );
    // The system speaks German.
    expect(
      find.descendant(
        of: automatic,
        matching: find.text('Jak w systemie: Deutsch'),
      ),
      findsOneWidget,
    );
    // Nothing chosen yet: the only check mark is on "automatically".
    expect(_checkMark(automatic), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);

    for (final ZenLanguage language in kZenLanguages) {
      final Finder option = find.byKey(
        ValueKey<String>('language-option-${language.code}'),
      );
      await _reveal(tester, option);
      expect(option, findsOneWidget, reason: language.code);
      expect(
        find.descendant(of: option, matching: find.text(language.nativeName)),
        findsOneWidget,
        reason: language.code,
      );
      expect(
        find.descendant(
          of: option,
          matching: find.text(language.code.toUpperCase()),
        ),
        findsOneWidget,
        reason: language.code,
      );
      expect(_checkMark(option), findsNothing, reason: language.code);
    }
  });

  testWidgets('choosing English remembers it and the screen speaks it', (
    WidgetTester tester,
  ) async {
    final MemoryZenLanguageStore store = MemoryZenLanguageStore();
    final List<String> loaded = <String>[];
    await _pumpLanguageScreen(tester, store: store, loaded: loaded);
    expect(find.text('Język'), findsOneWidget);

    final Finder english = find.byKey(
      const ValueKey<String>('language-option-en'),
    );
    await _reveal(tester, english);
    await tester.tap(english);
    await tester.pumpAndSettle();

    expect(store.code, 'en');
    expect(store.writes, 1);
    expect(loaded, <String>['en']);
    expect(ZenI18n.code, 'en');
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Język'), findsNothing);
    expect(_checkMark(english), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('"automatically" forgets the choice and follows the system', (
    WidgetTester tester,
  ) async {
    final MemoryZenLanguageStore store = MemoryZenLanguageStore();
    final List<String> loaded = <String>[];
    await _pumpLanguageScreen(tester, store: store, loaded: loaded);

    final Finder english = find.byKey(
      const ValueKey<String>('language-option-en'),
    );
    await _reveal(tester, english);
    await tester.tap(english);
    await tester.pumpAndSettle();
    expect(store.code, 'en');
    expect(find.text('Language'), findsOneWidget);

    final Finder automatic = find.byKey(
      const ValueKey<String>('language-option-auto'),
    );
    await _reveal(tester, automatic, up: true);
    await tester.tap(automatic);
    await tester.pumpAndSettle();

    expect(store.code, isNull);
    expect(store.writes, 2);
    // The system speaks German, so "automatically" is German.
    expect(loaded, <String>['en', 'de']);
    expect(ZenI18n.code, 'de');
    expect(find.text('Sprache'), findsOneWidget);
    expect(find.text('Wie das System: Deutsch'), findsOneWidget);
    expect(_checkMark(automatic), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });
}

/// What the fake loader "loads" for a language (the texts of this screen).
const Map<String, Map<String, Object?>> _strings =
    <String, Map<String, Object?>>{
      'en': <String, Object?>{
        'Język': 'Language',
        'Języki': 'Languages',
        'Automatycznie': 'Automatically',
        'Jak w systemie: {language}': 'Like the system: {language}',
      },
      'de': <String, Object?>{
        'Język': 'Sprache',
        'Języki': 'Sprachen',
        'Automatycznie': 'Automatisch',
        'Jak w systemie: {language}': 'Wie das System: {language}',
      },
    };

/// The language screen as the only route, with the choice kept in [store]
/// and every loaded language code added to [loaded]. The system speaks
/// German.
Future<void> _pumpLanguageScreen(
  WidgetTester tester, {
  required MemoryZenLanguageStore store,
  required List<String> loaded,
}) async {
  tester.platformDispatcher.localesTestValue = const <Locale>[
    Locale('de', 'DE'),
  ];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);

  Future<void> load(String code) async {
    loaded.add(code);
    ZenI18n.debugUse(code, _strings[code] ?? const <String, Object?>{});
  }

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        zenLanguageStoreProvider.overrideWithValue(store),
        zenLanguageLoaderProvider.overrideWithValue(load),
      ],
      child: MaterialApp(theme: ZenTheme.light(), home: const LanguageScreen()),
    ),
  );
  await tester.pump();
}

/// Scrolls the list (longer than the screen) until [option] is in view,
/// downwards or, with [up], upwards, and lets it settle there so a tap
/// lands on it.
Future<void> _reveal(
  WidgetTester tester,
  Finder option, {
  bool up = false,
}) async {
  await tester.scrollUntilVisible(
    option,
    up ? -200 : 200,
    scrollable: find
        .descendant(
          of: find.byKey(const ValueKey<String>('language-screen')),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pump();
}

/// The check mark of the chosen option inside [option].
Finder _checkMark(Finder option) =>
    find.descendant(of: option, matching: find.byIcon(Icons.check_rounded));
