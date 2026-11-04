import 'dart:async';

import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

/// Leak tracking of widget tests (docs/TESTING.md), on demand:
/// `flutter test --dart-define=zen.leaks=true`. Every object Flutter
/// tracks (controllers, notifiers, images, layers) that a test's widgets
/// created and nobody disposed fails that test file. Objects the test
/// helpers themselves make are not counted, nor objects merely not yet
/// collected (too noisy to judge in a test).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (const bool.fromEnvironment('zen.leaks')) {
    LeakTesting.enable();
    LeakTesting.settings = LeakTesting.settings.withIgnored(
      createdByTestHelpers: true,
      allNotGCed: true,
    );
  }
  await testMain();
}
