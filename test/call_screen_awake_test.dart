import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_screen_awake.dart';

/// The screen stays on for the whole of a video call and of a call heard
/// out loud, on every path into it, and goes back to normal when the call
/// ends (call_screen_awake.dart). Up to 1.17.1 only an incoming call that
/// still rang kept it on.
void main() {
  CallSession call({
    CallInviteKind kind = CallInviteKind.video,
    CallSessionStatus status = CallSessionStatus.active,
    bool incoming = false,
    bool speaker = false,
    bool camera = false,
    bool group = false,
  }) => CallSession(
    id: 'call-1',
    peerAddress: 'ada.ygg',
    displayName: 'Ada',
    kind: kind,
    status: status,
    startedAtMillis: 1,
    isIncoming: incoming,
    isSpeakerOn: speaker,
    isCameraEnabled: camera,
    isGroup: group,
  );

  group('which call keeps the screen on', () {
    test('a video call, dialled or answered, from the first ring on', () {
      for (final CallSessionStatus status in <CallSessionStatus>[
        CallSessionStatus.ringing,
        CallSessionStatus.connecting,
        CallSessionStatus.active,
      ]) {
        expect(
          callScreenAwakeReason(call(status: status)),
          'video call',
          reason: '$status',
        );
      }
      for (final CallSessionStatus status in <CallSessionStatus>[
        CallSessionStatus.connecting,
        CallSessionStatus.active,
      ]) {
        expect(
          callScreenAwakeReason(call(status: status, incoming: true)),
          'video call',
          reason: 'answered, $status',
        );
      }
      expect(callScreenAwakeReason(call(group: true)), 'video call');
    });

    test('a voice call once its camera is on', () {
      expect(
        callScreenAwakeReason(call(kind: CallInviteKind.audio, camera: true)),
        'video call',
      );
    });

    test('a voice call on the loudspeaker or a headset', () {
      expect(
        callScreenAwakeReason(call(kind: CallInviteKind.audio, speaker: true)),
        'loudspeaker or headset',
      );
      expect(
        callScreenAwakeReason(
          call(
            kind: CallInviteKind.audio,
            speaker: true,
            status: CallSessionStatus.ringing,
          ),
        ),
        'loudspeaker or headset',
      );
    });

    test('not a voice call at the ear, nor a call ringing in, nor none', () {
      // At the ear the proximity sensor decides instead.
      expect(callScreenAwakeReason(call(kind: CallInviteKind.audio)), isNull);
      // Its own ringing window keeps the screen on while it rings.
      expect(
        callScreenAwakeReason(
          call(status: CallSessionStatus.ringing, incoming: true),
        ),
        isNull,
      );
      expect(callScreenAwakeReason(null), isNull);
    });
  });

  group('the screen of a voice call at the ear', () {
    CallScreenMode mode(CallSession? session) =>
        callScreenModeFor(session).mode;

    test('goes dark at the ear on the earpiece, dialled or answered, '
        'from the first ring on', () {
      for (final CallSessionStatus status in CallSessionStatus.values) {
        expect(
          mode(call(kind: CallInviteKind.audio, status: status)),
          CallScreenMode.proximity,
          reason: '$status',
        );
      }
      for (final CallSessionStatus status in <CallSessionStatus>[
        CallSessionStatus.connecting,
        CallSessionStatus.active,
      ]) {
        expect(
          mode(
            call(kind: CallInviteKind.audio, status: status, incoming: true),
          ),
          CallScreenMode.proximity,
        );
      }
      expect(
        mode(call(kind: CallInviteKind.audio, group: true)),
        CallScreenMode.proximity,
      );
    });

    test('not on the loudspeaker or a headset, not in a video call, not '
        'while a call rings in, not without a call', () {
      expect(
        mode(call(kind: CallInviteKind.audio, speaker: true)),
        CallScreenMode.keepOn,
      );
      expect(mode(call()), CallScreenMode.keepOn);
      expect(
        mode(call(kind: CallInviteKind.audio, camera: true)),
        CallScreenMode.keepOn,
      );
      expect(
        mode(
          call(
            kind: CallInviteKind.audio,
            status: CallSessionStatus.ringing,
            incoming: true,
          ),
        ),
        CallScreenMode.normal,
      );
      expect(mode(null), CallScreenMode.normal);
    });
  });

  group('what is asked of the platform', () {
    late List<CallScreenMode> asked;
    late CallScreenAwake awake;

    setUp(() {
      asked = <CallScreenMode>[];
      awake = CallScreenAwake(
        setter: (CallScreenMode mode) async {
          asked.add(mode);
          return true;
        },
      );
    });

    test('taken when the call wants it, released when it ends', () async {
      awake.update(null);
      awake.update(call(status: CallSessionStatus.ringing));
      awake.update(call(status: CallSessionStatus.connecting));
      awake.update(call());
      awake.update(null);
      await Future<void>.delayed(Duration.zero);
      // The first state always goes (a new engine of the app may find what
      // an earlier one left), then only changes.
      expect(asked, <CallScreenMode>[
        CallScreenMode.normal,
        CallScreenMode.keepOn,
        CallScreenMode.normal,
      ]);
      expect(awake.keptOn, isFalse);
    });

    test('a voice call moves between the ear and out loud, and becomes a '
        'video call', () {
      awake.update(call(status: CallSessionStatus.ringing, incoming: true));
      awake.update(call(status: CallSessionStatus.active, incoming: true));
      expect(awake.keptOn, isTrue);
      awake.update(call(kind: CallInviteKind.audio, speaker: true));
      expect(awake.mode, CallScreenMode.keepOn);
      awake.update(call(kind: CallInviteKind.audio));
      expect(awake.mode, CallScreenMode.proximity);
      awake.update(call(kind: CallInviteKind.audio, speaker: true));
      awake.update(call(kind: CallInviteKind.audio));
      awake.update(call(kind: CallInviteKind.audio, camera: true));
      expect(awake.mode, CallScreenMode.keepOn);
      awake.update(call(kind: CallInviteKind.audio));
      awake.update(null);
      expect(asked, <CallScreenMode>[
        CallScreenMode.normal,
        CallScreenMode.keepOn,
        CallScreenMode.proximity,
        CallScreenMode.keepOn,
        CallScreenMode.proximity,
        CallScreenMode.keepOn,
        CallScreenMode.proximity,
        CallScreenMode.normal,
      ]);
    });
  });
}
