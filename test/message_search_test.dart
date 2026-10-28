import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/background_work.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/search/chat_search_controller.dart';
import 'package:zen/src/features/search/global_message_search.dart';
import 'package:zen/src/features/search/message_search.dart';
import 'package:zen/src/features/search/search_text.dart';

/// Search through one conversation (moving between matches) and through
/// all of them (grouped by conversation, newest first), and how long it
/// takes with 50 000 messages.

ChatMessage _m(String id, String text, int at, {String sender = 'ada.ygg'}) =>
    ChatMessage(
      id: id,
      sender: sender,
      text: text,
      sentAtMillis: at,
      direction: sender == 'self'
          ? ChatMessageDirection.outgoing
          : ChatMessageDirection.incoming,
    );

const List<String> _words = <String>[
  'dzień dobry',
  'co słychać',
  'idziemy jutro do kina',
  'kupiłem chleb i mleko',
  'zadzwonię wieczorem',
  'świetny pomysł',
  'gdzie są klucze',
  'pogoda dziś piękna',
  'wyślij mi zdjęcie',
  'dobranoc',
];

/// [count] messages, every [every]-th of them about a tortoise.
List<ChatMessage> _history(int count, {String prefix = 'm', int every = 0}) =>
    <ChatMessage>[
      for (int i = 0; i < count; i++)
        _m(
          '$prefix-$i',
          every > 0 && i % every == 0
              ? 'Wiadomość $i: mój ŻÓŁW znowu uciekł z ogródka'
              : 'Wiadomość $i: ${_words[i % _words.length]}',
          1000000 + i * 1000,
          sender: i.isEven ? 'self' : 'ada.ygg',
        ),
    ];

