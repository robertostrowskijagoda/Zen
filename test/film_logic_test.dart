import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/films/film_cache.dart';
import 'package:zen/src/features/films/film_delivery.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_order.dart';
import 'package:zen/src/features/films/film_prefs.dart';
import 'package:zen/src/features/films/film_trim.dart';
import 'package:zen/src/features/media/video_compressor.dart';

const int _hour = 3600 * 1000;
const int _now = 1000 * 24 * _hour;

MediaRef _ref(String id, {String mime = 'video/mp4'}) =>
    MediaRef(id: id, key: Uint8List(32), nonce: Uint8List(12), mime: mime);

FilmPost _film(
  String id, {
  String account = 'a',
  int ageHours = 1,
  bool own = false,
  bool close = false,
  int likes = 0,
  List<String> passedBy = const <String>[],
  FilmReplyRef? replyTo,
  bool poster = true,
}) => FilmPost(
  id: id,
  account: account,
  authorLabel: account,
  video: _ref('v-$id'),
  poster: poster ? _ref('p-$id', mime: 'image/jpeg') : null,
  millis: _now - ageHours * _hour,
  isOwn: own,
  close: close,
  passedBy: passedBy,
  replyTo: replyTo,
  likes: <FeedLiker>[
    for (int i = 0; i < likes; i++) FeedLiker(account: 'l$i', name: 'L$i'),
  ],
);

List<String> _ids(List<FilmPost> films) => <String>[
  for (final FilmPost f in films) f.id,
];

