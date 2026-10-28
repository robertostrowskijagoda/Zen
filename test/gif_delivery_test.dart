import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/media_vault.dart';

import 'support/friends_world.dart';

/// GIFs between simulated friends (`FriendsWorld`): one picked in the GIF
/// search goes as a copy small enough for the chat message itself and shows
/// on the friend's side as a GIF; a GIF's delivery and read receipts reach
/// the sender's ticks.

/// An animated GIF of noise (so it does not compress) of about
/// [side]² × [frames] bytes, with a comment the sender must not pass on.
Uint8List _gif({required int side, int frames = 3, int seed = 7}) {
  final Random random = Random(seed);
  img.Image frame() {
    final img.Image f = img.Image(width: side, height: side)
      ..frameDuration = 40;
    for (final img.Pixel p in f) {
      p
        ..r = random.nextInt(256)
        ..g = random.nextInt(256)
        ..b = random.nextInt(256);
    }
    return f;
  }

  final img.Image first = frame();
  for (int i = 1; i < frames; i++) {
    first.addFrame(frame());
  }
  final Uint8List plain = img.encodeGif(first);
  // A comment extension right after the colour table of the screen.
  final int packed = plain[10];
  final int afterTable = (packed & 0x80) != 0
      ? 13 + 3 * (1 << ((packed & 0x07) + 1))
      : 13;
  return Uint8List.fromList(<int>[
    ...plain.sublist(0, afterTable),
    0x21, 0xFE, 5, ...'Klipy'.codeUnits, 0, //
    ...plain.sublist(afterTable),
  ]);
}

/// The catalog host as the picker sees it: each copy by its URL.
final class _Catalog implements GifDownloader {
  _Catalog(this.files);

  final Map<String, Uint8List> files;
  final List<String> fetched = <String>[];

  @override
  Future<Uint8List> download(String url) async {
    fetched.add(url);
    final Uint8List? bytes = files[url];
    if (bytes == null) {
      throw StateError('no such GIF');
    }
    return bytes;
  }
}

LifecycleSnapshot _shown(int generation) => LifecycleSnapshot(
  visibility: AppVisibilityState.foreground,
  generation: generation,
  capturedAtMillis: 1,
);

Future<ChatMessage> _only(
  FriendsPhone phone,
  FriendsPhone peer,
  ChatMessageDirection direction,
) async => (await phone.thread(
  peer,
)).singleWhere((ChatMessage m) => m.direction == direction);

MessageDeliveryStage _stageOf(ChatMessage message) =>
    MessageDeliveryStatus.of(message, nowMillis: message.sentAtMillis)!.stage;

void main() {
  test('a GIF picked in the search reaches the friend as a GIF in the chat '
      'message itself, and the sender sees it delivered', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final Uint8List full = _gif(side: 700, frames: 4, seed: 1);
    final Uint8List small = _gif(side: 120, frames: 3, seed: 2);
    expect(full.length, greaterThan(kMaxCatalogGifSendBytes));
    expect(small.length, lessThan(kMaxCatalogGifSendBytes));
    final _Catalog catalog = _Catalog(<String, Uint8List>{
      'https://static.klipy.com/full.gif': full,
      'https://static.klipy.com/tiny.gif': small,
    });
    // What the catalog says about one result: the full copy is too large.
    final GifCatalogEntry entry = KlipyGifCatalog.parseResults(
      <String, dynamic>{
        'results': <Object>[
          <String, dynamic>{
            'media_formats': <String, dynamic>{
              'gif': <String, dynamic>{
                'url': 'https://static.klipy.com/full.gif',
                'size': full.length,
              },
              'tinygif': <String, dynamic>{
                'url': 'https://static.klipy.com/tiny.gif',
                'size': small.length,
              },
            },
          },
        ],
      },
    ).single;

    final Uint8List picked = await downloadGifToSend(catalog, entry);
    expect(catalog.fetched, <String>['https://static.klipy.com/tiny.gif']);
    expect(isAcceptableGif(picked), isTrue);
    expect(picked.length, lessThan(small.length), reason: 'no comment');

    await w['A'].hub.sendLocalAttachment(
      peerAddress: w['B'].address,
      bytes: picked,
      fileName: 'gif.gif',
      mimeType: 'image/gif',
      type: ChatMessageType.image,
      sentAtMillis: w.now,
    );
    await w.settle();

    final ChatMessage got = await _only(
      w['B'],
      w['A'],
      ChatMessageDirection.incoming,
    );
    expect(got.type, ChatMessageType.image);
    expect(got.mimeType, 'image/gif');
    expect(got.deliveryState, isNot(ChatMessageDeliveryState.sending));
    expect(
      await w['B'].container.read(mediaVaultProvider).read(got.attachmentPath!),
      picked,
      reason: 'the GIF itself, played as it came',
    );
    // In the message itself: no transfer, no copy sealed for mailboxes.
    expect(w.net.stats.byType['message_placeholder'], isNull);
    expect(w.net.stats.byType['message_chunk'], isNull);
    expect((await w['A'].relayStore.load()).outBlobs, isEmpty);

    final ChatMessage sent = await _only(
      w['A'],
      w['B'],
      ChatMessageDirection.outgoing,
    );
    expect(sent.deliveryState, ChatMessageDeliveryState.delivered);
    expect(_stageOf(sent), MessageDeliveryStage.delivered);
  });

  test('a GIF from the keyboard that came while the friend\'s app was in '
      'the background shows two ticks once they are back in the open '
      'conversation', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    // B's Zen is in the background, the conversation with A still open on
    // its screen.
    await b.hub.enterConversation(a.address);

    await a.hub.sendLocalAttachment(
      peerAddress: b.address,
      bytes: _gif(side: 96),
      fileName: 'klawiatura-1.gif',
      mimeType: 'image/gif',
      type: ChatMessageType.image,
      sentAtMillis: w.now,
    );
    await w.settle();
    await w.advance(const Duration(seconds: 10));

    ChatMessage sent = await _only(a, b, ChatMessageDirection.outgoing);
    expect(sent.deliveryState, ChatMessageDeliveryState.delivered);
    expect(_stageOf(sent), MessageDeliveryStage.delivered);
    expect(
      (await _only(b, a, ChatMessageDirection.incoming)).isRead,
      isFalse,
      reason: 'nobody looked yet',
    );

    // B comes back to Zen, to the conversation that stayed open.
    await b.hub.setLifecycle(_shown(12));
    await w.settle();

    expect((await _only(b, a, ChatMessageDirection.incoming)).isRead, isTrue);
    sent = await _only(a, b, ChatMessageDirection.outgoing);
    expect(sent.isRead, isTrue);
    expect(_stageOf(sent), MessageDeliveryStage.read);
  });
}
