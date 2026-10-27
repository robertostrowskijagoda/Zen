import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_items.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';

/// What each chip of the Tablica shows: one content, one card.
void main() {
  FeedPost friend(String id, int at, {bool own = false, int degree = 1}) =>
      FeedPost(
        id: id,
        account: 'acc-$id',
        authorLabel: 'Kasia',
        authorAddress: 'addr-$id',
        text: 'Zdjęcia z wycieczki',
        millis: at,
        isOwn: own,
        degree: degree,
        via: degree > 1 ? const <String>['Bob'] : const <String>[],
      );

  PyrFeedPost post(
    String id,
    PyrFeedKind kind, {
    required int at,
    int level = 1,
    bool lead = false,
    int pinnedAt = -1,
  }) => PyrFeedPost(
    id: id,
    kind: kind,
    author: 'k-$id',
    name: 'pseudonim-$id',
    text: 'tekst $id',
    at: at,
    level: level,
    nat: kind == PyrFeedKind.national ? 'PL' : '',
    lead: lead,
    pinnedAt: pinnedAt,
  );

  final PyramidFeed member = PyramidFeed(
    member: true,
    nat: 'PL',
    posts: <PyrFeedPost>[
      post('line2', PyrFeedKind.line, at: 50, level: 2),
      post('top', PyrFeedKind.top, at: 10, level: 0),
      post('line1', PyrFeedKind.line, at: 30),
      post('own', PyrFeedKind.own, at: 60, level: 3),
      post('nat', PyrFeedKind.national, at: 70, level: 4),
      post('natLead', PyrFeedKind.national, at: 5, level: 3, lead: true),
      post('natPin', PyrFeedKind.national, at: 1, level: 6, pinnedAt: 9),
    ],
    referenda: const <PyrFeedReferendum>[
      PyrFeedReferendum(id: 'r1', question: 'Park?', at: 1, end: 999),
    ],
  );
  final List<FeedPost> wall = <FeedPost>[friend('f1', 40), friend('f2', 20)];

  List<String> ids(FeedFilter f, PyramidFeed p) => <String>[
    for (final FeedItem i in composeFeed(f, wall: wall, pyramid: p)) i.id,
  ];

  test('„Wszystko”: friends and the important pyramid posts by time, the '
      'referendum card first; never the national section nor own posts', () {
    expect(ids(FeedFilter.all, member), <String>[
      'ref-r1',
      'line2',
      'f1',
      'line1',
      'f2',
      'top',
    ]);
  });

  test('„Znajomi”: the friends only', () {
    expect(ids(FeedFilter.friends, member), <String>['f1', 'f2']);
  });

  test('„Znajomi”, „2. stopień” and „3. stopień” look one, two or three '
      'steps far, in time; „Wszystko” as far as the reader looks', () {
    final List<FeedPost> mixed = <FeedPost>[
      friend('near', 50),
      friend('second', 40, degree: 2),
      friend('third', 30, degree: 3),
      friend('near2', 20),
    ];
    List<String> shown(FeedFilter f, {int depth = 2}) => <String>[
      for (final FeedItem i in composeFeed(
        f,
        wall: mixed,
        pyramid: PyramidFeed.empty,
        depth: depth,
      ))
        i.id,
    ];
    expect(shown(FeedFilter.friends), <String>['near', 'near2']);
    expect(shown(FeedFilter.second), <String>['near', 'second', 'near2']);
    expect(shown(FeedFilter.third), <String>[
      'near',
      'second',
      'third',
      'near2',
    ]);
    expect(shown(FeedFilter.all), <String>['near', 'second', 'near2']);
    expect(shown(FeedFilter.all, depth: 1), <String>['near', 'near2']);
    expect(shown(FeedFilter.all, depth: 3), <String>[
      'near',
      'second',
      'third',
      'near2',
    ]);
    expect(FeedFilter.friends.depth, 1);
    expect(FeedFilter.second.depth, 2);
    expect(FeedFilter.third.depth, 3);
    expect(FeedFilter.all.depth, isNull);
    expect(FeedFilter.parse('second'), FeedFilter.second);
  });

  test('„Przyjaciele”: only the posts of close friends, never own ones', () {
    final List<FeedPost> mixed = <FeedPost>[
      friend('close1', 50),
      friend('mid', 40),
      friend('own', 30, own: true),
      friend('close2', 20),
    ];
    bool isClose(FeedPost p) =>
        p.authorAddress == 'addr-close1' ||
        p.authorAddress == 'addr-close2' ||
        p.authorAddress == 'addr-own';
    List<String> shown(FeedFilter f) => <String>[
      for (final FeedItem i in composeFeed(
        f,
        wall: mixed,
        pyramid: member,
        isClose: isClose,
      ))
        i.id,
    ];
    expect(shown(FeedFilter.close), <String>['close1', 'close2']);
    // „Znajomi” keeps everyone; without a lookup nobody is a close friend.
    expect(shown(FeedFilter.friends), <String>[
      'close1',
      'mid',
      'own',
      'close2',
    ]);
    expect(ids(FeedFilter.close, member), isEmpty);
    expect(FeedFilter.parse('close'), FeedFilter.close);
  });

  test('„Piramida”: the top, then the line from the highest, own posts at '
      'their level; the referendum card first', () {
    expect(ids(FeedFilter.pyramid, member), <String>[
      'ref-r1',
      'top',
      'line1',
      'line2',
      'own',
    ]);
  });

  test('„Kraj”: the national section only — pinned, the lead, by level', () {
    expect(ids(FeedFilter.national, member), <String>[
      'natPin',
      'natLead',
      'nat',
    ]);
    for (final FeedFilter f in <FeedFilter>[
      FeedFilter.all,
      FeedFilter.friends,
      FeedFilter.close,
      FeedFilter.pyramid,
    ]) {
      expect(
        ids(f, member).where((String id) => id.startsWith('nat')),
        isEmpty,
        reason: '$f',
      );
    }
  });

  test('no content twice, whatever the sources hold', () {
    final PyrFeedPost twice = post('top', PyrFeedKind.top, at: 10, level: 0);
    final PyramidFeed doubled = PyramidFeed(
      member: true,
      posts: <PyrFeedPost>[...member.posts, twice],
      referenda: <PyrFeedReferendum>[...member.referenda, member.referenda[0]],
    );
    for (final FeedFilter f in FeedFilter.values) {
      final List<String> got = ids(f, doubled);
      expect(got.toSet(), hasLength(got.length), reason: '$f');
    }
    expect(
      ids(FeedFilter.all, doubled).where((String id) => id == 'top'),
      hasLength(1),
    );
  });

  test('an alarm in force heads every filter', () {
    final PyramidFeed alarmed = PyramidFeed(
      member: true,
      posts: member.posts,
      alarms: const <PyrFeedAlarm>[
        PyrFeedAlarm(id: 'a', text: 'Powódź', until: 999),
      ],
    );
    for (final FeedFilter f in FeedFilter.values) {
      expect(ids(f, alarmed).first, 'alarm-a', reason: '$f');
    }
  });

  test('a reader outside: the top in „Wszystko” and „Piramida”, the section '
      'only in „Kraj”; pyramid chips only with such posts', () {
    final PyramidFeed outside = PyramidFeed(
      posts: <PyrFeedPost>[
        post('top', PyrFeedKind.top, at: 10, level: 0),
        post('nat', PyrFeedKind.national, at: 70, level: 4),
      ],
    );
    expect(ids(FeedFilter.all, outside), <String>['f1', 'f2', 'top']);
    expect(ids(FeedFilter.pyramid, outside), <String>['top']);
    expect(ids(FeedFilter.national, outside), <String>['nat']);
    const List<FeedFilter> every = <FeedFilter>[
      FeedFilter.all,
      FeedFilter.friends,
      FeedFilter.second,
      FeedFilter.third,
      FeedFilter.close,
      FeedFilter.pyramid,
      FeedFilter.national,
    ];
    expect(feedFiltersFor(outside), every);

    final PyramidFeed onlyTop = PyramidFeed(
      posts: <PyrFeedPost>[post('top', PyrFeedKind.top, at: 10, level: 0)],
    );
    expect(feedFiltersFor(onlyTop), every);
    expect(feedFiltersFor(PyramidFeed.empty), <FeedFilter>[
      FeedFilter.all,
      FeedFilter.friends,
      FeedFilter.second,
      FeedFilter.third,
      FeedFilter.close,
      FeedFilter.national,
    ], reason: '„Kraj” is always there: the countries are picked in it');
    expect(
      feedFiltersFor(const PyramidFeed(member: true, nat: 'PL')),
      every,
      reason: 'a member has the chips without posts too',
    );
  });

  test('new posts: the top and the line not read yet, recent ones', () {
    const int day = 24 * 3600 * 1000;
    final PyramidFeed feed = PyramidFeed(
      member: true,
      posts: <PyrFeedPost>[
        post('top', PyrFeedKind.top, at: 40 * day, level: 0),
        post('line', PyrFeedKind.line, at: 41 * day),
        post('old', PyrFeedKind.line, at: 1 * day),
        post('own', PyrFeedKind.own, at: 41 * day),
        post('nat', PyrFeedKind.national, at: 41 * day),
      ],
    );
    expect(
      feed.unread((String id) => false, 42 * day).map((PyrFeedPost p) => p.id),
      <String>['line', 'top'],
    );
    expect(
      feed
          .unread((String id) => id == 'top', 42 * day)
          .map((PyrFeedPost p) => p.id),
      <String>['line'],
    );
    expect(
      feed
          .unreadNational((String id) => false, 42 * day)
          .map((PyrFeedPost p) => p.id),
      <String>['nat'],
    );
  });

  test('a filter asked for is handed to the Tablica and opens it', () {
    final int before = feedOpenRequest.value;
    openFeed(FeedFilter.pyramid);
    expect(feedFilterRequest.value, FeedFilter.pyramid);
    expect(feedOpenRequest.value, before + 1);
    feedFilterRequest.value = null;
    expect(FeedFilter.parse('national'), FeedFilter.national);
    expect(FeedFilter.parse('nonsense'), FeedFilter.all);
  });
}
