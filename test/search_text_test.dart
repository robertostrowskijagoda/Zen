import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/feed/feed_items.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/feed_search.dart';
import 'package:zen/src/features/search/message_search.dart';
import 'package:zen/src/features/search/search_text.dart';
import 'package:zen/src/features/social/mentions.dart';

/// How search compares text: case and Polish letters do not matter, every
/// word typed has to be there, and the places found are where the screen
/// marks them.

String _marked(String text, String query) {
  final StringBuffer out = StringBuffer();
  int at = 0;
  for (final SearchRange r in SearchQuery.parse(query).rangesIn(text)) {
    out
      ..write(text.substring(at, r.start))
      ..write('[')
      ..write(text.substring(r.start, r.end))
      ..write(']');
    at = r.end;
  }
  out.write(text.substring(at));
  return out.toString();
}

void main() {
  group('folding', () {
    test('lower case without Polish letters', () {
      expect(foldForSearch('Żółw'), 'zolw');
      expect(foldForSearch('ZAŻÓŁĆ GĘŚLĄ JAŹŃ'), 'zazolc gesla jazn');
      expect(foldForSearch('plain ascii'), 'plain ascii');
      expect(foldForSearch('Straße'), 'strasse');
      expect(foldForSearch('Crème Brûlée'), 'creme brulee');
    });

    test('accents written as separate marks are dropped too', () {
      // "z" + combining dot above, "o" + combining acute.
      expect(foldForSearch('żólw'), 'zolw');
    });

    test('other scripts are only lower-cased', () {
      expect(foldForSearch('ПРИВЕТ'), 'привет');
      expect(foldForSearch('日本'), '日本');
    });
  });

  group('matching', () {
    test('"zolw" finds "żółw", and the other way round', () {
      expect(SearchQuery.parse('zolw').matches('Mam żółwia w domu'), isTrue);
      expect(SearchQuery.parse('ŻÓŁW').matches('zolw'), isTrue);
      expect(SearchQuery.parse('Zolw').matches('ŻÓŁW!'), isTrue);
    });

    test('every word, in any order, also inside longer words', () {
      final SearchQuery q = SearchQuery.parse('  jutro   kino ');
      expect(q.terms, <String>['jutro', 'kino']);
      expect(q.matches('Idziemy do kina jutro?'), isFalse);
      expect(q.matches('Kino jutro o 18'), isTrue);
      expect(q.matches('jutro wieczorem kinomaniacy'), isTrue);
      expect(q.matches('tylko jutro'), isFalse);
    });

    test('an empty query matches nothing; one letter is names only', () {
      expect(SearchQuery.parse('   ').matches('cokolwiek'), isFalse);
      expect(SearchQuery.parse('a').searchesMessages, isFalse);
      expect(SearchQuery.parse('ab').searchesMessages, isTrue);
      expect(SearchQuery.parse('a b').searchesMessages, isTrue);
      // One character of Chinese or Japanese is a whole word.
      expect(SearchQuery.parse('猫').searchesMessages, isTrue);
    });

    test('the same words make the same query', () {
      expect(SearchQuery.parse('Kino JUTRO'), SearchQuery.parse('jutro kino'));
    });
  });

  group('marked places', () {
    test('in the original text, with its letters', () {
      expect(_marked('Mam ŻÓŁWIA i żółwia', 'zolw'), 'Mam [ŻÓŁW]IA i [żółw]ia');
      expect(
        _marked('Kino jutro, kino!', 'kino jutro'),
        '[Kino] [jutro], [kino]!',
      );
    });

    test('overlapping words are one place', () {
      expect(_marked('abcdef', 'abc cde'), '[abcde]f');
    });

    test('a separate accent stays with its letter', () {
      expect(_marked('żólw!', 'zolw'), '[żólw]!');
    });

    test('a letter folded to two is marked whole', () {
      expect(_marked('Straße', 'strass'), '[Straß]e');
      expect(_marked('Straße', 'strasse'), '[Straße]');
    });
  });

  group('snippet', () {
    test('a short text is shown whole, on one line', () {
      final ({String text, List<SearchRange> ranges}) s = searchSnippet(
        'Kupię\nżółwia',
        SearchQuery.parse('zolwia'),
      );
      expect(s.text, 'Kupię żółwia');
      expect(
        s.text.substring(s.ranges.single.start, s.ranges.single.end),
        'żółwia',
      );
    });

    test('a long text is cut around the first place found', () {
      final String long = '${'bla ' * 60}szukane słowo ${'ble ' * 60}';
      final ({String text, List<SearchRange> ranges}) s = searchSnippet(
        long,
        SearchQuery.parse('szukane'),
      );
      expect(s.text.length, lessThanOrEqualTo(122));
      expect(s.text.startsWith('…'), isTrue);
      expect(s.text.endsWith('…'), isTrue);
      expect(
        s.text.substring(s.ranges.single.start, s.ranges.single.end),
        'szukane',
      );
    });
  });

  group('what a message offers to search', () {
    test('text with names for mentions, file names, nothing else', () {
      const ChatMessage mention = ChatMessage(
        id: 'm1',
        sender: 'ada.ygg',
        text: 'Pytam <@0> o żółwia',
        sentAtMillis: 1,
        direction: ChatMessageDirection.incoming,
        mentions: <Mention>[Mention(address: 'bob.ygg', name: 'Bob')],
      );
      expect(searchableTextOf(mention), 'Pytam @Bob o żółwia');
      expect(
        searchableTextOf(
          const ChatMessage(
            id: 'f',
            sender: 'self',
            text: '',
            sentAtMillis: 1,
            direction: ChatMessageDirection.outgoing,
            type: ChatMessageType.file,
            fileName: 'Faktura.pdf',
          ),
        ),
        'Faktura.pdf',
      );
      expect(
        searchableTextOf(
          const ChatMessage(
            id: 's',
            sender: 'system',
            text: 'Połączenie gotowe',
            sentAtMillis: 1,
            direction: ChatMessageDirection.system,
          ),
        ),
        '',
      );
      expect(
        searchableTextOf(
          const ChatMessage(
            id: 'd',
            sender: 'self',
            text: 'skasowane',
            sentAtMillis: 1,
            direction: ChatMessageDirection.outgoing,
            deletedAtMillis: 2,
          ),
        ),
        '',
      );
    });
  });

  group('Tablica', () {
    FeedFriendItem post(
      String id,
      String text, {
      List<FeedComment>? comments,
    }) => FeedFriendItem(
      FeedPost(
        id: id,
        account: 'acc',
        authorLabel: 'Ada',
        text: text,
        millis: 1,
        isOwn: false,
        comments: comments ?? const <FeedComment>[],
      ),
    );

    test('posts by their text, author and comments', () {
      final List<FeedItem> items = <FeedItem>[
        post('p1', 'Sprzedam rower'),
        post('p2', 'Zgubiłem klucze'),
        post(
          'p3',
          'Kto idzie?',
          comments: const <FeedComment>[
            FeedComment(
              id: 'c',
              authorLabel: 'Bob',
              text: 'Żółw też',
              millis: 2,
            ),
          ],
        ),
      ];
      List<String> ids(String q) => <String>[
        for (final FeedItem i in searchFeed(items, SearchQuery.parse(q))) i.id,
      ];
      expect(ids('ROWER'), <String>['p1']);
      expect(ids('zgubilem'), <String>['p2']);
      expect(ids('zolw'), <String>['p3']);
      expect(ids('ada'), <String>['p1', 'p2', 'p3']);
      expect(ids(''), <String>['p1', 'p2', 'p3']);
    });
  });
}
