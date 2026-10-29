// The pictures of the user guide (docs/guide): the key screens at phone
// size, in English, in the Classic theme, light and dark, with sample
// people and content in English (friends, a conversation, posts, a video,
// a pyramid with its history, a flat door, dating profiles). Runs on the
// host, no device needed:
//
//   flutter test --no-pub tool/ui_tour/docs_screens_test.dart --update-goldens
//
// Writes docs/images/<screen>-light.png and docs/images/<screen>-dark.png
// (390 x 844 dp at 2x). Layout problems are printed and written to
// scratch/docs_screens/<mode>.txt (outside the repo). Texts that have no
// English translation yet show in Polish, so run it after the
// translations. DOCS_SCREENS_ONLY=dark renders one mode. Pictures and the
// video are made here from code, so every run draws the same thing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/neighbors/presentation/flat_door_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_timeline_view.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/runtime/runtime_deep_link_bridge.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import '../../test/support/pyramid_world.dart';

/// This device's mesh address and its flat door's (sample values).
const String _ownAddress = '200:5ee:d0c5:1a7e:4b2:91c3:7e10:2a4f';
const String _doorAddress = '201:3f8:c21d:66a0:9e47:b15:4c2:d813';

/// The day of the sample conversation, so its times never change.
final DateTime _chatDay = DateTime(2026, 10, 18);

