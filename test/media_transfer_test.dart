import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/media_transfer.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';

/// A two-frame GIF with a comment in it.
Uint8List _gif() {
  final img.Image first = img.Image(width: 8, height: 8)..frameDuration = 40;
  img.fill(first, color: img.ColorRgb8(255, 0, 0));
  final img.Image second = img.Image(width: 8, height: 8)..frameDuration = 40;
  img.fill(second, color: img.ColorRgb8(0, 0, 255));
  first.addFrame(second);
  final Uint8List gif = img.encodeGif(first);
  final int packed = gif[10];
  final int at =
      13 + ((packed & 0x80) != 0 ? 3 * (1 << ((packed & 0x07) + 1)) : 0);
  return Uint8List.fromList(<int>[
    ...gif.sublist(0, at),
    0x21, 0xFE, 6, ...'Gdynia'.codeUnits, 0x00, //
    ...gif.sublist(at),
  ]);
}

Uint8List _png() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 6, height: 4)));

/// The clipboard and drops of a test.
final class _FakeTransfer implements MediaTransferPlatform {
  final StreamController<MediaDrop> controller =
      StreamController<MediaDrop>.broadcast();
  List<TransferItem> clipboard = const <TransferItem>[];
  final List<bool> reads = <bool>[];

  @override
  Stream<MediaDrop> get drops => controller.stream;

  @override
  Future<List<TransferItem>> readClipboard({bool textFirst = false}) async {
    reads.add(textFirst);
    return clipboard;
  }
}

