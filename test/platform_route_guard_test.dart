import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/platform_route_guard.dart';

/// What the engine sends when the system's own routing hands a link to
/// Flutter (Android's onNewIntent with deep linking on).
Future<void> _pushFromSystem(WidgetTester tester, String location) async {
  const MethodCodec codec = JSONMethodCodec();
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/navigation',
    codec.encodeMethodCall(
      MethodCall('pushRouteInformation', <String, Object?>{
        'location': location,
        'state': null,
      }),
    ),
    (ByteData? _) {},
  );
}

void main() {
  testWidgets('a link pushed by the system never reaches the navigator', (
    WidgetTester tester,
  ) async {
    // No onUnknownRoute: without the guard this push crashed the app.
    await tester.pumpWidget(
      const PlatformRouteGuard(child: MaterialApp(home: Text('home'))),
    );
    await _pushFromSystem(tester, 'zen://chat/200:1::1');
    await _pushFromSystem(
      tester,
      'content://com.android.providers.downloads.documents/document/42',
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('home'), findsOneWidget);
    final NavigatorState navigator = tester.state<NavigatorState>(
      find.byType(Navigator),
    );
    expect(navigator.canPop(), isFalse);
  });

  testWidgets('an unknown page name closes again instead of crashing', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        onUnknownRoute: zenUnknownRoute,
        home: const Text('home'),
      ),
    );
    // As Flutter's own routing does it, without the guard above the app.
    await _pushFromSystem(
      tester,
      'https://robertostrowskijagoda.github.io/Zen/#X',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('home'), findsOneWidget);
    expect(key.currentState!.canPop(), isFalse);

    // A push by name from the app finishes as well.
    bool done = false;
    key.currentState!.pushNamed<void>('/nothing').then((_) => done = true);
    await tester.pumpAndSettle();
    expect(done, isTrue);
    expect(key.currentState!.canPop(), isFalse);
  });
}
