import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/chat/presentation/jump_to_latest.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// While a finger is on a conversation's list, or a fling it started still
/// runs, nothing but the finger moves it: a message coming in, a receipt,
/// a reaction, an edit, a deletion, a message expiring, a late one going in
/// further up, the typing line, a file arriving, one's own message from
/// another device. A bubble on the screen stays at its pixel through each
/// of these also when the list is left alone scrolled up, and at the newest
/// message a finger resting on the list keeps what it holds (what came in
/// waits below, on the button).

const String _ada = 'ada.ygg';
const String _bob = 'bob.ygg';
const String _groupId = 'grp-touch';
const String _groupKey = 'group:$_groupId';

/// A 1x1 PNG.
final Uint8List _png = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// Messages 40 minutes apart: a new day every 36 of them (a day line).
final int _start = DateTime(2026, 11, 1, 8).millisecondsSinceEpoch;
int _at(int n) => _start + n * 40 * 60 * 1000;

const int _count = 90;

String _textOf(int n) => 'Wiadomość numer $n.';

/// Message [n] of a long mixed conversation: texts short and long, one's
/// own with their ticks, photos, voice messages, files.
ChatMessage _mixed(int n, {required String friend}) {
  final bool outgoing = n % 4 == 1;
  final String sender = outgoing ? 'self' : friend;
  final ChatMessageDirection direction = outgoing
      ? ChatMessageDirection.outgoing
      : ChatMessageDirection.incoming;
  final ChatMessageDeliveryState state = outgoing
      ? ChatMessageDeliveryState.sent
      : ChatMessageDeliveryState.none;
  return switch (n % 11) {
    3 => ChatMessage(
      id: 'm-$n',
      sender: sender,
      text: '',
      sentAtMillis: _at(n),
      direction: direction,
      deliveryState: state,
      type: ChatMessageType.image,
      // Every other photo is still on its way.
      attachmentBytes: n.isEven ? null : _png,
      fileName: 'zdjecie-$n.png',
      mimeType: 'image/png',
      attachmentSizeBytes: _png.length,
    ),
    6 => ChatMessage(
      id: 'm-$n',
      sender: sender,
      text: '',
      sentAtMillis: _at(n),
      direction: direction,
      deliveryState: state,
      type: ChatMessageType.voice,
      attachmentBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      mimeType: 'audio/aac',
      durationMs: 4200,
      attachmentSizeBytes: 4,
    ),
    9 => ChatMessage(
      id: 'm-$n',
      sender: sender,
      text: '',
      sentAtMillis: _at(n),
      direction: direction,
      deliveryState: state,
      type: ChatMessageType.file,
      attachmentBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      fileName: 'plik-$n.pdf',
      mimeType: 'application/pdf',
      attachmentSizeBytes: 4,
    ),
    _ => ChatMessage(
      id: 'm-$n',
      sender: sender,
      text: n % 5 == 0
          ? '${_textOf(n)} ${'Dłuższy tekst w kilku linijkach. ' * 6}'
          : _textOf(n),
      sentAtMillis: _at(n),
      direction: direction,
      deliveryState: state,
    ),
  };
}

ChatMessage _incoming(int n, {required String friend, String? text}) =>
    ChatMessage(
      id: 'm-$n',
      sender: friend,
      text: text ?? _textOf(n),
      sentAtMillis: _at(n),
      direction: ChatMessageDirection.incoming,
    );

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// One of the two screens, with its conversation in a store.
final class _Chat {
  _Chat({required this.group, required this.store});

  final bool group;
  final MemoryMessageTimelineStore store;

  String get key => group ? _groupKey : _ada;
  String get friend => group ? _bob : _ada;
}

