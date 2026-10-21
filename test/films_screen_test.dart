import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/films/film_controller.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_publish.dart';
import 'package:zen/src/features/films/film_trim.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/films/presentation/film_editor_screen.dart';
import 'package:zen/src/features/films/presentation/film_player.dart';
import 'package:zen/src/features/films/presentation/film_recorder_screen.dart';
import 'package:zen/src/features/films/presentation/films_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';

MediaRef _ref(String id) => MediaRef(
  id: id,
  key: Uint8List(32),
  nonce: Uint8List(12),
  mime: 'video/mp4',
);

FilmPost _film(
  String id, {
  String caption = '',
  List<String> replies = const <String>[],
}) => FilmPost(
  id: id,
  account: 'acc-$id',
  authorLabel: 'Autor $id',
  video: _ref('v-$id'),
  millis: DateTime.now().millisecondsSinceEpoch,
  isOwn: false,
  caption: caption,
  replies: replies,
);

/// Films in memory; records what the screen asked for.
final class _FakeBackend extends FilmsBackend {
  _FakeBackend(this._films);

  List<FilmPost> _films;
  int _index = 0;
  bool _muted = false;
  bool _fof = false;
  final List<String> calls = <String>[];

  @override
  bool get ready => true;

  @override
  List<FilmPost> get films => _films;

  @override
  int get index => _index;

  @override
  set index(int value) {
    _index = value;
    calls.add('index $value');
    notifyListeners();
  }

  @override
  bool get muted => _muted;

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    notifyListeners();
  }

  @override
  bool get friendsOfFriends => _fof;

  @override
  Future<void> setFriendsOfFriends(bool on) async {
    _fof = on;
    notifyListeners();
  }

  @override
  Future<bool> canCompress() async => true;

  void _replace(FilmPost f) {
    _films = <FilmPost>[for (final FilmPost x in _films) x.id == f.id ? f : x];
    notifyListeners();
  }

  @override
  Future<String?> toggleLike(FilmPost film) async {
    calls.add('like ${film.id}');
    _replace(
      film.copyWith(
        likedByMe: !film.likedByMe,
        likes: film.likedByMe
            ? const <FeedLiker>[]
            : const <FeedLiker>[FeedLiker(account: 'me', name: 'Ty')],
      ),
    );
    return null;
  }

  @override
  Future<String?> react(FilmPost film, String emoji) async {
    calls.add('react ${film.id} $emoji');
    return null;
  }

  @override
  Future<String?> comment(FilmPost film, String text) async {
    calls.add('comment ${film.id} $text');
    _replace(
      film.copyWith(
        comments: <FeedComment>[
          ...film.comments,
          FeedComment(id: 'c$text', authorLabel: 'Ty', text: text, millis: 1),
        ],
      ),
    );
    return null;
  }

  @override
  void markWatched(FilmPost film) => calls.add('watched ${film.id}');

  @override
  Future<String?> delete(FilmPost film) async => null;

  @override
  Future<Uint8List?> filmBytes(FilmPost film) async => null;

  @override
  Future<LogEntry> publish(
    FilmDraft draft, {
    FilmPublishProgress? onProgress,
  }) => throw UnimplementedError();

  @override
  Future<void> refresh() async {}

  @override
  void focus(String filmId) {
    calls.add('focus $filmId');
    _index = indexOf(filmId);
    notifyListeners();
  }
}

/// Stands in for the video: shows what it was asked.
Widget _fakePlayer(BuildContext context, FilmPlayerRequest r) => ColoredBox(
  color: Theme.of(context).colorScheme.scrim,
  child: Center(
    child: Text(
      '${r.film.id} ${r.active ? 'playing' : 'idle'}'
      '${r.paused ? ' paused' : ''}${r.muted ? ' muted' : ''}',
      key: Key('player-${r.film.id}'),
    ),
  ),
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(420, 860);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(child: MaterialApp(home: child)));
  await tester.pump();
}

/// A camera that records nothing but says it did.
final class _FakeCamera implements FilmCamera {
  final List<String> calls = <String>[];
  List<FilmLens> available = <FilmLens>[FilmLens.back, FilmLens.front];

  @override
  Future<List<FilmLens>> lenses() async => available;

  @override
  Future<void> open(FilmLens lens) async => calls.add('open ${lens.name}');

  @override
  bool get hasTorch => true;

  @override
  Future<void> setTorch(bool on) async => calls.add('torch $on');

  @override
  Widget preview() => const SizedBox.expand(key: Key('fake-preview'));

  @override
  Future<void> startRecording() async => calls.add('start');

  @override
  Future<String> stopRecording() async {
    calls.add('stop');
    return '/tmp/recorded.mp4';
  }

  @override
  Future<void> close() async => calls.add('close');
}

