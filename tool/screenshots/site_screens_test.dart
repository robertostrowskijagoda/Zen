// The website's pictures and short films (tool/pages/shots), rendered from
// the real app with a demo account (demo_account.dart): made-up people with
// drawn faces, chats with a photo, a voice message and reactions, a group,
// posts, the friends graph and its timeline, people passed nearby, the
// settings and the lock screen. Runs on the host, no device needed; use
//
//   dart run tool/screenshots.dart
//
// which runs this once per language (SHOTS_LANG=pl|en) and then encodes
// the frames (encode.py). This file only renders: it writes full-size PNG
// frames to build/shots/<lang>/ (shots.dart has the list). SHOTS_ONLY=
// light|dark|phone|desktop|lock narrows a run. Layout problems are printed
// and written to build/shots/<lang>/problems-<theme>.txt.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/graph/graph_notes.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/nearby_screen.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_deep_link_bridge.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/storage_breakdown.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'demo_account.dart';
import 'shots.dart';

const int _day = 24 * 3600 * 1000;

/// Midnight starting yesterday: the conversation's day, so its times and
/// its "Yesterday" never change from run to run.
DateTime _yesterday() {
  final DateTime now = DateTime.now();
  return DateTime(now.year, now.month, now.day - 1);
}

/// A colour emoji font of this computer, if it has one: drawn in place of
/// "DM Sans", the second fallback of the app's text after Hanken Grotesk
/// (which has every letter of these languages), so that reactions show
/// their emoji. The test host has no font fallback of its own.
const List<String> _emojiFonts = <String>[
  'C:/Windows/Fonts/seguiemj.ttf',
  '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
  '/usr/share/fonts/noto/NotoColorEmoji.ttf',
  '/usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf',
];

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
  await load('Hanken Grotesk', <String>[
    'assets/fonts/HankenGrotesk-Variable.ttf',
  ]);
  await load('JetBrains Mono', <String>[
    'assets/fonts/JetBrainsMono-Variable.ttf',
  ]);
  final String emoji = _emojiFonts.firstWhere(
    (String p) => File(p).existsSync(),
    orElse: () => 'assets/fonts/DMSans-Variable.ttf',
  );
  await load('DM Sans', <String>[emoji]);
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

/// The conversation with the first friend: a photo, a voice message,
/// reactions and every delivery state of a sent message.
List<ChatMessage> _conversation(DemoAccount demo) {
  final DateTime day = _yesterday();
  int at(int hour, int minute) =>
      day.add(Duration(hours: hour, minutes: minute)).millisecondsSinceEpoch;
  final String friend = demo.friends[0].address;
  return <ChatMessage>[
    ChatMessage(
      id: 'c1',
      sender: friend,
      text: demo.text('c1'),
      sentAtMillis: at(18, 2),
      direction: ChatMessageDirection.incoming,
      type: ChatMessageType.image,
      attachmentBytes: lakePhoto(),
      mimeType: 'image/jpeg',
      reactions: const <String, String>{'self': '❤️'},
    ),
    ChatMessage(
      id: 'c2',
      sender: 'self',
      text: demo.text('c2'),
      sentAtMillis: at(18, 5),
      direction: ChatMessageDirection.outgoing,
      deliveryState: ChatMessageDeliveryState.delivered,
      readAtMillis: at(18, 6),
    ),
    ChatMessage(
      id: 'c3',
      sender: friend,
      text: '',
      sentAtMillis: at(18, 9),
      direction: ChatMessageDirection.incoming,
      type: ChatMessageType.voice,
      attachmentBytes: Uint8List(512),
      mimeType: 'audio/mp4',
      durationMs: 14000,
    ),
    ChatMessage(
      id: 'c4',
      sender: 'self',
      text: demo.text('c4'),
      sentAtMillis: at(18, 12),
      direction: ChatMessageDirection.outgoing,
      deliveryState: ChatMessageDeliveryState.delivered,
      readAtMillis: at(18, 13),
      reactions: <String, String>{friend: '👍'},
    ),
    ChatMessage(
      id: 'c5',
      sender: friend,
      text: demo.text('c5'),
      sentAtMillis: at(18, 14),
      direction: ChatMessageDirection.incoming,
      reactions: const <String, String>{'self': '😂'},
    ),
    ChatMessage(
      id: 'c6',
      sender: 'self',
      text: demo.text('c6'),
      sentAtMillis: at(18, 15),
      direction: ChatMessageDirection.outgoing,
      deliveryState: ChatMessageDeliveryState.delivered,
    ),
  ];
}

