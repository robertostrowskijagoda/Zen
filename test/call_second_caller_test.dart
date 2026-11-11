import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// A second call coming while this phone is on a call, rings out, or is
// rung: the newcomer hears "busy" and the call already here goes on, its
// media too. It used to close the media of a call that was not talking
// yet: a call ringing out was dropped for the newcomer's, and the person
// called was never told (their phone rang on; answered, it waited on
// "Łączenie…" for a call that was gone).

final String _cyd = PeerShareCodec.normalizeAddress('200::c0d');
final String _dan = PeerShareCodec.normalizeAddress('200::da9');
final String _eve = PeerShareCodec.normalizeAddress('200::e5e');
const String _groupId = 'g-calls';

/// Media that, like the real one, is not connected the moment the call is
/// started; it counts how often it was closed, and can hold a close back.
final class _Media extends CallMediaSessionController {
  int closes = 0;
  String? acceptedCallId;
  Completer<void>? closeGate;
  final Completer<void> closing = Completer<void>();
  String? _id;
  String? _remote;
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
  String? get remoteAddress => _remote;
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
    _remote = remoteAddress;
    _kind = kind;
  }

  @override
  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    acceptedCallId = callId;
    _id = callId;
    _remote = remoteAddress;
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
    closes += 1;
    if (!closing.isCompleted) {
      closing.complete();
    }
    await closeGate?.future;
    final String? id = _id;
    _id = null;
    _remote = null;
    _kind = null;
    if (id != null) {
      _onStatus?.call(id, CallMediaSessionLifecycle.ended);
    }
  }
}

/// This phone, with Cyd, Dan and Eve as friends and a group with Dan.
final class _Phone {
  _Phone({
    AppVisibilityState visibility = AppVisibilityState.foregroundFocused,
    Duration ringWait = Duration.zero,
  }) {
    FriendProfile friend(String address, String name) => FriendProfile(
      address: address,
      displayName: name,
      status: FriendRelationshipStatus.accepted,
    );
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelines),
        signalTransportProvider.overrideWithValue(transport),
        callMediaSessionControllerProvider.overrideWithValue(media),
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
                _eve: friend(_eve, 'Eve'),
              },
            ),
            groups: <String, GroupProfile>{
              _groupId: GroupProfile(
                id: _groupId,
                name: 'Ekipa',
                createdById: _dan,
                createdAtMillis: 1,
                memberAddresses: <String>[_dan],
              ),
            },
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    hub = container.read(socialHubControllerProvider.notifier);
  }

  final _Media media = _Media();
  final MemorySignalTransport transport = MemorySignalTransport();
  final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
  final MemoryRuntimeSystemNotificationService notices =
      MemoryRuntimeSystemNotificationService();
  late final ProviderContainer container;
  late final SocialHubController hub;

  CallSession? get call =>
      container.read(socialHubControllerProvider).activeCall;

  Future<void> frame(
    String from,
    Map<String, dynamic> payload, {
    int at = 1000,
  }) => hub.receiveSignal(
    zenSignalFromTransportPayload(sender: from, payload: payload)!,
    receivedAtMillis: at,
  );

  Future<void> invite(String from, String callId, {int at = 1000}) => frame(
    from,
    <String, dynamic>{'type': 'call_invite', 'callId': callId, 'kind': 'audio'},
    at: at,
  );

  Future<void> offer(String from, String callId, {int at = 1000}) =>
      frame(from, <String, dynamic>{
        'type': 'offer',
        'callId': callId,
        'kind': 'audio',
        'description': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      }, at: at);

  List<String> sentTo(String peer) => <String>[
    for (final s in transport.sentSignals)
      if (PeerShareCodec.addressesEqual(s.remoteAddress, peer))
        '${s.payload['type']}',
  ];

  Future<List<String>> lines(String peer) async => <String>[
    for (final ChatMessage m in await timelines.load(peer)) m.text,
  ];
}

int _count(List<String> lines, String needle) =>
    lines.where((String l) => l.contains(needle)).length;

