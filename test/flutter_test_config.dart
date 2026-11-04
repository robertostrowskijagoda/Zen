import 'dart:async';

import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

/// Leak tracking of widget tests (docs/TESTING.md), on demand:
/// `flutter test --dart-define=zen.leaks=true` (CI's "Leaks" step). Every
/// object Flutter tracks (controllers, notifiers, animations, pictures,
/// overlay entries) that a test's widgets created and nobody disposed fails
/// that test file. Not counted: objects the test helpers themselves make,
/// objects merely not collected yet (too noisy to judge in a test), and
/// the classes in [_notLeaks].
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (const bool.fromEnvironment('zen.leaks')) {
    LeakTesting.enable();
    LeakTesting.settings = LeakTesting.settings.withIgnored(
      createdByTestHelpers: true,
      allNotGCed: true,
      classes: _notLeaks,
    );
  }
  await testMain();
}

/// Objects that stay by design, or that tests make and keep.
const List<String> _notLeaks = <String>[
  // One per process for the app's whole life.
  'ClockSkewTracker',
  'ZenOpenedFiles',
  'ZenFormatGuard',
  'DamagedIdentityNotice',
  'ZenStorageHealth',
  'ZenAccountHost',
  '_LowRateClock',
  // Flutter's image cache keeps decoded images on purpose.
  'Image',
  'ImageInfo',
  '_CachedImage',
  'ImageStreamCompleterHandle',
  // Made by the tests themselves (the app's providers dispose their own).
  'MemoryAppSecurityService',
  'LocalAppSecurityService',
  'PyramidService',
  'MeetService',
  'OpenToMeetService',
  'GroupBoardService',
  'UpdateService',
  '_FakeCallMediaSessionController',
  'FakeGroupCallMedia',
  '_Gates',
  '_GatePrices',
];
