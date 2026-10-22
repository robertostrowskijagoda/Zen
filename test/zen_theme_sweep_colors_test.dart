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

/// The main places visited, in rail order (films and the alarm are left
/// out: video keeps its own white type, the alarm its emergency red).
const List<String> _tabs = <String>[
  'chats',
  'graph',
  'profile',
  'feed',
  'meet',
  'dating',
  'neighbors',
  'pyramid',
  'wallet',
];

/// The colours a screen of [zen] may draw text and icons with: the
/// palette, its tones and the readable ink on a filled colour.
List<Color> _palette(ZenColors zen) => <Color>[
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
];

List<double> _rgb(Color c) => <double>[c.r * 255, c.g * 255, c.b * 255];

/// Whether [c] (its opacity aside) is a colour of [palette] or a mix of
/// two of them (a tone faded over the background, a blend of accents):
/// within a couple of steps of a point on the line between the two.
bool _ofPalette(Color c, List<Color> palette) {
  final List<double> p = _rgb(c);
  double gap(List<double> a, List<double> b) {
    double worst = 0;
    for (int i = 0; i < 3; i++) {
      final double d = (a[i] - b[i]).abs();
      if (d > worst) {
        worst = d;
      }
    }
    return worst;
  }

  final List<List<double>> all = palette.map(_rgb).toList();
  for (final List<double> a in all) {
    if (gap(a, p) <= 2) {
      return true;
    }
  }
  for (int i = 0; i < all.length; i++) {
    for (int j = i + 1; j < all.length; j++) {
      final List<double> a = all[i];
      final List<double> b = all[j];
      double dot = 0;
      double len = 0;
      for (int k = 0; k < 3; k++) {
        dot += (p[k] - a[k]) * (b[k] - a[k]);
        len += (b[k] - a[k]) * (b[k] - a[k]);
      }
      if (len == 0) {
        continue;
      }
      final double t = (dot / len).clamp(0.0, 1.0);
      final List<double> on = <double>[
        for (int k = 0; k < 3; k++) a[k] + (b[k] - a[k]) * t,
      ];
      if (gap(on, p) <= 3) {
        return true;
      }
    }
  }
  return false;
}

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
  for (final Brightness brightness in Brightness.values) {
    testWidgets('the main screens of Zielony szyfr ${brightness.name} keep '
        'every text and icon in its palette', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(412 * 2, 1600 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final ThemeData theme = ZenTheme.forPalette(
        AppPalette.cipher,
        AppSettings.defaultAccentTheme,
        brightness,
      );
      final ZenColors zen = theme.extension<ZenColors>()!;
      expect(zen.duotone, isTrue);
      final List<Color> palette = _palette(zen);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            signalTransportProvider.overrideWithValue(MemorySignalTransport()),
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

      final List<String> strays = <String>[];
      final Set<String> seen = <String>{};
      int glyphs = 0;
      void scan(String where) {
        seen.add(where);
        // Icons are drawn as text too: this covers both.
        for (final RichText text in tester.widgetList<RichText>(
          find.byType(RichText),
        )) {
          final List<Color> colors = <Color>[];
          _collect(text.text, null, colors);
          for (final Color c in colors) {
            glyphs++;
            if (!_ofPalette(c, palette)) {
              final String hex = (c.toARGB32() & 0xFFFFFF)
                  .toRadixString(16)
                  .padLeft(6, '0');
              strays.add('$where: "${text.text.toPlainText()}" in #$hex');
            }
          }
        }
      }

      Future<void> backToRail() async {
        if (find.byKey(const Key('side-tab-chats')).evaluate().isEmpty) {
          await tester
              .state<NavigatorState>(find.byType(Navigator).first)
              .maybePop();
          await _frames(tester);
        }
      }

      for (final String tab in _tabs) {
        final Finder button = find.byKey(Key('side-tab-$tab'));
        if (button.evaluate().isEmpty) {
          continue;
        }
        await tester.tap(button);
        await _frames(tester);
        scan(tab);
        await backToRail();
      }
      await tester.tap(find.byKey(const Key('side-tab-chats')));
      await _frames(tester);
      await tester.tap(find.byKey(const Key('chats-status-chip')));
      await _frames(tester);
      scan('settings');

      expect(seen.length, greaterThanOrEqualTo(6), reason: seen.join(', '));
      expect(glyphs, greaterThan(100));
      expect(strays, isEmpty, reason: strays.join('\n'));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(_settle);
    });
  }
}