const String _groupId = 'demo-group-hikers';

/// The group's chat: four people, a photo and reactions.
List<ChatMessage> _groupChat(DemoAccount demo) {
  final DateTime day = _yesterday();
  int at(int hour, int minute) =>
      day.add(Duration(hours: hour, minutes: minute)).millisecondsSinceEpoch;
  final List<DemoPerson> f = demo.friends;
  return <ChatMessage>[
    ChatMessage(
      id: 'g1',
      sender: f[1].address,
      text: demo.text('g1'),
      sentAtMillis: at(19, 30),
      direction: ChatMessageDirection.incoming,
    ),
    ChatMessage(
      id: 'g1p',
      sender: f[1].address,
      text: '',
      sentAtMillis: at(19, 31),
      direction: ChatMessageDirection.incoming,
      type: ChatMessageType.image,
      attachmentBytes: hillsPhoto(),
      mimeType: 'image/jpeg',
      reactions: <String, String>{
        'self': '🔥',
        f[2].address: '🔥',
        f[4].address: '😮',
      },
    ),
    ChatMessage(
      id: 'g2',
      sender: f[2].address,
      text: demo.text('g2'),
      sentAtMillis: at(19, 40),
      direction: ChatMessageDirection.incoming,
    ),
    ChatMessage(
      id: 'g3',
      sender: 'self',
      text: demo.text('g3'),
      sentAtMillis: at(19, 42),
      direction: ChatMessageDirection.outgoing,
      deliveryState: ChatMessageDeliveryState.delivered,
      reactions: <String, String>{f[1].address: '👍', f[2].address: '🙏'},
    ),
    ChatMessage(
      id: 'g4',
      sender: f[4].address,
      text: demo.text('g4'),
      sentAtMillis: at(19, 50),
      direction: ChatMessageDirection.incoming,
    ),
    ChatMessage(
      id: 'g5',
      sender: f[1].address,
      text: demo.text('g5'),
      sentAtMillis: at(19, 52),
      direction: ChatMessageDirection.incoming,
      reactions: <String, String>{'self': '❤️', f[4].address: '❤️'},
    ),
  ];
}

