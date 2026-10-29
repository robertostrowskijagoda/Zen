import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/profile/profile_card.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

final String ada = PeerShareCodec.normalizeAddress('200::ada');
final String bob = PeerShareCodec.normalizeAddress('200::b0b');
final String eve = PeerShareCodec.normalizeAddress('200::e7e');

Uint8List _photo({int width = 400, int height = 300}) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 80, 40));
  return img.encodePng(image);
}

final class _Harness {
  _Harness(this.dir) {
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          MemoryRuntimeSystemNotificationService(),
        ),
        supportDirectoryResolverProvider.overrideWithValue(() async => dir),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.foregroundFocused,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                ada: FriendProfile(
                  address: ada,
                  status: FriendRelationshipStatus.accepted,
                ),
                bob: FriendProfile(
                  address: bob,
                  displayName: 'Bob',
                  nickname: 'Bobek',
                  status: FriendRelationshipStatus.accepted,
                ),
                eve: FriendProfile(
                  address: eve,
                  displayName: 'Ewa',
                  status: FriendRelationshipStatus.blocked,
                ),
              },
            ),
          ),
        ),
      ],
    );
    container.read(socialHubControllerProvider);
    addTearDown(container.dispose);
  }

  final Directory dir;
  final MemorySignalTransport transport = MemorySignalTransport();
  late final ProviderContainer container;

  SocialHubController get controller =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  Future<void> deliver(String from, Map<String, dynamic> payload) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
    );
    expect(signal, isNotNull);
    await controller.receiveSignal(signal!);
  }

  List<Map<String, dynamic>> profilesSentTo(String address) => transport
      .sentSignals
      .where(
        (s) =>
            PeerShareCodec.addressesEqual(s.remoteAddress, address) &&
            s.payload['type'] == 'profile_update',
      )
      .map((s) => s.payload)
      .toList();
}

