import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_event_text.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  group('FileSocialSnapshotStore', () {
    test(
      'an entry of the wrong kind is skipped, the others are kept',
      () async {
        final Directory tempDir = await Directory.systemTemp.createTemp(
          'zen-social-store-odd-',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final FileBinaryStore files = FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        );
        final FileSocialSnapshotStore store = FileSocialSnapshotStore(
          store: files,
        );
        await store.save(
          SocialHubState.empty().copyWith(
            groups: const <String, GroupProfile>{
              'g': GroupProfile(
                id: 'g',
                name: 'G',
                createdById: 'self',
                createdAtMillis: 0,
                memberAddresses: <String>['self'],
                pendingInviteIds: <String, String>{'200::a': 'inv-1'},
              ),
            },
          ),
        );
        // The JSON document is the snapshot's last string: written over
        // with entries a damaged or foreign file could hold.
        final Uint8List bytes = (await files.read('social/hub'))!;
        final int at = _lastJsonAt(bytes);
        final Map<String, dynamic> doc =
            jsonDecode(utf8.decode(bytes.sublist(at))) as Map<String, dynamic>;
        doc['disappear'] = <String, Object?>{'ada.ygg': 30, 'x': 'y', 'n': -5};
        doc['groupNotifyAll'] = <String, Object?>{
          'group:g': true,
          'group:h': 'yes',
        };
        doc['groups'] = <String, Object?>{
          'g': <String, Object?>{
            'pendingInviteIds': <String, Object?>{
              '200::a': 'inv-1',
              '200::b': 7,
            },
            'receivedInviteIds': <Object?>[],
          },
        };
        final Uint8List json = utf8.encode(jsonEncode(doc));
        await files.write(
          'social/hub',
          Uint8List.fromList(<int>[
            ...bytes.sublist(0, at - 4),
            ...(ByteData(
              4,
            )..setUint32(0, json.length, Endian.little)).buffer.asUint8List(),
            ...json,
          ]),
        );

        final SocialHubState loaded = (await store.load())!;
        expect(loaded.disappearingTimers, <String, int>{'ada.ygg': 30});
        expect(loaded.groupNotifyAll, <String, bool>{'group:g': true});
        expect(loaded.groups['g']!.pendingInviteIds, <String, String>{
          '200::a': 'inv-1',
        });
      },
    );

    test('keeps the friendship records and their clock', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-social-store-records-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      const String fred = '200::f';
      const String ola = '200::7';
      final FriendshipBook book = FriendshipBook.empty
          .invite(fred, (FriendProfile base) => base)
          .admit(
            fred,
            FriendshipEvidence.theyAcceptedMine,
            const FriendshipTick(100, 'phone'),
          )
          .remove(ola, const FriendshipTick(200, 'phone'));
      await store.save(SocialHubState.empty().copyWith(book: book));
      final SocialHubState loaded = (await store.load())!;
      expect(loaded.book.records, book.records);
      expect(loaded.book.clock, book.clock);
      expect(
        loaded.friendByAddress(fred)?.status,
        FriendRelationshipStatus.accepted,
      );
      expect(loaded.removedFriendAt(ola), 200);
    });

    test('round-trips friends and inbox state', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-social-store-test-',
      );
      addTearDown(() => tempDir.delete(recursive: true));

      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      final SocialHubState snapshot = SocialHubState(
        lifecycle: const LifecycleSnapshot(
          visibility: AppVisibilityState.foreground,
          generation: 3,
          capturedAtMillis: 99,
        ),
        book: FriendshipBook.restore(
          profiles: const <String, FriendProfile>{
            'ada.ygg': FriendProfile(
              address: 'ada.ygg',
              displayName: 'Ada',
              nickname: 'Ada z chóru',
              status: FriendRelationshipStatus.accepted,
              isOnline: true,
              lastPresenceAtMillis: 88,
              lastMessagePreview: 'Hej!',
              lastActivityLabel: 'Teraz',
              unreadCount: 3,
            ),
          },
        ),
        inbox: const <InboxEntry>[
          InboxEntry(
            id: 'accept-1',
            type: InboxEntryType.friendAccepted,
            title: 'Ada zaakceptował(a) zaproszenie',
            body: 'Po chwili wszystko bylo gotowe.',
            createdAtMillis: 11,
            routeKey: 'zen://inbox',
            peerAddress: 'ada.ygg',
          ),
        ],
        pendingSignalCount: 2,
        backgroundAlerts: const <InboxEntry>[
          InboxEntry(
            id: 'alert-1',
            type: InboxEntryType.message,
            title: 'Nowa wiadomość',
            body: 'Masz cos nowego do przeczytania.',
            createdAtMillis: 12,
            routeKey: 'zen://chat/ada.ygg?title=Ada',
            peerAddress: 'ada.ygg',
          ),
        ],
        activeCall: const CallSession(
          id: 'call-1',
          peerAddress: 'ada.ygg',
          displayName: 'Ada',
          kind: CallInviteKind.video,
          status: CallSessionStatus.active,
          startedAtMillis: 777,
          isMuted: true,
          isSpeakerOn: true,
          isCameraEnabled: false,
        ),
        groups: const <String, GroupProfile>{
          'grp-1': GroupProfile(
            id: 'grp-1',
            name: 'Moja Grupa',
            description: 'Opis grupy',
            createdById: 'self',
            createdAtMillis: 555,
            memberAddresses: <String>['ada.ygg', 'bob.ygg'],
            lastMessagePreview: 'Hej!',
            lastActivityLabel: 'Teraz',
            unreadCount: 1,
          ),
        },
        pendingLaunchIntent: RuntimeRouteIntent.conversation(
          id: 'launch-1',
          peerAddress: 'ada.ygg',
          title: 'Ada',
        ),
      );

      await store.save(snapshot);
      final SocialHubState? restored = await store.load();

      expect(restored, isNotNull);
      expect(restored!.lifecycle.visibility, AppVisibilityState.foreground);
      expect(restored.pendingSignalCount, 2);
      expect(restored.acceptedFriends.single.displayLabel, 'Ada');
      expect(restored.acceptedFriends.single.nickname, 'Ada z chóru');
      expect(restored.acceptedFriends.single.unreadCount, 3);
      expect(restored.acceptedFriends.single.lastPresenceAtMillis, 88);
      expect(restored.groups.length, 1);
      expect(restored.groups['grp-1']?.name, 'Moja Grupa');
      expect(restored.groups['grp-1']?.memberAddresses, <String>[
        'ada.ygg',
        'bob.ygg',
      ]);
      expect(restored.groups['grp-1']?.unreadCount, 1);
      expect(restored.inbox.single.title, 'Ada zaakceptował(a) zaproszenie');
      expect(restored.inbox.single.routeKey, 'zen://inbox');
      expect(restored.inbox.single.peerAddress, 'ada.ygg');
      expect(restored.backgroundAlerts.single.title, 'Nowa wiadomość');
      expect(
        restored.backgroundAlerts.single.routeKey,
        'zen://chat/ada.ygg?title=Ada',
      );
      expect(restored.backgroundAlerts.single.peerAddress, 'ada.ygg');
      expect(restored.pendingLaunchIntent!.peerAddress, 'ada.ygg');
      expect(restored.activeCall, isNotNull);
      expect(restored.activeCall!.id, 'call-1');
      expect(restored.activeCall!.kind, CallInviteKind.video);
      expect(restored.activeCall!.status, CallSessionStatus.active);
      expect(restored.activeCall!.isMuted, isTrue);
      expect(restored.activeCall!.isSpeakerOn, isTrue);
      expect(restored.activeCall!.isCameraEnabled, isFalse);
    });

    test('pinned by mutation testing: presence kept when only part of it '
        "is known, an entry said by its body's event, timers, levels, a "
        "group's notify-all and a group call's members", () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-social-store-pinned-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      final SocialHubState snapshot = SocialHubState.empty().copyWith(
        book: FriendshipBook.restore(
          profiles: const <String, FriendProfile>{
            'ada.ygg': FriendProfile(
              address: 'ada.ygg',
              displayName: 'Ada',
              status: FriendRelationshipStatus.accepted,
              lastOpenedAtMillis: 42,
            ),
            'bob.ygg': FriendProfile(
              address: 'bob.ygg',
              displayName: 'Bob',
              status: FriendRelationshipStatus.accepted,
              presenceAtMillis: 7,
            ),
            'cat.ygg': FriendProfile(
              address: 'cat.ygg',
              displayName: 'Cat',
              status: FriendRelationshipStatus.accepted,
              presence: PeerPresence.background,
            ),
          },
        ),
        inbox: const <InboxEntry>[
          InboxEntry(
            id: 'said',
            type: InboxEntryType.message,
            title: 'Ada',
            body: 'x',
            createdAtMillis: 3,
            bodyEvent: SocialEventText(
              'chat.attachmentFailed',
              <String, String>{'name': 'Ada'},
            ),
          ),
        ],
        disappearingTimers: const <String, int>{'ada.ygg': 30, 'group:g': 0},
        notificationPrivacy: const <String, NotificationPrivacy>{
          'ada.ygg': NotificationPrivacy.senderAndContent,
        },
        groupNotifyAll: const <String, bool>{'group:g': true},
        activeCall: const CallSession(
          id: 'call-g',
          peerAddress: 'ada.ygg',
          displayName: 'Grupa',
          kind: CallInviteKind.audio,
          status: CallSessionStatus.active,
          startedAtMillis: 9,
          isGroup: true,
          groupId: 'g',
          participantAddresses: <String>['ada.ygg', 'bob.ygg'],
        ),
      );
      await store.save(snapshot);
      final SocialHubState restored = (await store.load())!;
      expect(restored.friendByAddress('ada.ygg')?.lastOpenedAtMillis, 42);
      expect(restored.friendByAddress('bob.ygg')?.presenceAtMillis, 7);
      expect(
        restored.friendByAddress('bob.ygg')?.presence,
        PeerPresence.offline,
      );
      expect(
        restored.friendByAddress('cat.ygg')?.presence,
        PeerPresence.background,
      );
      expect(restored.inbox.single.bodyEvent?.code, 'chat.attachmentFailed');
      expect(restored.disappearingTimers, snapshot.disappearingTimers);
      expect(restored.notificationPrivacy, snapshot.notificationPrivacy);
      expect(restored.groupNotifyAll, snapshot.groupNotifyAll);
      expect(restored.activeCall?.isGroup, isTrue);
      expect(restored.activeCall?.groupId, 'g');
      expect(restored.activeCall?.participantAddresses, <String>[
        'ada.ygg',
        'bob.ygg',
      ]);
    });

    test('a friend goes by the name of their newest profile', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-social-store-names-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      await store.save(
        SocialHubState.empty().copyWith(
          book: FriendshipBook.restore(
            profiles: const <String, FriendProfile>{
              'ada.ygg': FriendProfile(
                address: 'ada.ygg',
                displayName: 'Ada',
                nickname: 'z chóru',
                status: FriendRelationshipStatus.accepted,
              ),
            },
          ),
          peerProfiles: const <String, PeerPublicProfile>{
            'ada.ygg': PeerPublicProfile(
              address: 'ada.ygg',
              version: 5,
              name: 'Ada Kowalska',
            ),
          },
        ),
      );
      final FriendProfile ada = (await store.load())!.friends['ada.ygg']!;
      expect(ada.displayName, 'Ada Kowalska');
      expect(ada.nickname, 'z chóru');
    });
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}

/// Where the JSON document at the end of a snapshot starts: the string
/// whose length (the four bytes before it) reaches the end.
int _lastJsonAt(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  for (int at = 4; at < bytes.length; at++) {
    if (bytes[at] == 0x7B &&
        data.getUint32(at - 4, Endian.little) == bytes.length - at) {
      return at;
    }
  }
  throw StateError('no JSON document');
}
