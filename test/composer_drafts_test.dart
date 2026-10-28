import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/presentation/comment_composer.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/runtime_deep_link_bridge.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/shell/composer_drafts.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/presentation/mention_field.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// What was written and not sent stays: per conversation, per post's
/// comments and for the new post, after the screen is closed and after the
/// app is, in the account's store; it goes once sent.

const String _ada = 'ada.ygg';
const String _bob = 'bob.ygg';
const String _groupId = 'grp-1';

/// No link opens the app.
final class _NoLinks implements DeepLinkSource {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get linkStream => const Stream<Uri>.empty();
}

/// Lets the disk's writes and reads finish.
Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Long enough for a draft to be written (a moment after the last key).
Future<void> _rest(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(_settle);
}

SocialHubState _social() => SocialHubState.empty().copyWith(
  friends: const <String, FriendProfile>{
    _ada: FriendProfile(
      address: _ada,
      displayName: 'Ada',
      status: FriendRelationshipStatus.accepted,
    ),
    _bob: FriendProfile(
      address: _bob,
      displayName: 'Bob',
      status: FriendRelationshipStatus.accepted,
    ),
  },
  groups: const <String, GroupProfile>{
    _groupId: GroupProfile(
      id: _groupId,
      name: 'Gildia Zen',
      createdById: 'self',
      createdAtMillis: 1000,
      memberAddresses: <String>[_ada],
    ),
  },
);

MemoryMessageTimelineStore _timeline() =>
    MemoryMessageTimelineStore(<String, List<ChatMessage>>{
      _ada: const <ChatMessage>[
        ChatMessage(
          id: 'm1',
          sender: _ada,
          text: 'Cześć!',
          sentAtMillis: 1700000000000,
          direction: ChatMessageDirection.incoming,
        ),
      ],
    });

/// One screen in its own app run: [disk] is the account's store, kept
/// between runs.
Future<void> _run(
  WidgetTester tester,
  LedgerDisk disk,
  Widget screen, {
  MemoryMessageTimelineStore? timeline,
  Size screenSize = const Size(360, 780),
}) async {
  tester.view.physicalSize = screenSize * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      // A new run: nothing of the last one is kept in memory.
      key: UniqueKey(),
      overrides: [
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(_social()),
        messageTimelineStoreProvider.overrideWithValue(timeline ?? _timeline()),
        ledgerDiskProvider.overrideWithValue(disk),
      ],
      child: MaterialApp(home: screen),
    ),
  );
  await tester.runAsync(_settle);
  await tester.pump(const Duration(milliseconds: 300));
}

/// The app is closed: the tree goes, the account's store stays.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.runAsync(_settle);
}

String _field(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.byKey(key)).controller!.text;

const Key _chatField = Key('conversation-composer-field');

/// The post editor's toolbar wants a wider screen with the test font.
const Size _wide = Size(500, 1400);
const Key _groupField = Key('group-chat-composer-field');

