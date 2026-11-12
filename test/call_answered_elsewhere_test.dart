// A call answered (or declined) on one device of the callee's account stops
// ringing on the account's other devices without a word: no "Nieodebrane
// połączenie", locked (LockedReceiver) or with Zen in the background (the
// app), and nothing in the chat says the call was missed or ended there.
//
// The caller's AccountRoutingTransport sends the invite to every device of
// the callee's account; once one device answers it tells the others with a
// `call_end` marked as taken on another device ([kCallElsewhereKey]). The
// caller's own hang-up before anyone answered still leaves the missed call.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_event_text.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

const String _caller = 'ada.ygg';
const String _phone = 'bobphone.ygg';
const String _laptop = 'boblaptop.ygg';

/// What the caller's phone knows of accounts: Bob has a phone and a laptop.
final class _CallerDirectory implements AccountDeviceDirectory {
  @override
  String get ownAccount => 'ADA';

  @override
  String? accountOf(String address) => switch (address) {
    _phone || _laptop => 'BOB',
    _caller => 'ADA',
    _ => null,
  };

  @override
  List<String> addressesOf(String account) =>
      account == 'BOB' ? const <String>[_phone, _laptop] : const <String>[];

  @override
  String? contactAddressOf(String account) => account == 'BOB' ? _phone : null;

  @override
  String? unlinkedAccountOf(String address) => null;
}

final class _Shown implements RuntimeSystemNotificationService {
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final MemoryRuntimeSystemNotificationService _d =
      MemoryRuntimeSystemNotificationService();

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) => _d.initialize(onOpenRoute: onOpenRoute, onAction: onAction);

  @override
  Future<bool> show(RuntimeSystemNotification notification) async {
    shown.add(notification);
    return _d.show(notification);
  }

  @override
  Future<void> dismiss(String id) => _d.dismiss(id);

  @override
  Future<void> dismissSlot(String slotKey) => _d.dismissSlot(slotKey);

  @override
  Future<void> clear() => _d.clear();
}

/// The frames the caller's routing sends to Bob's phone when Bob answers
/// (or declines) on his laptop: [answer] is the laptop's word.
Future<List<Map<String, dynamic>>> _framesToPhone(String answer) async {
  final MemorySignalTransport base = MemorySignalTransport();
  await base.start();
  final AccountRoutingTransport routed = AccountRoutingTransport(
    delegate: base,
    directory: () => _CallerDirectory(),
  );
  final StreamSubscription<SignalTransportFrame> sub = routed.frames.listen(
    (_) {},
  );
  await routed.send(
    remoteAddress: _phone,
    payload: <String, dynamic>{
      'type': 'call_invite',
      'callId': 'c1',
      'kind': 'audio',
    },
  );
  await base.injectIncoming(
    from: _laptop,
    payload: <String, dynamic>{'type': answer, 'callId': 'c1'},
  );
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  await sub.cancel();
  return <Map<String, dynamic>>[
    for (final ({String remoteAddress, Map<String, dynamic> payload}) s
        in base.sentSignals)
      if (PeerShareCodec.addressesEqual(s.remoteAddress, _phone)) s.payload,
  ];
}

