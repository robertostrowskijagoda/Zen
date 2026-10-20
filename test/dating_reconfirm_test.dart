import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/dating/presentation/dating_reconfirm.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  Future<MemoryAppSecurityService> security({required bool password}) async {
    final MemoryAppSecurityService service = MemoryAppSecurityService(
      passwordIterations: 10,
    );
    await service.initialize(settings: const AppSettings());
    if (password) {
      await service.setPassword('sekret123');
    }
    return service;
  }

  Future<void> pump(
    WidgetTester tester,
    MemoryAppSecurityService service, {
    bool askOnOpen = true,
    Duration away = Duration.zero,
  }) => tester.pumpWidget(
    ProviderScope(
      overrides: [appSecurityServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        home: DatingReconfirm(
          away: away,
          askOnOpen: askOnOpen,
          child: const Scaffold(body: Text('treść randek')),
        ),
      ),
    ),
  );

  Future<void> typePassword(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const Key('sensitive-access-password')),
      'sekret123',
    );
    await tester.tap(find.byKey(const Key('sensitive-access-confirm')));
    await tester.pumpAndSettle();
  }

  testWidgets('dating opens only after the app password, and asks again '
      'after the app was in the background', (WidgetTester tester) async {
    final MemoryAppSecurityService service = await security(password: true);
    await pump(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsNothing);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsOneWidget);
    await typePassword(tester);
    expect(find.text('treść randek'), findsOneWidget);

    // Away and back: shut again, and asked again at once.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsNothing);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsOneWidget);

    // Declined: the lock screen stays until the person unlocks it.
    await tester.tap(find.text('Anuluj'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dating-locked')), findsOneWidget);
    expect(find.text('treść randek'), findsNothing);
    await tester.tap(find.byKey(const Key('dating-unlock')));
    await tester.pumpAndSettle();
    await typePassword(tester);
    expect(find.text('treść randek'), findsOneWidget);
  });

  testWidgets('a short trip out of the app does not ask again', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService service = await security(password: true);
    await pump(tester, service, away: const Duration(hours: 1));
    await tester.pumpAndSettle();
    await typePassword(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsOneWidget);
  });

  testWidgets('without an app password there is nothing to ask', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService service = await security(password: false);
    await pump(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsOneWidget);
  });

  testWidgets('screens opened from inside dating do not ask on opening', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService service = await security(password: true);
    await pump(tester, service, askOnOpen: false);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsOneWidget);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsNothing);
  });
}
