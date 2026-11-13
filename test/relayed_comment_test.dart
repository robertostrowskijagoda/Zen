import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/feed/thread_moderation.dart'
    show kThreadBlockKind, threadBlockBody;
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// A comment from outside the reader's circle reaches the reader in bundles,
// each signed only by the friend who wrote it. Whose bundle is read first
// must not decide whose words a comment shows or whether it shows at all.

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
  final String dee = PeerShareCodec.normalizeAddress('200::d');
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

  String names(String x) => x == ada
      ? 'Ada'
      : x == bob
      ? 'Bob'
      : x == cel
      ? 'Cela'
      : x == dee
      ? 'Dee'
      : x;

  setUp(() => nodes = <String, _Linked>{});

  List<String> seen(LedgerNode reader, String post) => <String>[
    for (final FeedComment c in buildFeed(
      reader,
      nameOf: names,
    ).firstWhere((FeedPost p) => p.id == post).comments)
      '${c.authorLabel}: ${c.text}',
  ];

  Map<String, dynamic> bundle(
    String post,
    List<Map<String, dynamic>> comments,
  ) => <String, dynamic>{
    'post': post,
    'likes': <Map<String, dynamic>>[],
    'comments': comments,
  };

  group('a bundle without proofs (as older versions write them)', () {
    // Ada wrote the post; her bundle passes on Dee's comment (Dee is her
    // friend, a stranger to Cela). Bob is a friend of Ada and Cela, and
    // Cela reads his bundles before Ada's.
    Future<(LedgerNode, LedgerNode, LedgerNode, LogEntry)> world() async {
      final LedgerNode a = await make(ada, <String>[bob, cel]);
      final LedgerNode b = await make(bob, <String>[ada, cel]);
      final LedgerNode c = await make(cel, <String>[bob, ada]);
      await _settle();
      final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
      await a.publish(
        kReactionsKind,
        bundle(post.id, <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'dee-comment',
            'a': 'dee-account',
            'n': 'Dee',
            't': 'Gratulacje, Ada!',
            'at': 5,
          },
        ]),
        spaceKind: 'acts',
      );
      await _settle();
      return (a, b, c, post);
    }

    test('a friend cannot hide the author\'s comment by giving its id to '
        'someone the author blocked', () async {
      final (LedgerNode a, LedgerNode b, LedgerNode c, LogEntry post) =
          await world();
      await a.publish(
        kThreadBlockKind,
        threadBlockBody('troll-account', name: 'Troll'),
        spaceKind: 'acts',
      );
      await b.publish(
        kReactionsKind,
        bundle(post.id, <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'dee-comment',
            'a': 'troll-account',
            'n': 'x',
            't': 'x',
            'at': 5,
          },
        ]),
        spaceKind: 'acts',
      );
      await _settle();
      expect(c.friendAccounts.values.first, b.account);
      expect(seen(c, post.id), <String>['Dee (przez Ada): Gratulacje, Ada!']);
    });

    test('a friend cannot rewrite the comment the author passed on', () async {
      final (LedgerNode _, LedgerNode b, LedgerNode c, LogEntry post) =
          await world();
      await b.publish(
        kReactionsKind,
        bundle(post.id, <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'dee-comment',
            'a': 'dee-account',
            'n': 'Dee',
            't': 'Ada, nikt Cię tu nie lubi.',
            'at': 5,
          },
        ]),
        spaceKind: 'acts',
      );
      await _settle();
      expect(seen(c, post.id), <String>['Dee (przez Ada): Gratulacje, Ada!']);
    });
  });

  group('a comment with its proof', () {
    // Dee (Ada's friend only) comments under Ada's post for real; Ada's
    // bundle passes it on with its proof.
    Future<(LedgerNode, LedgerNode, LedgerNode, LedgerNode, LogEntry)>
    world() async {
      final LedgerNode a = await make(ada, <String>[bob, cel, dee]);
      final LedgerNode b = await make(bob, <String>[ada, cel]);
      final LedgerNode c = await make(cel, <String>[bob, ada]);
      final LedgerNode d = await make(dee, <String>[ada]);
      await _settle();
      final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
      await _settle();
      await d.publish(
        kCommentKind,
        commentBody(post.id, 'Gratulacje, Ada!'),
        spaceKind: 'acts',
      );
      await _settle();
      expect(await relayReactions(a, nameOf: names), 1);
      await _settle();
      return (a, b, c, d, post);
    }

    test('passed on by the author and by a friend, it shows once with its '
        'own words', () async {
      final (_, LedgerNode b, LedgerNode c, LedgerNode d, LogEntry post) =
          await world();
      // Bob reshares the post and passes Ada's bundle on.
      await b.publish(kReshareKind, reshareBody(post));
      await _settle();
      expect(await relayReactions(b, nameOf: names), 1);
      await _settle();
      final BundleComment passed = readBundles(
        c.entriesOf(spaceKind: 'acts', ofAccount: b.account),
      )[post.id]!.comments.single;
      expect(passed.proof, isNotNull);
      expect(passed.account, d.account);
      expect(seen(c, post.id), <String>['Dee (przez Ada): Gratulacje, Ada!']);
    });

    test(
      'a friend read first can neither hide it nor change its words',
      () async {
        final (
          LedgerNode a,
          LedgerNode b,
          LedgerNode c,
          LedgerNode d,
          LogEntry post,
        ) = await world();
        final BundleComment real = readBundles(
          c.entriesOf(spaceKind: 'acts', ofAccount: a.account),
        )[post.id]!.comments.single;
        expect(real.proof, isNotNull);
        await a.publish(
          kThreadBlockKind,
          threadBlockBody('troll-account', name: 'Troll'),
          spaceKind: 'acts',
        );
        await b.publish(
          kReactionsKind,
          bundle(post.id, <Map<String, dynamic>>[
            <String, dynamic>{
              'id': real.id,
              'a': 'troll-account',
              'n': 'x',
              't': 'x',
              'at': 5,
              kBundleProofKey: real.proof,
            },
          ]),
          spaceKind: 'acts',
        );
        await _settle();
        expect(seen(c, post.id), <String>['Dee (przez Ada): Gratulacje, Ada!']);
        await b.publish(
          kReactionsKind,
          bundle(post.id, <Map<String, dynamic>>[
            <String, dynamic>{
              'id': real.id,
              'a': d.account,
              'n': 'Dee',
              't': 'Ada, nikt Cię tu nie lubi.',
              'at': 5,
              kBundleProofKey: real.proof,
            },
          ]),
          spaceKind: 'acts',
        );
        await _settle();
        expect(seen(c, post.id), <String>['Dee (przez Ada): Gratulacje, Ada!']);
      },
    );

    test('a proof holds only for the words, writer and post it was made of, '
        'and a copy that proves itself wins whoever carried it', () async {
      final (
        LedgerNode a,
        LedgerNode b,
        LedgerNode c,
        LedgerNode d,
        LogEntry post,
      ) = await world();
      final BundleComment real = readBundles(
        c.entriesOf(spaceKind: 'acts', ofAccount: a.account),
      )[post.id]!.comments.single;
      Map<String, dynamic> copy({
        String? account,
        String text = 'Gratulacje, Ada!',
      }) => <String, dynamic>{
        'id': real.id,
        'a': account ?? d.account,
        'n': 'Dee',
        't': text,
        'at': 5,
        kBundleProofKey: real.proof,
      };
      Future<BundleComment?> read(
        Map<String, dynamic> comment, {
        String? on,
      }) async {
        final LogEntry e = await b.publish(
          kReactionsKind,
          bundle(on ?? post.id, <Map<String, dynamic>>[comment]),
          spaceKind: 'acts',
        );
        return readBundles(<LogEntry>[e])[on ?? post.id]!.comments.firstOrNull;
      }

      expect((await read(copy()))!.proof, isNotNull);
      expect((await read(copy(text: 'Inne słowa')))!.proof, isNull);
      expect((await read(copy(account: 'troll-account')))!.proof, isNull);
      expect((await read(copy(), on: 'another-post'))!.proof, isNull);

      // Neither copy is the author's: the one that proves itself is shown,
      // though the other came first.
      final BundleComment forged = (await read(copy(text: 'Inne słowa')))!;
      final BundleComment honest = (await read(copy()))!;
      FeedComment shown(BundleComment x) => FeedComment(
        id: x.id,
        authorLabel: x.name,
        text: x.text,
        millis: x.millis,
        account: x.account,
      );
      final RelayedComments relayed = RelayedComments()
        ..add(post.id, forged, shown(forged))
        ..add(post.id, honest, shown(honest));
      expect(
        <String>[for (final FeedComment x in relayed.of(post.id)) x.text],
        <String>['Gratulacje, Ada!'],
      );

      // Without proofs and without the author's copy, a copy naming a
      // blocked person does not push the other one out.
      final BundleComment troll = (await read(
        <String, dynamic>{...copy(account: 'troll-account')}
          ..remove(kBundleProofKey),
      ))!;
      final BundleComment plain = (await read(
        <String, dynamic>{...copy()}..remove(kBundleProofKey),
      ))!;
      final RelayedComments old = RelayedComments()
        ..add(post.id, troll, shown(troll))
        ..add(post.id, plain, shown(plain));
      expect(
        <String>[
          for (final FeedComment x in old.of(
            post.id,
            blocked: (String account) => account == 'troll-account',
          ))
            x.account,
        ],
        <String>[d.account],
      );
    });
  });
}