Future<_Chat> _open(WidgetTester tester, {required bool group}) async {
  _phone(tester);
  final String friend = group ? _bob : _ada;
  final MemoryMessageTimelineStore store = MemoryMessageTimelineStore(
    <String, List<ChatMessage>>{
      group ? _groupKey : _ada: <ChatMessage>[
        for (int i = 0; i < _count; i++) _mixed(i, friend: friend),
      ],
    },
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        messageTimelineStoreProvider.overrideWithValue(store),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty().copyWith(
            book: FriendshipBook.restore(
              profiles: const <String, FriendProfile>{
                _ada: FriendProfile(
                  address: _ada,
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.accepted,
                ),
              },
            ),
            groups: const <String, GroupProfile>{
              _groupId: GroupProfile(
                id: _groupId,
                name: 'Ekipa',
                createdById: 'self',
                createdAtMillis: 0,
                memberAddresses: <String>['self', _bob],
              ),
            },
          ),
        ),
      ],
      child: MaterialApp(
        home: group
            ? const GroupConversationScreen(
                groupId: _groupId,
                groupName: 'Ekipa',
              )
            : const ConversationScreen(peerAddress: _ada, title: 'Ada'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Chat(group: group, store: store);
}

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));

Finder get _list => find.byType(ListView);

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: _list, matching: find.byType(Scrollable)).first,
    )
    .position;

/// A few frames for the conversation to be read again and laid out, with
/// no time for a finger's gesture to end.
Future<void> _frames(WidgetTester tester) async {
  for (int i = 0; i < 3; i++) {
    await tester.pump();
  }
}

/// The conversation becomes [change] of what it is.
Future<void> _change(
  WidgetTester tester,
  _Chat chat,
  List<ChatMessage> Function(List<ChatMessage> messages) change,
) async {
  await chat.store.save(chat.key, change(await chat.store.load(chat.key)));
  _container(tester).read(messageTimelineRevisionProvider.notifier).bump();
  await _frames(tester);
}

Future<void> _arrive(WidgetTester tester, _Chat chat, ChatMessage m) =>
    _change(tester, chat, (List<ChatMessage> all) => <ChatMessage>[...all, m]);

ChatMessage Function(ChatMessage) _only(
  String id,
  ChatMessage Function(ChatMessage) edit,
) =>
    (ChatMessage m) => m.id == id ? edit(m) : m;

Future<void> _edit(
  WidgetTester tester,
  _Chat chat,
  String id,
  ChatMessage Function(ChatMessage) edit,
) => _change(
  tester,
  chat,
  (List<ChatMessage> all) => all.map(_only(id, edit)).toList(),
);

void _typing(WidgetTester tester, bool typing) {
  final SocialHubController hub = _container(
    tester,
  ).read(socialHubControllerProvider.notifier);
  // ignore: invalid_use_of_protected_member
  hub.state = hub.state.copyWith(
    book: hub.state.book.edit(
      _ada,
      (FriendProfile f) => f.copyWith(isTyping: typing),
    ),
  );
}

/// The text message on screen nearest the middle of the list (or the
/// lowest one, [lowest]): the bubble whose pixel is watched.
({int n, Finder finder}) _marked(WidgetTester tester, {bool lowest = false}) {
  final Rect list = tester.getRect(_list);
  ({int n, Finder finder})? best;
  double bestScore = double.infinity;
  for (int n = 0; n < _count; n++) {
    final Finder f = find.textContaining(_textOf(n));
    if (f.evaluate().length != 1) {
      continue;
    }
    final double y = tester.getTopLeft(f).dy;
    if (y < list.top + 40 || y > list.bottom - 80) {
      continue;
    }
    final double score = lowest ? -y : (y - list.center.dy).abs();
    if (score < bestScore) {
      bestScore = score;
      best = (n: n, finder: f);
    }
  }
  if (best == null) {
    fail('no text message on the screen');
  }
  return best;
}

