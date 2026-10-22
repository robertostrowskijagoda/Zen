import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_locales.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/chat/presentation/disappearing_timer_dialog.dart';
import 'package:zen/src/features/chat/presentation/message_extras.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/presentation/met_level_prompt.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
import 'package:zen/src/features/social/presentation/friend_nickname_prompt.dart';

import 'support/text_fit.dart';

/// The smallest phone, with the keyboard open (about 260 dp of it).
const Size _phone = Size(320, 568);
const double _keyboard = 260;

/// A dialog or a sheet to open, and the button that must stay above the
/// keyboard ([action]; null: no keyboard for this one).
typedef _Case = ({
  String name,
  Future<void> Function(BuildContext context) open,
  Key shown,
  Key? action,
});

final List<_Case> _cases = <_Case>[
  (
    name: 'edit a message',
    open: (BuildContext c) => showEditMessageDialog(c, 'Hej, co słychać?'),
    shown: const Key('edit-message-field'),
    action: const Key('edit-message-save'),
  ),
  (
    name: 'met in person',
    open: (BuildContext c) => showDialog<void>(
      context: c,
      builder: (BuildContext _) =>
          const MetLevelDialog(name: 'Aleksandra Wielopolska-Konstantynowicz'),
    ),
    shown: const Key('met-level-dialog'),
    action: const Key('met-level-save'),
  ),
  (
    name: 'friend nickname',
    open: (BuildContext c) => promptForFriendNickname(
      context: c,
      friend: const FriendProfile(address: 'ania.ygg', displayName: 'Ania'),
    ),
    shown: const Key('friend-nickname-field'),
    action: const Key('friend-nickname-save'),
  ),
  (
    name: 'account password',
    open: (BuildContext c) => askAccountPassword(c, t('Hasło konta')),
    shown: const Key('account-password-field'),
    action: const Key('account-password-ok'),
  ),
  (
    name: 'password before a sensitive place',
    open: (BuildContext c) => confirmSensitiveAccess(c, reason: 'Sprawdzam'),
    shown: const Key('sensitive-access-dialog'),
    action: const Key('sensitive-access-confirm'),
  ),
  (
    name: 'disappearing messages',
    open: (BuildContext c) => showDisappearingTimerDialog(c, current: 0),
    shown: const Key('disappearing-timer-dialog'),
    action: null,
  ),
  (
    name: 'reaction picker',
    open: (BuildContext c) => pickReaction(c),
    shown: const Key('reaction-picker'),
    action: null,
  ),
];

