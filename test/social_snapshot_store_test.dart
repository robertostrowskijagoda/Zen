import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  group('FileSocialSnapshotStore', () {
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