void main() {
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('zen-transfer-');
  });

  tearDownAll(() {
    dir.deleteSync(recursive: true);
  });

  File write(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes);

  test('the runners\' messages are read, anything malformed skipped', () {
    final List<TransferItem> items = transferItemsFromMessage(<Object?>[
      <String, Object?>{'path': '/home/ala/Pobrane/kot.gif'},
      <String, Object?>{'name': 'schowek.png', 'bytes': _png()},
      <String, Object?>{'bytes': Uint8List(0)},
      'nie mapa',
    ]);
    expect(items.map((TransferItem i) => i.name), <String>[
      'kot.gif',
      'schowek.png',
    ]);
    expect(items.first.path, '/home/ala/Pobrane/kot.gif');
    expect(transferItemsFromMessage(null), isEmpty);

    final MediaDrop drop = mediaDropFromMessage(<String, Object?>{
      'paths': <Object?>[r'C:\Users\Ala\film.mp4', 7],
      'x': 12,
      'y': 30.5,
    })!;
    expect(drop.items.single.name, 'film.mp4');
    expect(drop.position, const Offset(12, 30.5));
    expect(
      mediaDropFromMessage(<String, Object?>{'paths': <Object?>[]}),
      isNull,
    );
  });

  test('items become a GIF, a photo, a film or a file', () async {
    final OutgoingAttachment gif = (await prepareOutgoing(
      TransferItem(name: 'taniec.webp', bytes: _gif()),
    ))!;
    expect(gif.kind, OutgoingKind.gif);
    expect(gif.fileName, 'taniec.gif');
    expect(gif.chatType, ChatMessageType.image);
    expect(String.fromCharCodes(gif.bytes!).contains('Gdynia'), isFalse);

    final OutgoingAttachment photo = (await prepareOutgoing(
      TransferItem(name: 'schowek.png', bytes: _png()),
    ))!;
    expect(photo.kind, OutgoingKind.photo);
    expect(photo.fileName, 'schowek.jpg');
    expect(photo.bytes!.sublist(0, 3), <int>[0xFF, 0xD8, 0xFF]);

    final File film = write('wakacje.mp4', <int>[
      0, 0, 0, 16, ...'ftypisom'.codeUnits, 0, 0, 0, 0, //
      0, 0, 0, 8, ...'mdat'.codeUnits,
    ]);
    final OutgoingAttachment video = (await prepareOutgoing(
      TransferItem(name: 'wakacje.mp4', path: film.path),
    ))!;
    expect(video.kind, OutgoingKind.video);
    expect(video.path, film.path);
    expect(video.chatType, ChatMessageType.video);

    final File notes = write('notatki.txt', 'lista zakupow'.codeUnits);
    final OutgoingAttachment file = (await prepareOutgoing(
      TransferItem(name: 'notatki.txt', path: notes.path),
    ))!;
    expect(file.kind, OutgoingKind.file);
    expect(file.chatType, ChatMessageType.file);
    expect(file.gifProblem, isNull);

    expect(
      await prepareOutgoing(
        TransferItem(name: 'brak', path: '${dir.path}/nie-ma-mnie'),
      ),
      isNull,
    );
  });

  test('a GIF that cannot play asks to go as a file', () async {
    final File big = write(
      'wielki.gif',
      Uint8List(kMaxSentGifBytes + 10)..setRange(0, 6, 'GIF89a'.codeUnits),
    );
    final OutgoingAttachment tooLarge = (await prepareOutgoing(
      TransferItem(name: 'wielki.gif', path: big.path),
    ))!;
    expect(tooLarge.kind, OutgoingKind.file);
    expect(tooLarge.gifProblem, PickedGifStatus.tooLarge);
    expect(tooLarge.path, big.path);

    final Uint8List gif = _gif();
    final OutgoingAttachment broken = (await prepareOutgoing(
      TransferItem(
        name: 'ucięty.gif',
        bytes: Uint8List.sublistView(gif, 0, gif.length - 6),
      ),
    ))!;
    expect(broken.gifProblem, PickedGifStatus.broken);
  });

  test('posts and the gallery take photos, GIFs and films only', () async {
    final File notes = write('plan.txt', 'plan'.codeUnits);
    final ({List<DraftMedia> media, String? error}) got =
        await draftMediaFromTransfer(<TransferItem>[
          TransferItem(name: 'kot.gif', bytes: _gif()),
          TransferItem(name: 'plan.txt', path: notes.path),
        ]);
    expect(got.media.single.mime, 'image/gif');
    expect(got.error, 'Tu można dodać tylko zdjęcia, GIF-y i filmy.');
  });

  test('event and flat photos stay still pictures (small JPEGs)', () {
    final Uint8List? photo = compressEventPhoto(_gif());
    expect(photo, isNotNull);
    expect(photo!.sublist(0, 3), <int>[0xFF, 0xD8, 0xFF]);
  });

  testWidgets('a drop goes to the area under it, else to the newest one', (
    WidgetTester tester,
  ) async {
    final _FakeTransfer fake = _FakeTransfer();
    MediaTransfer.platform = fake;
    final List<String> left = <String>[];
    final List<String> right = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Row(
          children: <Widget>[
            Expanded(
              child: MediaDropArea(
                onItems: (List<TransferItem> items) =>
                    left.addAll(items.map((TransferItem i) => i.name)),
                child: const SizedBox.expand(),
              ),
            ),
            Expanded(
              child: MediaDropArea(
                onItems: (List<TransferItem> items) =>
                    right.addAll(items.map((TransferItem i) => i.name)),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      ),
    );
    const TransferItem item = TransferItem(name: 'a.jpg', path: '/tmp/a.jpg');
    fake.controller.add(
      const MediaDrop(<TransferItem>[item], position: Offset(10, 10)),
    );
    await tester.pump();
    expect(left, <String>['a.jpg']);
    expect(right, isEmpty);

    fake.controller.add(const MediaDrop(<TransferItem>[item]));
    await tester.pump();
    expect(right, <String>['a.jpg']);
  });

  testWidgets('Ctrl+V sends a picture, and pastes text as usual', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      final _FakeTransfer fake = _FakeTransfer()
        ..clipboard = <TransferItem>[
          TransferItem(name: 'schowek.gif', bytes: _gif()),
        ];
      MediaTransfer.platform = fake;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async => call.method == 'Clipboard.getData'
            ? <String, Object?>{'text': 'hej'}
            : null,
      );
      final List<String> got = <String>[];
      final TextEditingController text = TextEditingController();
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaDropArea(
              onItems: (List<TransferItem> items) =>
                  got.addAll(items.map((TransferItem i) => i.name)),
              child: TextField(controller: text, autofocus: true),
            ),
          ),
        ),
      );
      await tester.pump();

      Future<void> pasteKeys() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
        await tester.pump();
      }

      await pasteKeys();
      expect(got, <String>['schowek.gif']);
      expect(fake.reads, <bool>[true]);
      expect(text.text, isEmpty);

      fake.clipboard = const <TransferItem>[];
      await pasteKeys();
      expect(got, hasLength(1));
      expect(text.text, 'hej');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a damaged GIF goes as a file only after asking', (
    WidgetTester tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (BuildContext c) {
              context = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    final Uint8List gif = _gif();
    final List<OutgoingAttachment> sent = <OutgoingAttachment>[];
    final Future<void> sending = sendTransferItems(context, <TransferItem>[
      TransferItem(name: 'dobry.gif', bytes: gif),
      TransferItem(
        name: 'zly.gif',
        bytes: Uint8List.sublistView(gif, 0, gif.length - 6),
      ),
    ], send: (OutgoingAttachment a) async => sent.add(a));
    await tester.pumpAndSettle();
    expect(sent.single.kind, OutgoingKind.gif);
    expect(find.byKey(const Key('gif-as-file-dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('gif-send-as-file')));
    await tester.pumpAndSettle();
    await sending;
    expect(sent.last.kind, OutgoingKind.file);
    expect(sent.last.fileName, 'zly.gif');
  });
}