Future<void> _pumpAndOpen(
  WidgetTester tester,
  _Case c, {
  required String code,
  required double scale,
}) async {
  final MemoryAppSecurityService security = MemoryAppSecurityService(
    hasPassword: true,
    passwordIterations: 10,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appSecurityServiceProvider.overrideWithValue(security)],
      child: MaterialApp(
        theme: ZenTheme.dark(),
        locale: zenLocaleOf(code),
        supportedLocales: zenSupportedLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Align(
              alignment: Alignment.topCenter,
              child: TextButton(
                key: const Key('open'),
                onPressed: () => unawaited(c.open(context)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Reads the Dart files under [dir].
Iterable<(String, String)> _sources(String dir) sync* {
  for (final FileSystemEntity f in Directory(dir).listSync(recursive: true)) {
    if (f is File && f.path.endsWith('.dart')) {
      yield (f.path, f.readAsStringSync());
    }
  }
}

/// The index of the bracket closing the one at [open] (strings and line
/// comments skipped).
int _closing(String s, int open) {
  int depth = 0;
  int i = open;
  while (i < s.length) {
    final String c = s[i];
    if (s.startsWith('//', i)) {
      final int nl = s.indexOf('\n', i);
      i = nl < 0 ? s.length : nl;
      continue;
    }
    if (c == "'" || c == '"') {
      final String quote = s.startsWith(c * 3, i) ? c * 3 : c;
      i += quote.length;
      while (i < s.length && !s.startsWith(quote, i)) {
        i += s[i] == r'\' ? 2 : 1;
      }
      i += quote.length;
      continue;
    }
    if ('([{'.contains(c)) {
      depth++;
    } else if (')]}'.contains(c)) {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
    i++;
  }
  return s.length - 1;
}

void main() {
  setUpAll(loadAppFonts);
  tearDown(ZenI18n.debugReset);

  for (final String code in const <String>['pl', 'de', 'ar']) {
    for (final double scale in const <double>[1, 1.3]) {
      for (final _Case c in _cases) {
        testWidgets(
          '${c.name} fits ${_phone.width.toInt()}x${_phone.height.toInt()} '
          '${c.action == null ? '' : 'over the keyboard '}'
          'in "$code" at text scale $scale',
          (WidgetTester tester) async {
            ZenI18n.debugUse(code, textFitStrings(code));
            tester.view.physicalSize = _phone;
            tester.view.devicePixelRatio = 1;
            if (c.action != null) {
              tester.view.viewInsets = const FakeViewPadding(bottom: _keyboard);
            }
            addTearDown(tester.view.reset);

            await _pumpAndOpen(tester, c, code: code, scale: scale);

            final Object? overflow = tester.takeException();
            expect(overflow, isNull, reason: '${c.name}: $overflow');
            expect(find.byKey(c.shown), findsOneWidget, reason: c.name);
            expect(truncatedTexts(tester), isEmpty, reason: c.name);
            final Key? action = c.action;
            if (action != null) {
              // The decision stays on screen, above the keyboard.
              final Rect button = tester.getRect(find.byKey(action));
              expect(
                button.bottom,
                lessThanOrEqualTo(_phone.height - _keyboard + 0.5),
                reason: '${c.name}: under the keyboard',
              );
              expect(button.top, greaterThanOrEqualTo(0), reason: c.name);
            }

            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }

  group('right to left', () {
    test('a graph label takes the direction of its own letters', () {
      expect(labelDirection('Ania', TextDirection.rtl), TextDirection.ltr);
      expect(labelDirection('علي', TextDirection.ltr), TextDirection.rtl);
      expect(labelDirection('שרה', TextDirection.ltr), TextDirection.rtl);
      expect(labelDirection('Ольга', TextDirection.rtl), TextDirection.ltr);
      // No letter with a direction: the app's language decides.
      expect(labelDirection('42 ✨', TextDirection.rtl), TextDirection.rtl);
      expect(labelDirection('', TextDirection.ltr), TextDirection.ltr);
    });

    test('layouts use start and end, not left and right', () {
      final RegExp physicalInsets = RegExp(
        r'EdgeInsets\.only\([^)]*\b(left|right):',
      );
      final RegExp physicalAlign = RegExp(
        r'(alignment:|\?|:)\s*Alignment\.(centerLeft|centerRight|topLeft|'
        r'topRight|bottomLeft|bottomRight)\b',
      );
      final RegExp lopsided = RegExp(
        r'EdgeInsets\.fromLTRB\(\s*([\d.]+)\s*,\s*[^,()]+,\s*([\d.]+)\s*,',
      );
      final List<String> found = <String>[];
      for (final (String path, String text) in <(String, String)>[
        ..._sources('lib/src/features'),
        ..._sources('lib/src/app/theme'),
      ]) {
        final List<String> lines = text.split('\n');
        for (int i = 0; i < lines.length; i++) {
          final String line = lines[i];
          final RegExpMatch? lop = lopsided.firstMatch(line);
          if (physicalInsets.hasMatch(line) ||
              (physicalAlign.hasMatch(line) &&
                  !line.contains('begin:') &&
                  !line.contains('end:')) ||
              (lop != null && lop.group(1) != lop.group(2))) {
            found.add('$path:${i + 1}: ${line.trim()}');
          }
        }
      }
      expect(found, isEmpty, reason: found.join('\n'));
    });
  });

  test('every alert dialog scrolls (long text, a field over the keyboard)', () {
    final List<String> found = <String>[];
    for (final (String path, String text) in _sources('lib')) {
      for (final RegExpMatch m in RegExp(
        r'\bAlertDialog(\.adaptive)?\(',
      ).allMatches(text)) {
        final int open = m.end - 1;
        final String body = text.substring(open, _closing(text, open) + 1);
        final int content = body.indexOf('content:');
        // Scrollable itself, or its content is a scroll view already.
        final bool scrolls =
            body.contains('scrollable: true') ||
            content < 0 ||
            RegExp(
              r'^content:\s*(const\s+)?(SizedBox|ConstrainedBox|SelectionArea|'
              r'Padding)?[^;]*?\b(SingleChildScrollView|ListView)'
              r'(\.builder|\.separated)?\(',
            ).hasMatch(
              body.substring(content, (content + 260).clamp(0, body.length)),
            );
        if (!scrolls) {
          final int line = '\n'.allMatches(text.substring(0, m.start)).length;
          found.add('$path:${line + 1}');
        }
      }
    }
    expect(found, isEmpty, reason: found.join('\n'));
  });
}
