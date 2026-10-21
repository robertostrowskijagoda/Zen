import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/films/film_controller.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_pass.dart';
import 'package:zen/src/features/films/film_prefs.dart';
import 'package:zen/src/features/films/film_publish.dart';
import 'package:zen/src/features/films/film_trim.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/video_compressor.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Uint8List _box(String type, List<int> payload) {
  final int size = 8 + payload.length;
  return Uint8List.fromList(<int>[
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...type.codeUnits,
    ...payload,
  ]);
}

List<int> _u32(int v) => <int>[
  (v >> 24) & 0xFF,
  (v >> 16) & 0xFF,
  (v >> 8) & 0xFF,
  v & 0xFF,
];

/// A small MP4 (12.5 s, 720 × 1280) as an encoder would leave it.
Uint8List _film() => Uint8List.fromList(<int>[
  ..._box('ftyp', 'isom'.codeUnits),
  ..._box('moov', <int>[
    ..._box('mvhd', <int>[
      ...List<int>.filled(12, 0),
      ..._u32(1000),
      ..._u32(12500),
      ...List<int>.filled(80, 0),
    ]),
    ..._box('trak', <int>[
      ..._box('tkhd', <int>[
        ...List<int>.filled(40, 0),
        ..._u32(0x10000), ..._u32(0), ..._u32(0), //
        ..._u32(0), ..._u32(0x10000), ..._u32(0), //
        ..._u32(0), ..._u32(0), ..._u32(0x40000000),
        ..._u32(720 << 16),
        ..._u32(1280 << 16),
      ]),
      ..._box('mdia', <int>[
        ..._box('hdlr', <int>[
          ...List<int>.filled(8, 0),
          ...'vide'.codeUnits,
          ...List<int>.filled(12, 0),
        ]),
      ]),
    ]),
  ]),
  ..._box('mdat', List<int>.filled(4096, 9)),
]);

/// An encoder that writes a ready film and remembers what it was asked.
final class _FakeCompressor implements VideoCompressor {
  final List<String> calls = <String>[];

  @override
  Future<bool> available() async => true;