/// Waits (up to a few seconds) for work that runs in an isolate.
Future<void> _eventually(bool Function() done) async {
  for (int i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Map<String, dynamic> _update({
  required int v,
  String name = 'Ada Lovelace',
  String status = 'Na spacerze',
  String bio = 'Liczę rzeczy.',
  String? avatar,
}) => <String, dynamic>{
  'type': 'profile_update',
  'v': v,
  'name': name,
  'status': status,
  'bio': bio,
  'avatar': ?avatar,
};

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zen-profile-');
  });

  tearDown(() async {
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  });

  test('on screen a friend goes by their own name; "Kontakt Zen" only when '
      'no name of theirs is known at all', () {
    final String named = PeerShareCodec.normalizeAddress('200::a1');
    final String nameless = PeerShareCodec.normalizeAddress('200::a2');
    final String member = PeerShareCodec.normalizeAddress('200::a3');
    final SocialHubState state =
        SocialHubState.empty(
          lifecycle: const LifecycleSnapshot(
            visibility: AppVisibilityState.foreground,
            generation: 1,
            capturedAtMillis: 0,
          ),
        ).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{
              named: FriendProfile(
                address: named,
                status: FriendRelationshipStatus.accepted,
              ),
              nameless: FriendProfile(
                address: nameless,
                status: FriendRelationshipStatus.accepted,
              ),
            },
          ),
          peerProfiles: <String, PeerPublicProfile>{
            named: PeerPublicProfile(address: named, version: 1, name: 'Ada'),
          },
        );
    // Their newest profile, over the name they gave in a group.
    expect(
      state.displayNameOf(named, selfNamed: 'Ada z grupy', fallback: '?'),
      'Ada',
    );
    // A friend whose name never came: the one they gave themselves in the
    // group, not a placeholder.
    expect(
      state.displayNameOf(nameless, selfNamed: 'Bartek', fallback: '?'),
      'Bartek',
    );
    expect(state.displayNameOf(nameless, fallback: 'Uczestnik'), 'Kontakt Zen');
    // Not a friend: what they call themselves, else the fallback.
    expect(
      state.displayNameOf(member, selfNamed: '  Ola ', fallback: '?'),
      'Ola',
    );
    expect(state.displayNameOf(member, fallback: 'Uczestnik'), 'Uczestnik');
  });

  group('receiving', () {
    test('a friend\'s profile is kept, photo included', () async {
      final _Harness h = _Harness(dir);
      final Uint8List thumb = makeAvatarThumbnail(_photo())!;
      await h.deliver(ada, _update(v: 10, avatar: base64Encode(thumb)));

      final PeerPublicProfile peer = h.state.peerProfileOf(ada)!;
      expect(peer.name, 'Ada Lovelace');
      expect(peer.status, 'Na spacerze');
      expect(peer.bio, 'Liczę rzeczy.');
      expect(peer.avatarPath, isNotNull);
      expect(File(peer.avatarPath!).existsSync(), isTrue);
      // Encrypted in the vault, under a name that says nothing about Ada.
      expect(isMediaVaultPath(peer.avatarPath), isTrue);
      final Uint8List photo = await h.container
          .read(mediaVaultProvider)
          .read(peer.avatarPath!);
      expect(img.decodeJpg(photo)?.width, kProfileAvatarSize);
      expect(
        File(peer.avatarPath!).readAsBytesSync().take(2),
        isNot(<int>[0xFF, 0xD8]),
      );
      // No nickname given: their own name is shown.
      expect(h.state.nameFor(h.state.friendByAddress(ada)!), 'Ada Lovelace');
    });

    test('their new name is shown; the nickname stays under it', () async {
      final _Harness h = _Harness(dir);
      await h.deliver(bob, _update(v: 5, name: 'Robert'));
      final FriendProfile friend = h.state.friendByAddress(bob)!;
      expect(h.state.nameFor(friend), 'Robert');
      expect(friend.displayName, 'Robert');
      expect(friend.nickname, 'Bobek');
      expect(h.state.peerProfileOf(bob)!.name, 'Robert');
    });

    test('older copies are ignored, a newer one replaces the photo', () async {
      final _Harness h = _Harness(dir);
      final String first = base64Encode(makeAvatarThumbnail(_photo())!);
      await h.deliver(ada, _update(v: 10, avatar: first));
      final String firstPath = h.state.peerProfileOf(ada)!.avatarPath!;

      await h.deliver(ada, _update(v: 9, name: 'Stara wersja'));
      expect(h.state.peerProfileOf(ada)!.name, 'Ada Lovelace');

      await h.deliver(ada, _update(v: 11, name: 'Ada'));
      final PeerPublicProfile peer = h.state.peerProfileOf(ada)!;
      expect(peer.name, 'Ada');
      // No photo in the update: they removed it.
      expect(peer.avatarPath, isNull);
      expect(File(firstPath).existsSync(), isFalse);
    });

    test(
      'garbage instead of a photo is dropped, the rest still applies',
      () async {
        final _Harness h = _Harness(dir);
        await h.deliver(
          ada,
          _update(
            v: 3,
            avatar: base64Encode(utf8.encode('<script>x</script>')),
          ),
        );
        final PeerPublicProfile peer = h.state.peerProfileOf(ada)!;
        expect(peer.name, 'Ada Lovelace');
        expect(peer.avatarPath, isNull);
        expect(Directory('${dir.path}/vault').existsSync(), isFalse);
      },
    );

    test('blocked people and strangers cannot push a profile', () async {
      final _Harness h = _Harness(dir);
      await h.deliver(eve, _update(v: 3));
      await h.deliver(PeerShareCodec.normalizeAddress('200::5'), _update(v: 3));
      expect(h.state.peerProfiles, isEmpty);
    });

    test('overlong fields are cut down', () async {
      final _Harness h = _Harness(dir);
      await h.deliver(ada, _update(v: 3, name: 'A' * 500, bio: 'b' * 5000));
      final PeerPublicProfile peer = h.state.peerProfileOf(ada)!;
      expect(peer.name.length, 60);
      expect(peer.bio.length, 400);
    });
  });

  group('sending', () {
    test('editing the profile shares it with friends once', () async {
      final _Harness h = _Harness(dir);
      final File photo = File('${dir.path}/me.png')
        ..writeAsBytesSync(_photo(width: 900, height: 700));
      await h.container
          .read(userProfileControllerProvider.notifier)
          .updateProfile(displayName: 'Robert', avatarPath: photo.path);
      await _eventually(
        () =>
            h.profilesSentTo(ada).isNotEmpty &&
            h.profilesSentTo(bob).isNotEmpty,
      );

      for (final String friend in <String>[ada, bob]) {
        final List<Map<String, dynamic>> sent = h.profilesSentTo(friend);
        expect(sent, hasLength(1), reason: friend);
        expect(sent.single['name'], 'Robert');
        final Uint8List avatar = base64Decode(sent.single['avatar'] as String);
        // A small thumbnail, never the original photo.
        expect(avatar.length, lessThan(kMaxIncomingAvatarBytes));
        final img.Image decoded = img.decodeImage(avatar)!;
        expect(decoded.width, kProfileAvatarSize);
        expect(decoded.height, kProfileAvatarSize);
      }
      expect(h.profilesSentTo(eve), isEmpty);

      // Nothing changed: nothing more goes out.
      await h.controller.hydrateFromStore();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(h.profilesSentTo(ada), hasLength(1));
    });

    test('accepting someone sends them the profile', () async {
      final _Harness h = _Harness(dir);
      await h.container
          .read(userProfileControllerProvider.notifier)
          .updateProfile(displayName: 'Robert');
      await _eventually(() => h.profilesSentTo(ada).isNotEmpty);
      final String kuba = PeerShareCodec.normalizeAddress('200::c0b');
      await h.controller.receiveSignal(
        ZenSignal(
          type: ZenSignalType.friendRequest,
          sender: kuba,
          displayName: 'Kuba',
        ),
      );
      await h.controller.acceptFriendRequest(peerAddress: kuba);
      await _eventually(() => h.profilesSentTo(kuba).isNotEmpty);
      expect(h.profilesSentTo(kuba), hasLength(1));
    });
  });

  group('photos', () {
    test('a thumbnail is a small square JPEG', () {
      final Uint8List thumb = makeAvatarThumbnail(
        _photo(width: 1200, height: 500),
      )!;
      expect(thumb[0], 0xFF);
      expect(thumb[1], 0xD8);
      final img.Image decoded = img.decodeImage(thumb)!;
      expect(decoded.width, kProfileAvatarSize);
      expect(decoded.height, kProfileAvatarSize);
    });

    test('an incoming image claiming huge dimensions is refused', () {
      final Uint8List wide = img.encodePng(img.Image(width: 3000, height: 2));
      expect(sanitizeIncomingAvatar(wide), isNull);
    });

    test('non-images are refused', () {
      expect(
        makeAvatarThumbnail(Uint8List.fromList(utf8.encode('MZ...'))),
        isNull,
      );
      expect(sanitizeIncomingAvatar(Uint8List(10)), isNull);
    });
  });
}
