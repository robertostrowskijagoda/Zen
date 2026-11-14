import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_media_size.dart';
import 'package:zen/src/domain/messages/chat_message.dart';

/// The size of a message's picture: taken from the sender only as whole
/// pixels within bounds, and the box it gives a bubble never larger than
/// the bubble allows nor thinner than 1:8, whatever the sender says.

ChatMediaSize _size(int width, int height) => ChatMediaSize.of(width, height)!;

void main() {
  group('ChatMediaSize.of', () {
    test('takes whole pixels from 1 to the largest side', () {
      expect(ChatMediaSize.of(1, 1)?.width, 1);
      expect(ChatMediaSize.of(640, 480)?.height, 480);
      expect(
        ChatMediaSize.of(kMaxChatMediaSide, kMaxChatMediaSide)?.width,
        kMaxChatMediaSide,
      );
    });

    test('anything else is no size at all', () {
      for (final (Object?, Object?) bad in <(Object?, Object?)>[
        (0, 10),
        (10, 0),
        (-1, 10),
        (10, -1),
        (kMaxChatMediaSide + 1, 10),
        (10, kMaxChatMediaSide + 1),
        (1 << 62, 10),
        (10.5, 10),
        ('10', 10),
        (null, 10),
        (10, null),
        (double.nan, 10),
        (double.infinity, 10),
      ]) {
        expect(ChatMediaSize.of(bad.$1, bad.$2), isNull, reason: '$bad');
      }
    });

    test('goes to and from JSON; a broken one reads as none', () {
      final ChatMediaSize size = _size(320, 200);
      expect(size.toJson(), <String, dynamic>{'w': 320, 'h': 200});
      expect(ChatMediaSize.fromJson(size.toJson()), size);
      expect(ChatMediaSize.fromJson(<String, dynamic>{'w': 320}), isNull);
      expect(ChatMediaSize.fromJson(<String, dynamic>{'w': 0, 'h': 2}), isNull);
      expect(ChatMediaSize.fromJson(<Object>[320, 200]), isNull);
      expect(ChatMediaSize.fromJson(null), isNull);
      expect(size.toPayload(), <String, dynamic>{
        kMediaWidthKey: 320,
        kMediaHeightKey: 200,
      });
      expect(size, isNot(_size(200, 320)));
      expect(size.hashCode, _size(320, 200).hashCode);
    });
  });

  group('aspectRatio', () {
    test('is width over height', () {
      expect(_size(300, 150).aspectRatio, 2);
      expect(_size(150, 300).aspectRatio, 0.5);
    });

    test('is held within 1:8 either way', () {
      expect(_size(8, 1).aspectRatio, 8);
      expect(_size(1, 8).aspectRatio, 1 / 8);
      expect(_size(kMaxChatMediaSide, 1).aspectRatio, kMaxChatMediaAspect);
      expect(_size(1, kMaxChatMediaSide).aspectRatio, 1 / kMaxChatMediaAspect);
    });
  });

  group('boxWithin', () {
    ({double width, double height}) gif(int w, int h) =>
        _size(w, h).boxWithin(maxWidth: 300, maxHeight: 320);

    ({double width, double height}) photo(int w, int h) =>
        _size(w, h).boxWithin(maxWidth: 300, maxHeight: 320, enlarge: true);

    test('a GIF that fits keeps its own size', () {
      expect(gif(60, 30), (width: 60.0, height: 30.0));
      expect(gif(300, 320), (width: 300.0, height: 320.0));
    });

    test('a wide GIF is as wide as the bubble, in its proportions', () {
      expect(gif(600, 150), (width: 300.0, height: 75.0));
    });

    test('a tall GIF is as tall as allowed, in its proportions', () {
      final ({double width, double height}) box = gif(150, 900);
      expect(box.height, 320);
      expect(box.width, closeTo(320 / 6, 1e-9));
    });

    test('a photo fills the width unless it would be too tall', () {
      expect(photo(60, 30), (width: 300.0, height: 150.0));
      expect(photo(4000, 3000), (width: 300.0, height: 225.0));
      expect(photo(3000, 4000), (width: 240.0, height: 320.0));
    });

    test('a hostile size never makes a box larger than allowed', () {
      for (final ChatMediaSize size in <ChatMediaSize>[
        _size(1, kMaxChatMediaSide),
        _size(kMaxChatMediaSide, 1),
        _size(kMaxChatMediaSide, kMaxChatMediaSide),
        _size(1, 1),
      ]) {
        for (final bool enlarge in <bool>[false, true]) {
          final ({double width, double height}) box = size.boxWithin(
            maxWidth: 300,
            maxHeight: 320,
            enlarge: enlarge,
          );
          expect(box.width, inInclusiveRange(0.1, 300), reason: '$size');
          expect(box.height, inInclusiveRange(0.1, 320), reason: '$size');
          // Never thinner than the proportions allow.
          expect(
            box.width / box.height,
            inInclusiveRange(1 / kMaxChatMediaAspect, kMaxChatMediaAspect),
          );
        }
      }
      // 1 x 65536 is a thin GIF of 1 x 8, not one 65536 tall.
      expect(gif(1, kMaxChatMediaSide), (width: 1.0, height: 8.0));
      expect(photo(1, kMaxChatMediaSide), (width: 40.0, height: 320.0));
      expect(photo(kMaxChatMediaSide, 1), (width: 300.0, height: 37.5));
    });

    test('an unknown room is the picture\'s own size', () {
      expect(
        _size(
          200,
          100,
        ).boxWithin(maxWidth: double.infinity, maxHeight: double.nan),
        (width: 200.0, height: 100.0),
      );
      expect(_size(200, 100).boxWithin(maxWidth: 0, maxHeight: -5), (
        width: 200.0,
        height: 100.0,
      ));
    });
  });

  group('a message keeps the size of its picture', () {
    ChatMessage photoMessage({ChatMediaSize? mediaSize}) => ChatMessage(
      id: 'p',
      sender: 'ada',
      text: 'foto.jpg',
      sentAtMillis: 1,
      direction: ChatMessageDirection.incoming,
      type: ChatMessageType.image,
      fileName: 'foto.jpg',
      mediaSize: mediaSize,
    );

    test('in its stored extras and back', () {
      final ChatMessage message = photoMessage(mediaSize: _size(400, 300));
      final Map<String, dynamic>? extras = chatMessageExtrasToJson(message);
      expect(extras?[kMediaSizeKey], <String, dynamic>{'w': 400, 'h': 300});
      final ChatMessage back = chatMessageWithExtras(photoMessage(), extras);
      expect(back.mediaSize, _size(400, 300));
    });

    test('a message without one stores nothing for it', () {
      expect(chatMessageExtrasToJson(photoMessage()), isNull);
      expect(
        chatMessageWithExtras(photoMessage(), <String, dynamic>{
          kMediaSizeKey: <String, dynamic>{'w': -3, 'h': 1},
        }).mediaSize,
        isNull,
      );
    });

    test('copyWith keeps it, changes it or clears it', () {
      final ChatMessage message = photoMessage(mediaSize: _size(10, 20));
      expect(message.copyWith(text: 'x').mediaSize, _size(10, 20));
      expect(
        message.copyWith(mediaSize: _size(30, 40)).mediaSize,
        _size(30, 40),
      );
      expect(message.copyWith(mediaSize: null).mediaSize, isNull);
      expect(message.deletedAt(5).mediaSize, isNull);
    });
  });
}
