import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/presentation/post_reactions_sheet.dart';

void main() {
  testWidgets('likers: friends first, the rest as a number', (
    WidgetTester tester,
  ) async {
    const FeedPost post = FeedPost(
      id: 'p',
      account: 'a',
      authorLabel: 'Ada',
      text: 'Hej',
      millis: 0,
      isOwn: false,
      likers: <String>['Bob', 'Mama (przez Bob)'],
      likes: <FeedLiker>[
        FeedLiker(account: 'b', name: 'Bob', friend: true),
        FeedLiker(account: 'm', name: 'Mama (przez Bob)'),
      ],
      likeTotal: 1286,
    );
    expect(likeSummary(post), 'Lubią to: Bob i 1285 innych osób');
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => showPostLikers(
                context,
                post,
                mutualFriends: (String account) => account == 'm' ? 3 : 7,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('post-likers')), findsOneWidget);
    expect(find.text('Polubili (1286)'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Mama (przez Bob)'), findsOneWidget);
    expect(find.text('…i 1284 inne osoby'), findsOneWidget);
    // Only someone who is not your friend gets the mutual friends line.
    expect(find.text('3 wspólnych znajomych'), findsOneWidget);
    expect(find.byKey(const Key('post-liker-mutual-m')), findsOneWidget);
    expect(find.byKey(const Key('post-liker-mutual-b')), findsNothing);
  });

  test('summaries in Polish', () {
    FeedPost liked(List<FeedLiker> likes, {int? total}) => FeedPost(
      id: 'p',
      account: 'a',
      authorLabel: 'Ada',
      text: 'Hej',
      millis: 0,
      isOwn: false,
      likers: <String>[for (final FeedLiker l in likes) l.name],
      likes: likes,
      likeTotal: total,
    );
    expect(likeSummary(liked(const <FeedLiker>[])), isNull);
    expect(
      likeSummary(liked(const <FeedLiker>[FeedLiker(account: 'x', name: 'X')])),
      'Lubi to 1 osoba',
    );
    expect(
      likeSummary(
        liked(const <FeedLiker>[
          FeedLiker(account: 'me', name: 'Ty', friend: true),
        ]),
      ),
      'Lubią to: Ty',
    );
    expect(
      likeSummary(
        liked(const <FeedLiker>[
          FeedLiker(account: 'me', name: 'Ty', friend: true),
          FeedLiker(account: 'b', name: 'Bob', friend: true),
          FeedLiker(account: 'c', name: 'Cela', friend: true),
        ], total: 5),
      ),
      'Lubią to: Ty, Bob i 3 inne osoby',
    );
  });
}
