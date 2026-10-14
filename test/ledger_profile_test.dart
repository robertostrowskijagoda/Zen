import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
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

void main() {
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

  test(
    'fields are clipped and a profile is written only when changed',
    () async {
      final Map<String, dynamic> body = profileBody(
        name: '  ${'x' * 100}  ',
        address: ada,
      );
      expect((body['name'] as String).length, kMaxProfileName);

      final LedgerNode a = await make(ada, const <String>[]);
      expect(latestProfile(a, a.account), isNull);
      expect(
        await publishProfileIfChanged(
          a,
          profileBody(name: 'Ada', address: ada),
        ),
        isTrue,
      );
      expect(
        await publishProfileIfChanged(
          a,
          profileBody(name: 'Ada', address: ada),
        ),
        isFalse,
      );
      expect(
        await publishProfileIfChanged(
          a,
          profileBody(name: 'Ada K.', address: ada),
        ),
        isTrue,
      );
      final LedgerProfile? p = latestProfile(a, a.account);
      expect(p?.name, 'Ada K.');
      expect(p?.address, ada);
    },
  );

  test('a followed stranger is shown by the name from their profile', () async {
    final LedgerNode a = await make(ada, const <String>[]);
    final LedgerNode c = await make(cel, const <String>[]);
    await publishProfileIfChanged(a, profileBody(name: 'Ada', address: ada));
    await a.publish(kPostKind, newPostBody('Cześć obserwujący'));
    await c.follow(ada);
    await _settle();

    expect(c.knownAccountOf(ada), a.account);
    final FeedPost post = buildFeed(c, nameOf: (String x) => x).single;
    expect(post.authorLabel, 'Ada');
  });

  test('a reshare introduces the author: name and address to follow', () async {
    final LedgerNode a = await make(ada, <String>[bob]);
    final LedgerNode b = await make(bob, <String>[ada, cel]);
    final LedgerNode c = await make(cel, <String>[bob]);
    await publishProfileIfChanged(a, profileBody(name: 'Ada', address: ada));
    final LogEntry post = await a.publish(
      kPostKind,
      newPostBody('Do udostępnienia'),
    );
    await _settle();
    final LogEntry? profile = latestProfileEntry(b, a.account);
    expect(profile, isNotNull);
    await b.publish(kReshareKind, reshareBody(post, authorProfile: profile));
    // Bob's own profile passed off as Ada's is dropped from the reshare.
    await publishProfileIfChanged(b, profileBody(name: 'Bob', address: bob));
    final Map<String, dynamic> body = reshareBody(
      post,
      authorProfile: latestProfileEntry(b, b.account),
    );
    expect(body.containsKey('profile'), isFalse);
    await _settle();

    final ReshareCache cache = ReshareCache();
    await cache.checkAll(c.entriesOf(ofAccount: b.account));
    final FeedPost seen = buildFeed(
      c,
      nameOf: (String x) => x == bob ? 'Bob' : x,
      reshares: cache,
    ).single;
    expect(seen.authorLabel, 'Ada');
    expect(seen.authorAddress, ada);
    expect(seen.resharedBy, <String>['Bob']);

    // Following from there works like any follow.
    await c.follow(seen.authorAddress);
    await _settle();
    expect(c.knownAccountOf(ada), a.account);
  });

  test('the profile photo travels with the public profile', () async {
    final LedgerNode a = await make(ada, const <String>[]);
    final LedgerNode c = await make(cel, const <String>[]);
    final Uint8List photo = Uint8List.fromList(
      List<int>.generate(4000, (int i) => i % 251),
    );
    final Map<String, dynamic>? ref = await avatarRefFor(a, photo);
    // Same photo, same reference: the profile does not change on restart.
    expect(await avatarRefFor(a, photo), ref);
    expect(await avatarRefFor(a, null), isNull);
    await publishProfileIfChanged(
      a,
      profileBody(name: 'Ada', address: ada, avatar: ref),
    );
    expect(
      await publishProfileIfChanged(
        a,
        profileBody(name: 'Ada', address: ada, avatar: ref),
      ),
      isFalse,
    );
    await c.follow(ada);
    await _settle();
    final LedgerProfile? seen = latestProfile(c, a.account);
    expect(seen?.avatar, isNotNull);
    expect(await openMedia(c.blobs, seen!.avatar!), photo);
  });
}
