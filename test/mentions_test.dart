import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/rich_text.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/presentation/mention_field.dart';

// Mentions as text: tokens and the list next to them, what an edit does to
// them, the word typed after "@", who a group chat offers, and what is
// shown of them.

const Mention _ada = Mention(address: '200::A', account: 'acc-a', name: 'Ada');
const Mention _bob = Mention(address: '200::B', name: 'Bob Nowak');

void main() {
  group('stored mentions', () {
    test('a text keeps tokens and the list, not the names', () {
      const String display = 'Hej @Ada i @Bob Nowak, i znowu @Ada!';
      final ({String text, List<Mention> mentions}) stored =
          encodeMentions(display, const <MentionSpan>[
            MentionSpan(start: 4, end: 8, mention: _ada),
            MentionSpan(start: 11, end: 21, mention: _bob),
            MentionSpan(start: 31, end: 35, mention: _ada),
          ]);
      expect(stored.text, 'Hej <@0> i <@1>, i znowu <@0>!');
      expect(stored.mentions, <Mention>[_ada, _bob]);
      // Back for editing, with the names of the moment.
      final ({String text, List<MentionSpan> spans}) shown = decodeMentions(
        stored.text,
        stored.mentions,
        nameOf: (Mention m) => m == _ada ? 'Ada Kowalska' : '',
      );
      expect(
        shown.text,
        'Hej @Ada Kowalska i @Bob Nowak, i znowu @Ada Kowalska!',
      );
      expect(shown.spans, hasLength(3));
      expect(shown.spans.first.mention, _ada);
    });

    test('a new name changes what is shown, never whom it means', () {
      const String text = 'Brawo <@0>';
      expect(mentionsAsPlainText(text, const <Mention>[_ada]), 'Brawo @Ada');
      expect(
        mentionsAsPlainText(text, const <Mention>[
          _ada,
        ], nameOf: (Mention m) => 'Adusia'),
        'Brawo @Adusia',
      );
      // A token pointing nowhere is shown as written.
      expect(
        mentionsAsPlainText('<@3> hej', const <Mention>[_ada]),
        '<@3> hej',
      );
    });

    test('an edit keeps the places of the people already mentioned', () {
      const String display = 'Teraz tylko @Bob Nowak';
      final ({String text, List<Mention> mentions}) stored = encodeMentions(
        display,
        const <MentionSpan>[MentionSpan(start: 12, end: 22, mention: _bob)],
        keep: const <Mention>[_ada, _bob],
      );
      expect(stored.text, 'Teraz tylko <@1>');
      expect(stored.mentions, <Mention>[_ada, _bob]);
    });

    test('only the people the text names count, and only so many', () {
      expect(usedMentions('<@1>', const <Mention>[_ada, _bob]), <Mention>[
        _bob,
      ]);
      expect(
        mentionsAnyOf(
          '<@1>',
          const <Mention>[_ada, _bob],
          addresses: <String>['200::A'],
        ),
        isFalse,
      );
      expect(
        mentionsAnyOf('<@0>', const <Mention>[_ada, _bob], account: 'acc-a'),
        isTrue,
      );
      final List<Map<String, dynamic>> many = <Map<String, dynamic>>[
        for (int i = 0; i < kMaxMentions + 5; i++)
          Mention(
            address: '200::${(i + 1).toRadixString(16)}',
            name: 'P$i',
          ).toJson(),
      ];
      expect(mentionsFromJson(many), hasLength(kMaxMentions));
      expect(
        mentionsFromJson(<Object?>[
          <String, dynamic>{'n': 'x'},
          7,
        ]),
        isEmpty,
      );
    });

    test('a post and a comment carry only what their text names', () {
      final Map<String, dynamic> post = newPostBody(
        'Hej <@1>',
        mentions: const <Mention>[_ada, _bob],
      );
      expect(mentionsFromJson(post[kMentionsKey]), <Mention>[_ada, _bob]);
      final Map<String, dynamic> plain = newPostBody(
        'Bez nikogo',
        mentions: const <Mention>[_ada],
      );
      expect(plain.containsKey(kMentionsKey), isFalse);
      final Map<String, dynamic> comment = commentBody(
        'post-1',
        '  <@0> patrz  ',
        mentions: const <Mention>[_ada],
      );
      expect(comment['text'], '<@0> patrz');
      expect(mentionsFromJson(comment[kMentionsKey]), <Mention>[_ada]);
    });
  });

  group('writing', () {
    test('mentions move with edits around them and go when edited inside', () {
      const List<MentionSpan> spans = <MentionSpan>[
        MentionSpan(start: 4, end: 8, mention: _ada),
      ];
      // Typed in front: it moves.
      expect(
        shiftMentionSpans('Hej @Ada', 'Oj, Hej @Ada', spans).single.start,
        8,
      );
      // Typed after: it stays.
      expect(
        shiftMentionSpans('Hej @Ada', 'Hej @Ada!', spans).single,
        spans.single,
      );
      // Typed inside: plain text now.
      expect(shiftMentionSpans('Hej @Ada', 'Hej @Adam', spans), hasLength(1));
      expect(shiftMentionSpans('Hej @Ada', 'Hej @Aa', spans), isEmpty);
      expect(shiftMentionSpans('Hej @Ada', '', spans), isEmpty);
    });

    test('the word after "@" at the cursor is what is looked for', () {
      expect(mentionQueryAt('Hej @Ad', 7), (start: 4, query: 'Ad'));
      expect(mentionQueryAt('@', 1), (start: 0, query: ''));
      expect(mentionQueryAt('mail@example', 12), isNull);
      expect(mentionQueryAt('Hej @Ada kot', 12), isNull);
      expect(mentionQueryAt('(@Bo', 4), (start: 1, query: 'Bo'));
    });

    test('suggestions match the start of a name or of its words', () {
      const List<MentionCandidate> all = <MentionCandidate>[
        MentionCandidate(mention: _ada, reach: MentionReach.friend),
        MentionCandidate(mention: _bob, reach: MentionReach.friend),
        MentionCandidate(
          mention: Mention(address: '200::C', name: 'Łucja'),
          reach: MentionReach.friendOfFriend,
        ),
      ];
      expect(suggestMentions(all, 'no').single.mention, _bob);
      expect(suggestMentions(all, 'luc').single.mention.name, 'Łucja');
      expect(suggestMentions(all, ''), hasLength(3));
      expect(suggestMentions(all, '', limit: 2), hasLength(2));
      expect(suggestMentions(all, 'x'), isEmpty);
    });
  });

  group('a group chat', () {
    test('offers its members only, never this device', () {
      const GroupProfile group = GroupProfile(
        id: 'g',
        name: 'Ekipa',
        createdById: '200::A',
        createdAtMillis: 0,
        memberAddresses: <String>['200::A', '200::B', '200::5E1F'],
      );
      final List<MentionCandidate> offered = groupMentionCandidates(
        group,
        selfAddress: '200::5E1F',
        nameOf: (String a) => a == '200::A' ? 'Ada' : 'Bob',
      );
      expect(offered.map((MentionCandidate c) => c.mention.address), <String>[
        '200::A',
        '200::B',
      ]);
      expect(
        offered.every((MentionCandidate c) => c.reach == MentionReach.member),
        isTrue,
      );
    });

    test('a message keeps its mentions, as stored and as received', () {
      const ChatMessage m = ChatMessage(
        id: 'm',
        sender: 'self',
        text: 'Hej <@0>',
        sentAtMillis: 1,
        direction: ChatMessageDirection.outgoing,
        mentions: <Mention>[_bob],
      );
      final ChatMessage back = chatMessageWithExtras(
        m.copyWith(mentions: const <Mention>[]),
        chatMessageExtrasToJson(m),
      );
      expect(back.mentions, <Mention>[_bob]);
      expect(back.plainText, 'Hej @Bob Nowak');

      final ZenSignal? signal = zenSignalFromTransportPayload(
        sender: '200::A',
        payload: <String, dynamic>{
          'type': 'group_message',
          'groupId': 'g',
          'msgId': 'x',
          'text': 'Hej <@0>',
          kMentionsKey: <Object?>[_bob.toJson()],
          // What only this device may set never comes over the wire.
          kMentionsYouKey: true,
        },
      );
      expect(signalMentions(signal!), <Mention>[_bob]);
      expect(signalMentionsYou(signal), isFalse);
      expect(signalNoticePreview(signal), 'Hej @Bob Nowak');
    });

    test('the route of a mention opens the chat at the message', () {
      final String key = buildGroupRouteKey(
        groupId: 'g',
        title: 'Ekipa',
        messageId: 'msg-1',
      );
      final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
        id: 'n',
        routeKey: key,
      );
      expect(intent?.groupId, 'g');
      expect(intent?.messageId, 'msg-1');
    });
  });

  group('what is shown', () {
    test('a token in a post is a mention run; previews show the name', () {
      final List<RichRun> runs = visibleRuns('**Hej** <@0>, https://a.pl');
      final RichRun mention = runs.firstWhere((RichRun r) => r.isMention);
      expect(mention.mention, 0);
      expect(runs.where((RichRun r) => r.link), hasLength(1));
      expect(
        plainText('**Hej** <@0>', mentions: const <Mention>[_ada]),
        'Hej @Ada',
      );
    });

    test('the notice of a mention at each privacy level', () {
      NoticeText n = mentionNoticeText(
        level: NotificationPrivacy.senderAndContent,
        sender: 'Ada',
        preview: 'Hej @Bob',
      );
      expect(n.title, 'Ada wspomniał(a) o Tobie');
      expect(n.body, 'Hej @Bob');
      n = mentionNoticeText(
        level: NotificationPrivacy.senderAndContent,
        sender: 'Ada',
        group: 'Ekipa',
        preview: 'Hej @Bob',
      );
      expect(n.title, 'Ekipa');
      expect(n.body, 'Ada wspomniał(a) o Tobie: Hej @Bob');
      n = mentionNoticeText(
        level: NotificationPrivacy.senderOnly,
        sender: 'Ada',
        group: 'Ekipa',
        preview: 'Hej @Bob',
      );
      expect(n.body, 'Ada wspomniał(a) o Tobie');
      n = mentionNoticeText(
        level: NotificationPrivacy.senderOnly,
        sender: 'Ada',
        preview: 'Hej @Bob',
      );
      expect('${n.title} ${n.body}', isNot(contains('Hej')));
      n = mentionNoticeText(
        level: NotificationPrivacy.generic,
        sender: 'Ada',
        preview: 'Hej @Bob',
      );
      expect(n.title, 'Ktoś wspomniał o Tobie');
      expect('${n.title} ${n.body}', isNot(contains('Ada')));
      n = mentionNoticeText(
        level: NotificationPrivacy.generic,
        sender: 'Ada',
        group: 'Ekipa',
        preview: 'Hej @Bob',
      );
      expect(n.title, 'Nowa wiadomość');
      expect('${n.title} ${n.body}', isNot(contains('Ekipa')));
    });
  });

  group('the field and the text', () {
    testWidgets('"@" offers the allowed people; a tap puts in a mention', (
      WidgetTester tester,
    ) async {
      final MentionTextController field = MentionTextController();
      addTearDown(field.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  MentionSuggestions(
                    controller: field,
                    candidates: () => const <MentionCandidate>[
                      MentionCandidate(
                        mention: _ada,
                        reach: MentionReach.member,
                      ),
                      MentionCandidate(
                        mention: _bob,
                        reach: MentionReach.member,
                      ),
                    ],
                  ),
                  TextField(key: const Key('f'), controller: field),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('mention-suggestions')), findsNothing);
      await tester.enterText(find.byKey(const Key('f')), 'Cześć @no');
      await tester.pump();
      expect(find.byKey(const Key('mention-suggestions')), findsOneWidget);
      expect(find.byKey(const Key('mention-suggestion-200::A')), findsNothing);
      await tester.tap(find.byKey(const Key('mention-suggestion-200::B')));
      await tester.pump();
      expect(field.text, 'Cześć @Bob Nowak ');
      expect(find.byKey(const Key('mention-suggestions')), findsNothing);
      final ({String text, List<Mention> mentions}) stored = field.storedText();
      expect(stored.text, 'Cześć <@0> ');
      expect(stored.mentions, <Mention>[_bob]);
    });

    testWidgets('a mention shows as a name; a copy has the name too', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: CopyableText(
                'Hej <@0>!',
                mentions: <Mention>[_ada],
                style: TextStyle(),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Hej @Ada!', findRichText: true), findsOneWidget);
      expect(find.textContaining('<@0>', findRichText: true), findsNothing);
    });
  });
}