/// Friends with their faces, presence and last messages; the group.
SocialHubState _people(DemoAccount demo, Directory faces) {
  final int now = DateTime.now().millisecondsSinceEpoch;
  const List<PeerPresence> presence = <PeerPresence>[
    PeerPresence.online,
    PeerPresence.online,
    PeerPresence.background,
    PeerPresence.offline,
    PeerPresence.online,
    PeerPresence.offline,
    PeerPresence.background,
  ];
  final List<String> when = <String>[
    '18:15',
    '17:40',
    '16:02',
    demo.text('yesterday'),
    demo.text('yesterday'),
    demo.text('mon'),
    demo.text('sun'),
  ];
  const List<int> unread = <int>[0, 2, 0, 1, 0, 0, 0];
  final Map<String, FriendProfile> friends = <String, FriendProfile>{};
  final Map<String, PeerPublicProfile> profiles = <String, PeerPublicProfile>{};
  for (int i = 0; i < demo.friends.length; i++) {
    final DemoPerson p = demo.friends[i];
    final String address = PeerShareCodec.normalizeAddress(p.address);
    friends[address] = FriendProfile(
      address: address,
      displayName: p.name,
      status: FriendRelationshipStatus.accepted,
      isOnline: presence[i] == PeerPresence.online,
      lastPresenceAtMillis: now,
      presence: presence[i],
      presenceAtMillis: now,
      lastMessagePreview: demo.text('l$i'),
      lastActivityLabel: when[i],
      unreadCount: unread[i],
    );
    final File face = File('${faces.path}/face-${p.index}.png')
      ..writeAsBytesSync(drawAvatar(p));
    profiles[address] = PeerPublicProfile(
      address: address,
      version: 1,
      name: p.name,
      avatarPath: face.path,
    );
  }
  final List<DemoPerson> f = demo.friends;
  return SocialHubState.preview().copyWith(
    friends: friends,
    peerProfiles: profiles,
    groups: <String, GroupProfile>{
      _groupId: GroupProfile(
        id: _groupId,
        name: demo.text('group'),
        description: demo.text('groupAbout'),
        createdById: 'self',
        createdAtMillis: _yesterday().millisecondsSinceEpoch - 30 * _day,
        memberAddresses: <String>[
          for (final int i in <int>[1, 2, 4])
            PeerShareCodec.normalizeAddress(f[i].address),
        ],
        memberNames: <String, String>{
          for (final int i in <int>[1, 2, 4])
            PeerShareCodec.normalizeAddress(f[i].address): f[i].name,
        },
        lastMessagePreview: '${f[1].name}: ${demo.text('g5')}',
        lastActivityLabel: '19:52',
        unreadCount: 3,
      ),
    },
    inbox: const <InboxEntry>[],
  );
}

/// The dates the friends graph grew by (kept on this phone).
Map<String, dynamic> _graphNotes(DemoAccount demo) {
  final int now = DateTime.now().millisecondsSinceEpoch;
  final int start = now - now % _day;
  return <String, dynamic>{
    'v': 1,
    'b': start - 360 * _day,
    'fs': <String, int>{
      for (int i = 0; i < demo.friends.length; i++)
        PeerShareCodec.normalizeAddress(demo.friends[i].address):
            start - DemoAccount.friendDaysAgo[i] * _day,
    },
    'ff': <String, int>{
      for (int i = 0; i < demo.far.length; i++)
        PeerShareCodec.normalizeAddress(demo.far[i].address):
            start - DemoAccount.farDaysAgo[i] * _day,
    },
  };
}

/// What the renderer needs to know about one run.
final class _Run {
  _Run(this.lang, this.theme, this.size);

  final String lang;
  final String theme;
  final ShotSize size;

  bool get dark => theme == 'dark';

  final List<String> problems = <String>[];
  String where = 'start';

  String get dir => '$kShotsRawDir/$lang';
}

/// Writes what is on screen as a PNG of the full size.
Future<void> _capture(WidgetTester tester, String path) async {
  final ui.Image image = await captureImage(
    find.byType(MaterialApp).first.evaluate().single,
  );
  await tester.runAsync(() async {
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final File file = File(path)..parent.createSync(recursive: true);
    file.writeAsBytesSync(png!.buffer.asUint8List());
  });
  image.dispose();
}

void main() {
  setUpAll(_loadFonts);

  final String lang = Platform.environment['SHOTS_LANG'] ?? 'en';
  final Set<String> only = <String>{
    for (final String s in (Platform.environment['SHOTS_ONLY'] ?? '').split(
      ',',
    ))
      if (s.trim().isNotEmpty) s.trim(),
  };
  // Each list narrows only when SHOTS_ONLY names one of its words.
  Iterable<String> narrowed(List<String> all) {
    final Iterable<String> picked = all.where(only.contains);
    return picked.isEmpty ? all : picked;
  }

  for (final String theme in narrowed(kShotThemes)) {
    for (final String kind in narrowed(const <String>[
      'phone',
      'desktop',
      'lock',
    ])) {
      testWidgets('site screens $lang $theme $kind', (WidgetTester tester) {
        return _app(
          tester,
          _Run(
            lang,
            theme,
            kind == 'desktop' ? ShotSize.desktop : ShotSize.phone,
          ),
          locked: kind == 'lock',
        );
      });
    }
  }
}

