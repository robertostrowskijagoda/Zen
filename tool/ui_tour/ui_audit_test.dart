// Przegląd całego UI w kilku rozmiarach ekranu i skalach tekstu, z danymi
// (piramida, wydarzenie, kółko, pytanie, mieszkanie, randki, czaty).
// Zbiera KAŻDY błąd układu (przepełnienia, nachodzenie) zamiast przerywać na
// pierwszym i wypisuje je na końcu; wybrane konfiguracje zapisują zrzuty.
//
//   flutter test tool/ui_tour/ui_audit_test.dart --update-goldens
//
// Zrzuty: scratch/audit/<konfiguracja>/<ekran>.png (poza repo).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/account/presentation/account_recovery_screen.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/presentation/dating_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/presentation/alarm_screen.dart';
import 'package:zen/src/features/meet/presentation/ask_screen.dart';
import 'package:zen/src/features/meet/presentation/circle_screen.dart';
import 'package:zen/src/features/meet/presentation/events_screen.dart';
import 'package:zen/src/features/meet/presentation/graph_screen.dart';
import 'package:zen/src/features/meet/presentation/nearby_screen.dart';
import 'package:zen/src/features/meet/presentation/table_screen.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/presentation/flat_door_screen.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/presentation/share_app_screen.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';

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

final class _Config {
  const _Config(
    this.name,
    this.width,
    this.height,
    this.dpr,
    this.scale, {
    this.light = false,
    this.shots = false,
  });

  final String name;
  final double width;
  final double height;
  final double dpr;
  final double scale;
  final bool light;
  final bool shots;
}

const List<_Config> _configs = <_Config>[
  _Config('p360', 360, 780, 3, 1.0, shots: true),
  _Config('p360big', 360, 780, 3, 1.3, shots: true),
  _Config('p412light', 412, 915, 2.625, 1.0, light: true, shots: true),
  _Config('p320', 320, 640, 2, 1.0),
  _Config('p320big', 320, 640, 2, 1.5),
  _Config('desk', 1280, 800, 1.25, 1.0, shots: true),
];

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