/// Bob's phone, locked: what it rang and which missed-call notices it left
/// after [frames] from the caller.
Future<({List<bool> rings, List<String> missed})> _lockedPhoneAfter(
  List<Map<String, dynamic>> frames,
) async {
  final Directory dir = await Directory.systemTemp.createTemp('zen-call-');
  addTearDown(() => dir.delete(recursive: true));
  final _Shown shade = _Shown();
  final LockedReceiver phone = LockedReceiver(
    transport: MemorySignalTransport(),
    capability: BackgroundCapability.fromDraft(
      BackgroundCapabilityDraft(
        inboxPublicKey: Uint8List(32),
        friends: const <String>{_caller},
      ),
      backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
    ),
    inbox: SealedInboxWriter(
      file: File('${dir.path}/inbox.zbox'),
      recipientPublicKey: Uint8List(32),
    ),
    notices: shade,
    mailboxPollInterval: Duration.zero,
    presenceRoundEvery: Duration.zero,
    noticeThrottle: Duration.zero,
  );
  final List<bool> rings = <bool>[];
  phone.ringForCall = (bool on) async => rings.add(on);
  phone.showCallCard = (String from) async {};
  await phone.start();
  addTearDown(phone.stop);
  for (final Map<String, dynamic> p in frames) {
    await phone.handleFrame(
      SignalTransportFrame(
        from: _caller,
        payload: p,
        receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }
  return (
    rings: rings,
    missed: <String>[
      for (final RuntimeSystemNotification n in shade.shown)
        if (n.slotKey == kLockedMissedCallSlot) n.title,
    ],
  );
}

/// Bob's phone with Zen in the background: the notifications it showed and
/// the chat lines about calls with the caller after [frames].
Future<({List<String> missedNotices, List<String> callLines})> _appAfter(
  List<Map<String, dynamic>> frames,
) async {
  final _Shown shade = _Shown();
  final MemoryMessageTimelineStore timeline = MemoryMessageTimelineStore();
  final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
    bootstrap: () async => RuntimeNodeSession(
      transport: MemorySignalTransport(),
      snapshot: RuntimeTransportSnapshot.started(
        localAddress: _phone,
        peers: 1,
      ),
    ),
  );
  final ProviderContainer container = ProviderContainer(
    overrides: [
      ...buildAppSettingsProviderOverrides(
        store: MemoryAppSettingsStore(),
        initialState: const AppSettings(),
        hydrationEnabled: false,
      ),
      runtimeNodeRuntimeProvider.overrideWithValue(runtime),
      signalTransportProvider.overrideWithValue(MemorySignalTransport()),
      signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
      socialSnapshotStoreProvider.overrideWithValue(
        MemorySocialSnapshotStore(),
      ),
      messageTimelineStoreProvider.overrideWithValue(timeline),
      runtimeSystemNotificationServiceProvider.overrideWith(
        (Ref ref) => NoticeSettingsNotificationService(
          shade,
          muted: (NoticeKind kind) =>
              ref.read(appSettingsControllerProvider).mutes(kind),
          sounds: () =>
              ref.read(appSettingsControllerProvider).notificationSounds,
        ),
      ),
      incomingCallCardProvider.overrideWithValue(
        ({
          required String displayName,
          required bool isVideo,
          required String peerAddress,
          required String acceptRouteKey,
        }) async => true,
      ),
      socialHubSeedProvider.overrideWithValue(
        SocialHubState.empty(
          lifecycle: const LifecycleSnapshot(
            visibility: AppVisibilityState.background,
            generation: 1,
            capturedAtMillis: 0,
          ),
        ).copyWith(
          book: FriendshipBook.restore(
            profiles: const <String, FriendProfile>{
              _caller: FriendProfile(
                address: _caller,
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
              ),
            },
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(socialHubControllerProvider);
  await runtime.start();
  final SocialHubController hub = container.read(
    socialHubControllerProvider.notifier,
  );
  for (final Map<String, dynamic> p in frames) {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: _caller,
      payload: p,
    );
    if (signal != null) {
      await hub.receiveSignal(
        signal,
        receivedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      await pumpEventQueue();
    }
  }
  expect(container.read(socialHubControllerProvider).activeCall, isNull);
  return (
    missedNotices: <String>[
      for (final RuntimeSystemNotification n in shade.shown)
        if (n.category == RuntimeSystemNotificationCategory.call &&
            n.title.contains('Nieodebrane'))
          n.title,
    ],
    callLines: <String>[
      for (final ChatMessage m in await timeline.load(_caller))
        if (chatMessageEvent(m)?.code case final String key
            when key.startsWith('call.'))
          key,
    ],
  );
}

void main() {
  for (final String answer in <String>['call_accept', 'call_decline']) {
    test('the caller tells the callee\'s other devices that the call was '
        'taken on another device ($answer)', () async {
      final List<Map<String, dynamic>> toPhone = await _framesToPhone(answer);
      expect(toPhone.map((Map<String, dynamic> p) => p['type']), <String>[
        'call_invite',
        'call_end',
      ]);
      expect(toPhone.last[kCallElsewhereKey], isTrue);
      expect(toPhone.last['callId'], 'c1');
    });

    test('locked phone: a call taken on the laptop ($answer) stops ringing '
        'and leaves no missed call', () async {
      final ({List<bool> rings, List<String> missed}) after =
          await _lockedPhoneAfter(await _framesToPhone(answer));
      expect(after.rings, <bool>[true, false]);
      expect(after.missed, isEmpty);
    });

    test('Zen in the background: a call taken on the laptop ($answer) ends '
        'without a missed-call notification or line', () async {
      final ({List<String> missedNotices, List<String> callLines}) after =
          await _appAfter(await _framesToPhone(answer));
      expect(after.missedNotices, isEmpty);
      expect(after.callLines, isNot(contains('call.missed')));
      expect(after.callLines, isNot(contains('call.endedBy')));
    });
  }

  test('the caller hanging up before anyone answered still leaves the '
      'missed call, locked and in the app', () async {
    final List<Map<String, dynamic>> hangUp = <Map<String, dynamic>>[
      <String, dynamic>{'type': 'call_invite', 'callId': 'c1', 'kind': 'audio'},
      <String, dynamic>{'type': 'call_end', 'callId': 'c1'},
    ];
    final ({List<bool> rings, List<String> missed}) locked =
        await _lockedPhoneAfter(hangUp);
    expect(locked.rings, <bool>[true, false]);
    expect(locked.missed, hasLength(1));
    final ({List<String> missedNotices, List<String> callLines}) app =
        await _appAfter(hangUp);
    expect(app.missedNotices, hasLength(1));
  });
}