Future<void> _settle(ChatSearchController c) async {
  for (int i = 0; i < 20 && (c.busy || c.total == 0); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('in one conversation', () {
    test('counts from the newest match and moves both ways', () async {
      final ChatSearchController c = ChatSearchController(
        debounce: Duration.zero,
      );
      addTearDown(c.dispose);
      c.updateThread(<ChatMessage>[
        _m('a', 'Jutro kino', 1),
        _m('b', 'nic', 2),
        _m('c', 'KINO dziś?', 3),
        _m('d', 'kino jutro o 18', 4),
      ]);
      c.open(text: 'kino');
      await _settle(c);
      expect(c.total, 3);
      expect(c.position, 1);
      expect(c.currentId, 'd');
      expect(c.matchIds, <String>['a', 'c', 'd']);
      expect(c.isMatch('b'), isFalse);
      final int jumps = c.jumps;
      c.older();
      expect(c.currentId, 'c');
      expect(c.position, 2);
      expect(c.jumps, jumps + 1);
      c.older();
      expect(c.currentId, 'a');
      c.older();
      // Past the oldest: back to the newest.
      expect(c.currentId, 'd');
      c.newer();
      expect(c.currentId, 'a');
    });

    test('more words narrow it down; one letter is not searched', () async {
      final ChatSearchController c = ChatSearchController(
        debounce: Duration.zero,
      );
      addTearDown(c.dispose);
      c.updateThread(<ChatMessage>[
        _m('a', 'Jutro kino', 1),
        _m('c', 'KINO dziś?', 3),
      ]);
      c.open();
      c.setText('kino jutro');
      await _settle(c);
      expect(c.matchIds, <String>['a']);
      c.setText('k');
      expect(c.total, 0);
      expect(c.query.searchesMessages, isFalse);
    });

    test('opened at a message, it stands there', () async {
      final ChatSearchController c = ChatSearchController(
        debounce: Duration.zero,
      );
      addTearDown(c.dispose);
      c.updateThread(<ChatMessage>[
        _m('a', 'żółw', 1),
        _m('b', 'żółw', 2),
        _m('c', 'żółw', 3),
      ]);
      c.open(text: 'zolw', at: 'b');
      await _settle(c);
      expect(c.currentId, 'b');
      expect(c.position, 2);
    });

    test('a new message keeps the one shown', () async {
      final ChatSearchController c = ChatSearchController(
        debounce: Duration.zero,
      );
      addTearDown(c.dispose);
      final List<ChatMessage> thread = <ChatMessage>[
        _m('a', 'żółw', 1),
        _m('b', 'żółw', 2),
      ];
      c.updateThread(thread);
      c.open(text: 'zolw');
      await _settle(c);
      c.older();
      expect(c.currentId, 'a');
      c.updateThread(<ChatMessage>[...thread, _m('c', 'też żółw', 3)]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.total, 3);
      expect(c.currentId, 'a');
      expect(c.position, 3);
    });

    test('hidden and deleted messages are not found', () async {
      final ChatSearchController c = ChatSearchController(
        debounce: Duration.zero,
      );
      addTearDown(c.dispose);
      c.updateThread(
        <ChatMessage>[
          _m('a', 'żółw', 1),
          _m('b', 'żółw', 2),
          _m('c', 'żółw', 3).copyWith(deletedAtMillis: 4),
        ],
        hidden: (ChatMessage m) => m.id == 'b',
        hiddenVersion: 1,
      );
      c.open(text: 'zolw');
      await _settle(c);
      expect(c.matchIds, <String>['a']);
    });

    test('closing forgets what was found', () async {
      final ChatSearchController c = ChatSearchController(
        debounce: Duration.zero,
      );
      addTearDown(c.dispose);
      c.updateThread(<ChatMessage>[_m('a', 'żółw', 1)]);
      c.open(text: 'zolw');
      await _settle(c);
      expect(c.total, 1);
      c.close();
      expect(c.active, isFalse);
      expect(c.total, 0);
      expect(c.text, '');
    });
  });

  group('in every conversation', () {
    late MemoryMessageTimelineStore store;

    setUp(() {
      store = MemoryMessageTimelineStore(<String, List<ChatMessage>>{
        'ada.ygg': <ChatMessage>[
          _m('a1', 'Mój żółw śpi', 100),
          _m('a2', 'Nic ciekawego', 200),
          _m('a3', 'ŻÓŁW się obudził', 900),
        ],
        'bob.ygg': <ChatMessage>[
          _m('b1', 'Kupiłem zolwia', 500, sender: 'bob.ygg'),
          _m('b2', 'zółw raz', 510, sender: 'bob.ygg'),
          _m('b3', 'żółw dwa', 520, sender: 'bob.ygg'),
          _m('b4', 'żółw trzy', 530, sender: 'bob.ygg'),
        ],
        'group:g1': <ChatMessage>[
          _m('g1', 'W grupie o żółwiach', 700, sender: 'cyd.ygg'),
        ],
        'eve.ygg': <ChatMessage>[_m('e1', 'Bez zwierząt', 950)],
      });
    });

    const List<SearchConversation> conversations = <SearchConversation>[
      SearchConversation.peer(address: 'ada.ygg', title: 'Ada'),
      SearchConversation.peer(address: 'bob.ygg', title: 'Bob'),
      SearchConversation.group(groupId: 'g1', title: 'Ekipa'),
      SearchConversation.peer(address: 'eve.ygg', title: 'Ewa'),
    ];

    test('grouped by conversation, the newest match first', () async {
      final GlobalMessageSearch search = GlobalMessageSearch(store: store);
      addTearDown(search.dispose);
      await search.load(conversations);
      final List<GlobalSearchGroup> groups = search.search(
        SearchQuery.parse('zolw'),
      );
      expect(
        <String>[
          for (final GlobalSearchGroup g in groups) g.conversation.title,
        ],
        <String>['Ada', 'Ekipa', 'Bob'],
      );
      // Ada: the newest first.
      expect(
        <String>[for (final GlobalSearchHit h in groups[0].hits) h.messageId],
        <String>['a3', 'a1'],
      );
      // Bob: four matches, three listed, the newest.
      expect(groups[2].total, 4);
      expect(
        <String>[for (final GlobalSearchHit h in groups[2].hits) h.messageId],
        <String>['b4', 'b3', 'b2'],
      );
      // The group's key in the store.
      expect(groups[1].conversation.storeKey, 'group:g1');
      // The snippet marks the word as written.
      final GlobalSearchHit hit = groups[0].hits.first;
      expect(
        hit.snippet.substring(hit.ranges.first.start, hit.ranges.first.end),
        'ŻÓŁW',
      );
    });

    test('nothing for a query too short, nothing hidden', () async {
      final GlobalMessageSearch search = GlobalMessageSearch(
        store: store,
        hidden: (ChatMessage m) => m.id == 'g1',
      );
      addTearDown(search.dispose);
      await search.load(conversations);
      expect(search.search(SearchQuery.parse('z')), isEmpty);
      expect(<String>[
        for (final GlobalSearchGroup g in search.search(
          SearchQuery.parse('żółwiach'),
        ))
          g.conversation.title,
      ], isEmpty);
    });

    test('results stop at the cap', () async {
      final GlobalMessageSearch search = GlobalMessageSearch(store: store);
      addTearDown(search.dispose);
      await search.load(conversations);
      final List<GlobalSearchGroup> groups = search.search(
        SearchQuery.parse('zolw'),
        maxHits: 3,
      );
      int listed = 0;
      for (final GlobalSearchGroup g in groups) {
        listed += g.hits.length;
      }
      expect(listed, 3);
    });

    test('reading shows progress and can be stopped', () async {
      final GlobalMessageSearch search = GlobalMessageSearch(store: store);
      final List<double> progress = <double>[];
      await search.load(
        conversations,
        onProgress: () {
          progress.add(search.progress);
          if (progress.length == 2) {
            search.dispose();
          }
        },
      );
      expect(progress, <double>[0.25, 0.5]);
      expect(search.search(SearchQuery.parse('zolw')), isEmpty);
    });
  });

  group('50 000 messages', () {
    // Generous bounds for a loaded test machine; on a desktop the work
    // takes a fraction of them.
    const Duration indexBound = Duration(seconds: 4);
    const Duration queryBound = Duration(milliseconds: 400);

    test('one conversation: indexed once, then each search is quick', () async {
      final List<ChatMessage> thread = _history(50000, every: 500);
      final ConversationSearchIndex index = ConversationSearchIndex();
      final Stopwatch build = Stopwatch()..start();
      await index.update(thread);
      build.stop();
      expect(index.length, 50000);
      expect(build.elapsed, lessThan(indexBound));

      final Stopwatch query = Stopwatch()..start();
      final List<int> found = await index.find(SearchQuery.parse('zolw'));
      query.stop();
      expect(found.length, 100);
      expect(query.elapsed, lessThan(queryBound));
      // Newest first.
      expect(index.idAt(found.first), 'm-49500');

      // A new message costs one fold, not 50 000.
      final Stopwatch again = Stopwatch()..start();
      await index.update(<ChatMessage>[
        ...thread,
        _m('new', 'jeszcze jeden żółw', 99999999),
      ]);
      again.stop();
      expect(again.elapsed, lessThan(indexBound));
      expect((await index.find(SearchQuery.parse('zolw'))).length, 101);
    });

    test('a long history is folded in its own isolate', () async {
      debugSetBackgroundWorkEnabled(true);
      addTearDown(() => debugSetBackgroundWorkEnabled(null));
      final List<ChatMessage> thread = _history(50000, every: 1000);
      final ConversationSearchIndex index = ConversationSearchIndex();
      final Stopwatch build = Stopwatch()..start();
      await index.update(thread);
      build.stop();
      expect(build.elapsed, lessThan(indexBound));
      expect((await index.find(SearchQuery.parse('ŻÓŁW'))).length, 50);
    });

    test('the conversation search caps its matches', () async {
      final ChatSearchController c = ChatSearchController(
        debounce: Duration.zero,
      );
      addTearDown(c.dispose);
      c.updateThread(_history(50000));
      final Stopwatch watch = Stopwatch()..start();
      c.open(text: 'wiadomosc');
      for (int i = 0; i < 400 && (c.busy || c.total == 0); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      watch.stop();
      expect(c.total, kChatSearchMaxMatches);
      expect(c.capped, isTrue);
      expect(c.currentId, 'm-49999');
      expect(watch.elapsed, lessThan(indexBound));
    });

    test('every conversation: 50 000 messages in 50 of them', () async {
      final MemoryMessageTimelineStore store =
          MemoryMessageTimelineStore(<String, List<ChatMessage>>{
            for (int c = 0; c < 50; c++)
              'peer$c.ygg': _history(
                1000,
                prefix: 'c$c',
                every: c == 7 ? 100 : 0,
              ),
          });
      final GlobalMessageSearch search = GlobalMessageSearch(store: store);
      addTearDown(search.dispose);
      final Stopwatch load = Stopwatch()..start();
      await search.load(<SearchConversation>[
        for (int c = 0; c < 50; c++)
          SearchConversation.peer(address: 'peer$c.ygg', title: 'P$c'),
      ]);
      load.stop();
      expect(search.messageCount, 50000);
      expect(load.elapsed, lessThan(indexBound));

      final Stopwatch query = Stopwatch()..start();
      final List<GlobalSearchGroup> groups = search.search(
        SearchQuery.parse('zolw ogrodka'),
      );
      query.stop();
      expect(query.elapsed, lessThan(queryBound));
      expect(groups.single.conversation.title, 'P7');
      expect(groups.single.total, 10);

      // A word in every message: the list stops at the cap.
      final Stopwatch broad = Stopwatch()..start();
      final List<GlobalSearchGroup> all = search.search(
        SearchQuery.parse('wiadomosc'),
      );
      broad.stop();
      expect(broad.elapsed, lessThan(queryBound));
      expect(all, hasLength(50));
      expect(all.first.total, 1000);
    });
  });
}