void main() {
  group('order', () {
    test('fresh unwatched first, then older, then watched and own', () {
      final List<FilmPost> order = orderFilms(
        <FilmPost>[
          _film('own', own: true, account: 'me'),
          _film('old', ageHours: 24 * 9, account: 'b'),
          _film('seen', account: 'c'),
          _film('fresh', account: 'd'),
        ],
        nowMillis: _now,
        watched: <String>{'seen'},
        me: 'me',
      );
      expect(_ids(order), <String>['fresh', 'old', 'own', 'seen']);
    });

    test('popular among friends and close friends come forward', () {
      final List<FilmPost> order = orderFilms(<FilmPost>[
        _film('plain', account: 'a', ageHours: 2),
        _film('liked', account: 'b', ageHours: 2, likes: 6),
        _film('close', account: 'c', ageHours: 2, close: true),
      ], nowMillis: _now);
      expect(order.first.id, 'liked');
      expect(order.last.id, 'plain');
    });

    test('fresher wins between equal films; answers to me first', () {
      final List<FilmPost> order = orderFilms(
        <FilmPost>[
          _film('older', account: 'a', ageHours: 40),
          _film('newer', account: 'b', ageHours: 1),
          _film(
            'answer',
            account: 'c',
            ageHours: 10,
            replyTo: const FilmReplyRef(id: 'x', account: 'me'),
          ),
        ],
        nowMillis: _now,
        me: 'me',
      );
      expect(_ids(order), <String>['answer', 'newer', 'older']);
    });

    test('a friend of a friend\'s film is a little behind', () {
      final double near = filmScore(_film('a'), nowMillis: _now);
      final double far = filmScore(
        _film('b', passedBy: <String>['Bob']),
        nowMillis: _now,
      );
      // Passed on counts as popular, but being far takes some back.
      expect(far, greaterThan(near - 0.5));
      expect(
        filmScore(_film('c'), nowMillis: _now),
        greaterThan(filmScore(_film('d', ageHours: 30), nowMillis: _now)),
      );
    });

    test('the same author does not play twice in a row', () {
      final List<FilmPost> order = orderFilms(<FilmPost>[
        _film('a1', account: 'a', likes: 9),
        _film('a2', account: 'a', likes: 8),
        _film('b1', account: 'b'),
      ], nowMillis: _now);
      expect(_ids(order), <String>['a1', 'b1', 'a2']);
    });

    test('the session keeps what was played and re-ranks the rest', () {
      expect(
        mergeFilmOrder(
          previous: <String>['a', 'b', 'c', 'd', 'e'],
          index: 1,
          ranked: <String>['new', 'e', 'd', 'c', 'b', 'a'],
          keepAhead: 1,
        ),
        <String>['a', 'b', 'c', 'new', 'e', 'd'],
      );
      // A removed film leaves the session.
      expect(
        mergeFilmOrder(
          previous: <String>['a', 'b'],
          index: 0,
          ranked: <String>['b'],
        ),
        <String>['b'],
      );
    });
  });

  group('fetching', () {
    test('the film on screen whole, the next two only their start', () {
      final List<FilmPost> films = <FilmPost>[
        for (int i = 0; i < 8; i++) _film('f$i'),
      ];
      final FilmFetchPlan plan = planFilmFetch(
        order: films,
        index: 1,
        fetching: <String>{'v-f0'},
      );
      expect(plan.full, <String>['v-f1']);
      expect(plan.heads, <String>['v-f2', 'v-f3']);
      expect(plan.pause, <String>['v-f0']);
      expect(plan.posters, <String>[for (int i = 1; i <= 6; i++) 'p-f$i']);
    });

    test('nothing again that is here already', () {
      final List<FilmPost> films = <FilmPost>[
        for (int i = 0; i < 4; i++) _film('f$i'),
      ];
      final FilmFetchPlan plan = planFilmFetch(
        order: films,
        index: 0,
        complete: <String>{'v-f0', 'p-f0', 'p-f1'},
        headReady: <String>{'v-f1'},
      );
      expect(plan.full, isEmpty);
      expect(plan.heads, <String>['v-f2']);
      expect(plan.posters, <String>['p-f2', 'p-f3']);
    });

    test('with downloads off only the film on screen comes', () {
      final FilmFetchPlan plan = planFilmFetch(
        order: <FilmPost>[_film('a'), _film('b')],
        index: 0,
        download: false,
      );
      expect(plan.full, <String>['v-a']);
      expect(plan.heads, isEmpty);
      expect(plan.posters, <String>['p-a']);
    });

    test('sources: author, watchers, mailboxes, friends; no repeats', () {
      expect(
        filmSources(
          authorAddresses: <String>['200::a'],
          watchers: <String>['200::w', '200::a'],
          mailboxes: <String>['200::m'],
          friends: <String>['200::f', '200::w', '200::me'],
          self: '200::me',
        ),
        <String>['200::a', '200::w', '200::m', '200::f'],
      );
    });

    test('a mailbox keeps the newest films of each friend within 20 MB', () {
      const int mb = 1024 * 1024;
      final Set<String> keep = planMailboxSeeding(<SeedCandidate>[
        (author: 'a', blob: 'a-new', bytes: 12 * mb, millis: 3),
        (author: 'a', blob: 'a-mid', bytes: 6 * mb, millis: 2),
        (author: 'a', blob: 'a-old', bytes: 1 * mb, millis: 1),
        (author: 'b', blob: 'b-big', bytes: 25 * mb, millis: 5),
        (author: 'b', blob: 'b-small', bytes: 1 * mb, millis: 4),
      ]);
      expect(keep, <String>{'a-new', 'a-mid', 'a-old'});
    });
  });

  group('cache', () {
    test('within the limit nothing goes', () {
      expect(
        planFilmCacheEviction(<FilmCacheItem>[
          const FilmCacheItem(id: 'a', bytes: 10, lastUsedMillis: 1),
        ], limitBytes: 10),
        isEmpty,
      );
    });

    test('watched films go first, least recently used first', () {
      final List<String> out = planFilmCacheEviction(<FilmCacheItem>[
        const FilmCacheItem(id: 'new-unseen', bytes: 40, lastUsedMillis: 9),
        const FilmCacheItem(id: 'old-unseen', bytes: 40, lastUsedMillis: 1),
        const FilmCacheItem(
          id: 'new-seen',
          bytes: 40,
          lastUsedMillis: 8,
          watched: true,
        ),
        const FilmCacheItem(
          id: 'old-seen',
          bytes: 40,
          lastUsedMillis: 2,
          watched: true,
        ),
      ], limitBytes: 70);
      expect(out, <String>['old-seen', 'new-seen', 'old-unseen']);
    });

    test('kept films are never picked', () {
      final List<String> out = planFilmCacheEviction(
        <FilmCacheItem>[
          const FilmCacheItem(
            id: 'on-screen',
            bytes: 50,
            lastUsedMillis: 1,
            watched: true,
          ),
          const FilmCacheItem(id: 'other', bytes: 50, lastUsedMillis: 5),
        ],
        limitBytes: 60,
        keep: <String>{'on-screen'},
      );
      expect(out, <String>['other']);
    });

    test('the remembered state survives a round trip', () {
      final FilmPrefs prefs = FilmPrefs(muted: true, friendsOfFriends: true)
        ..markWatched('f1')
        ..touch('b1', 42);
      final FilmPrefs back = FilmPrefs.fromBytes(prefs.toBytes());
      expect(back.muted, isTrue);
      expect(back.friendsOfFriends, isTrue);
      expect(back.watched, <String>{'f1'});
      expect(back.used, <String, int>{'b1': 42});
      expect(FilmPrefs.fromBytes(Uint8List.fromList(<int>[1, 2])).muted, false);
    });
  });

  group('trimming', () {
    test('a long recording starts cut to a minute', () {
      expect(
        FilmTrim.initial(150000),
        const FilmTrim(startMs: 0, endMs: kFilmDefaultMaxMs),
      );
      expect(FilmTrim.initial(20000), const FilmTrim(startMs: 0, endMs: 20000));
      expect(FilmTrim.initial(20000).isWhole(20000), isTrue);
    });

    test('the ends stay inside, at least a second apart', () {
      const FilmTrim t = FilmTrim(startMs: 0, endMs: 10000);
      expect(t.withStart(-5, 30000).startMs, 0);
      expect(
        t.withStart(9800, 30000),
        const FilmTrim(startMs: 9000, endMs: 10000),
      );
      expect(t.withEnd(500, 30000), const FilmTrim(startMs: 0, endMs: 1000));
      expect(t.withEnd(99999, 30000).endMs, 30000);
    });

    test('never longer than 90 seconds: the other end follows', () {
      const FilmTrim t = FilmTrim(startMs: 10000, endMs: 70000);
      final FilmTrim longer = t.withEnd(150000, 200000);
      expect(longer, const FilmTrim(startMs: 60000, endMs: 150000));
      expect(longer.lengthMs, kFilmHardMaxMs);
      expect(longer.overDefault, isTrue);
      final FilmTrim earlier = const FilmTrim(
        startMs: 100000,
        endMs: 190000,
      ).withStart(0, 200000);
      expect(earlier, const FilmTrim(startMs: 0, endMs: 90000));
    });

    test('times read as minutes and seconds', () {
      expect(filmClock(0), '0:00');
      expect(filmClock(7400), '0:07');
      expect(filmClock(90000), '1:30');
    });
  });

  group('compression plan', () {
    test('a minute fits 2.5 Mb/s in 20 MB, longer films get less', () {
      final VideoCompressionPlan minute = planVideoCompression(
        durationMs: 60000,
      );
      expect(minute.videoBitrate, kVideoTargetBitrate);
      expect(minute.maxShortSide, 720);
      expect(minute.estimatedBytes(60000), lessThan(kCompressedVideoMaxBytes));
      final VideoCompressionPlan long = planVideoCompression(durationMs: 90000);
      expect(long.videoBitrate, lessThan(kVideoTargetBitrate));
      expect(long.estimatedBytes(90000), lessThan(kCompressedVideoMaxBytes));
      expect(
        () => planVideoCompression(durationMs: 20 * 60 * 1000),
        throwsArgumentError,
      );
    });

    test('pictures shrink to 720 on the short side, even, never grow', () {
      expect(scaledVideoSize(1080, 1920), (width: 720, height: 1280));
      expect(scaledVideoSize(1920, 1080), (width: 1280, height: 720));
      expect(scaledVideoSize(640, 481), (width: 640, height: 480));
      expect(scaledVideoSize(1440, 1081), (width: 958, height: 720));
      expect(scaledVideoSize(0, 100), (width: 0, height: 0));
    });
  });

  group('film bodies', () {
    final Map<String, dynamic> video = <String, dynamic>{
      'id': 'blob',
      'k': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      'n': 'AAAAAAAAAAAAAAAA',
      'mime': 'video/mp4',
      'ms': 12000,
    };

    test('captions up to 150 characters, trimmed', () {
      final Map<String, dynamic> body = newFilmBody(
        video: video,
        caption: '  ${'x' * kMaxFilmCaptionChars}  ',
      );
      expect(body['cap'], 'x' * kMaxFilmCaptionChars);
      expect(
        () => newFilmBody(video: video, caption: 'x' * 151),
        throwsArgumentError,
      );
      expect(newFilmBody(video: video)['cap'], '');
    });

    test('only a film, never longer than the hard limit', () {
      expect(
        () => newFilmBody(
          video: <String, dynamic>{...video, 'mime': 'image/jpeg'},
        ),
        throwsArgumentError,
      );
      expect(
        () => newFilmBody(
          video: <String, dynamic>{...video, 'ms': kFilmHardMaxMs + 5000},
        ),
        throwsArgumentError,
      );
    });

    test('an answer names the film it answers', () {
      final Map<String, dynamic> body = newFilmBody(
        video: video,
        replyTo: const FilmReplyRef(id: 'film-1', account: 'acc'),
      );
      expect(
        FilmReplyRef.fromJson(body['re']),
        const FilmReplyRef(id: 'film-1', account: 'acc'),
      );
      expect(FilmReplyRef.fromJson(<String, dynamic>{'id': ''}), isNull);
    });

    test('reactions: one of the offered ones, taken back with nothing', () {
      expect(filmReactionBody('f', '🔥'), <String, dynamic>{
        'post': 'f',
        'e': '🔥',
      });
      expect(filmReactionBody('f', '')['e'], '');
      expect(() => filmReactionBody('f', 'x'), throwsArgumentError);
    });

    test('views go in batches', () {
      final List<Map<String, dynamic>> bodies = filmSeenBodies(<String>[
        for (int i = 0; i < kMaxSeenPerEntry + 3; i++) 'f$i',
      ]);
      expect(bodies, hasLength(2));
      expect((bodies.last['posts'] as List).length, 3);
    });
  });
}
