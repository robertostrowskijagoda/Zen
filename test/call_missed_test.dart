import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// A call to someone who was away (offline, the phone off) used to leave no
// trace on their phone: the ring and its hangup are real-time only. The
// caller now tells the callee afterwards, reliably (`call_missed`), and the
// callee notes the missed call once: not again for a call whose ring it
// heard.

final String _cyd = PeerShareCodec.normalizeAddress('200::c0d');
final String _dan = PeerShareCodec.normalizeAddress('200::da9');

/// Media that connects nothing.
final class _Media extends CallMediaSessionController {
  String? _id;
  CallInviteKind? _kind;
  CallMediaStatusListener? _onStatus;
  CallMediaErrorListener? _onError;

  @override
  RTCVideoRenderer? get localRenderer => null;
  @override
  RTCVideoRenderer? get remoteRenderer => null;
  @override
  String? get activeCallId => _id;
  @override
  String? get remoteAddress => null;
  @override
  CallInviteKind? get activeKind => _kind;
  @override
  bool get hasLocalStream => _id != null;
  @override
  bool get hasRemoteStream => false;
  @override
  bool get hasLocalVideo => false;
  @override
  bool get hasRemoteVideo => false;
  @override
  CallMediaStatusListener? get onStatusChanged => _onStatus;
  @override
  set onStatusChanged(CallMediaStatusListener? v) => _onStatus = v;
  @override
  CallMediaErrorListener? get onError => _onError;
  @override
  set onError(CallMediaErrorListener? v) => _onError = v;
  @override
  Future<void> startOutgoing({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
  }) async {
    _id = callId;
    _kind = kind;
  }

  @override
  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    _id = callId;
    _kind = kind;
  }

  @override
  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {}
  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {}
  @override
  Future<bool> resendLocalOffer(String callId) async => false;
  @override
  Future<bool> resendLocalAnswer(String callId) async => false;
  @override
  Future<void> setMuted(bool muted) async {}
  @override
  Future<void> setSpeakerOn(bool enabled) async {}
  @override
  Future<void> setCameraEnabled(bool enabled) async {}
  @override
  Future<void> close() async {
    final String? id = _id;
    _id = null;
    _kind = null;
    if (id != null) {
      _onStatus?.call(id, CallMediaSessionLifecycle.ended);
    }
  }
}

/// A phone with Cyd and Dan as friends; [timelines] may outlive it (a
/// restart).
final class _Phone {
  _Phone({
    AppVisibilityState visibility = AppVisibilityState.background,
    Duration ringWait = Duration.zero,
    AppSettings settings = const AppSettings(),
    MemoryMessageTimelineStore? timelines,
  }) : timelines = timelines ?? MemoryMessageTimelineStore() {
    FriendProfile friend(String address, String name) => FriendProfile(
      address: address,
      displayName: name,
      status: FriendRelationshipStatus.accepted,
    );
    container = ProviderContainer(
      overrides: [
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          initialState: settings,
          hydrationEnabled: false,
        ),
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(this.timelines),
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(_Media()),
        runtimeSystemNotificationServiceProvider.overrideWithValue(notices),
        callReRingIntervalProvider.overrideWithValue(Duration.zero),
        callRingingWaitTimeoutProvider.overrideWithValue(ringWait),
        deviceLockedProbeProvider.overrideWithValue(() async => false),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: LifecycleSnapshot(
              visibility: visibility,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                _cyd: friend(_cyd, 'Cyd'),
                _dan: friend(_dan, 'Dan'),
              },
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    hub = container.read(socialHubControllerProvider.notifier);
  }

  final MemorySignalTransport transport = MemorySignalTransport();
  final MemoryMessageTimelineStore timelines;
  final MemoryRuntimeSystemNotificationService notices =
      MemoryRuntimeSystemNotificationService();
  late final ProviderContainer container;
  late final SocialHubController hub;

  CallSession? get call =>
      container.read(socialHubControllerProvider).activeCall;

  Future<void> frame(
    String from,
    Map<String, dynamic> payload, {
    int at = 100000,
  }) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: payload,
    );
    if (signal != null) {
      await hub.receiveSignal(signal, receivedAtMillis: at);
    }
  }

  List<Map<String, dynamic>> sent(String type) => <Map<String, dynamic>>[
    for (final s in transport.sentSignals)
      if (s.payload['type'] == type) s.payload,
  ];

  Future<List<ChatMessage>> chat(String peer) => timelines.load(peer);

  Future<int> missedLines(String peer) async => (await chat(
    peer,
  )).where((ChatMessage m) => m.text.contains('Nieodebrane')).length;

  int get missedNotices => notices.activeNotifications
      .where((RuntimeSystemNotification n) => n.title.contains('Nieodebrane'))
      .length;
}

