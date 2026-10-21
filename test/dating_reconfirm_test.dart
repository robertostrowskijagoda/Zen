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

  Future<void> pump(WidgetTester tester, MemoryAppSecurityService service) =>
      tester.pumpWidget(
        ProviderScope(
          overrides: [appSecurityServiceProvider.overrideWithValue(service)],
          child: const MaterialApp(
            home: DatingReconfirm(child: Scaffold(body: Text('treść randek'))),
          ),
        ),
      );

  testWidgets('dating opens at once in an unlocked app: no password, no '
      'biometrics, also after a trip out of the app', (
    WidgetTester tester,
  ) async {
    late final MemoryAppSecurityService service;
    await tester.runAsync(() async {
      service = await security(password: true);
    });
    expect(service.isLocked, isFalse);
    await pump(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsOneWidget);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsNothing);

    // Out of the app and back while the app itself stays unlocked: still
    // open (the app's own lock decides when to lock).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsOneWidget);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsNothing);
  });

  testWidgets('while the app is locked nothing of dating is even built; '
      'unlocking the app opens it again by itself', (
    WidgetTester tester,
  ) async {
    late final MemoryAppSecurityService service;
    await tester.runAsync(() async {
      service = await security(password: true);
    });
    await pump(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsOneWidget);

    service.lock();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('dating-locked')), findsOneWidget);
    expect(find.text('treść randek'), findsNothing);

    await tester.runAsync(() async {
      expect(await service.unlock('sekret123'), isTrue);
    });
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsOneWidget);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsNothing);
  });

  testWidgets('without an app password there is nothing to ask', (
    WidgetTester tester,
  ) async {
    late final MemoryAppSecurityService service;
    await tester.runAsync(() async {
      service = await security(password: false);
    });
    await pump(tester, service);
    await tester.pumpAndSettle();
    expect(find.text('treść randek'), findsOneWidget);
  });
}
