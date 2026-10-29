// Owner report R5-#6 (28.10.2026, after 1.14.0): no notice of the new version arrived on 1.13.1.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in runtime_system_notifications.dart (the notice's own channel at
// default importance, 34b737e2) and latest_release.dart (the project pages
// before GitHub's rate-limited API, 2887b37f); guarded by
// the test below, test/update_notice_test.dart and
// test/update_check_sources_test.dart ("GitHub's API rate-limited: …").
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/update/update_notice.dart';

void main() {
  test('R5-#6: a phone on 1.13.1 is told of the new version', () {
    final RuntimeSystemNotification n = updateAvailableNotification(
      '1.14.0',
      createdAtMillis: 1,
    );
    final AndroidNotificationChannel channel =
        FlutterLocalRuntimeSystemNotificationService.androidChannelFor(n);

    // Before: 'zen_updates' at low importance, which Samsung and Pixel put
    // among the silent notifications with no icon in the status bar, so
    // the notice was posted and never seen. A channel keeps the importance
    // it was made with, so it takes a new id.
    expect(channel.importance, isNot(Importance.low));
    expect(channel.importance, Importance.defaultImportance);
    expect(channel.id, isNot('zen_updates'));
    expect(channel.playSound, isFalse);
    expect(
      FlutterLocalRuntimeSystemNotificationService.androidChannels().map(
        (AndroidNotificationChannel c) => c.id,
      ),
      contains(channel.id),
    );
  });
}