Future<void> _loadFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final FontLoader loader = FontLoader(family);
    for (final String p in paths) {
      final File f = File(p);
      if (f.existsSync()) {
        loader.addFont(
          Future<ByteData>.value(
            ByteData.view(Uint8List.fromList(f.readAsBytesSync()).buffer),
          ),
        );
      }
    }
    await loader.load();
  }

  await load('Fredoka', <String>['assets/fonts/Fredoka-Variable.ttf']);
  await load('Quicksand', <String>[
    'assets/fonts/pebbles/Quicksand-Variable.ttf',
  ]);
  await load('Hanken Grotesk', <String>[
    'assets/fonts/HankenGrotesk-Variable.ttf',
  ]);
  await load('JetBrains Mono', <String>[
    'assets/fonts/JetBrainsMono-Variable.ttf',
  ]);
  await load('DM Sans', <String>['assets/fonts/DMSans-Variable.ttf']);
  await load('Space Mono', <String>[
    'assets/fonts/SpaceMono-Regular.ttf',
    'assets/fonts/SpaceMono-Bold.ttf',
  ]);
  final String root = Platform.environment['FLUTTER_ROOT'] ?? '';
  await load('MaterialIcons', <String>[
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

/// Text on screen, also inside rich text.
Finder _text(String part) => find.textContaining(part, findRichText: true);

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// A short conversation with Ada: read, delivered, queued and failed
/// messages, so the delivery icons show.
Map<String, List<ChatMessage>> _threads() {
  int at(int hour, int minute) => _chatDay
      .add(Duration(hours: hour, minutes: minute))
      .millisecondsSinceEpoch;
  return <String, List<ChatMessage>>{
    'ada.ygg': <ChatMessage>[
      ChatMessage(
        id: 'd1',
        sender: 'ada.ygg',
        text: 'Hi! A walk by the river tomorrow?',
        sentAtMillis: at(9, 12),
        direction: ChatMessageDirection.incoming,
      ),
      ChatMessage(
        id: 'd2',
        sender: 'self',
        text: 'Gladly. 10 am at the bridge?',
        sentAtMillis: at(9, 14),
        direction: ChatMessageDirection.outgoing,
        deliveryState: ChatMessageDeliveryState.delivered,
        readAtMillis: at(9, 15),
      ),
      ChatMessage(
        id: 'd3',
        sender: 'ada.ygg',
        text: "Deal. I'll bring a flask of tea.",
        sentAtMillis: at(9, 31),
        direction: ChatMessageDirection.incoming,
      ),
      ChatMessage(
        id: 'd4',
        sender: 'self',
        text: 'Great, see you tomorrow!',
        sentAtMillis: at(9, 33),
        direction: ChatMessageDirection.outgoing,
        deliveryState: ChatMessageDeliveryState.delivered,
      ),
      ChatMessage(
        id: 'd5',
        sender: 'self',
        text: 'PS: the forecast says sun all morning.',
        sentAtMillis: at(10, 2),
        direction: ChatMessageDirection.outgoing,
        deliveryState: ChatMessageDeliveryState.sent,
      ),
      ChatMessage(
        id: 'd6',
        sender: 'self',
        text: 'And bring the frisbee!',
        sentAtMillis: at(10, 3),
        direction: ChatMessageDirection.outgoing,
        deliveryState: ChatMessageDeliveryState.failed,
      ),
    ],
  };
}

/// Friends, a group and one notification, in English.
SocialHubState _people() {
  FriendProfile friend(
    String name,
    String preview,
    String when, {
    bool online = false,
    int unread = 0,
  }) => FriendProfile(
    address: '${name.toLowerCase()}.ygg',
    displayName: name,
    status: FriendRelationshipStatus.accepted,
    isOnline: online,
    lastMessagePreview: preview,
    lastActivityLabel: when,
    unreadCount: unread,
  );
  final List<FriendProfile> friends = <FriendProfile>[
    friend('Ada', 'And bring the frisbee!', '10:03', online: true),
    friend(
      'Ben',
      'Photos from the hike are in the group.',
      '9:41',
      online: true,
      unread: 2,
    ),
    friend('Chloe', 'Thanks for the soup recipe!', 'Yesterday'),
    friend('Dan', "I'll call you after work.", 'Yesterday', online: true),
    friend('Emma', 'Count me in for Saturday.', 'Mon'),
    friend('Finn', 'Ha, good one.', 'Sun'),
  ];
  return SocialHubState.preview().copyWith(
    book: FriendshipBook.restore(
      profiles: <String, FriendProfile>{
        for (final FriendProfile f in friends) f.address: f,
      },
    ),
    groups: <String, GroupProfile>{
      'docs-group-hikers': GroupProfile(
        id: 'docs-group-hikers',
        name: 'Weekend hikers',
        description: 'Trails, maps and lifts to the start',
        createdById: 'self',
        createdAtMillis: _chatDay.millisecondsSinceEpoch,
        memberAddresses: const <String>['ada.ygg', 'ben.ygg', 'emma.ygg'],
        lastMessagePreview: 'Ben: Saturday, 8 am at the station?',
        lastActivityLabel: '9:40',
        unreadCount: 1,
      ),
    },
    inbox: <InboxEntry>[
      InboxEntry(
        id: 'docs-request',
        type: InboxEntryType.friendRequest,
        title: 'Jake wants to be your friend',
        body: 'His note: "We met at the climbing wall on Saturday."',
        createdAtMillis: _chatDay.millisecondsSinceEpoch,
        routeKey: 'zen://inbox',
      ),
    ],
  );
}

/// A picture drawn from code: a sky in two colours, a sun and hills.
Uint8List _picture(
  int width,
  int height, {
  required List<int> top,
  required List<int> bottom,
  required List<int> sun,
  required List<int> hills,
}) {
  final img.Image image = img.Image(width: width, height: height);
  final double cx = width * 0.62;
  final double cy = height * 0.42;
  final double r = width * 0.15;
  for (int y = 0; y < height; y++) {
    final double k = y / (height - 1);
    for (int x = 0; x < width; x++) {
      final double hill =
          height * 0.70 + math.sin(x / width * math.pi * 2.2) * height * 0.05;
      final double dx = x - cx;
      final double dy = y - cy;
      final List<int> c;
      if (y > hill) {
        c = hills;
      } else if (dx * dx + dy * dy < r * r) {
        c = sun;
      } else {
        c = <int>[
          for (int i = 0; i < 3; i++)
            (top[i] + (bottom[i] - top[i]) * k).round(),
        ];
      }
      image.setPixelRgb(x, y, c[0], c[1], c[2]);
    }
  }
  return img.encodeJpg(image, quality: 82);
}

/// The smallest file the players take for an MP4: `ftyp`, `moov`, `mdat`.
Uint8List _tinyMp4() {
  final List<int> out = <int>[];
  void box(String type, List<int> body) {
    final int size = 8 + body.length;
    out
      ..addAll(<int>[
        size >> 24,
        (size >> 16) & 255,
        (size >> 8) & 255,
        size & 255,
      ])
      ..addAll(ascii.encode(type))
      ..addAll(body);
  }

  box('ftyp', <int>[
    ...ascii.encode('isom'),
    0,
    0,
    2,
    0,
    ...ascii.encode('isom'),
    ...ascii.encode('mp41'),
  ]);
  box('moov', const <int>[]);
  box('mdat', List<int>.filled(64, 0));
  return Uint8List.fromList(out);
}

/// Two dating profiles that fit this person, as if they had come through
/// friends, and this person's own profile (`dating/state`).
Map<String, dynamic> _datingState(int now) {
  String digest(Uint8List bytes) =>
      base64Url.encode(sha256.convert(bytes).bytes);
  SeenProfile seen(
    int n,
    String name,
    String about,
    String looking,
    List<String> interests,
    Uint8List photo, {
    required String friend,
    required String friendName,
  }) => SeenProfile(
    profile: DatingProfile(
      key: base64Url.encode(List<int>.filled(32, n)),
      name: name,
      gender: DatingGender.woman,
      at: now - n * 3600 * 1000,
      about: about,
      lookingFor: looking,
      wants: const DatingWants(genders: <DatingGender>{DatingGender.man}),
      interests: interests,
      photoDigests: <String>[digest(photo)],
      photoSlots: <String>[base64Encode(photo)],
    ),
    replyTo: 'docs-route-$n',
    at: now - n * 3600 * 1000,
    friend: friend,
    path: <String>[friendName],
    distance: 2,
    mutual: <String>[friend],
  );
  return <String, dynamic>{
    'me': MyDating(
      enabled: true,
      name: 'Robert',
      gender: DatingGender.man,
      about: 'Mountains, board games and cooking for friends.',
      lookingFor: 'Someone for weekend trips and long talks.',
      wants: const DatingWants(genders: <DatingGender>{DatingGender.woman}),
      interests: <String>['hiking', 'board games', 'cooking'],
    ).toJson(),
    'profiles': <Map<String, dynamic>>[
      seen(
        1,
        'Julia',
        'Architect, early riser, happiest on a mountain trail or in a '
            'small cinema. I bake bread on Sundays.',
        'Someone curious who likes long walks and longer talks.',
        <String>['hiking', 'cinema', 'baking'],
        _picture(
          300,
          400,
          top: <int>[255, 183, 125],
          bottom: <int>[255, 236, 210],
          sun: <int>[255, 244, 214],
          hills: <int>[94, 120, 92],
        ),
        friend: 'ada.ygg',
        friendName: 'Ada',
      ).toJson(),
      seen(
        2,
        'Sophie',
        'Nurse, cyclist and a terrible but enthusiastic singer.',
        'A friend for bike trips who might become more.',
        <String>['cycling', 'music', 'travel'],
        _picture(
          300,
          400,
          top: <int>[120, 170, 230],
          bottom: <int>[220, 236, 250],
          sun: <int>[255, 250, 230],
          hills: <int>[70, 110, 140],
        ),
        friend: 'ben.ygg',
        friendName: 'Ben',
      ).toJson(),
    ],
  };
}

/// A small pyramid with a history: thirteen people admitted, Gus swaps
/// places with his head Chris, Eli leaves, Gus and Chris remove Hana.
const List<(String, String?, String)> _tree = <(String, String?, String)>[
  ('Olivia', null, ''),
  ('Adam', 'Olivia', '0'),
  ('Beth', 'Olivia', '1'),
  ('Chris', 'Adam', '00'),
  ('Dana', 'Adam', '01'),
  ('Eli', 'Beth', '10'),
  ('Fay', 'Beth', '11'),
  ('Gus', 'Chris', '000'),
  ('Hana', 'Chris', '001'),
  ('Ivan', 'Dana', '010'),
  ('Jade', 'Dana', '011'),
  ('Kai', 'Fay', '110'),
  ('Lena', 'Fay', '111'),
];

Future<(FoldWorld, PyramidState)> _history() async {
  const int t0 = FoldWorld.t0;
  const int day = FoldWorld.day;
  final FoldWorld w = await FoldWorld.make(tree: _tree);
  final PyramidState st = w.fold(<PyramidRecord>[
    await w.rec(
      PyrT.swap,
      t0 + day,
      <String>['Gus', 'Hana'],
      <String, dynamic>{'cell': '00', 'head': w.id('Chris'), 'up': w.id('Gus')},
    ),
    await w.rec(
      PyrT.leave,
      t0 + 2 * day,
      <String>['Eli'],
      <String, dynamic>{'k': w.id('Eli')},
    ),
    await w.rec(
      PyrT.remove,
      t0 + 3 * day,
      <String>['Gus', 'Chris'],
      <String, dynamic>{'k': w.id('Hana')},
    ),
  ]);
  return (w, st);
}

void main() {
  setUpAll(_loadFonts);

  final String only = Platform.environment['DOCS_SCREENS_ONLY'] ?? '';
  for (final Brightness brightness in Brightness.values) {
    final bool dark = brightness == Brightness.dark;
    final String mode = dark ? 'dark' : 'light';
    if (only.isNotEmpty && only != mode) {
      continue;
    }
    testWidgets('docs screens $mode', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(390 * 2.0, 844 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      // The guide is in English.
      await tester.runAsync(() => ZenI18n.load('en'));
      // Films play through a still player (the poster shows), and their
      // plain copy goes to a temporary folder of this run.
      final VideoPlayerPlatform player = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = _StillVideoPlayer();
      addTearDown(() => VideoPlayerPlatform.instance = player);
      final Directory temp = Directory.systemTemp.createTempSync('zen_docs_');
      addTearDown(() {
        try {
          temp.deleteSync(recursive: true);
        } on FileSystemException {
          // Left for the system to clean.
        }
      });
      const MethodChannel paths = MethodChannel(
        'plugins.flutter.io/path_provider',
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(paths, (
        MethodCall call,
      ) async {
        if (call.method == 'getTemporaryDirectory') {
          return temp.path;
        }
        throw MissingPluginException();
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          paths,
          null,
        ),
      );
      // Dating profiles that came through friends, before the app reads
      // them.
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      disk.files['dating/state'] = Uint8List.fromList(
        utf8.encode(
          jsonEncode(_datingState(DateTime.now().millisecondsSinceEpoch)),
        ),
      );

      final List<String> problems = <String>[];
      String where = 'start';
      final FlutterExceptionHandler? original = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails d) {
        problems.add(
          '[$mode] $where: ${d.exceptionAsString().split('\n').first}',
        );
      };

      // This device and its friends' ledgers, linked in memory: friends'
      // posts reach the feed the way they do over the network.
      final Map<String, _LinkedTransport> links = <String, _LinkedTransport>{};
      final String me = PeerShareCodec.normalizeAddress(_ownAddress);
      final _LinkedTransport mine = links[me] = _LinkedTransport(me, links);
      await mine.start();

      final ProviderContainer container = ProviderContainer(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          deepLinkSourceProvider.overrideWithValue(_NoDeepLinks()),
          signalTransportProvider.overrideWithValue(mine),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(disk),
          socialHubSeedProvider.overrideWithValue(_people()),
          // The flat's door needs this device's address and a door
          // address, which come from the network in the app.
          neighborsServiceProvider.overrideWith((Ref ref) {
            final MeetService meet = ref.watch(meetServiceProvider);
            final NeighborsService neighbors = NeighborsService(
              host: MeetEventHost(
                meet.host,
                address: () => _ownAddress,
                name: () => 'Robert',
              ),
              disk: ref.read(ledgerDiskProvider),
              doorInbox: () => _doorAddress,
            );
            unawaited(neighbors.load());
            ref.onDispose(neighbors.dispose);
            return neighbors;
          }),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(_threads()),
          ),
          appSettingsInitialStateProvider.overrideWithValue(
            AppSettings(
              themeMode: dark ? AppThemeMode.dark : AppThemeMode.light,
            ),
          ),
        ],
      );
      bool disposed = false;
      void disposeContainer() {
        if (!disposed) {
          disposed = true;
          container.dispose();
        }
      }

      addTearDown(disposeContainer);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ZenRewriteApp(),
        ),
      );
      await _settle(tester, 12);

      // Sample data. Started in the test's zone (the services were made
      // there), with real time in between for isolates and timers outside.
      Future<void> seed(String what, Future<void> Function() body) async {
        where = 'seed $what';
        bool done = false;
        Object? error;
        unawaited(
          body().then(
            (_) => done = true,
            onError: (Object e) {
              error = e;
              done = true;
            },
          ),
        );
        for (int i = 0; i < 400 && !done; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (!done) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
          }
        }
        if (!done) {
          problems.add('[$mode] seed $what: did not finish');
        } else if (error != null) {
          problems.add('[$mode] seed $what failed: $error');
        }
        await _settle(tester, 2);
      }

      final List<LedgerNode> friendLedgers = <LedgerNode>[];
      await seed('friends\' posts', () async {
        Future<void> postsOf(String name, List<String> texts) async {
          final String address = PeerShareCodec.normalizeAddress(
            '${name.toLowerCase()}.ygg',
          );
          final _LinkedTransport transport = links[address] = _LinkedTransport(
            address,
            links,
          );
          await transport.start();
          final LedgerNode node = LedgerNode(
            transport: transport,
            disk: MemoryLedgerDisk(),
            friendAddresses: () => <String>[me],
            deviceName: '$name phone',
            bridges: BridgeBook(probe: (String _) async => null),
          );
          friendLedgers.add(node);
          await node.start();
          for (final String text in texts) {
            await node.publish(kPostKind, newPostBody(text));
          }
        }

        await postsOf('Emma', <String>[
          'Thank you all for the bonfire last night: quiet, warm and very '
              'much us.',
        ]);
        await postsOf('Ben', <String>[
          'First frost at the allotment. Anyone up for autumn tidying on '
              'Saturday? There will be pumpkin soup.',
        ]);
      });
      await seed('pyramid', () async {
        await container
            .read(pyramidServiceProvider)
            .found(myName: 'Robert', nat: 'PL', birthYear: 1990, gender: 'm');
        await container
            .read(pyramidServiceProvider)
            .post(
              'Cell meeting on Saturday at 6 pm in the park. Bring a snack!',
            );
      });
      await seed('flat', () async {
        await container
            .read(neighborsServiceProvider)
            .createFlat(
              'The Smiths',
              place: 'Flat 5, 2nd floor',
              about: 'A family with two kids and a dog. Happy to lend a drill.',
            );
      });
      await seed('video', () async {
        final LedgerNode? node = container.read(ledgerNodeProvider);
        if (node == null) {
          return;
        }
        final Map<String, dynamic> video = await storeMedia(
          node.blobs,
          _tinyMp4(),
          mime: 'video/mp4',
          durationMs: 14000,
        );
        final Map<String, dynamic> poster = await storeMedia(
          node.blobs,
          _picture(
            360,
            640,
            top: <int>[255, 140, 105],
            bottom: <int>[255, 214, 170],
            sun: <int>[255, 246, 220],
            hills: <int>[60, 82, 110],
          ),
        );
        await node.publish(
          kFilmKind,
          await node.seal(
            Audience.all,
            newFilmBody(
              video: video,
              caption: 'Sunrise over the lake this morning.',
              poster: poster,
              width: 720,
              height: 1280,
            ),
          ),
        );
      });
      late FoldWorld world;
      late PyramidState history;
      await tester.runAsync(() async {
        (world, history) = await _history();
      });

      // Some screens fill in from work outside the test's clock (decrypting,
      // isolates): real time in small steps until [ready] shows.
      Future<void> until(Finder ready) async {
        for (int i = 0; i < 80 && ready.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (ready.evaluate().isEmpty) {
          problems.add('[$mode] $where: never showed $ready');
        }
      }

      Future<void> shot(String name, {Finder? ready}) async {
        where = name;
        // ignore: avoid_print
        print('[docs $mode] $name');
        await _settle(tester);
        if (ready != null) {
          await until(ready);
          // Pictures decode outside the test's clock too.
          for (int i = 0; i < 10; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          await _settle(tester);
        }
        await expectLater(
          find.byType(MaterialApp).first,
          matchesGoldenFile('../../docs/images/$name-$mode.png'),
        );
      }

      Future<bool> tap(Finder f) async {
        if (f.evaluate().isEmpty) {
          problems.add('[$mode] $where: not found: $f');
          return false;
        }
        await tester.ensureVisible(f.first);
        await tester.pump();
        await tester.tap(f.first, warnIfMissed: false);
        await _settle(tester);
        return true;
      }

      NavigatorState nav() =>
          tester.state<NavigatorState>(find.byType(Navigator).first);

      Future<void> page(
        String name,
        Widget Function() build, {
        Finder? ready,
      }) async {
        where = name;
        unawaited(nav().push(MaterialPageRoute<void>(builder: (_) => build())));
        await shot(name, ready: ready);
        nav().pop();
        await _settle(tester);
      }

      // The tabs of the rail, each with what must be on it.
      for (final (String tab, String name, Finder? ready)
          in <(String, String, Finder?)>[
            ('chats', 'shell', null),
            ('graph', 'graph', null),
            ('feed', 'feed', _text('pumpkin soup')),
            (
              'films',
              'films',
              find.byWidgetPredicate(
                (Widget w) => w is Image && w.image is MemoryImage,
              ),
            ),
            ('meet', 'meet', null),
            ('dating', 'dating', _text('Julia')),
            ('pyramid', 'pyramid', null),
            ('wallet', 'wallet', null),
          ]) {
        where = 'tab $tab';
        if (await tap(find.byKey(Key('side-tab-$tab')))) {
          await shot(name, ready: ready);
        }
      }
      await tap(find.byKey(const Key('side-tab-chats')));

      await page(
        'chat',
        () => const ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
      );
      await page(
        'neighbours-door',
        () => const FlatDoorScreen(),
        ready: _text('The Smiths'),
      );

      // The pyramid's places through time: now, then halfway back with
      // one person picked.
      final String gus = world.id('Gus');
      Widget timeline() => Scaffold(
        appBar: AppBar(title: Text(t('Miejsca w czasie'))),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[PyramidTimelineView(s: history, me: gus)],
        ),
      );
      await page('pyramid-tree', timeline);
      where = 'pyramid-history';
      unawaited(
        nav().push(MaterialPageRoute<void>(builder: (_) => timeline())),
      );
      await _settle(tester);
      final Finder slider = find.byKey(const Key('pyr-timeline-slider'));
      if (slider.evaluate().isNotEmpty) {
        tester.widget<Slider>(slider).onChanged!(14);
        await tester.pump();
        await tap(find.byKey(ValueKey<String>('pyr-tl-${world.id('Chris')}')));
        await shot('pyramid-history');
      } else {
        problems.add('[$mode] pyramid-history: no slider');
      }
      nav().pop();
      await _settle(tester);

      // The settings, then the theme picker (Settings -> Appearance).
      where = 'settings';
      if (await tap(find.byKey(const Key('chats-status-chip')))) {
        await shot('settings');
        // Appearance is further down the list, built only when near.
        where = 'themes';
        final Finder appearance = find.byKey(
          const Key('settings-nav-appearance'),
        );
        final Finder list = find.descendant(
          of: find.byKey(const Key('settings-tab-body')),
          matching: find.byType(Scrollable),
        );
        if (list.evaluate().isNotEmpty) {
          try {
            await tester.scrollUntilVisible(
              appearance,
              220,
              scrollable: list.first,
            );
          } on StateError catch (e) {
            problems.add('[$mode] themes: $e');
          }
          await tester.pump();
        }
        if (await tap(appearance)) {
          await shot('themes');
        }
      }

      for (final LedgerNode node in friendLedgers) {
        await seed('stop ${node.deviceName}', node.stop);
      }

      // The test must end with no timer pending: take the app down, drop
      // its providers and let what is still scheduled run out.
      await tester.pumpWidget(const SizedBox.shrink());
      disposeContainer();
      await tester.pump(const Duration(minutes: 10));
      await tester.pump(const Duration(minutes: 10));

      FlutterError.onError = original;
      final Set<String> unique = <String>{...problems};
      final StringBuffer out = StringBuffer(
        '=== docs $mode: ${unique.length} problem(s)\n',
      );
      for (final String p in unique) {
        out.writeln(p);
      }
      Directory('scratch/docs_screens').createSync(recursive: true);
      File('scratch/docs_screens/$mode.txt').writeAsStringSync(out.toString());
      // ignore: avoid_print
      print(out);
    });
  }
}

/// No platform plugin in widget tests: the deep-link source never emits.
final class _NoDeepLinks implements DeepLinkSource {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get linkStream => const Stream<Uri>.empty();
}

/// A player that takes every film and shows nothing over its poster, as
/// the first frame of a film looks: the test host has no video decoder.
final class _StillVideoPlayer extends VideoPlayerPlatform {
  final Map<int, StreamController<VideoEvent>> _events =
      <int, StreamController<VideoEvent>>{};
  int _next = 1;

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final int id = _next++;
    final StreamController<VideoEvent> events = StreamController<VideoEvent>();
    _events[id] = events;
    events.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 14),
        size: const Size(720, 1280),
        rotationCorrection: 0,
      ),
    );
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      _events[playerId]?.stream ?? const Stream<VideoEvent>.empty();

  @override
  Future<void> dispose(int playerId) async {
    await _events.remove(playerId)?.close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async =>
      const Duration(seconds: 5);

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.shrink();
}

/// A transport that hands what is sent straight to the linked transport of
/// that address (friends' ledgers in this test).
final class _LinkedTransport extends MemorySignalTransport {
  _LinkedTransport(this.address, this.links);

  final String address;
  final Map<String, _LinkedTransport> links;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _LinkedTransport? target =
        links[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}
