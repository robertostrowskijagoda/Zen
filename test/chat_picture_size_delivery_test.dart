import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/domain/messages/chat_media_size.dart';
import 'package:zen/src/domain/messages/chat_message.dart';

import 'support/friends_world.dart';

/// The sender reads the size of a photo or a GIF when it is attached, and
/// the friend's message has it before the file is there: in the chat
/// message itself, with a large file's placeholder and chunks, and in a
/// group (simulated friends, `FriendsWorld`).

Uint8List _gif(int width, int height) => img.encodeGif(
  img.Image(width: width, height: height, numChannels: 4)
    ..clear(img.ColorRgba8(255, 0, 0, 255)),
);

/// A PNG of noise (so it does not shrink) over the 1 MB a chat message
/// carries itself.
Uint8List _largePng(int width, int height) {
  final Random random = Random(3);
  final img.Image picture = img.Image(width: width, height: height);
  for (final img.Pixel p in picture) {
    p
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  return img.encodePng(picture, level: 0);
}

Future<ChatMessage> _outgoing(FriendsPhone phone, Object conversation) async =>
    (await phone.thread(conversation)).singleWhere(
      (ChatMessage m) => m.direction == ChatMessageDirection.outgoing,
    );

Future<ChatMessage?> _incoming(FriendsPhone phone, Object conversation) async =>
    (await phone.thread(conversation))
        .where((ChatMessage m) => m.direction == ChatMessageDirection.incoming)
        .firstOrNull;

void main() {
  test(
    'a GIF in the chat message itself carries its size to the friend',
    () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      await w['A'].hub.sendLocalAttachment(
        peerAddress: w['B'].address,
        bytes: _gif(160, 90),
        fileName: 'gif.gif',
        mimeType: 'image/gif',
        type: ChatMessageType.image,
        sentAtMillis: w.now,
      );
      await w.settle();

      final ChatMessage sent = (await _outgoing(w['A'], w['B']));
      expect(sent.mediaSize, ChatMediaSize.of(160, 90));
      final ChatMessage? got = await _incoming(w['B'], w['A']);
      expect(got?.attachmentPath, isNotNull);
      expect(got?.mediaSize, ChatMediaSize.of(160, 90));
    },
  );

  test('a photo too large for the message itself has its size from the '
      'placeholder, before and after the file is whole', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final Uint8List photo = _largePng(640, 600);
    expect(photo.length, greaterThan(1024 * 1024));
    await w['A'].hub.sendLocalAttachment(
      peerAddress: w['B'].address,
      bytes: photo,
      fileName: 'zdjecie.png',
      mimeType: 'image/png',
      type: ChatMessageType.image,
      sentAtMillis: w.now,
    );
    await w.until(
      () async => (await _incoming(w['B'], w['A'])) != null,
      reason: 'the placeholder reaching B',
      within: const Duration(minutes: 5),
    );
    final ChatMessage first = (await _incoming(w['B'], w['A']))!;
    expect(first.mediaSize, ChatMediaSize.of(640, 600));

    await w.until(
      () async => (await _incoming(w['B'], w['A']))?.attachmentPath != null,
      reason: 'the photo reaching B whole',
      within: const Duration(minutes: 5),
    );
    final ChatMessage whole = (await _incoming(w['B'], w['A']))!;
    expect(whole.type, ChatMessageType.image);
    expect(whole.mediaSize, ChatMediaSize.of(640, 600));
  });

  test('a GIF in a group carries its size to the members', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final String id = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
      w['B'],
    ]);
    await w.deliver();
    await w['A'].hub.sendGroupAttachment(
      groupId: id,
      bytes: _gif(48, 120),
      fileName: 'gif.gif',
      mimeType: 'image/gif',
      type: ChatMessageType.image,
    );
    await w.deliver();

    final ChatMessage? got = await _incoming(w['B'], 'group:$id');
    expect(got?.attachmentPath, isNotNull);
    expect(got?.mediaSize, ChatMediaSize.of(48, 120));
  });

  test('a file that is no picture carries no size', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w['A'].hub.sendLocalAttachment(
      peerAddress: w['B'].address,
      bytes: Uint8List.fromList('Lista zakupów'.codeUnits),
      fileName: 'lista.txt',
      mimeType: 'text/plain',
      type: ChatMessageType.file,
      sentAtMillis: w.now,
    );
    await w.settle();
    expect((await _outgoing(w['A'], w['B'])).mediaSize, isNull);
    expect((await _incoming(w['B'], w['A']))?.mediaSize, isNull);
  });
}
