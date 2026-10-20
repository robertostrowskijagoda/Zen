import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/profile_card.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

UserProfile _me(Map<ProfileField, FieldVisibility> who) {
  Map<String, String> visibility = const <String, String>{};
  for (final MapEntry<ProfileField, FieldVisibility> e in who.entries) {
    visibility = withFieldVisibility(visibility, e.key, e.value);
  }
  return UserProfile(
    displayName: 'Ada',
    customStatus: 'Na spacerze',
    bio: 'Liczę rzeczy.',
    nationalities: const <String>['PL', 'UA'],
    visibility: visibility,
  );
}

Future<Uint8List?> _noImage(String? path) async => null;

void main() {
  group('fields and who sees them', () {
    test('defaults: status for friends, photo public', () {
      const UserProfile p = UserProfile();
      expect(fieldVisibility(p, ProfileField.status), FieldVisibility.all);
      expect(fieldVisibility(p, ProfileField.photo), FieldVisibility.public);
      expect(fieldVisibility(p, ProfileField.nationality), FieldVisibility.all);
      // A default is not stored; anything else is, and survives JSON.
      final Map<String, String> v = withFieldVisibility(
        const <String, String>{},
        ProfileField.bio,
        FieldVisibility.close,
      );
      expect(v, <String, String>{'bio': 'close'});
      expect(
        withFieldVisibility(v, ProfileField.bio, FieldVisibility.public),
        isEmpty,
      );
      final UserProfile restored = UserProfile.fromJson(
        UserProfile(
          visibility: v,
          nationalities: const <String>['PL'],
        ).toJson(),
      );
      expect(
        fieldVisibility(restored, ProfileField.bio),
        FieldVisibility.close,
      );
      expect(restored.nationalities, <String>['PL']);
    });

    test('who may see a field at which level', () {
      expect(fieldVisibleTo(FieldVisibility.public, null), isTrue);
      expect(fieldVisibleTo(FieldVisibility.all, null), isFalse);
      expect(fieldVisibleTo(FieldVisibility.all, FriendLevel.weak), isTrue);
      expect(fieldVisibleTo(FieldVisibility.mid, FriendLevel.weak), isFalse);
      expect(fieldVisibleTo(FieldVisibility.mid, FriendLevel.friend), isTrue);
      expect(
        fieldVisibleTo(FieldVisibility.close, FriendLevel.friend),
        isFalse,
      );
      expect(fieldVisibleTo(FieldVisibility.close, FriendLevel.close), isTrue);
      expect(
        fieldVisibleTo(FieldVisibility.onlyMe, FriendLevel.close),
        isFalse,
      );
    });

    test('nationalities are country codes', () {
      expect(parseNationalities(' pl, ua;PL '), <String>['PL', 'UA']);
      expect(parseNationalities(''), isEmpty);
      expect(() => parseNationalities('Polska'), throwsArgumentError);
      expect(() => parseNationalities('PL UA DE FR'), throwsArgumentError);
      expect(cleanNationalities(<Object?>['PL', 'xx', 7, 'UA']), <String>[
        'PL',
        'UA',
      ]);
      expect(nationalityLabel('PL'), '🇵🇱 PL');
    });

    test('the profile is split by audience', () {
      final Map<Audience, Map<String, dynamic>> parts = profileParts(
        _me(<ProfileField, FieldVisibility>{
          ProfileField.status: FieldVisibility.close,
          ProfileField.bio: FieldVisibility.mid,
          ProfileField.friendCount: FieldVisibility.public,
          ProfileField.followerCount: FieldVisibility.onlyMe,
        }),
        address: '200::a',
        avatar: <String, dynamic>{'id': 'photo'},
        friendCount: 12,
        followerCount: 40,
      );
      final Map<String, dynamic> public = parts[Audience.public]!;
      expect(public['name'], 'Ada');
      expect(public['status'], '');
      expect(public['bio'], '');
      expect(public['avatar'], <String, dynamic>{'id': 'photo'});
      expect(public['nf'], 12);
      expect(public.containsKey('nfw'), isFalse);
      expect(public.containsKey('nat'), isFalse);
      expect(parts[Audience.all], <String, dynamic>{
        'nat': <String>['PL', 'UA'],
      });
      expect(parts[Audience.mid], <String, dynamic>{'bio': 'Liczę rzeczy.'});
      expect(parts[Audience.close], <String, dynamic>{'status': 'Na spacerze'});
    });

    test(
      'friends get in profile_update only what all friends may see',
      () async {
        final Map<String, dynamic> open = await buildProfilePayload(
          _me(const <ProfileField, FieldVisibility>{}),
        );
        expect(open['status'], 'Na spacerze');
        expect(open['bio'], 'Liczę rzeczy.');
        final Map<String, dynamic> closed = await buildProfilePayload(
          _me(<ProfileField, FieldVisibility>{
            ProfileField.status: FieldVisibility.close,
            ProfileField.bio: FieldVisibility.all,
          }),
        );
        expect(closed['status'], '');
        expect(closed['bio'], 'Liczę rzeczy.');
      },
    );
  });

  group('in the ledger', () {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final String cel = PeerShareCodec.normalizeAddress('200::c');
    late Map<String, _Linked> nodes;

    Future<LedgerNode> make(String address, List<String> friends) async {
      final _Linked t = nodes[address] = _Linked(address, nodes);
      await t.start();
      final LedgerNode n = LedgerNode(
        transport: t,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => friends,
        bridges: BridgeBook(probe: (String _) async => null),
      );
      addTearDown(n.stop);
      await n.start();
      return n;
    }

    setUp(() => nodes = <String, _Linked>{});

    test('each reader sees the fields meant for them', () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada]);
      final LedgerNode c = await make(cel, const <String>[]);
      await _settle();
      final UserProfile me = _me(<ProfileField, FieldVisibility>{
        ProfileField.status: FieldVisibility.close,
        ProfileField.bio: FieldVisibility.mid,
        ProfileField.friendCount: FieldVisibility.public,
        ProfileField.followerCount: FieldVisibility.all,
      });
      expect(
        await publishOwnProfile(
          a,
          me: me,
          address: ada,
          readImage: _noImage,
          friendCount: 1,
          followerCount: 1,
        ),
        isTrue,
      );
      // Nothing changed: nothing new is written.
      expect(
        await publishOwnProfile(
          a,
          me: me,
          address: ada,
          readImage: _noImage,
          friendCount: 1,
          followerCount: 1,
        ),
        isFalse,
      );
      await c.follow(ada);
      await _settle();

      // Bob is a friend ("Znajomy"): bio and nationality, not the status.
      final ProfileView onBob = readProfile(b, a.account)!;
      expect(onBob.name, 'Ada');
      expect(onBob.bio, 'Liczę rzeczy.');
      expect(onBob.nationalities, <String>['PL', 'UA']);
      expect(onBob.status, '');
      expect(onBob.friendCount, 1);
      expect(onBob.followerCount, 1);

      // Cela only follows: the public fields.
      final ProfileView onCela = readProfile(c, a.account)!;
      expect(onCela.name, 'Ada');
      expect(onCela.bio, '');
      expect(onCela.nationalities, isEmpty);
      expect(onCela.friendCount, 1);
      expect(onCela.followerCount, isNull);

      // A friend promoted to "Przyjaciel" reads the status too.
      await a.setLevel(bob, FriendLevel.close);
      await _settle();
      expect(readProfile(b, a.account)!.status, 'Na spacerze');

      // Made public, the status reaches followers; the sealed part that
      // had it is written again without it.
      await publishOwnProfile(
        a,
        me: me.copyWith(
          visibility: withFieldVisibility(
            me.visibility,
            ProfileField.status,
            FieldVisibility.public,
          ),
        ),
        address: ada,
        readImage: _noImage,
        friendCount: 1,
        followerCount: 1,
      );
      await c.greetFriends();
      await _settle();
      expect(readProfile(c, a.account)!.status, 'Na spacerze');
      expect(latestProfile(c, a.account)!.status, 'Na spacerze');
    });
  });
}
