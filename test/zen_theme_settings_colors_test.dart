import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_backdrop.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// The colours a screen of [zen] may draw text and icons with: the
/// palette, its tones, and the readable ink on a filled accent.
Set<int> _allowed(ZenColors zen) => <Color>{
  zen.background,
  zen.surface,
  zen.surfaceRaised,
  zen.surfaceMuted,
  zen.surfaceSunk,
  zen.outline,
  zen.outlineSoft,
  zen.outlineStrong,
  zen.textPrimary,
  zen.textSecondary,
  zen.textMuted,
  zen.accent,
  zen.accentSecondary,
  zen.accentTertiary,
  zen.accentSoft,
  zen.onAccent,
  zen.success,
  zen.warning,
  zen.danger,
  ...ZenTones.of(zen),
  ZenColors.foregroundFor(const Color(0xFFFFFFFF)),
  ZenColors.foregroundFor(const Color(0xFF000000)),
}.map(_rgb).toSet();

/// The colour without its opacity (a faded text is still its colour).
int _rgb(Color c) => c.toARGB32() & 0xFFFFFF;

/// The colours of the visible glyphs of a text or an icon.
void _collect(InlineSpan span, Color? inherited, List<Color> out) {
  final Color? color = span.style?.color ?? inherited;
  if (span is TextSpan) {
    if ((span.text ?? '').trim().isNotEmpty && color != null) {
      out.add(color);
    }
    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      _collect(child, color, out);
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _frames(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  for (final AppPalette palette in AppPalette.values) {
    for (final Brightness brightness in Brightness.values) {
      testWidgets(
        'the settings use only colours of ${palette.name} ${brightness.name}',
        (WidgetTester tester) async {
          tester.view.physicalSize = const Size(412 * 2, 3200 * 2);
          tester.view.devicePixelRatio = 2;
          addTearDown(tester.view.reset);
          final ThemeData theme = ZenTheme.forPalette(
            palette,
            AppSettings.defaultAccentTheme,
            brightness,
          );
          final ZenColors zen = theme.extension<ZenColors>()!;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                socialHubAutoHydrateProvider.overrideWithValue(false),
                signalTransportProvider.overrideWithValue(
                  MemorySignalTransport(),
                ),
                ledgerNodeEnabledProvider.overrideWithValue(true),
                ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
              ],
              child: MaterialApp(
                theme: theme,
                builder: (BuildContext context, Widget? child) =>
                    ZenBackdropHost(child: child ?? const SizedBox.shrink()),
                home: const AppShellScreen(),
              ),
            ),
          );
          await tester.runAsync(_settle);
          await _frames(tester);
          await tester.tap(find.byKey(const Key('chats-status-chip')));
          await _frames(tester);

          final Finder settings = find.byKey(const Key('profile-page'));
          expect(settings, findsOneWidget);
          final Set<int> allowed = _allowed(zen);
          final List<String> strays = <String>[];
          int glyphs = 0;
          // Icons are drawn as text too: this covers both.
          for (final RichText text in tester.widgetList<RichText>(
            find.descendant(of: settings, matching: find.byType(RichText)),
          )) {
            final List<Color> colors = <Color>[];
            _collect(text.text, null, colors);
            for (final Color c in colors) {
              glyphs++;
              if (!allowed.contains(_rgb(c))) {
                strays.add(
                  '"${text.text.toPlainText()}" in '
                  '#${_rgb(c).toRadixString(16).padLeft(6, '0')}',
                );
              }
            }
          }
          expect(glyphs, greaterThan(20));
          expect(strays, isEmpty, reason: strays.join('\n'));

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(_settle);
        },
      );
    }
  }
}