/// `call_missed` as a mailbox hands it over: from the caller, with the id
/// its queue gave it.
Map<String, dynamic> _missed(
  String callId, {
  String kind = 'audio',
  int at = 50000,
  String rid = 'r-1',
}) => <String, dynamic>{
  'type': 'call_missed',
  'callId': callId,
  'kind': kind,
  'at': at,
  kReliableIdKey: rid,
};

void main() {
  group('the caller', () {
    test('a ring nobody answers is told to the callee afterwards, reliably: '
        'the call id, its kind, when it was made', () async {
      final _Phone p = _Phone(
        visibility: AppVisibilityState.foregroundFocused,
        ringWait: const Duration(milliseconds: 30),
      );
      await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.video);
      final CallSession call = p.call!;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(p.call, isNull);
      final Map<String, dynamic> told = p.sent('call_missed').single;
      expect(told, <String, dynamic>{
        'type': 'call_missed',
        'callId': call.id,
        'kind': 'video',
        'at': call.startedAtMillis,
      });
      expect(
        p.transport.sentSignals
            .where((s) => s.payload['type'] == 'call_missed')
            .single
            .remoteAddress,
        _cyd,
      );
      // Through the queue and the mailboxes like a message, the newest per
      // caller, kept for a device taken for gone.
      expect(isReliablePayload(told), isTrue);
      expect(relayReplaceKeyOf(told), 'call_missed');
      expect(relayIsPersonalPayload(told), isTrue);
    });

    test('hanging up before an answer tells it; an answered, declined or '
        'busy call does not', () async {
      final _Phone p = _Phone(visibility: AppVisibilityState.foregroundFocused);
      await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.audio);
      final String first = p.call!.id;
      await p.hub.endActiveCall(peerAddress: _cyd);
      expect(p.sent('call_missed').single['callId'], first);

      // Answered: the answer makes it "Łączenie…", then hung up.
      await p.hub.sendCallInvite(peerAddress: _dan, kind: CallInviteKind.audio);
      final String answered = p.call!.id;
      await p.frame(_dan, <String, dynamic>{
        'type': 'answer',
        'callId': answered,
        'kind': 'audio',
        'description': <String, dynamic>{'type': 'answer', 'sdp': 'v=0'},
      });
      expect(p.call?.status, CallSessionStatus.connecting);
      await p.hub.endActiveCall(peerAddress: _dan);

      for (final String reply in <String>['call_decline', 'busy']) {
        await p.hub.sendCallInvite(
          peerAddress: _dan,
          kind: CallInviteKind.audio,
        );
        await p.frame(_dan, <String, dynamic>{
          'type': reply,
          'callId': p.call!.id,
          'kind': 'audio',
        });
        expect(p.call, isNull, reason: reply);
      }
      expect(p.sent('call_missed'), hasLength(1));
    });
  });

  group('the callee', () {
    test('away when it rang: one missed-call line, at the time of the call, '
        'and one notification when the word comes through a mailbox; a copy '
        'of it and a start of the app after it add nothing', () async {
      final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore(
        <String, List<ChatMessage>>{
          // Cyd wrote after she called.
          _cyd: <ChatMessage>[
            ChatMessage(
              id: 'm-later',
              sender: _cyd,
              text: 'Oddzwoń',
              sentAtMillis: 60000,
              direction: ChatMessageDirection.incoming,
            ),
          ],
        },
      );
      final _Phone p = _Phone(timelines: timelines);
      await p.frame(_cyd, _missed('call-cyd-1', kind: 'video'));
      final List<ChatMessage> chat = await p.chat(_cyd);
      expect(chat.map((ChatMessage m) => m.text), <String>[
        'Nieodebrane połączenie wideo.',
        'Oddzwoń',
      ]);
      expect(chat.first.sentAtMillis, 50000);
      expect(p.missedNotices, 1);
      expect(p.notices.activeNotifications.single.body, contains('Cyd'));
      expect(p.call, isNull, reason: 'it never rings');

      // The same word again (from another mailbox), then after a restart.
      await p.notices.clear();
      await p.frame(_cyd, _missed('call-cyd-1', rid: 'r-2'), at: 110000);
      final _Phone again = _Phone(timelines: timelines);
      await again.frame(_cyd, _missed('call-cyd-1', rid: 'r-3'), at: 120000);
      expect(await again.missedLines(_cyd), 1);
      expect(p.missedNotices + again.missedNotices, 0);

      // A missed call of another day is a call of its own.
      await again.frame(_cyd, _missed('call-cyd-2', at: 90000), at: 130000);
      expect(await again.missedLines(_cyd), 2);
      expect(again.missedNotices, 1);
    });

    test('a callee whose phone rang gets no second entry: the caller hung '
        'up, the ring ran out, or it was turned away as "busy"', () async {
      final _Phone p = _Phone(ringWait: const Duration(milliseconds: 40));
      // The caller hung up.
      await p.frame(_cyd, <String, dynamic>{
        'type': 'call_invite',
        'callId': 'c-hung',
        'kind': 'audio',
      });
      await p.frame(_cyd, <String, dynamic>{
        'type': 'hangup',
        'callId': 'c-hung',
        'kind': 'audio',
      });
      expect(p.missedNotices, 1);
      final int linesAfterHangup = (await p.chat(_cyd)).length;
      await p.notices.clear();
      await p.frame(_cyd, _missed('c-hung', rid: 'r-h'));
      expect((await p.chat(_cyd)).length, linesAfterHangup);
      expect(p.missedNotices, 0);

      // The ring ran out.
      await p.frame(_dan, <String, dynamic>{
        'type': 'call_invite',
        'callId': 'c-out',
        'kind': 'audio',
      });
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(p.call, isNull);
      expect(await p.missedLines(_dan), 1);
      await p.notices.clear();
      await p.frame(_dan, _missed('c-out', rid: 'r-o'));
      expect(await p.missedLines(_dan), 1);
      expect(p.missedNotices, 0);

      // Turned away as "busy" while ringing out to Cyd.
      final _Phone busy = _Phone();
      await busy.hub.sendCallInvite(
        peerAddress: _cyd,
        kind: CallInviteKind.audio,
      );
      await busy.frame(_dan, <String, dynamic>{
        'type': 'call_invite',
        'callId': 'c-busy',
        'kind': 'audio',
      });
      expect(await busy.missedLines(_dan), 1);
      expect(busy.missedNotices, 1);
      await busy.notices.clear();
      await busy.frame(_dan, _missed('c-busy', rid: 'r-b'));
      expect(await busy.missedLines(_dan), 1);
      expect(busy.missedNotices, 0);
      expect(busy.call?.peerAddress, _cyd, reason: 'the call out goes on');
    });

    test('a ring still on (its hangup got lost) ends with the word, which '
        'leaves one missed call', () async {
      final _Phone p = _Phone();
      await p.frame(_cyd, <String, dynamic>{
        'type': 'call_invite',
        'callId': 'c-lost',
        'kind': 'audio',
      });
      expect(p.call?.status, CallSessionStatus.ringing);
      await p.frame(_cyd, _missed('c-lost'));
      expect(p.call, isNull);
      expect(p.missedNotices, 1);
      // Ended as a hangup ends it, no second line on top.
      await p.frame(_cyd, _missed('c-lost', rid: 'r-9'));
      expect(p.missedNotices, 1);
      expect(
        (await p.chat(
          _cyd,
        )).where((ChatMessage m) => m.text.startsWith('Nieodebrane')),
        isEmpty,
      );
    });

    test(
      '"Połączenia" switched off: the chat notes it, no notification',
      () async {
        final _Phone p = _Phone(
          settings: const AppSettings(
            mutedNotices: <NoticeKind>{NoticeKind.call},
          ),
        );
        await p.frame(_cyd, _missed('call-cyd-3'));
        expect(await p.missedLines(_cyd), 1);
        expect(p.notices.activeNotifications, isEmpty);
      },
    );

    test('nobody but a friend leaves one', () async {
      final _Phone p = _Phone();
      final String stranger = PeerShareCodec.normalizeAddress('200::bad');
      await p.frame(stranger, _missed('call-x'));
      expect(await p.chat(stranger), isEmpty);
      expect(p.notices.activeNotifications, isEmpty);
    });
  });

  test('it never rings, on this Zen or one before 1.16.5', () {
    final ZenSignal signal = zenSignalFromTransportPayload(
      sender: _cyd,
      payload: _missed('c-1'),
    )!;
    expect(signal.type, ZenSignalType.callEnd);
    expect(isMissedCallNotice(signal), isTrue);
    // A plain hangup is no missed-call notice.
    expect(
      isMissedCallNotice(
        zenSignalFromTransportPayload(
          sender: _cyd,
          payload: <String, dynamic>{'type': 'hangup', 'callId': 'c-1'},
        )!,
      ),
      isFalse,
    );
    // Without a call id it names nothing.
    expect(
      zenSignalFromTransportPayload(
        sender: _cyd,
        payload: <String, dynamic>{'type': 'call_missed'},
      ),
      isNull,
    );
    // A Zen before 1.16.5 reads a type it does not know as nothing at all,
    // as this one reads one it does not know.
    expect(
      zenSignalFromTransportPayload(
        sender: _cyd,
        payload: <String, dynamic>{'type': 'call_missed_later', 'callId': 'c'},
      ),
      isNull,
    );
  });
}
