import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/meet/presentation/met_level_prompt.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/presentation/age_gate.dart';
import 'package:zen/src/features/settings/presentation/group_invite_tile.dart';

/// The screens of the levels of acquaintance and the age gate (§8, §27).
Widget _app(ProviderContainer container, Widget home) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: ZenTheme.dark(), home: home),
    );

ProviderContainer _container([AppSettings settings = const AppSettings()]) {
  final ProviderContainer c = ProviderContainer(
    overrides: [
      appSettingsInitialStateProvider.overrideWithValue(settings),
      appSettingsHydrationEnabledProvider.overrideWithValue(false),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

DateTime _today() => DateTime(2026, 10, 20);

void main() {
  testWidgets('the age gate asks once, then shows the section', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = _container();
    await tester.pumpWidget(
      _app(c, const AgeGate(now: _today, child: Text('randki'))),
    );
    expect(find.byKey(const Key('age-gate-ask')), findsOneWidget);
    expect(find.text('randki'), findsNothing);

    await tester.tap(find.byKey(const Key('age-gate-adult')));
    await tester.pumpAndSettle();
    expect(find.text('randki'), findsOneWidget);
    expect(c.read(appSettingsControllerProvider).adultConfirmed, isTrue);
  });

  testWidgets('under 18 the section stays closed', (WidgetTester tester) async {
    final ProviderContainer c = _container(
      AppSettings(birthDateMillis: DateTime(2012, 3, 4).millisecondsSinceEpoch),
    );
    await tester.pumpWidget(
      _app(c, const AgeGate(now: _today, child: Text('randki'))),
    );
    expect(find.byKey(const Key('age-gate-minor')), findsOneWidget);
    expect(find.text('randki'), findsNothing);
  });

  testWidgets('an adult date of birth opens it', (WidgetTester tester) async {
    final ProviderContainer c = _container(
      AppSettings(birthDateMillis: DateTime(1990, 3, 4).millisecondsSinceEpoch),
    );
    await tester.pumpWidget(
      _app(c, const AgeGate(now: _today, child: Text('randki'))),
    );
    expect(find.byKey(const Key('age-gate')), findsNothing);
    expect(find.text('randki'), findsOneWidget);
  });

  testWidgets('met in person: the level picked comes back, skip keeps it', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = _container();
    FriendLevel? picked;
    bool done = false;
    await tester.pumpWidget(
      _app(
        c,
        Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              key: const Key('open'),
              onPressed: () async {
                // No ledger in this test: only the answer is checked.
                picked = await showMetLevelPrompt(
                  context,
                  address: '200::a1',
                  name: 'Ada',
                );
                done = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('met-level-dialog')), findsOneWidget);
    // "Znajomy" is chosen until something else is.
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('met-level-friend')))
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('met-level-close')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('met-level-save')));
    await tester.pumpAndSettle();
    expect(done, isTrue);
    expect(picked, FriendLevel.close);

    done = false;
    await tester.tap(find.byKey(const Key('open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('met-level-skip')));
    await tester.pumpAndSettle();
    expect(done, isTrue);
    expect(picked, isNull);
  });

  testWidgets('who may invite to groups is chosen with chips', (
    WidgetTester tester,
  ) async {
    final ProviderContainer c = _container();
    await tester.pumpWidget(
      _app(c, const Scaffold(body: GroupInviteFromTile())),
    );
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('group-invite-from-friends')),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('group-invite-from-closeFriends')));
    await tester.pumpAndSettle();
    expect(
      c.read(appSettingsControllerProvider).groupInviteFrom,
      GroupInviteFrom.closeFriends,
    );
  });
}