void main() {
  test('while this phone rings out to Cyd, Dan calls: Dan hears "busy", the '
      'call to Cyd keeps ringing with its media, and Dan is noted once as a '
      'missed call', () async {
    final _Phone p = _Phone();
    await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.audio);
    final CallSession out = p.call!;
    expect(out.status, CallSessionStatus.ringing);
    expect(p.media.activeCallId, out.id);

    // Dan rings; his phone re-sends the invite every second, its offer comes
    // right after the first.
    for (int i = 0; i < 4; i++) {
      await p.invite(_dan, 'call-dan-1', at: 1000 + i * 1000);
      if (i == 0) {
        await p.offer(_dan, 'call-dan-1', at: 1001);
      }
    }

    expect(p.media.closes, 0, reason: 'the call to Cyd keeps its media');
    expect(p.media.activeCallId, out.id);
    expect(p.call?.id, out.id, reason: 'the call being made stays');
    expect(p.call?.status, CallSessionStatus.ringing);
    expect(p.sentTo(_dan), isNotEmpty);
    expect(p.sentTo(_dan).toSet(), <String>{'busy'});
    expect(p.sentTo(_cyd), <String>['call_invite']);
    expect(
      _count(await p.lines(_dan), 'Nieodebrane połączenie'),
      1,
      reason: 'one missed call, however often Dan re-sent his invite',
    );
    expect(_count(await p.lines(_dan), 'Przyszło zaproszenie'), 0);
  });

  test('rung by Cyd, Dan calls: Dan hears "busy", Cyd\'s call rings on and '
      'is answered with the offer she sent', () async {
    final _Phone p = _Phone();
    await p.invite(_cyd, 'call-cyd-1');
    await p.offer(_cyd, 'call-cyd-1');
    expect(p.call?.isIncoming, isTrue);
    for (int i = 0; i < 3; i++) {
      await p.invite(_dan, 'call-dan-2', at: 2000 + i * 1000);
      if (i == 0) {
        await p.offer(_dan, 'call-dan-2', at: 2001);
      }
    }
    expect(p.sentTo(_dan).toSet(), <String>{'busy'});
    expect(p.sentTo(_cyd), isNot(contains('busy')));
    expect(p.call?.id, 'call-cyd-1');
    expect(p.call?.status, CallSessionStatus.ringing);
    expect(p.media.closes, 0);

    await p.hub.acceptIncomingCall(peerAddress: _cyd);
    expect(
      p.media.acceptedCallId,
      'call-cyd-1',
      reason: 'her offer was kept: no new request for it',
    );
    expect(p.sentTo(_cyd), isNot(contains('call_offer_request')));
    expect(_count(await p.lines(_dan), 'Nieodebrane połączenie'), 1);
  });

  test('rung by Cyd with Zen in the background, Dan\'s invite and offer '
      'come: "busy" for both, Cyd\'s call rings on, and the missed call '
      'from Dan is told', () async {
    final _Phone p = _Phone(visibility: AppVisibilityState.background);
    await p.invite(_cyd, 'call-cyd-2');
    await p.offer(_cyd, 'call-cyd-2');
    await p.invite(_dan, 'call-dan-3', at: 2000);
    await p.offer(_dan, 'call-dan-3', at: 2001);
    await p.invite(_dan, 'call-dan-3', at: 3000);
    expect(p.call?.id, 'call-cyd-2');
    expect(p.call?.status, CallSessionStatus.ringing);
    expect(p.media.closes, 0);
    expect(p.sentTo(_dan), <String>['busy', 'busy', 'busy']);
    final List<RuntimeSystemNotification> missed = <RuntimeSystemNotification>[
      for (final RuntimeSystemNotification n in p.notices.activeNotifications)
        if (n.title.contains('Nieodebrane')) n,
    ];
    expect(missed, hasLength(1));
    expect(missed.single.body, contains('Dan'));
    // Cyd keeps ringing, not turned away as "busy" by her own next invite.
    await p.invite(_cyd, 'call-cyd-2', at: 4000);
    expect(p.sentTo(_cyd), isNot(contains('busy')));
    await p.hub.acceptIncomingCall(peerAddress: _cyd);
    expect(p.media.acceptedCallId, 'call-cyd-2');
  });

  test('two calling each other at once keep the call the rule picks, no '
      '"busy" for either', () async {
    final _Phone p = _Phone();
    await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.audio);
    final String mine = p.call!.id;
    // Cyd's id sorts after this phone's: this phone's call stays.
    await p.invite(_cyd, 'call-zzz-$_cyd');
    expect(p.call?.id, mine);
    expect(p.sentTo(_cyd), isNot(contains('busy')));
    expect(p.media.closes, 0);
  });

  test('a group call does not ring over a call ringing out or in, and a '
      'call does not ring over a group call ringing in', () async {
    final _Phone p = _Phone();
    await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.audio);
    final String mine = p.call!.id;
    const Map<String, dynamic> groupRing = <String, dynamic>{
      'type': 'group_call_invite',
      'groupId': _groupId,
      'callId': 'gc-1',
      'kind': 'audio',
    };
    await p.frame(_dan, groupRing);
    expect(p.call?.id, mine);
    expect(p.media.closes, 0);
    expect(p.sentTo(_cyd), <String>['call_invite']);

    // Now rung by Cyd, the group call rings again.
    await p.hub.endActiveCall(peerAddress: _cyd);
    await p.invite(_cyd, 'call-cyd-3', at: 5000);
    await p.frame(_dan, groupRing, at: 5001);
    expect(p.call?.id, 'call-cyd-3');
    expect(p.call?.status, CallSessionStatus.ringing);

    // Rung by the group call, Eve calls alone: "busy".
    await p.hub.declineIncomingCall(peerAddress: _cyd);
    await p.frame(_dan, groupRing, at: 6000);
    expect(p.call?.isGroup, isTrue);
    await p.invite(_eve, 'call-eve-1', at: 7000);
    expect(p.sentTo(_eve), <String>['busy']);
    expect(p.call?.isGroup, isTrue);
    expect(p.call?.id, 'gc-1');
  });

  test('a call coming in the moment this phone ends its own (its ring ran '
      'out, the media still closing) hears no "busy" and rings once that '
      'call is gone', () async {
    final _Phone p = _Phone(ringWait: const Duration(milliseconds: 200));
    p.media.closeGate = Completer<void>();
    await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.audio);
    await p.media.closing.future;
    // Dan's invite lands while the ring to Cyd is being ended.
    await p.invite(_dan, 'call-dan-4', at: 2000);
    expect(p.sentTo(_dan), isEmpty);
    p.media.closeGate!.complete();
    await pumpEventQueue();
    expect(p.call, isNull);

    // His next invite, a second later, rings.
    await p.invite(_dan, 'call-dan-4', at: 3000);
    expect(p.call?.id, 'call-dan-4');
    expect(p.call?.isIncoming, isTrue);
    expect(p.sentTo(_dan), isEmpty);
    final List<String> lines = await p.lines(_dan);
    expect(_count(lines, 'Przyszło zaproszenie'), 1);
    expect(_count(lines, 'Nieodebrane'), 0);
  });

  test('a call that is talking still sends a newcomer "busy", and notes '
      'the newcomer as a missed call once', () async {
    final _Phone p = _Phone();
    await p.hub.sendCallInvite(peerAddress: _cyd, kind: CallInviteKind.audio);
    p.media.onStatusChanged?.call(p.call!.id, CallMediaSessionLifecycle.active);
    expect(p.call?.status, CallSessionStatus.active);
    await p.invite(_dan, 'call-dan-5', at: 2000);
    await p.invite(_dan, 'call-dan-5', at: 3000);
    expect(p.sentTo(_dan), <String>['busy', 'busy']);
    expect(p.call?.status, CallSessionStatus.active);
    expect(_count(await p.lines(_dan), 'Nieodebrane połączenie'), 1);
  });
}