void main() {
  setUpAll(_loadFonts);

  final List<String> only = (Platform.environment['AUDIT_ONLY'] ?? '')
      .split(',')
      .where((String s) => s.isNotEmpty)
      .toList();
  for (final _Config c in _configs) {
    if (only.isNotEmpty && !only.contains(c.name)) {
      continue;
    }
    testWidgets('audit ${c.name}', (WidgetTester tester) async {
      tester.view.physicalSize = Size(c.width * c.dpr, c.height * c.dpr);
      tester.view.devicePixelRatio = c.dpr;
      tester.platformDispatcher.textScaleFactorTestValue = c.scale;
      tester.platformDispatcher.platformBrightnessTestValue = c.light
          ? Brightness.light
          : Brightness.dark;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      // The computer layout (the app frames itself on Windows).
      if (c.name == 'desk') {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      }

      final List<String> problems = <String>[];
      String where = 'start';
      final FlutterExceptionHandler? original = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails d) {
        final String text = d.toString();
        final RegExpMatch? widget = RegExp(
          r'relevant error-causing widget was:\s*\n\s*(.*)\n\s*(.*)',
        ).firstMatch(text);
        final String head = d.exceptionAsString().split('\n').first;
        problems.add(
          '[${c.name}] $where: $head${widget == null ? '' : ' @ ${widget.group(1)} ${widget.group(2)}'}',
        );
      };

      final ProviderContainer container = ProviderContainer(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          socialHubSeedProvider.overrideWithValue(SocialHubState.preview()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const ZenRewriteApp(),
        ),
      );
      await _settle(tester, 12);

      // Data, so the screens are not just empty states.
      String? eventId;
      String? circleId;
      Future<void> seed(String what, Future<void> Function() body) async {
        where = 'seed $what';
        // ignore: avoid_print
        print('[audit ${c.name}] seed $what');
        // Started in the test's zone (the services were made there, so their
        // queued futures complete only when it is pumped), with real time
        // in between for isolates and timers outside it.
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
          problems.add('[${c.name}] seed $what: did not finish');
        } else if (error != null) {
          problems.add('[${c.name}] seed $what failed: $error');
        }
        await _settle(tester, 2);
      }

      await seed('pyramid', () async {
        await container
            .read(pyramidServiceProvider)
            .createPyramid(
              name: 'Piramida Mokotów i okolice',
              myName: 'Robert',
              nat: 'PL',
              birthYear: 1990,
              gender: 'm',
            );
        await container
            .read(pyramidServiceProvider)
            .post(
              'Pierwsze spotkanie komórki w sobotę o 18:00 w parku — przynieście coś do jedzenia!',
            );
      });
      await seed('event', () async {
        final MeetEvent e = await container
            .read(eventServiceProvider)
            .create(
              title:
                  'Grill w ogrodzie u Ani z bardzo długim tytułem, żeby sprawdzić zawijanie',
              startsAt: DateTime.now()
                  .add(const Duration(days: 2))
                  .millisecondsSinceEpoch,
              kind: EventKind.party,
              description:
                  'Przynieś coś do jedzenia albo picia. Będzie muzyka, gry planszowe i ognisko do późna.',
              place: 'ul. Długa 12, Warszawa',
              reach: EventReach.friends,
              capacity: 12,
            );
        eventId = e.id;
      });
      await seed('circle', () async {
        final DinnerCircle k = await container
            .read(circleServiceProvider)
            .create(
              name: 'Czwartkowe kolacje sąsiedzkie',
              friends: <String>['ada.ygg', 'maks.ygg'],
              weekday: 4,
              hour: 19,
              firstDinner: DateTime.now().add(const Duration(days: 3)),
            );
        circleId = k.id;
      });
      await seed('ask', () async {
        await container
            .read(askServiceProvider)
            .ask(
              'Czy ktoś zna dobrego hydraulika na Mokotowie, który przyjdzie jeszcze w tym tygodniu?',
            );
      });
      await seed('flat', () async {
        await container
            .read(neighborsServiceProvider)
            .createFlat(
              'Kowalscy spod piątki',
              place: 'ul. Długa 12/5',
              about:
                  'Rodzina z dwójką dzieci i psem. Chętnie pożyczymy wiertarkę.',
            );
      });
      await seed('dating', () async {
        await container.read(datingServiceProvider).saveMine((MyDating m) {
          m
            ..enabled = true
            ..adult = true
            ..name = 'Robert'
            ..age = 34
            ..gender = DatingGender.man
            ..about = 'Lubię góry, planszówki i gotowanie dla znajomych.'
            ..lookingFor = 'Kogoś do wspólnych wycieczek i rozmów do rana.';
        });
      });

      Future<void> shot(String name) async {
        where = name;
        // ignore: avoid_print
        print('[audit ${c.name}] $name');
        await _settle(tester);
        if (c.shots) {
          await expectLater(
            find.byType(MaterialApp).first,
            matchesGoldenFile('../../scratch/audit/${c.name}/$name.png'),
          );
        }
      }

      Future<bool> tap(Finder f) async {
        if (f.evaluate().isEmpty) {
          return false;
        }
        await tester.ensureVisible(f.first);
        await tester.tap(f.first, warnIfMissed: false);
        await _settle(tester);
        return true;
      }

      NavigatorState nav() =>
          tester.state<NavigatorState>(find.byType(Navigator).first);

      Future<void> screen(
        String name,
        Widget Function() build, {
        List<String> tabs = const <String>[],
        bool scroll = true,
      }) async {
        where = name;
        nav().push(MaterialPageRoute<void>(builder: (_) => build()));
        await shot(name);
        for (final String t in tabs) {
          if (await tap(find.widgetWithText(Tab, t))) {
            await shot('${name}_${t.toLowerCase()}');
          }
        }
        if (scroll) {
          final Finder s = find.byType(Scrollable);
          if (s.evaluate().isNotEmpty) {
            where = '$name (scrolled)';
            try {
              await tester.drag(
                s.last,
                const Offset(0, -1500),
                warnIfMissed: false,
              );
            } on Object {
              // not draggable
            }
            await _settle(tester, 3);
          }
        }
        nav().maybePop();
        await _settle(tester);
      }

      for (final String tab in <String>[
        'graph',
        'chats',
        'profile',
        'feed',
        'meet',
        'dating',
        'neighbors',
        'pyramid',
        'wallet',
        'nearby',
        'invite',
        'about',
        'alarm',
      ]) {
        where = 'tab $tab';
        if (await tap(find.byKey(Key('side-tab-$tab')))) {
          await shot('tab_$tab');
        }
      }
      await tap(find.byKey(const Key('side-tab-chats')));

      await screen('events', () => const EventsScreen());
      await screen('event_new', () => const CreateEventScreen());
      await screen(
        'event_new_dinner',
        () => const CreateEventScreen(kind: EventKind.dinner),
      );
      if (eventId != null) {
        await screen('event_detail', () => EventScreen(eventId: eventId!));
      }
      await screen('nearby', () => const NearbyScreen());
      await screen('table', () => const TableScreen());
      await screen('circles', () => const CirclesScreen());
      if (circleId != null) {
        await screen('circle_detail', () => CircleScreen(circleId: circleId!));
      }
      await screen('ask', () => const AskScreen());
      await screen('graph', () => const GraphScreen());
      await screen('alarm', () => const AlarmScreen());
      await screen(
        'dating',
        () => const DatingScreen(),
        tabs: <String>['Pary (0)', 'Więcej'],
      );
      await screen('neighbors', () => const NeighborsScreen());
      await screen('flat_door', () => const FlatDoorScreen());
      await screen('flat_home', () => const FlatHomeScreen());
      await screen(
        'pyramid',
        () => const PyramidScreen(),
        tabs: <String>[
          'Polityka',
          'Kraj',
          'Głosowania',
          'Portfel',
          'Władza',
          'Historia',
        ],
      );
      await screen(
        'profile',
        () => const ProfileScreen(),
        tabs: <String>['Galeria', 'Podziękowania'],
      );
      await screen(
        'friend_profile',
        () => const ProfileScreen(address: 'ada.ygg'),
      );
      await screen(
        'chat',
        () => const ConversationScreen(peerAddress: 'ada.ygg', title: 'Ada'),
        scroll: false,
      );
      await screen(
        'group_chat',
        () => const GroupConversationScreen(
          groupId: 'preview-group-1',
          groupName: 'Projekt Zen',
        ),
        scroll: false,
      );
      await screen('share_app', () => const ShareAppScreen());
      await screen('updates', () => const UpdatesScreen());
      await screen('devices', () => const AccountDevicesScreen());
      await screen('recovery', () => const AccountRecoveryScreen());

      // Settings and every page of it.
      await tap(find.byKey(const Key('side-tab-chats')));
      where = 'settings';
      if (await tap(find.byKey(const Key('chats-status-chip')))) {
        await shot('settings');
        for (final String page in <String>[
          'security',
          'appearance',
          'data',
          'updates',
          'network',
          'delivery',
          'account',
          'gifs',
          'diagnostics',
          'recordings',
        ]) {
          where = 'settings $page';
          if (await tap(find.byKey(Key('settings-nav-$page')))) {
            await shot('settings_$page');
            nav().maybePop();
            await _settle(tester);
          }
        }
      }

      FlutterError.onError = original;
      debugDefaultTargetPlatformOverride = null;
      final Set<String> unique = <String>{...problems};
      final StringBuffer out = StringBuffer(
        '=== ${c.name}: ${unique.length} problem(s)\n',
      );
      for (final String p in unique) {
        out.writeln(p);
      }
      Directory('scratch/audit').createSync(recursive: true);
      File('scratch/audit/${c.name}.txt').writeAsStringSync(out.toString());
      // ignore: avoid_print
      print(out);
    });
  }
}
