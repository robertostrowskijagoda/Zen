import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_media_size.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// A photo or a GIF whose message says its size has its final size in the
/// chat from the start: while the file is on its way, while it is decoded
/// and once it shows, so nothing around it moves when it comes in. Sizes a
/// sender makes up are held within the bubble; a message without a size
/// (from a Zen before 1.17.5) shows as it did.

const String _ada = 'ada.ygg';

Uint8List _gif(int width, int height) => img.encodeGif(
  img.Image(width: width, height: height, numChannels: 4)
    ..clear(img.ColorRgba8(255, 0, 0, 255)),
);

Uint8List _png(int width, int height) => img.encodePng(
  img.Image(width: width, height: height)..clear(img.ColorRgb8(0, 90, 200)),
);

ChatMediaSize _size(int width, int height) => ChatMediaSize.of(width, height)!;

ChatMessage _picture({
  required bool gif,
  Uint8List? bytes,
  ChatMediaSize? size,
  String id = 'p',
  int sentAtMillis = 1,
}) => ChatMessage(
  id: id,
  sender: _ada,
  text: gif ? 'gif.gif' : 'zdjecie.png',
  sentAtMillis: sentAtMillis,
  direction: ChatMessageDirection.incoming,
  type: ChatMessageType.image,
  attachmentBytes: bytes,
  fileName: gif ? 'gif.gif' : 'zdjecie.png',
  mimeType: gif ? 'image/gif' : 'image/png',
  attachmentSizeBytes: 2048,
  mediaSize: size,
  deliveryState: bytes == null
      ? ChatMessageDeliveryState.sending
      : ChatMessageDeliveryState.none,
);

/// [message] in a bubble at most 300 wide.
Widget _body(ChatMessage message) => ProviderScope(
  child: MaterialApp(
    theme: ZenTheme.dark(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: ChatAttachmentBody(key: const Key('body'), message: message),
        ),
      ),
    ),
  ),
);

Size _bodySize(WidgetTester tester) =>
    tester.getSize(find.byKey(const Key('body')));

/// Lets the picture decode and show (real time: decoding is not faked).
Future<void> _decoded(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
  }
}

