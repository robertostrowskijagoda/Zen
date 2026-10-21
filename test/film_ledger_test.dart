import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/films/film_feed.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_pass.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/mp4_probe.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

import 'support/ledger_sim.dart';

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

Map<String, dynamic> _video(String id) => <String, dynamic>{
  'id': id,
  'k': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
  'n': 'AAAAAAAAAAAAAAAA',
  'mime': 'video/mp4',
  'ms': 8000,
};

/// A box: size, type, payload.
Uint8List _box(String type, List<int> payload) {
  final int size = 8 + payload.length;
  return Uint8List.fromList(<int>[
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...payload,
  ]);
}

List<int> _u32(int v) => <int>[
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// A track header (version 0) with [matrix] and a picture of [w] × [h].
Uint8List _tkhd(int w, int h, List<int> matrix) => _box('tkhd', <int>[
  ...List<int>.filled(4 + 4 + 4 + 4 + 4 + 4 + 8 + 2 + 2 + 2 + 2, 0),
  for (final int m in matrix) ..._u32(m),
  ..._u32(w << 16),
  ..._u32(h << 16),
]);

Uint8List _trak(String handler, Uint8List tkhd) => _box('trak', <int>[
  ...tkhd,
  ..._box('mdia', <int>[
    ..._box('hdlr', <int>[
      ...List<int>.filled(8, 0),
      ...handler.codeUnits,
      ...List<int>.filled(12, 0),
    ]),
  ]),
]);

void main() {
  group('a film in the ledger', () {
    late Map<String, _Linked> nodes;
    late String ada;
    late String bob;
    late String cel;

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

    String names(String address) => address == ada
        ? 'Ada'
        : address == bob
        ? 'Bob'
        : 'Cel';

    setUp(() {
      nodes = <String, _Linked>{};
      ada = PeerShareCodec.normalizeAddress('200::a');
      bob = PeerShareCodec.normalizeAddress('200::b');
      cel = PeerShareCodec.normalizeAddress('200::c');
    });

    test('friends see it with likes, reactions, views and answers', () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada]);
      final LogEntry film = await b.publish(
        kFilmKind,
        newFilmBody(
          video: _video('blob-1'),
          caption: 'Skałki',
          audience: Audience.public,
        ),
      );
      await _settle();

      List<FilmPost> seenBy(LedgerNode n) =>
          buildFilms(NodeFilmLedgerView(n), nameOf: names);
      final FilmPost onAda = seenBy(a).single;
      expect(onAda.id, film.id);
      expect(onAda.caption, 'Skałki');
      expect(onAda.authorLabel, 'Bob');
      expect(onAda.isOwn, isFalse);
      // Nothing is downloaded on its own: the entry lists no files.
      expect(film.blobs, isEmpty);

      await a.publish(kLikeKind, likeBody(film.id), spaceKind: 'acts');
      await a.publish(
        kFilmReactionKind,
        filmReactionBody(film.id, '🔥'),
        spaceKind: 'acts',
      );
      await a.publish(
        kFilmSeenKind,
        filmSeenBodies(<String>[film.id]).single,
        spaceKind: 'acts',
      );
      final LogEntry answer = await a.publish(
        kFilmKind,
        newFilmBody(
          video: _video('blob-2'),
          audience: Audience.public,
          replyTo: FilmReplyRef(id: film.id, account: b.account),
        ),
      );
      await _settle();

      final List<FilmPost> onBob = seenBy(b);
      final FilmPost own = onBob.firstWhere((FilmPost f) => f.id == film.id);
      expect(own.isOwn, isTrue);
      expect(own.likes.map((FeedLiker l) => l.name), <String>['Ada']);
      expect(own.reactions, <String, int>{'🔥': 1});
      expect(own.views, 1);
      expect(own.replies, <String>[answer.id]);
      final FilmPost reply = onBob.firstWhere(
        (FilmPost f) => f.id == answer.id,
      );
      expect(reply.replyTo?.id, film.id);
      // Views are counted for the author only.
      expect(seenBy(a).firstWhere((FilmPost f) => f.id == film.id).views, 0);

      // Taken back, then removed.
      await a.publish(
        kFilmReactionKind,
        filmReactionBody(film.id, ''),
        spaceKind: 'acts',
      );
      await b.publish(kPostDeleteKind, deletePostBody(film.id));
      await _settle();
      expect(seenBy(a).map((FilmPost f) => f.id), <String>[answer.id]);
      expect(seenBy(b).single.replies, isEmpty);
    });

    test('a liked public film reaches friends of friends who opt in', () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada, cel]);
      final LedgerNode c = await make(cel, <String>[bob]);
      final LogEntry film = await c.publish(
        kFilmKind,
        newFilmBody(video: _video('blob-c'), audience: Audience.public),
      );
      final LogEntry closed = await c.publish(
        kFilmKind,
        newFilmBody(video: _video('blob-d')),
      );
      await _settle();
      final FilmPost onBob = buildFilms(
        NodeFilmLedgerView(b),
        nameOf: names,
      ).firstWhere((FilmPost f) => f.id == film.id);
      await b.publish(
        kFilmPassKind,
        filmPassBody(onBob.entry!, authorName: 'Cel', authorAddress: cel),
        spaceKind: 'acts',
      );
      // Only public films can be passed on.
      expect(() => filmPassBody(closed), throwsArgumentError);
      await _settle();

      final FilmPassCache passes = FilmPassCache();
      expect(
        await passes.checkAll(
          a.entriesOf(spaceKind: 'acts', ofAccount: b.account),
        ),
        isTrue,
      );
      expect(
        buildFilms(NodeFilmLedgerView(a), nameOf: names, passes: passes),
        isEmpty,
      );
      final FilmPost far = buildFilms(
        NodeFilmLedgerView(a),
        nameOf: names,
        passes: passes,
        friendsOfFriends: true,
      ).single;
      expect(far.id, film.id);
      expect(far.authorLabel, 'Cel');
      expect(far.passedBy, <String>['Bob']);
      expect(far.passerAddresses, <String>[bob]);
      expect(far.fromFriendOfFriend, isTrue);
      expect(passedFilmIds(b.entriesOf(spaceKind: 'acts')), <String>{film.id});

      // A changed caption inside a pass is refused.
      final Map<String, dynamic> forged = onBob.entry!.toCertifiedJson();
      forged['body'] = <String, dynamic>{
        ...onBob.entry!.body,
        'cap': 'Podróbka',
      };
      final LogEntry fake = await b.publish(kFilmPassKind, <String, dynamic>{
        'fid': film.id,
        'film': forged,
      }, spaceKind: 'acts');
      expect(await unpackFilmPass(fake), isNull);
    });
  });

  group('fetching only the start of a film', () {
    test('the first piece comes, then the rest when asked', () async {
      final SimNet net = SimNet();
      final SimNode a = net.add('a');
      final SimNode b = net.add('b');
      net.link('a', 'b');
      final Uint8List film = Uint8List.fromList(simBytes(700 * 1024));
      final String id = await a.blobs.put(film, mime: 'video/mp4');

      String? head;
      b.replicator.onBlobHead = (String done) => head = done;
      b.replicator.fetchBlob(id, <String>['a'], firstChunks: 1);
      await net.pump();
      expect(head, id);
      expect(await b.blobs.chunkAt(id, 0), isNotNull);
      expect(await b.blobs.chunkAt(id, 1), isNull);
      expect(b.blobs.isComplete(id), isFalse);
      expect(b.blobs.wanted, isNot(contains(id)));

      // Retries and new sources do not pull the rest in.
      b.replicator
        ..retryBlobs()
        ..offerSource('a');
      await net.pump();
      expect(await b.blobs.chunkAt(id, 1), isNull);

      b.replicator.fetchBlob(id, <String>['a']);
      await net.pump();
      expect(await b.blobs.read(id), film);
    });

    test('a paused film stops and picks up later', () async {
      final SimNet net = SimNet();
      final SimNode a = net.add('a');
      final SimNode b = net.add('b');
      net.link('a', 'b');
      final Uint8List film = Uint8List.fromList(simBytes(600 * 1024));
      final String id = await a.blobs.put(film);
      b.replicator
        ..fetchBlob(id, <String>['a'])
        ..pauseBlob(id);
      await net.pump();
      expect(b.blobs.isComplete(id), isFalse);
      b.replicator.fetchBlob(id, <String>['a']);
      await net.pump();
      expect(await b.blobs.read(id), film);
    });

    test('a start already here is not asked for again', () async {
      final SimNet net = SimNet();
      final SimNode a = net.add('a');
      final SimNode b = net.add('b');
      net.link('a', 'b');
      final String id = await a.blobs.put(
        Uint8List.fromList(simBytes(300 * 1024)),
      );
      b.replicator.fetchBlob(id, <String>['a'], firstChunks: 1);
      await net.pump();
      int heads = 0;
      b.replicator.onBlobHead = (String _) => heads++;
      b.replicator.fetchBlob(id, <String>['a'], firstChunks: 1);
      await net.pump();
      expect(heads, 0);
      expect(b.blobs.wanted, isEmpty);
    });
  });

  group('mp4 index', () {
    test('length, picture and turn are read without decoding', () {
      final Uint8List mvhd = _box('mvhd', <int>[
        0, 0, 0, 0, // version, flags
        ..._u32(0), ..._u32(0), // times
        ..._u32(1000), // time scale
        ..._u32(12500), // duration
        ...List<int>.filled(80, 0),
      ]);
      const List<int> turned = <int>[
        0, 0x10000, 0, //
        -0x10000 & 0xFFFFFFFF, 0, 0, //
        0, 0, 0x40000000,
      ];
      final Uint8List file = Uint8List.fromList(<int>[
        ..._box('ftyp', 'isom'.codeUnits),
        ..._box('moov', <int>[
          ...mvhd,
          ..._trak('vide', _tkhd(1920, 1080, turned)),
          ..._trak('soun', _tkhd(0, 0, List<int>.filled(9, 0))),
        ]),
        ..._box('mdat', List<int>.filled(16, 7)),
      ]);
      final Mp4Info info = probeMp4(file)!;
      expect(info.durationMs, 12500);
      expect(info.width, 1920);
      expect(info.height, 1080);
      expect(info.rotation, 90);
      expect(info.displayWidth, 1080);
      expect(info.displayHeight, 1920);
      expect(info.hasVideo, isTrue);
      expect(info.hasAudio, isTrue);
    });

    test('anything else is not a film', () {
      expect(probeMp4(Uint8List.fromList(List<int>.filled(64, 1))), isNull);
      expect(probeMp4(_box('ftyp', 'isom'.codeUnits)), isNull);
    });
  });
}