void main() {
  group('the pager', () {
    testWidgets('plays the film on screen and moves on with a swipe', (
      WidgetTester tester,
    ) async {
      final _FakeBackend backend = _FakeBackend(<FilmPost>[
        _film('one', caption: 'Pierwszy'),
        _film('two'),
      ]);
      await _pump(tester, FilmsScreen(backend: backend, player: _fakePlayer));

      expect(find.text('one playing'), findsOneWidget);
      expect(find.text('Pierwszy'), findsOneWidget);
      // The caption can be selected and copied.
      expect(
        find.byWidgetPredicate(
          (Widget w) => w is SelectableText && w.data == 'Pierwszy',
        ),
        findsOneWidget,
      );

      await tester.fling(
        find.byKey(const Key('films-pager')),
        const Offset(0, -600),
        2000,
      );
      await tester.pumpAndSettle();
      expect(backend.index, 1);
      expect(find.text('two playing'), findsOneWidget);
    });

    testWidgets('a tap pauses, holding pauses, the sound switches', (
      WidgetTester tester,
    ) async {
      final _FakeBackend backend = _FakeBackend(<FilmPost>[_film('one')]);
      await _pump(tester, FilmsScreen(backend: backend, player: _fakePlayer));

      await tester.tap(find.byKey(const Key('film-surface-one')));
      // The single tap waits for a possible second one.
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('one playing paused'), findsOneWidget);
      expect(find.byKey(const Key('film-paused-one')), findsOneWidget);
      await tester.tap(find.byKey(const Key('film-surface-one')));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('one playing'), findsOneWidget);

      final TestGesture hold = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('film-surface-one'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.text('one playing paused'), findsOneWidget);
      await hold.up();
      await tester.pump();
      expect(find.text('one playing'), findsOneWidget);

      await tester.tap(find.byKey(const Key('films-sound')));
      await tester.pump();
      expect(find.text('one playing muted'), findsOneWidget);
    });

    testWidgets('a double tap likes the film', (WidgetTester tester) async {
      final _FakeBackend backend = _FakeBackend(<FilmPost>[_film('one')]);
      await _pump(tester, FilmsScreen(backend: backend, player: _fakePlayer));

      final Finder surface = find.byKey(const Key('film-surface-one'));
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 300));
      expect(backend.calls, contains('like one'));
      expect(backend.films.single.likedByMe, isTrue);
      await tester.pump(const Duration(seconds: 1));

      // A second double tap does not take the like back.
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(surface);
      await tester.pump(const Duration(seconds: 1));
      expect(backend.calls.where((String c) => c == 'like one'), hasLength(1));
    });

    testWidgets('comments open in a sheet and a new one is sent', (
      WidgetTester tester,
    ) async {
      final _FakeBackend backend = _FakeBackend(<FilmPost>[_film('one')]);
      await _pump(tester, FilmsScreen(backend: backend, player: _fakePlayer));

      await tester.tap(find.byKey(const Key('film-comments-one')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('film-comments-sheet')), findsOneWidget);
      // Playing goes on under the sheet.
      expect(find.text('one playing'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('film-comment-field')),
        'Super',
      );
      await tester.tap(find.byKey(const Key('film-comment-send')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('comment one Super'));
      expect(find.text('Super'), findsOneWidget);
    });

    testWidgets('reactions and the answers of a film', (
      WidgetTester tester,
    ) async {
      final _FakeBackend backend = _FakeBackend(<FilmPost>[
        _film('one', replies: <String>['two']),
        _film('two'),
      ]);
      await _pump(tester, FilmsScreen(backend: backend, player: _fakePlayer));

      await tester.tap(find.byKey(const Key('film-react-one')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('film-reaction-🔥')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('react one 🔥'));

      await tester.tap(find.byKey(const Key('film-replies-one')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('film-reply-item-two')));
      await tester.pumpAndSettle();
      expect(backend.calls, contains('focus two'));
      expect(backend.index, 1);
    });

    testWidgets('watching long enough counts once the player says so', (
      WidgetTester tester,
    ) async {
      final _FakeBackend backend = _FakeBackend(<FilmPost>[_film('one')]);
      FilmPlayerRequest? asked;
      await _pump(
        tester,
        FilmsScreen(
          backend: backend,
          player: (BuildContext context, FilmPlayerRequest r) {
            asked = r;
            return const SizedBox.expand();
          },
        ),
      );
      asked!.onWatched();
      expect(backend.calls, contains('watched one'));
      expect(
        filmWatchedAfter(const Duration(seconds: 4)),
        const Duration(seconds: 2),
      );
      expect(
        filmWatchedAfter(const Duration(seconds: 30)),
        const Duration(seconds: 3),
      );
    });

    testWidgets('after the last film an end card; without films a prompt', (
      WidgetTester tester,
    ) async {
      final _FakeBackend backend = _FakeBackend(<FilmPost>[_film('one')]);
      await _pump(tester, FilmsScreen(backend: backend, player: _fakePlayer));
      await tester.fling(
        find.byKey(const Key('films-pager')),
        const Offset(0, -600),
        2000,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('films-end')), findsOneWidget);
      await tester.tap(find.byKey(const Key('films-again')));
      await tester.pumpAndSettle();
      expect(find.text('one playing'), findsOneWidget);

      await _pump(
        tester,
        FilmsScreen(
          key: const ValueKey<String>('empty'),
          backend: _FakeBackend(<FilmPost>[]),
          player: _fakePlayer,
        ),
      );
      expect(find.byKey(const Key('films-empty')), findsOneWidget);
    });
  });

  group('the recorder', () {
    Future<List<FilmRecording?>> openRecorder(
      WidgetTester tester,
      _FakeCamera camera, {
      String? picked,
    }) async {
      final List<FilmRecording?> got = <FilmRecording?>[];
      await _pump(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              got.add(
                await FilmRecorderScreen.open(
                  context,
                  camera: camera,
                  pickFile: () async => picked,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return got;
    }

    testWidgets('holding the button records, letting go finishes', (
      WidgetTester tester,
    ) async {
      final _FakeCamera camera = _FakeCamera();
      final List<FilmRecording?> got = await openRecorder(tester, camera);
      expect(find.byKey(const Key('fake-preview')), findsOneWidget);
      expect(camera.calls, contains('open back'));

      final TestGesture hold = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('film-recorder-record'))),
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(camera.calls, contains('start'));
      // Recording runs on the wall clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await hold.up();
      await tester.pumpAndSettle();
      expect(camera.calls, contains('stop'));
      expect(find.byKey(const Key('film-recorder')), findsNothing);
      expect(got.single?.path, '/tmp/recorded.mp4');
      expect(got.single!.recordedMs, greaterThanOrEqualTo(kFilmMinMs));
    });

    testWidgets('lenses switch, the torch lights, the limit is chosen', (
      WidgetTester tester,
    ) async {
      final _FakeCamera camera = _FakeCamera();
      await openRecorder(tester, camera);
      await tester.tap(find.byKey(const Key('film-recorder-flip')));
      await tester.pumpAndSettle();
      expect(camera.calls, contains('open front'));
      await tester.tap(find.byKey(const Key('film-recorder-torch')));
      await tester.pump();
      expect(camera.calls, contains('torch true'));
      await tester.tap(find.byKey(const Key('film-recorder-90')));
      await tester.pump();
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const Key('film-recorder-90')))
            .selected,
        isTrue,
      );
      await tester.tap(find.byKey(const Key('film-recorder-timer')));
      await tester.pump();
      expect(find.text(' 3 s'), findsOneWidget);
    });

    testWidgets('without a camera a film is picked from the disk', (
      WidgetTester tester,
    ) async {
      final _FakeCamera camera = _FakeCamera()..available = <FilmLens>[];
      final List<FilmRecording?> got = await openRecorder(
        tester,
        camera,
        picked: '/films/a.mp4',
      );
      expect(find.byKey(const Key('film-recorder-record')), findsNothing);
      await tester.tap(find.byKey(const Key('film-recorder-pick-empty')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('film-recorder')), findsNothing);
      expect(got.single?.path, '/films/a.mp4');
      expect(got.single!.recordedMs, 0);
    });
  });

  group('the editor', () {
    testWidgets('trims, limits the caption and publishes', (
      WidgetTester tester,
    ) async {
      FilmDraft? sent;
      bool? published;
      await _pump(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              published = await Navigator.of(context).push<bool>(
                MaterialPageRoute<bool>(
                  builder: (BuildContext _) => FilmEditorScreen(
                    path: '/films/a.mp4',
                    canTrim: true,
                    replyTo: const FilmReplyRef(id: 'orig', account: 'acc'),
                    replyToName: 'Ola',
                    preview:
                        (BuildContext context, String path, FilmTrim trim) =>
                            Text('preview ${trim.startMs}-${trim.endMs}'),
                    lengthOf: (String path) async => 120000,
                    publish:
                        (FilmDraft draft, FilmPublishProgress progress) async {
                          progress(FilmPublishStage.compressing, 0.5);
                          sent = draft;
                        },
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('preview 0-60000'), findsOneWidget);
      expect(find.byKey(const Key('film-editor-trim')), findsOneWidget);
      expect(find.text('0:00 – 1:00 (1:00)'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('film-editor-caption')),
        'x' * 200,
      );
      await tester.pump();
      final TextField field = tester.widget<TextField>(
        find.byKey(const Key('film-editor-caption')),
      );
      expect(field.controller!.text.length, kMaxFilmCaptionChars);

      await tester.tap(find.byKey(const Key('film-editor-audience-public')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('film-editor-publish')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('film-editor-publish')));
      await tester.pumpAndSettle();
      expect(sent, isNotNull);
      expect(sent!.trim, const FilmTrim(startMs: 0, endMs: 60000));
      expect(sent!.audience, Audience.public);
      expect(sent!.caption.length, kMaxFilmCaptionChars);
      expect(sent!.replyTo?.id, 'orig');
      expect(sent!.durationMs, 120000);
      expect(published, isTrue);
    });

    testWidgets('without an encoder there is nothing to trim', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FilmEditorScreen(
          path: '/films/a.mp4',
          canTrim: false,
          preview: (BuildContext context, String path, FilmTrim trim) =>
              const SizedBox(),
          lengthOf: (String path) async => 20000,
          publish: (FilmDraft draft, FilmPublishProgress progress) async {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('film-editor-trim')), findsNothing);
      expect(
        find.text('Na tym urządzeniu filmu nie da się przyciąć.'),
        findsOneWidget,
      );
    });
  });
}