void main() {
  group('a bubble whose message says the size of its picture', () {
    testWidgets('a GIF has its size on its way, while it is decoded and '
        'once it plays', (WidgetTester tester) async {
      final ChatMediaSize size = _size(600, 150);
      await tester.pumpWidget(_body(_picture(gif: true, size: size)));
      expect(
        find.byKey(const Key('picture-on-its-way-p')),
        findsOneWidget,
        reason: 'a placeholder of the final size',
      );
      final Size onItsWay = _bodySize(tester);
      expect(onItsWay, const Size(300, 75));

      await tester.pumpWidget(
        _body(_picture(gif: true, bytes: _gif(600, 150), size: size)),
      );
      expect(find.byType(RawImage), findsNothing, reason: 'not decoded yet');
      expect(_bodySize(tester), onItsWay, reason: 'while it is decoded');

      await _decoded(tester);
      expect(find.byType(RawImage), findsOneWidget);
      expect(_bodySize(tester), onItsWay, reason: 'once it plays');
      expect(tester.getSize(find.byType(RawImage)), const Size(300, 75));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a photo has its size on its way and once it shows', (
      WidgetTester tester,
    ) async {
      final ChatMediaSize size = _size(400, 300);
      await tester.pumpWidget(_body(_picture(gif: false, size: size)));
      final Size onItsWay = _bodySize(tester);
      expect(
        tester.getSize(find.byKey(const Key('picture-box-p'))),
        const Size(300, 225),
      );
      expect(find.text('zdjecie.png'), findsOneWidget);

      await tester.pumpWidget(
        _body(_picture(gif: false, bytes: _png(400, 300), size: size)),
      );
      expect(_bodySize(tester), onItsWay, reason: 'before it is decoded');
      await _decoded(tester);
      expect(_bodySize(tester), onItsWay, reason: 'once it shows');
      expect(find.byKey(const Key('picture-on-its-way-p')), findsNothing);
      expect(tester.getSize(find.byType(Image)), const Size(300, 225));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a picture that is not what its size said, or does not '
        'open, keeps the box', (WidgetTester tester) async {
      final ChatMediaSize size = _size(200, 100);
      await tester.pumpWidget(
        _body(_picture(gif: true, bytes: _gif(50, 400), size: size)),
      );
      final Size before = _bodySize(tester);
      await _decoded(tester);
      expect(_bodySize(tester), before);
      expect(before, const Size(200, 100));

      await tester.pumpWidget(
        _body(
          _picture(
            gif: true,
            bytes: Uint8List.fromList(<int>[0x47, 0x49, 0x46, 0x38, 1, 2]),
            size: size,
          ),
        ),
      );
      await _decoded(tester);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(_bodySize(tester), const Size(200, 100));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a size a sender made up stays within the bubble and lays '
      'out', (WidgetTester tester) async {
    for (final ChatMediaSize size in <ChatMediaSize>[
      _size(1, kMaxChatMediaSide),
      _size(kMaxChatMediaSide, 1),
      _size(kMaxChatMediaSide, kMaxChatMediaSide),
      _size(1, 1),
    ]) {
      for (final bool gif in <bool>[true, false]) {
        for (final Uint8List? bytes in <Uint8List?>[
          null,
          gif ? _gif(40, 40) : _png(40, 40),
        ]) {
          await tester.pumpWidget(
            _body(_picture(gif: gif, bytes: bytes, size: size)),
          );
          await _decoded(tester);
          final String what = '$size, gif: $gif, file: ${bytes != null}';
          expect(tester.takeException(), isNull, reason: what);
          final Size box = tester.getSize(
            find.byKey(const Key('picture-box-p')),
          );
          expect(box.width, lessThanOrEqualTo(300), reason: what);
          expect(box.height, lessThanOrEqualTo(320), reason: what);
          expect(box.width, greaterThan(0), reason: what);
          expect(box.height, greaterThan(0), reason: what);
          expect(
            box.width / box.height,
            inInclusiveRange(
              1 / kMaxChatMediaAspect - 1e-9,
              kMaxChatMediaAspect + 1e-9,
            ),
            reason: what,
          );
          await tester.pumpWidget(const SizedBox());
        }
      }
    }
  });

  group('a message without a size (a Zen before 1.17.5)', () {
    testWidgets('on its way, a file line as before', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_body(_picture(gif: false)));
      expect(find.text('Transfer w toku'), findsNothing, reason: 'size known');
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(find.byKey(const Key('picture-box-p')), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });

    testWidgets('a photo across the bubble, 220 high', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_body(_picture(gif: false, bytes: _png(40, 30))));
      await _decoded(tester);
      expect(find.byKey(const Key('picture-box-p')), findsNothing);
      expect(tester.getSize(find.byType(Image)), const Size(300, 220));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a GIF in its own proportions once it plays', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _body(_picture(gif: true, bytes: _gif(600, 150))),
      );
      await _decoded(tester);
      expect(find.byKey(const Key('picture-box-p')), findsNothing);
      expect(tester.getSize(find.byType(RawImage)), const Size(300, 75));
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('in a conversation, a GIF coming in at the newest message '
      'moves none of the messages above it', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final MemoryMessageTimelineStore store = MemoryMessageTimelineStore(
      <String, List<ChatMessage>>{
        _ada: <ChatMessage>[
          for (int i = 0; i < 12; i++)
            ChatMessage(
              id: 'm-$i',
              sender: _ada,
              text: 'Wiadomość numer $i',
              sentAtMillis: 1000 + i * 1000,
              direction: ChatMessageDirection.incoming,
            ),
          _picture(
            gif: true,
            id: 'gif-1',
            size: _size(240, 180),
            sentAtMillis: 100000,
          ),
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
            ),
          ),
        ],
        child: const MaterialApp(
          home: ConversationScreen(peerAddress: _ada, title: 'Ada'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder above = find.text('Wiadomość numer 11');
    final double before = tester.getTopLeft(above).dy;
    expect(
      tester.getSize(find.byKey(const Key('picture-box-gif-1'))),
      const Size(240, 180),
    );

    // The GIF arrives whole, and is decoded.
    await store.update(
      _ada,
      (List<ChatMessage> all) => <ChatMessage>[
        for (final ChatMessage m in all)
          m.id == 'gif-1'
              ? m.copyWith(
                  attachmentBytes: _gif(240, 180),
                  deliveryState: ChatMessageDeliveryState.none,
                )
              : m,
      ],
    );
    ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    ).read(messageTimelineRevisionProvider.notifier).bump();
    // Not settled: the GIF's progress ring turns until it is decoded.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RawImage), findsNothing, reason: 'not decoded yet');
    expect(tester.getTopLeft(above).dy, closeTo(before, 0.5));
    await _decoded(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(RawImage), findsOneWidget, reason: 'it plays');
    expect(tester.getTopLeft(above).dy, closeTo(before, 0.5));
  });
}