void main() {
  group('ComposerDrafts', () {
    test('a draft is read back by the next run of the app', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ComposerDrafts first = ComposerDrafts(disk);
      await first.load();
      first.put(
        ComposerDrafts.peerChat(_ada),
        const ComposerDraft(text: 'Do jutra'),
      );
      first.put(
        ComposerDrafts.newPost,
        ComposerDraft(
          text: 'Post o <@0>',
          mentions: const <Mention>[Mention(address: _ada, name: 'Ada')],
          audience: Audience.close.name,
        ),
      );
      await first.flush();
      expect(disk.files.keys, contains(ComposerDrafts.key));

      final ComposerDrafts next = ComposerDrafts(disk);
      expect(next[ComposerDrafts.peerChat(_ada)], isNull);
      await next.load();
      expect(next[ComposerDrafts.peerChat(_ada)]!.text, 'Do jutra');
      final ComposerDraft post = next[ComposerDrafts.newPost]!;
      expect(post.text, 'Post o <@0>');
      expect(post.mentions.single.address, _ada);
      expect(post.audience, Audience.close.name);
      expect(next[ComposerDrafts.peerChat(_bob)], isNull);
    });

    test('an emptied draft goes from the store at once', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ComposerDrafts drafts = ComposerDrafts(disk);
      await drafts.load();
      drafts
        ..put(ComposerDrafts.peerChat(_ada), const ComposerDraft(text: 'A'))
        ..put(ComposerDrafts.peerChat(_bob), const ComposerDraft(text: 'B'));
      await drafts.flush();
      drafts.clear(ComposerDrafts.peerChat(_ada));
      await Future<void>.delayed(Duration.zero);

      final ComposerDrafts next = ComposerDrafts(disk);
      await next.load();
      expect(next[ComposerDrafts.peerChat(_ada)], isNull);
      expect(next[ComposerDrafts.peerChat(_bob)]!.text, 'B');

      next.clear(ComposerDrafts.peerChat(_bob));
      await next.flush();
      expect(disk.files.containsKey(ComposerDrafts.key), isFalse);
    });

    test('what is typed before the store is read wins over it', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ComposerDrafts first = ComposerDrafts(disk);
      first
        ..put(ComposerDrafts.peerChat(_ada), const ComposerDraft(text: 'stare'))
        ..put(ComposerDrafts.peerChat(_bob), const ComposerDraft(text: 'Bob'));
      await first.flush();

      final ComposerDrafts next = ComposerDrafts(disk);
      next.put(
        ComposerDrafts.peerChat(_ada),
        const ComposerDraft(text: 'nowe'),
      );
      await next.load();
      expect(next[ComposerDrafts.peerChat(_ada)]!.text, 'nowe');
      expect(next[ComposerDrafts.peerChat(_bob)]!.text, 'Bob');
    });

    test('a wipe forgets them and nothing is written back', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ComposerDrafts drafts = ComposerDrafts(disk);
      await drafts.load();
      drafts.put(
        ComposerDrafts.peerChat(_ada),
        const ComposerDraft(text: 'tajne'),
      );
      drafts.forget();
      drafts.put(
        ComposerDrafts.peerChat(_bob),
        const ComposerDraft(text: 'też'),
      );
      await drafts.flush();
      drafts.dispose();
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(disk.files, isEmpty);
      expect(drafts[ComposerDrafts.peerChat(_ada)], isNull);
    });

    test('long texts and many drafts are kept within bounds', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ComposerDrafts drafts = ComposerDrafts(disk);
      await drafts.load();
      for (int i = 0; i < ComposerDrafts.maxDrafts + 5; i++) {
        drafts.put(ComposerDrafts.comment('p$i'), ComposerDraft(text: '$i'));
      }
      drafts.put(
        ComposerDrafts.newPost,
        ComposerDraft(text: 'x' * (ComposerDrafts.maxChars + 10)),
      );
      await drafts.flush();
      final Map<String, dynamic> stored =
          jsonDecode(utf8.decode(disk.files[ComposerDrafts.key]!))
              as Map<String, dynamic>;
      final Map<String, dynamic> kept =
          stored['drafts'] as Map<String, dynamic>;
      expect(kept.length, ComposerDrafts.maxDrafts);
      // The oldest went first.
      expect(kept.containsKey(ComposerDrafts.comment('p0')), isFalse);
      expect(
        (kept[ComposerDrafts.newPost] as Map<String, dynamic>)['t'],
        hasLength(ComposerDrafts.maxChars),
      );
    });

    test('a store that is not one is no drafts', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk()
        ..files[ComposerDrafts.key] = Uint8List.fromList(utf8.encode('{x'));
      final ComposerDrafts drafts = ComposerDrafts(disk);
      await drafts.load();
      expect(drafts.isLoaded, isTrue);
      expect(drafts[ComposerDrafts.newPost], isNull);
    });
  });

  group('a conversation', () {
    testWidgets('keeps its unsent message when closed and after a restart, '
        'each conversation its own', (WidgetTester tester) async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await _run(
        tester,
        disk,
        const ConversationScreen(peerAddress: _ada, title: 'Ada'),
      );
      await tester.enterText(find.byKey(_chatField), 'Zaraz będę');
      await _rest(tester);
      await _close(tester);
      // In the account's store (encrypted in the app), nowhere else.
      expect(disk.files.keys, <String>[ComposerDrafts.key]);

      await _run(
        tester,
        disk,
        const ConversationScreen(peerAddress: _ada, title: 'Ada'),
      );
      expect(_field(tester, _chatField), 'Zaraz będę');
      await _close(tester);

      // Bob's conversation has a field of its own.
      await _run(
        tester,
        disk,
        const ConversationScreen(peerAddress: _bob, title: 'Bob'),
      );
      expect(_field(tester, _chatField), isEmpty);
      await tester.enterText(find.byKey(_chatField), 'Hej Bob');
      await _rest(tester);
      await _close(tester);

      await _run(
        tester,
        disk,
        const ConversationScreen(peerAddress: _ada, title: 'Ada'),
      );
      expect(_field(tester, _chatField), 'Zaraz będę');
      await _close(tester);
    });

    testWidgets('a sent message leaves no draft', (WidgetTester tester) async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final MemoryMessageTimelineStore timeline = _timeline();
      await _run(
        tester,
        disk,
        const ConversationScreen(peerAddress: _ada, title: 'Ada'),
        timeline: timeline,
      );
      await tester.enterText(find.byKey(_chatField), 'Już wysyłam');
      await _rest(tester);
      await tester.tap(find.byKey(const Key('conversation-send-button')));
      await tester.pump();
      await tester.runAsync(_settle);
      await tester.pumpAndSettle();
      expect(_field(tester, _chatField), isEmpty);
      await _close(tester);

      await _run(
        tester,
        disk,
        const ConversationScreen(peerAddress: _ada, title: 'Ada'),
        timeline: timeline,
      );
      expect(_field(tester, _chatField), isEmpty);
      expect(find.text('Już wysyłam'), findsOneWidget);
      await _close(tester);
    });

    testWidgets('a group keeps its unsent message with its mention', (
      WidgetTester tester,
    ) async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await _run(
        tester,
        disk,
        const GroupConversationScreen(
          groupId: _groupId,
          groupName: 'Gildia Zen',
        ),
      );
      final TextField field = tester.widget<TextField>(find.byKey(_groupField));
      final ComposerDrafts drafts = ProviderScope.containerOf(
        tester.element(find.byKey(_groupField)),
      ).read(composerDraftsProvider);
      // A mention picked from the suggestions.
      (field.controller! as MentionTextController).setStoredText(
        'Spotkanie z <@0> o 18',
        const <Mention>[Mention(address: _ada, name: 'Ada')],
      );
      await _rest(tester);
      expect(
        drafts[ComposerDrafts.groupChat(_groupId)]!.mentions.single.address,
        _ada,
      );
      await _close(tester);

      await _run(
        tester,
        disk,
        const GroupConversationScreen(
          groupId: _groupId,
          groupName: 'Gildia Zen',
        ),
      );
      expect(_field(tester, _groupField), 'Spotkanie z @Ada o 18');
      await _close(tester);
    });
  });

  testWidgets('the app opened again shows the same conversation with the '
      'unsent message in it', (WidgetTester tester) async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    Future<void> launch() async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          key: UniqueKey(),
          overrides: [
            deepLinkSourceProvider.overrideWithValue(_NoLinks()),
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(_social()),
            messageTimelineStoreProvider.overrideWithValue(_timeline()),
            signalTransportProvider.overrideWithValue(MemorySignalTransport()),
            ledgerNodeEnabledProvider.overrideWithValue(true),
            ledgerDiskProvider.overrideWithValue(disk),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.runAsync(_settle);
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await launch();
    await tester.tap(find.byKey(const Key('conversation-card-$_ada')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.enterText(find.byKey(_chatField), 'Dokończę później');
    // The app goes away (and may be killed) before the delay is over.
    await tester.pump(const Duration(milliseconds: 50));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(_settle);
    await _close(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await launch();
    expect(find.byType(ConversationScreen), findsOneWidget);
    expect(_field(tester, _chatField), 'Dokończę później');
    await _close(tester);
  });

  group('comments', () {
    Widget composer({required String postId, CommentSend? onSend}) => Scaffold(
      body: CommentComposer(
        fieldKey: const Key('comment-field'),
        sendKey: const Key('comment-send'),
        draftKey: ComposerDrafts.comment(postId),
        onSend: onSend ?? (String text, List<CommentPicture> p) async => null,
      ),
    );

    testWidgets('an unsent comment stays with its post, and goes once sent', (
      WidgetTester tester,
    ) async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await _run(tester, disk, composer(postId: 'post-1'));
      await tester.enterText(
        find.byKey(const Key('comment-field')),
        'Świetne zdjęcie',
      );
      await _rest(tester);
      await _close(tester);

      await _run(tester, disk, composer(postId: 'post-2'));
      expect(_field(tester, const Key('comment-field')), isEmpty);
      await _close(tester);

      String? sent;
      await _run(
        tester,
        disk,
        composer(
          postId: 'post-1',
          onSend: (String text, List<CommentPicture> p) async {
            sent = text;
            return null;
          },
        ),
      );
      expect(_field(tester, const Key('comment-field')), 'Świetne zdjęcie');
      await tester.tap(find.byKey(const Key('comment-send')));
      await tester.pump();
      await tester.runAsync(_settle);
      expect(sent, 'Świetne zdjęcie');
      expect(_field(tester, const Key('comment-field')), isEmpty);
      await _close(tester);

      await _run(tester, disk, composer(postId: 'post-1'));
      expect(_field(tester, const Key('comment-field')), isEmpty);
      await _close(tester);
    });
  });

  group('a new post', () {
    testWidgets('its text and audience are kept, and go once published', (
      WidgetTester tester,
    ) async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ComposerDrafts drafts = ComposerDrafts(disk);
      await tester.runAsync(drafts.load);
      PostDraft? published;
      Widget editor(ComposerDraft? draft) => PostEditorScreen(
        drafts: drafts,
        initialText: draft?.text ?? '',
        initialMentions: draft?.mentions ?? const <Mention>[],
        initialAudience:
            Audience.values.asNameMap()[draft?.audience] ?? Audience.public,
        onSubmit: (PostDraft d) async {
          published = d;
          return null;
        },
      );
      await _run(tester, disk, editor(null), screenSize: _wide);
      await tester.enterText(find.byKey(const Key('post-text')), 'Mój post');
      await tester.pump();
      await tester.tap(find.byKey(const Key('post-audience')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-audience-close')));
      await tester.pumpAndSettle();
      // Closed with something written: kept as a draft.
      await tester.tap(find.byKey(const Key('post-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-keep-draft')));
      await tester.pumpAndSettle();
      await tester.runAsync(drafts.flush);
      await _close(tester);

      // The next run of the app reads it back.
      final ComposerDrafts next = ComposerDrafts(disk);
      await tester.runAsync(next.load);
      final ComposerDraft? kept = next[ComposerDrafts.newPost];
      expect(kept!.text, 'Mój post');
      expect(kept.audience, Audience.close.name);

      await _run(tester, disk, editor(kept), screenSize: _wide);
      expect(find.text('Mój post'), findsOneWidget);
      await tester.tap(find.byKey(const Key('post-publish')));
      await tester.pumpAndSettle();
      expect(published!.text, 'Mój post');
      expect(published!.audience, Audience.close);
      await tester.runAsync(drafts.flush);
      expect(drafts[ComposerDrafts.newPost], isNull);
      await _close(tester);
    });

    testWidgets('a draft dropped on closing is gone', (
      WidgetTester tester,
    ) async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final ComposerDrafts drafts = ComposerDrafts(disk);
      await tester.runAsync(drafts.load);
      await _run(
        tester,
        disk,
        PostEditorScreen(drafts: drafts, onSubmit: (PostDraft d) async => null),
        screenSize: _wide,
      );
      await tester.enterText(find.byKey(const Key('post-text')), 'Nie wyślę');
      await tester.pump();
      expect(drafts[ComposerDrafts.newPost]!.text, 'Nie wyślę');
      await tester.tap(find.byKey(const Key('post-close')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('post-discard')));
      await tester.pumpAndSettle();
      expect(drafts[ComposerDrafts.newPost], isNull);
      await _close(tester);
    });
  });
}