  @override
  Future<CompressedVideo> compress({
    required String input,
    required String output,
    required VideoCompressionPlan plan,
    int startMs = 0,
    int? endMs,
    VideoSource? source,
    void Function(double fraction)? onProgress,
  }) async {
    calls.add(
      'compress $startMs-$endMs ${plan.videoBitrate} '
      '${source?.width}x${source?.height}',
    );
    onProgress?.call(1);
    final Uint8List bytes = _film();
    await File(output).writeAsBytes(bytes);
    return CompressedVideo(
      path: output,
      durationMs: 12500,
      bytes: bytes.length,
      width: 720,
      height: 1280,
    );
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<Uint8List?> thumbnail(
    String input, {
    int atMs = 0,
    int maxSide = 480,
  }) async => null;
}

void main() {
  test(
    'a film is compressed, published, liked, passed on and watched',
    () async {
      final Directory dir = await Directory.systemTemp.createTemp('films');
      addTearDown(() => dir.delete(recursive: true));
      final String ada = PeerShareCodec.normalizeAddress('200::a');
      final String bob = PeerShareCodec.normalizeAddress('200::b');
      final Map<String, _Linked> nodes = <String, _Linked>{};
      Future<LedgerNode> make(String address, List<String> friends) async {
        final _Linked t = nodes[address] = _Linked(address, nodes);
        await t.start();
        final LedgerNode n = LedgerNode(
          transport: t,
          disk: MemoryLedgerDisk(),
          friendAddresses: () => friends,
          bridges: BridgeBook(probe: (String _) async => null),
        );
        addTearDown(n.stop);
        await n.start();
        return n;
      }

      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada]);
      final _FakeCompressor encoder = _FakeCompressor();
      final FilmsController onBob = FilmsController(
        node: b,
        disk: MemoryLedgerDisk(),
        nameOf: (String address) => 'Ada',
        compressor: encoder,
        temporaryPath: () async => '${dir.path}/out.mp4',
      );
      addTearDown(onBob.dispose);
      await onBob.start();
      expect(onBob.ready, isTrue);
      expect(onBob.films, isEmpty);

      final File recorded = File('${dir.path}/recorded.mp4');
      await recorded.writeAsBytes(_film());
      final List<FilmPublishStage> stages = <FilmPublishStage>[];
      await onBob.publish(
        FilmDraft(
          path: recorded.path,
          durationMs: 20000,
          trim: const FilmTrim(startMs: 2000, endMs: 14500),
          caption: '  Na skałkach ',
          audience: Audience.public,
        ),
        onProgress: (FilmPublishStage stage, double _) => stages.add(stage),
      );
      // The bridge learns the picture's size from the file's own index.
      expect(encoder.calls, <String>['compress 2000-14500 2500000 720x1280']);
      expect(stages, contains(FilmPublishStage.publishing));
      final FilmPost own = onBob.films[onBob.index];
      expect(own.isOwn, isTrue);
      expect(own.caption, 'Na skałkach');
      expect(own.video.durationMs, 12500);
      expect(own.width, 720);
      expect(b.blobs.isComplete(own.video.id), isTrue);
      await _settle();

      final FilmsController onAda = FilmsController(
        node: a,
        disk: MemoryLedgerDisk(),
        nameOf: (String address) => 'Bob',
        compressor: encoder,
      );
      await onAda.start();
      final FilmPost seen = onAda.films.single;
      expect(seen.authorLabel, 'Bob');
      // On screen: the film comes whole from its author.
      await _settle();
      expect(a.blobs.isComplete(seen.video.id), isTrue);

      expect(await onAda.toggleLike(seen), isNull);
      onAda.markWatched(seen);
      onAda.dispose();
      await _settle();
      // A liked public film of a friend goes on to the liker's friends.
      expect(passedFilmIds(a.entriesOf(spaceKind: 'acts')), <String>{seen.id});
      expect(seenFilms(a.entriesOf(spaceKind: 'acts')), <String>{seen.id});

      // The author sees the like and the view.
      await onBob.refresh();
      final FilmPost counted = onBob.films.firstWhere(
        (FilmPost f) => f.id == own.id,
      );
      expect(counted.likeCount, 1);
      expect(counted.views, 1);
    },
  );

  test('a film too long or too big does not go', () async {
    final Directory dir = await Directory.systemTemp.createTemp('films');
    addTearDown(() => dir.delete(recursive: true));
    final _Linked t = _Linked('200::9', <String, _Linked>{});
    await t.start();
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => const <String>[],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(n.stop);
    await n.start();
    final File recorded = File('${dir.path}/r.mp4');
    await recorded.writeAsBytes(_film());
    await expectLater(
      publishFilm(
        n,
        FilmDraft(
          path: recorded.path,
          durationMs: 200000,
          trim: const FilmTrim(startMs: 0, endMs: 120000),
        ),
        compressor: _FakeCompressor(),
        temporaryPath: () async => '${dir.path}/out.mp4',
      ),
      throwsArgumentError,
    );
    await expectLater(
      publishFilm(
        n,
        FilmDraft(
          path: recorded.path,
          durationMs: 12500,
          trim: const FilmTrim(startMs: 0, endMs: 12500),
          caption: 'x' * (kMaxFilmCaptionChars + 1),
        ),
        compressor: _FakeCompressor(),
        temporaryPath: () async => '${dir.path}/out.mp4',
      ),
      throwsArgumentError,
    );
  });

  test('the films remembered as watched are capped, oldest go', () {
    final FilmPrefs prefs = FilmPrefs();
    for (int i = 0; i < FilmPrefs.maxKept + 10; i++) {
      prefs.markWatched('f$i');
    }
    expect(prefs.watched, hasLength(FilmPrefs.maxKept));
    expect(prefs.watched.first, 'f10');
  });
}
