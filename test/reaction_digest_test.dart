import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_digest.dart';

FeedPost _post({
  List<FeedLiker> likes = const <FeedLiker>[],
  List<FeedComment> comments = const <FeedComment>[],
}) => FeedPost(
  id: 'p1',
  account: 'me',
  authorLabel: 'Ty',
  text: 'Pierwszy dzień wiosny',
  millis: 1000,
  isOwn: true,
  likers: <String>[for (final FeedLiker l in likes) l.name],
  likes: likes,
  comments: comments,
);

FeedLiker _liker(String account, String name) =>
    FeedLiker(account: account, name: name, friend: true);

FeedComment _comment(String id, String account, String name) => FeedComment(
  id: id,
  authorLabel: name,
  text: 'Super',
  millis: 2000,
  account: account,
);

void main() {
  test('the first digest takes what is there as seen', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final ReactionsSeen seen = await ReactionsSeen.load(disk);
    expect(seen.fresh, isTrue);
    final FeedPost before = _post(likes: <FeedLiker>[_liker('b', 'Bob')]);
    expect(seen.noticesFor(<FeedPost>[before]), isEmpty);
    seen.markSeen(<FeedPost>[before]);
    await seen.save(disk);

    final ReactionsSeen again = await ReactionsSeen.load(disk);
    expect(again.fresh, isFalse);
    expect(again.noticesFor(<FeedPost>[before]), isEmpty);
  });

  test('new likes and comments are gathered per post', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final ReactionsSeen seen = await ReactionsSeen.load(disk);
    seen.markSeen(<FeedPost>[
      _post(likes: <FeedLiker>[_liker('b', 'Bob')]),
    ]);
    final FeedPost now = _post(
      likes: <FeedLiker>[
        _liker('me', 'Ty'),
        _liker('b', 'Bob'),
        _liker('c', 'Cela'),
        _liker('d', 'Dan'),
        _liker('e', 'Ewa'),
        _liker('f', 'Fran'),
      ],
      comments: <FeedComment>[
        _comment('c1', 'c', 'Cela'),
        _comment('c2', 'c', 'Cela'),
        _comment('c3', 'd', 'Dan'),
        _comment('c4', 'me', 'Ty'),
        _comment('c5', 'e', 'Ewa').hidden(),
      ],
    );
    final List<ReactionNotice> notices = seen.noticesFor(<FeedPost>[now]);
    expect(notices, hasLength(1));
    final ReactionNotice n = notices.single;
    // Your own like and comment are no news; Bob's like was seen; a hidden
    // comment is not announced.
    expect(n.likes, 4);
    expect(n.likers, <String>['Cela', 'Dan', 'Ewa', 'Fran']);
    expect(n.comments, 3);
    expect(n.commenters, <String>['Cela', 'Dan']);
    expect(
      noticeLikesText(n),
      'Cela i 3 inne osoby polubili Twój post „Pierwszy dzień wiosny”',
    );
    expect(
      noticeCommentsText(n),
      'Cela i 1 inna osoba skomentowali Twój post „Pierwszy dzień wiosny”',
    );

    seen.markSeen(<FeedPost>[now]);
    expect(seen.noticesFor(<FeedPost>[now]), isEmpty);
  });

  test('one like reads as one person', () {
    const ReactionNotice n = ReactionNotice(
      postId: 'p',
      excerpt: '',
      likers: <String>['Bob'],
      likes: 1,
      commenters: <String>['Bob'],
      comments: 2,
      millis: 0,
    );
    expect(noticeLikesText(n), 'Bob polubił(a) Twój post');
    expect(
      noticeCommentsText(n),
      'Bob skomentował(a) Twój post (2 komentarze)',
    );
  });
}