/// Starts the app with the demo account and walks through the screens of
/// [run] (with [locked], only the lock screen).
Future<void> _app(WidgetTester tester, _Run run, {bool locked = false}) async {
  final DemoAccount demo = DemoAccount.of(run.lang);
  final Brightness brightness = run.dark ? Brightness.dark : Brightness.light;
  tester.view.physicalSize = Size(
    run.size.pixelWidth * 1.0,
    run.size.pixelHeight * 1.0,
  );
  tester.view.devicePixelRatio = run.size.ratio;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  await tester.runAsync(() => ZenI18n.load(run.lang));

  final Directory temp = Directory.systemTemp.createTempSync('zen_shots_');
  addTearDown(() {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Left for the system to clean.
    }
  });
  const MethodChannel paths = MethodChannel('plugins.flutter.io/path_provider');
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

  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  disk.files[GraphNotesService.storeKey] = Uint8List.fromList(
    utf8.encode(jsonEncode(_graphNotes(demo))),
  );

  final FlutterExceptionHandler? original = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails d) {
    run.problems.add(
      '[${run.theme} ${run.size.name}] ${run.where}: '
      '${d.exceptionAsString().split('\n').first}',
    );
  };

  // This person's own name and face.
  final File ownFace = File('${temp.path}/face-0.png')
    ..writeAsBytesSync(drawAvatar(DemoPerson(0, demo.me, demoOwnPalette)));
  final MemoryUserProfileStore ownProfile = MemoryUserProfileStore();
  await ownProfile.save(
    UserProfile(displayName: demo.me, avatarPath: ownFace.path),
  );

  final Map<String, _LinkedTransport> links = <String, _LinkedTransport>{};
  final String me = PeerShareCodec.normalizeAddress(demo.ownAddress);
  final _LinkedTransport mine = links[me] = _LinkedTransport(me, links);
  await mine.start();

  final ProviderContainer container = ProviderContainer(
    overrides: [
      socialHubAutoHydrateProvider.overrideWithValue(false),
      deepLinkSourceProvider.overrideWithValue(_NoDeepLinks()),
      signalTransportProvider.overrideWithValue(mine),
      ledgerNodeEnabledProvider.overrideWithValue(true),
      ledgerDiskProvider.overrideWithValue(disk),
      socialHubSeedProvider.overrideWithValue(_people(demo, temp)),
      circleReminderProvider.overrideWithValue(false),
      userProfileStoreProvider.overrideWithValue(ownProfile),
      supportDirectoryResolverProvider.overrideWithValue(() async => temp),
      // The folders of the account are not on this computer: what a few
      // months of use takes.
      storageBreakdownProvider.overrideWith(
        (Ref ref) async => const StorageBreakdown(
          feedBytes: 186 * 1024 * 1024,
          mediaBytes: 412 * 1024 * 1024,
          backupsBytes: 38 * 1024 * 1024,
          otherBytes: 64 * 1024 * 1024,
        ),
      ),
      messageTimelineStoreProvider.overrideWithValue(
        MemoryMessageTimelineStore(<String, List<ChatMessage>>{
          PeerShareCodec.normalizeAddress(demo.friends[0].address):
              _conversation(demo),
          'group:$_groupId': _groupChat(demo),
        }),
      ),
      nearbyServiceProvider.overrideWith((Ref ref) {
        final MeetService meet = ref.watch(meetServiceProvider);
        final NearbyService nearby = NearbyService(
          radio: _Radio(),
          network: _Net(),
          meet: meet,
          ownAddress: () => me,
          sendMesh: (String to, Map<String, dynamic> p) async {},
          frames: const Stream<SignalTransportFrame>.empty(),
        )..encounters = ref.watch(encounterLogProvider);
        ref.onDispose(() => unawaited(nearby.close()));
        return nearby;
      }),
      if (locked)
        appSecurityServiceProvider.overrideWithValue(
          MemoryAppSecurityService(
            hasPassword: true,
            locked: true,
            passwordIterations: 10,
          ),
        ),
      appSettingsInitialStateProvider.overrideWithValue(
        AppSettings(
          themeMode: run.dark ? AppThemeMode.dark : AppThemeMode.light,
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

  final _Shots shots = _Shots(tester, run);

  if (locked) {
    await shots.shot(
      'lock',
      ready: find.byKey(const Key('app-unlock-password-field')),
    );
  } else {
    await _walk(tester, container, run, demo, links, shots);
  }

  // The test must end with no timer pending: take the app down, drop its
  // providers and let what is still scheduled run out.
  await tester.pumpWidget(const SizedBox.shrink());
  disposeContainer();
  await tester.pump(const Duration(minutes: 10));
  await tester.pump(const Duration(minutes: 10));

  FlutterError.onError = original;
  final Set<String> unique = <String>{...run.problems};
  final StringBuffer out = StringBuffer(
    '=== ${run.lang} ${run.theme} ${run.size.name}${locked ? ' lock' : ''}: '
    '${unique.length} problem(s)\n',
  );
  for (final String p in unique) {
    out.writeln(p);
  }
  File(
      '${run.dir}/problems-${run.theme}-${run.size.name}${locked ? '-lock' : ''}.txt',
    )
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(out.toString());
  // ignore: avoid_print
  print(out);
}

/// Taking pictures and frames of what is on screen.
final class _Shots {
  _Shots(this.tester, this.run);

  final WidgetTester tester;
  final _Run run;

  /// Real time in small steps until [ready] shows: some screens fill in
  /// from work outside the test's clock (decrypting, isolates, files).
  Future<void> until(Finder ready, {int tries = 80}) async {
    for (int i = 0; i < tries && ready.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    if (ready.evaluate().isEmpty) {
      run.problems.add('[${run.theme}] ${run.where}: never showed $ready');
    }
  }

  /// Pictures (faces, photos) decode outside the test's clock.
  Future<void> decode() async {
    for (int i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await _settle(tester);
  }

  Future<void> shot(String id, {Finder? ready, int tries = 80}) async {
    run.where = id;
    // ignore: avoid_print
    print('[shots ${run.lang} ${run.theme}] $id');
    await _settle(tester);
    if (ready != null) {
      await until(ready, tries: tries);
    }
    await decode();
    await _capture(tester, '${run.dir}/$id-${run.theme}.png');
  }

  /// One frame of film [id], shown for [ms] milliseconds.
  Future<void> frame(String id, int n, int ms) async {
    final String folder = '${run.dir}/$id-${run.theme}';
    await _capture(tester, '$folder/${n.toString().padLeft(3, '0')}.png');
    final File timing = File('$folder/frames.json');
    final List<dynamic> list = n == 0 || !timing.existsSync()
        ? <dynamic>[]
        : jsonDecode(timing.readAsStringSync()) as List<dynamic>;
    list.add(ms);
    timing.writeAsStringSync(jsonEncode(list));
  }

  Future<bool> tap(Finder f) async {
    if (f.evaluate().isEmpty) {
      run.problems.add('[${run.theme}] ${run.where}: not found: $f');
      return false;
    }
    await tester.ensureVisible(f.first);
    await tester.pump();
    await tester.tap(f.first, warnIfMissed: false);
    await _settle(tester);
    return true;
  }
}

/// The demo's content that needs the running app, then every screen.
Future<void> _walk(
  WidgetTester tester,
  ProviderContainer container,
  _Run run,
  DemoAccount demo,
  Map<String, _LinkedTransport> links,
  _Shots shots,
) async {
  final String me = PeerShareCodec.normalizeAddress(demo.ownAddress);

  // Started in the test's zone (the services were made there), with real
  // time in between for isolates and timers outside.
  Future<void> seed(String what, Future<void> Function() body) async {
    run.where = 'seed $what';
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
      run.problems.add('[${run.theme}] seed $what: did not finish');
    } else if (error != null) {
      run.problems.add('[${run.theme}] seed $what failed: $error');
    }
    await _settle(tester, 2);
  }

  final List<LedgerNode> friendLedgers = <LedgerNode>[];
  final bool phone = run.size == ShotSize.phone;
  await seed('friends\' posts', () async {
    Future<void> postsOf(
      DemoPerson who,
      String text, {
      Uint8List? photo,
    }) async {
      final String address = PeerShareCodec.normalizeAddress(who.address);
      final _LinkedTransport transport = links[address] = _LinkedTransport(
        address,
        links,
      );
      await transport.start();
      final LedgerNode node = LedgerNode(
        transport: transport,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => <String>[me],
        deviceName: '${who.name} phone',
        bridges: BridgeBook(probe: (String _) async => null),
      );
      friendLedgers.add(node);
      await node.start();
      final List<Map<String, dynamic>> images = <Map<String, dynamic>>[];
      if (photo != null) {
        final Map<String, dynamic> ref = await storeMedia(node.blobs, photo);
        images.add(ref);
        // Already fetched by this device (the same sealed bytes have the
        // same id), as after a moment on the network.
        final Uint8List? sealed = await node.blobs.read(ref['id'] as String);
        final LedgerNode? own = container.read(ledgerNodeProvider);
        if (sealed != null && own != null) {
          await own.blobs.put(sealed, mime: 'application/octet-stream');
        }
      }
      await node.publish(kPostKind, newPostBody(text, images: images));
    }

    await postsOf(demo.friends[4], demo.text('p2'));
    await postsOf(demo.friends[1], demo.text('p1'));
    await postsOf(demo.friends[2], demo.text('p3'), photo: sunrisePhoto());
  });
  await seed('friend lists', () async {
    final MeetService meet = container.read(meetServiceProvider);
    for (final MapEntry<int, List<int>> e in DemoAccount.friendLists.entries) {
      final Map<String, String> list = <String, String>{
        for (final int i in e.value)
          PeerShareCodec.normalizeAddress(demo.far[i].address):
              demo.far[i].name,
        for (final (int a, int b) in DemoAccount.friendPairs)
          if (a == e.key || b == e.key)
            PeerShareCodec.normalizeAddress(
              demo.friends[a == e.key ? b : a].address,
            ): demo.friends[a == e.key ? b : a].name,
      };
      await meet.store.setFriendList(
        demo.friends[e.key].address,
        list,
        'demo-${e.key}',
      );
    }
    await meet.reload();
  });
  await seed('friend levels', () async {
    final LedgerNode? node = container.read(ledgerNodeProvider);
    if (node == null) {
      return;
    }
    const List<FriendLevel> levels = <FriendLevel>[
      FriendLevel.close,
      FriendLevel.close,
      FriendLevel.friend,
      FriendLevel.friend,
      FriendLevel.close,
      FriendLevel.weak,
      FriendLevel.friend,
    ];
    for (int i = 0; i < demo.friends.length; i++) {
      await node.setLevel(demo.friends[i].address, levels[i]);
    }
  });
  await seed('people passed', () async {
    final EncounterLog log = container.read(encounterLogProvider);
    await log.load();
    await log.setRecording(true);
    // Yesterday morning, so the list always reads the same.
    final int base = _yesterday().millisecondsSinceEpoch + 9 * 3600 * 1000;
    void passed(int friend, int minutesFromBase, int forMinutes) {
      final int from = base + minutesFromBase * 60000;
      for (int m = 0; m <= forMinutes; m += 5) {
        log.saw(
          token: 'f$friend',
          at: from + m * 60000,
          friend: demo.friends[friend].address,
        );
      }
    }

    passed(2, 30, 25);
    passed(5, 70, 10);
    passed(3, 95, 40);
    for (int i = 0; i < 9; i++) {
      log.saw(token: 'x$i', at: base + (40 + i * 3) * 60000);
    }
    await log.flush();
  });

  NavigatorState nav() =>
      tester.state<NavigatorState>(find.byType(Navigator).first);

  Future<void> page(String id, Widget Function() build, {Finder? ready}) async {
    run.where = id;
    unawaited(nav().push(MaterialPageRoute<void>(builder: (_) => build())));
    await shots.shot(id, ready: ready);
    nav().pop();
    await _settle(tester);
  }

  final String friendName = demo.friends[0].name;
  final String friendAddress = PeerShareCodec.normalizeAddress(
    demo.friends[0].address,
  );

  if (!phone) {
    // The computer: the chat list and the open conversation side by side
    // when the window is wide enough.
    await shots.tap(find.byKey(const Key('side-tab-chats')));
    await page(
      'desktop',
      () => ConversationScreen(peerAddress: friendAddress, title: friendName),
      ready: _text(demo.text('c6')),
    );
  } else {
    await shots.tap(find.byKey(const Key('side-tab-chats')));
    await shots.shot('chats', ready: _text(demo.text('group')));
    await page(
      'conversation',
      () => ConversationScreen(peerAddress: friendAddress, title: friendName),
      ready: _text(demo.text('c6')),
    );
    await page(
      'group',
      () => GroupConversationScreen(
        groupId: _groupId,
        groupName: demo.text('group'),
      ),
      ready: _text(demo.text('g5')),
    );
    if (await shots.tap(find.byKey(const Key('side-tab-feed')))) {
      await shots.shot(
        'feed',
        ready: find.byWidgetPredicate(
          (Widget w) => w is Image && w.image is MemoryImage,
        ),
        // The photo comes from the friend's device first.
        tries: 400,
      );
    }
    if (await shots.tap(find.byKey(const Key('side-tab-graph')))) {
      // The people glide to their places first.
      await _settle(tester, 16);
      await shots.shot('graph');
      run.where = 'graph-timeline';
      if (await shots.tap(find.byKey(const Key('graph-mode-time')))) {
        await _settle(tester, 8);
        await shots.shot('graph-timeline');
        await _graphFilm(tester, run, shots);
      }
      await shots.tap(find.byKey(const Key('graph-mode-presence')));
    }
    if (await shots.tap(find.byKey(const Key('side-tab-nearby')))) {
      // Down to the people passed today ("Mijani").
      run.where = 'nearby';
      await _settle(tester);
      final Finder passed = find.byKey(const Key('encounters'));
      final Finder list = find.descendant(
        of: find.byType(NearbyScreen),
        matching: find.byType(Scrollable),
      );
      if (passed.evaluate().isEmpty && list.evaluate().isNotEmpty) {
        try {
          await tester.scrollUntilVisible(passed, 300, scrollable: list.first);
        } on StateError catch (e) {
          run.problems.add('[${run.theme}] nearby: $e');
        }
      }
      if (passed.evaluate().isNotEmpty) {
        await tester.ensureVisible(passed);
        await _settle(tester);
      }
      await shots.shot('nearby');
    }
    await shots.tap(find.byKey(const Key('side-tab-chats')));
    await _sendFilm(tester, run, demo, shots, nav, friendAddress, friendName);

    // Settings: notifications and sounds, then data and storage.
    run.where = 'settings';
    if (await shots.tap(find.byKey(const Key('chats-status-chip')))) {
      for (final (String id, String key) in <(String, String)>[
        ('notifications', 'settings-nav-notifications'),
        ('storage', 'settings-nav-data'),
      ]) {
        run.where = id;
        final Finder tile = find.byKey(Key(key));
        final Finder list = find.descendant(
          of: find.byKey(const Key('settings-tab-body')),
          matching: find.byType(Scrollable),
        );
        if (tile.evaluate().isEmpty && list.evaluate().isNotEmpty) {
          try {
            await tester.scrollUntilVisible(tile, 220, scrollable: list.first);
          } on StateError catch (e) {
            run.problems.add('[${run.theme}] $id: $e');
          }
          await tester.pump();
        }
        if (await shots.tap(tile)) {
          await shots.shot(id);
          final NavigatorState n = nav();
          if (n.canPop()) {
            n.pop();
            await _settle(tester);
          }
        }
      }
    }
  }

  for (final LedgerNode node in friendLedgers) {
    await seed('stop ${node.deviceName}', node.stop);
  }
}

/// "graph-growth": the friends graph's timeline from its first day to
/// today.
Future<void> _graphFilm(WidgetTester tester, _Run run, _Shots shots) async {
  run.where = 'graph-growth';
  final Finder slider = find.byKey(const Key('graph-time-slider'));
  if (slider.evaluate().isEmpty) {
    run.problems.add('[${run.theme}] graph-growth: no slider');
    return;
  }
  const int frames = 24;
  for (int i = 0; i <= frames; i++) {
    final Slider s = tester.widget<Slider>(slider);
    s.onChanged?.call(i / frames);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await shots.frame(
      'graph-growth',
      i,
      i == frames ? 2600 : (i == 0 ? 900 : 260),
    );
  }
}

/// "send-message": writing a message to a friend and sending it.
Future<void> _sendFilm(
  WidgetTester tester,
  _Run run,
  DemoAccount demo,
  _Shots shots,
  NavigatorState Function() nav,
  String friendAddress,
  String friendName,
) async {
  run.where = 'send-message';
  unawaited(
    nav().push(
      MaterialPageRoute<void>(
        builder: (_) =>
            ConversationScreen(peerAddress: friendAddress, title: friendName),
      ),
    ),
  );
  await _settle(tester);
  await shots.until(_text(demo.text('c6')));
  await shots.decode();
  final Finder field = find.byKey(const Key('conversation-composer-field'));
  if (field.evaluate().isEmpty) {
    run.problems.add('[${run.theme}] send-message: no composer');
    nav().pop();
    await _settle(tester);
    return;
  }
  int n = 0;
  await shots.frame('send-message', n++, 1200);
  final String message = demo.text('send');
  final List<String> words = message.split(' ');
  for (int i = 1; i <= words.length; i++) {
    await tester.enterText(field, words.take(i).join(' '));
    await tester.pump(const Duration(milliseconds: 120));
    await shots.frame('send-message', n++, 220);
  }
  await shots.frame('send-message', n++, 500);
  final Finder send = find.byKey(const Key('conversation-send-button'));
  if (send.evaluate().isNotEmpty) {
    await tester.tap(send.first, warnIfMissed: false);
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 90));
      await shots.frame('send-message', n++, 90);
    }
    await _settle(tester, 4);
    await shots.frame('send-message', n++, 2800);
  } else {
    run.problems.add('[${run.theme}] send-message: no send button');
  }
  nav().pop();
  await _settle(tester);
}

/// No platform plugin in widget tests: the deep-link source never emits.
final class _NoDeepLinks implements DeepLinkSource {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get linkStream => const Stream<Uri>.empty();
}

/// Bluetooth that is on and allowed, with nobody new around.
final class _Radio implements NearbyRadio {
  @override
  Stream<Map<Object?, Object?>> get events =>
      const Stream<Map<Object?, Object?>>.empty();

  @override
  Future<Map<Object?, Object?>> state() async => <Object?, Object?>{
    'supported': true,
    'enabled': true,
    'permitted': true,
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> requestEnable() async => true;

  @override
  Future<bool> startAdvertising(Uint8List token) async => true;

  @override
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async => true;

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<bool> startScan({bool lowPower = false}) async => true;

  @override
  Future<void> stopScan() async {}

  @override
  Future<bool> wave(String device, Uint8List data) async => false;
}

/// The same Wi-Fi, with nobody on it.
final class _Net implements NearbyNetwork {
  @override
  void update({
    required int firstSlot,
    required Uint8List? adverts,
    required bool looking,
  }) {}

  @override
  List<(Uint8List, int)> heard() => const <(Uint8List, int)>[];
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
