import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';
import 'package:zen/src/features/calls/noop_call_media_session.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';

void main() {
  const CallSession call = CallSession(
    id: 'call-1',
    peerAddress: 'ada.ygg',
    displayName: 'Ada',
    kind: CallInviteKind.video,
    status: CallSessionStatus.active,
    startedAtMillis: 1,
  );

  tearDown(() => androidScreenCaptureActive.value = false);

  test('sharing the screen adds the mediaProjection service type', () {
    expect(
      foregroundServiceTypesForCallSession(call),
      isNot(contains(ForegroundServiceTypes.mediaProjection)),
    );
    androidScreenCaptureActive.value = true;
    expect(
      foregroundServiceTypesForCallSession(call),
      orderedEquals(const <ForegroundServiceTypes>[
        ForegroundServiceTypes.specialUse,
        ForegroundServiceTypes.microphone,
        ForegroundServiceTypes.camera,
        ForegroundServiceTypes.mediaProjection,
      ]),
    );
    // No call, no capture type.
    expect(
      foregroundServiceTypesForCallSession(null),
      orderedEquals(const <ForegroundServiceTypes>[
        ForegroundServiceTypes.specialUse,
      ]),
    );
  });

  test('a controller without screen sharing says so', () async {
    final NoopCallMediaSessionController media =
        NoopCallMediaSessionController();
    expect(media.isScreenSharing, isFalse);
    expect(media.remoteScreenSharing, isFalse);
    expect(await media.listScreenSources(), isEmpty);
    expect(media.startScreenShare, throwsUnsupportedError);
  });
}
