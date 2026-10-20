import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
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
    expect(media.remoteScreenRenderer, isNull);
    expect(await media.listScreenSources(), isEmpty);
    expect(media.startScreenShare, throwsUnsupportedError);
  });

  group('screen slot in the SDP', () {
    const String cameraOnly =
        'v=0\r\n'
        'o=- 1 2 IN IP4 127.0.0.1\r\n'
        's=-\r\n'
        't=0 0\r\n'
        'a=msid-semantic: WMS cam\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
        'a=mid:0\r\n'
        'a=sendrecv\r\n'
        'a=msid:cam audio1\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'a=mid:1\r\n'
        'a=recvonly\r\n';
    const String withScreen =
        '${cameraOnly}m=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'a=mid:2\r\n'
        'a=sendrecv\r\n'
        'a=msid:screen-stream screen-track\r\n';

    test('a camera-only call has no screen slot', () {
      expect(screenShareSlotInSdp(cameraOnly), isNull);
      expect(screenShareSlotInSdp(''), isNull);
    });

    test('the second video section is the screen, with its msid', () {
      final ({String mid, String? streamId})? slot = screenShareSlotInSdp(
        withScreen,
      );
      expect(slot?.mid, '2');
      expect(slot?.streamId, 'screen-stream');
    });

    test('a slot that sends nothing has no stream id', () {
      final ({String mid, String? streamId})? slot = screenShareSlotInSdp(
        withScreen
            .replaceFirst('a=msid:screen-stream screen-track\r\n', '')
            .replaceFirst('a=mid:2\r\na=sendrecv', 'a=mid:2\r\na=recvonly'),
      );
      expect(slot?.mid, '2');
      expect(slot?.streamId, isNull);
    });

    test('only the camera section is forced to sendrecv', () {
      final String forced = forceCameraSectionSendRecv(
        withScreen.replaceFirst(
          'a=mid:2\r\na=sendrecv',
          'a=mid:2\r\na=recvonly',
        ),
      );
      final List<String> sections = forced.split('m=');
      // audio, camera, screen (after the session part).
      expect(sections, hasLength(4));
      expect(sections[2], contains('a=sendrecv'));
      expect(sections[2], isNot(contains('a=recvonly')));
      expect(sections[3], contains('a=recvonly'));
      expect(sections[3], isNot(contains('a=sendrecv')));
      expect(forced, contains('\r\n'));
    });

    test('a camera section without a direction gets one', () {
      const String sdp =
          'v=0\n'
          'm=video 9 UDP/TLS/RTP/SAVPF 96\n'
          'a=mid:1\n';
      expect(forceCameraSectionSendRecv(sdp), contains('a=sendrecv'));
    });
  });

  test('a group participant without a shared screen has no screen view', () {
    const GroupCallPeerView view = GroupCallPeerView(
      address: 'ada.ygg',
      state: GroupCallLegState.connected,
    );
    expect(view.sharingScreen, isFalse);
    expect(view.screenRenderer, isNull);
  });
}