double _y(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

/// Every kind of change, below or above the bubble [marked], for the
/// conversation [chat] (the typing line only in a 1:1 chat).
List<(String, Future<void> Function())> _changes(
  WidgetTester tester,
  _Chat chat,
  int marked, {
  required int next,
}) {
  // Below the screen: newer than anything on it (the lists are laid out
  // from the newest message at the bottom), so nothing on the screen is on
  // the far side of the change. (A bubble on the screen that grows moves
  // those above it: something on the screen has to give way.)
  final double bottom = tester.getRect(_list).bottom;
  bool offScreen(int n) {
    for (final Finder f in <Finder>[
      find.textContaining(_textOf(n)),
      find.text('zdjecie-$n.png'),
    ]) {
      if (f.evaluate().isNotEmpty && tester.getTopLeft(f.first).dy < bottom) {
        return false;
      }
    }
    return true;
  }

  bool text(int n) => n % 11 != 3 && n % 11 != 6 && n % 11 != 9;
  int below(bool Function(int n) wanted) {
    for (int n = _count - 1; n > marked; n--) {
      if (wanted(n) && offScreen(n)) {
        return n;
      }
    }
    fail('no message below the screen');
  }

  final int ownBelow = below((int n) => n % 4 == 1 && text(n));
  final int theirsBelow = below((int n) => n % 4 != 1 && text(n));
  final int goes = below(
    (int n) => n != ownBelow && n != theirsBelow && text(n),
  );
  final int stub = below((int n) => n % 11 == 3 && n.isEven);
  int arriving = next;
  return <(String, Future<void> Function())>[
    (
      'a message coming in',
      () => _arrive(
        tester,
        chat,
        _incoming(arriving++, friend: chat.friend, text: 'Nowa wiadomość'),
      ),
    ),
    (
      'a long message coming in',
      () => _arrive(
        tester,
        chat,
        _incoming(
          arriving++,
          friend: chat.friend,
          text: 'Nowa długa. ${'Bardzo długi tekst. ' * 40}',
        ),
      ),
    ),
    (
      'a receipt on one\'s own message',
      () => _edit(
        tester,
        chat,
        'm-$ownBelow',
        (ChatMessage m) => m.copyWith(
          deliveryState: ChatMessageDeliveryState.delivered,
          readAtMillis: _at(_count),
        ),
      ),
    ),
    (
      'a reaction',
      () => _edit(
        tester,
        chat,
        'm-$theirsBelow',
        (ChatMessage m) => m.copyWith(
          reactions: const <String, String>{'self': '👍', _bob: '❤️'},
        ),
      ),
    ),
    (
      'an edit',
      () => _edit(
        tester,
        chat,
        'm-$theirsBelow',
        (ChatMessage m) => m.copyWith(
          text: '${m.text} ${'Dopisane później. ' * 12}',
          editedAtMillis: _at(_count),
        ),
      ),
    ),
    (
      'a deletion for everyone',
      () => _edit(
        tester,
        chat,
        'm-$ownBelow',
        (ChatMessage m) => m.copyWith(deletedAtMillis: _at(_count), text: ''),
      ),
    ),
    (
      'a disappearing message going',
      () => _change(
        tester,
        chat,
        (List<ChatMessage> all) => <ChatMessage>[
          for (final ChatMessage m in all)
            if (m.id != 'm-$goes') m,
        ],
      ),
    ),
    (
      'a late message going in further up',
      () => _change(
        tester,
        chat,
        (List<ChatMessage> all) => insertChronologically(
          all,
          ChatMessage(
            id: 'late',
            sender: chat.friend,
            text: 'Spóźniona. ${'Trzymana przez przekaźniki. ' * 10}',
            sentAtMillis: _at(2) + 1000,
            direction: ChatMessageDirection.incoming,
          ),
        ),
      ),
    ),
    (
      'a file arriving',
      () => _edit(
        tester,
        chat,
        'm-$stub',
        (ChatMessage m) => m.copyWith(attachmentBytes: _png),
      ),
    ),
    if (!chat.group) ...<(String, Future<void> Function())>[
      (
        'the typing line showing',
        () async {
          _typing(tester, true);
          await _frames(tester);
        },
      ),
      (
        'the typing line going',
        () async {
          _typing(tester, false);
          await _frames(tester);
        },
      ),
    ],
  ];
}

Future<void> _dragUp(WidgetTester tester, {int times = 5}) async {
  for (int i = 0; i < times; i++) {
    await tester.drag(_list, const Offset(0, 300));
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final bool inGroup in <bool>[false, true]) {
    final String chatName = inGroup ? 'group chat' : '1:1 chat';

    group(chatName, () {
      testWidgets('while a finger drags the list, nothing that comes or '
          'changes moves what is under it: only the finger does', (
        WidgetTester tester,
      ) async {
        final _Chat chat = await _open(tester, group: inGroup);
        await _dragUp(tester);
        final ({int n, Finder finder}) marked = _marked(tester);
        final TestGesture finger = await tester.startGesture(
          tester.getCenter(_list),
        );
        await finger.moveBy(const Offset(0, 40));
        await tester.pump();
        int next = 200;
        for (final (String what, Future<void> Function() change) in _changes(
          tester,
          chat,
          marked.n,
          next: next,
        )) {
          await finger.moveBy(const Offset(0, 6));
          await tester.pump();
          final double before = _y(tester, marked.finder);
          await change();
          expect(
            _y(tester, marked.finder),
            closeTo(before, 0.5),
            reason: '$what under the finger',
          );
          next += 2;
        }
        await finger.up();
        await tester.pumpAndSettle();
      });

      testWidgets('a fling goes on from where it is when a message comes in: '
          'no step back, no jump', (WidgetTester tester) async {
        final _Chat chat = await _open(tester, group: inGroup);
        await _dragUp(tester, times: 2);
        await tester.fling(_list, const Offset(0, 200), 1500);
        await tester.pump(const Duration(milliseconds: 16));
        final ({int n, Finder finder}) marked = _marked(tester);
        double last = _y(tester, marked.finder);
        await tester.pump(const Duration(milliseconds: 16));
        double step = _y(tester, marked.finder) - last;
        last += step;
        expect(step, greaterThan(5), reason: 'the fling runs');
        await chat.store.append(
          chat.key,
          _incoming(300, friend: chat.friend, text: 'W trakcie lotu'),
        );
        _container(
          tester,
        ).read(messageTimelineRevisionProvider.notifier).bump();
        for (int frame = 0; frame < 4; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final double now = _y(tester, marked.finder);
          final double moved = now - last;
          expect(
            moved,
            inInclusiveRange(0, step + 1),
            reason: 'frame $frame after the message came in',
          );
          step = moved;
          last = now;
        }
        await tester.pumpAndSettle();
      });

      testWidgets('at the newest message, a finger resting on the list keeps '
          'what it holds; what came in waits below, on the button, which '
          'brings it', (WidgetTester tester) async {
        final _Chat chat = await _open(tester, group: inGroup);
        final ({int n, Finder finder}) marked = _marked(tester, lowest: true);
        final TestGesture finger = await tester.startGesture(
          tester.getCenter(_list),
        );
        await tester.pump(const Duration(milliseconds: 50));
        final double held = _y(tester, marked.finder);
        await _arrive(
          tester,
          chat,
          _incoming(
            400,
            friend: chat.friend,
            text: 'Przyszła pod palcem. ${'Długa. ' * 30}',
          ),
        );
        expect(_y(tester, marked.finder), closeTo(held, 0.5), reason: 'held');

        // Dragged a little, still near the newest message.
        await finger.moveBy(const Offset(0, 20));
        await tester.pump();
        final double dragged = _y(tester, marked.finder);
        await _arrive(
          tester,
          chat,
          _incoming(401, friend: chat.friend, text: 'I jeszcze jedna'),
        );
        expect(
          _y(tester, marked.finder),
          closeTo(dragged, 0.5),
          reason: 'dragged',
        );
        await finger.up();
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('jump-to-latest-badge')), findsOneWidget);
        await tester.tap(find.byKey(const Key('jump-to-latest-button')));
        await tester.pumpAndSettle();
        expect(_position(tester).pixels, lessThan(1));
        expect(find.text('I jeszcze jedna'), findsOneWidget);
        expect(find.byKey(const Key('jump-to-latest-button')), findsNothing);

        // Left alone at the newest message, a new one is followed.
        await _arrive(
          tester,
          chat,
          _incoming(402, friend: chat.friend, text: 'Ostatnia'),
        );
        await tester.pumpAndSettle();
        expect(_position(tester).pixels, lessThan(1));
        expect(find.text('Ostatnia'), findsOneWidget);
      });

      testWidgets('scrolled up and left alone, a bubble on the screen stays '
          'at its pixel through every kind of change, and keeps its state', (
        WidgetTester tester,
      ) async {
        final _Chat chat = await _open(tester, group: inGroup);
        await _dragUp(tester);
        final ({int n, Finder finder}) marked = _marked(tester);
        final Element element = marked.finder.evaluate().single;
        for (final (String what, Future<void> Function() change) in _changes(
          tester,
          chat,
          marked.n,
          next: 500,
        )) {
          final double before = _y(tester, marked.finder);
          await change();
          await tester.pumpAndSettle();
          expect(_y(tester, marked.finder), closeTo(before, 0.5), reason: what);
        }
        expect(
          identical(marked.finder.evaluate().single, element),
          isTrue,
          reason: 'the bubble was kept, not built anew',
        );
      });

      testWidgets('one\'s own message written on another device does not '
          'take the list from under a dragging finger', (
        WidgetTester tester,
      ) async {
        final _Chat chat = await _open(tester, group: inGroup);
        await _dragUp(tester, times: 3);
        final ({int n, Finder finder}) marked = _marked(tester);
        final TestGesture finger = await tester.startGesture(
          tester.getCenter(_list),
        );
        await finger.moveBy(const Offset(0, 30));
        await tester.pump();
        await finger.moveBy(const Offset(0, 10));
        await tester.pump();
        final double before = _y(tester, marked.finder);
        await _arrive(
          tester,
          chat,
          ChatMessage(
            id: 'own-elsewhere',
            sender: 'self',
            text: 'Z drugiego urządzenia',
            sentAtMillis: _at(_count + 5),
            direction: ChatMessageDirection.outgoing,
            deliveryState: ChatMessageDeliveryState.sent,
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(_y(tester, marked.finder), closeTo(before, 0.5));
        await finger.moveBy(const Offset(0, 10));
        await tester.pump();
        expect(_y(tester, marked.finder), closeTo(before + 10, 0.5));
        await finger.up();
        await tester.pumpAndSettle();
      });
    });
  }

  group('ChatScrollController', () {
    testWidgets('a bubble below the screen measured anew while a finger '
        'drags the list (a GIF decoded, a file arrived) does not move what '
        'is on it', (WidgetTester tester) async {
      final ChatScrollController controller = ChatScrollController(
        reversed: true,
      );
      addTearDown(controller.dispose);
      final ValueNotifier<double> gif = ValueNotifier<double>(320);
      addTearDown(gif.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              reverse: true,
              itemCount: 60,
              itemBuilder: (BuildContext context, int i) => i == 8
                  ? ValueListenableBuilder<double>(
                      key: const ValueKey<String>('gif'),
                      valueListenable: gif,
                      builder: (BuildContext context, double h, _) =>
                          SizedBox(height: h, child: const Text('gif')),
                    )
                  : SizedBox(
                      key: ValueKey<String>('row-$i'),
                      height: 70,
                      child: Text('row $i'),
                    ),
            ),
          ),
        ),
      );
      // Up, past the GIF: it stays built just below the screen.
      final TestGesture finger = await tester.startGesture(
        tester.getCenter(find.byType(ListView)),
      );
      for (int i = 0; i < 24; i++) {
        await finger.moveBy(const Offset(0, 40));
        await tester.pump(const Duration(milliseconds: 50));
      }
      final Finder read = find.text('row 16');
      expect(read, findsOneWidget);
      expect(tester.getTopLeft(read).dy, greaterThan(0));
      // Built (in the list's cache), below the screen.
      final Finder gifRow = find.text('gif', skipOffstage: false);
      expect(gifRow, findsOneWidget);
      expect(
        tester.getTopLeft(gifRow).dy,
        greaterThan(tester.getBottomLeft(find.byType(ListView)).dy),
      );
      final double before = tester.getTopLeft(read).dy;
      gif.value = 140;
      await tester.pump();
      expect(tester.getTopLeft(read).dy, closeTo(before, 0.5));
      await finger.moveBy(const Offset(0, 10));
      await tester.pump();
      expect(tester.getTopLeft(read).dy, closeTo(before + 10, 0.5));
      gif.value = 260;
      await tester.pump();
      expect(tester.getTopLeft(read).dy, closeTo(before + 10, 0.5));
      await finger.up();
      await tester.pumpAndSettle();
    });
  });
}
