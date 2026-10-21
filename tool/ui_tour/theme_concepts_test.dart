// The look concepts side by side: the same screens (Tablica, Czaty, a
// conversation, Profil, and the Wygląd picker) in every palette, light and
// dark, with the app's real fonts. Runs on the host, no device needed:
//
//   flutter test --no-pub tool/ui_tour/theme_concepts_test.dart --update-goldens
//
// Shots: scratch/concepts/<palette>_<mode>/<screen>.png (outside the repo),
// layout problems in scratch/concepts/<palette>_<mode>.txt. A dark-only
// palette (winamp) has no _light shots. neon_dark also gets an animation
// strip: the conversation opening, frames anim_00.png … anim_05.png at
// 0, 200, … 1000 ms (for a GIF).
// CONCEPTS_ONLY=neon_dark,winamp_dark renders just those.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/runtime_deep_link_bridge.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

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
  await load('VT323', <String>['assets/fonts/VT323-Regular.ttf']);
  await load('Space Mono', <String>[
    'assets/fonts/SpaceMono-Regular.ttf',
    'assets/fonts/SpaceMono-Bold.ttf',
  ]);
  final String root = Platform.environment['FLUTTER_ROOT'] ?? '';
  await load('MaterialIcons', <String>[
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

Future<void> _settle(WidgetTester tester, [int frames = 6]) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// A short conversation with Ada, so the bubbles of both sides show.
Map<String, List<ChatMessage>> _threads() {
  final int now = DateTime.now().millisecondsSinceEpoch;
  int ago(int minutes) => now - minutes * 60 * 1000;
  return <String, List<ChatMessage>>{
    'ada.ygg': <ChatMessage>[
      ChatMessage(
        id: 'c1',
        sender: 'ada.ygg',
        text: 'Hej! Idziemy jutro na spacer nad Wisłę?',
        sentAtMillis: ago(42),
        direction: ChatMessageDirection.incoming,
      ),
      ChatMessage(
        id: 'c2',
        sender: 'self',
        text: 'Chętnie. O 10 przy moście?',
        sentAtMillis: ago(40),
        direction: ChatMessageDirection.outgoing,
        deliveryState: ChatMessageDeliveryState.delivered,
        readAtMillis: ago(39),
      ),
      ChatMessage(
        id: 'c3',
        sender: 'ada.ygg',
        text: 'Pasuje. Wezmę termos z herbatą ☕',
        sentAtMillis: ago(12),
        direction: ChatMessageDirection.incoming,
      ),
      ChatMessage(
        id: 'c4',
        sender: 'self',
        text: 'Super, to do jutra!',
        sentAtMillis: ago(10),
        direction: ChatMessageDirection.outgoing,
        deliveryState: ChatMessageDeliveryState.delivered,
      ),
      ChatMessage(
        id: 'c5',
        sender: 'ada.ygg',
        text: 'Jestem online, mogę wejść na rozmowę za 5 minut.',
        sentAtMillis: ago(1),
        direction: ChatMessageDirection.incoming,
      ),
    ],
  };
}

void main() {
  setUpAll(_loadFonts);

  final List<String> only = (Platform.environment['CONCEPTS_ONLY'] ?? '')
      .split(',')
      .where((String s) => s.isNotEmpty)
      .toList();
  for (final AppPalette palette in AppPalette.values) {
    for (final Brightness brightness in Brightness.values) {
      final bool dark = brightness == Brightness.dark;
      final String config = '${palette.name}_${dark ? 'dark' : 'light'}';
      if (only.isNotEmpty && !only.contains(config)) {
        continue;
      }
      if (palette.darkOnly && !dark) {
        continue;
      }
      testWidgets('concept $config', (WidgetTester tester) async {
        tester.view.physicalSize = const Size(412 * 2.625, 915 * 2.625);
        tester.view.devicePixelRatio = 2.625;
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearAllTestValues);
        final bool motion = ZenMotion.enabled;
        addTearDown(() => ZenMotion.enabled = motion);

        final List<String> problems = <String>[];
        String where = 'start';
        final FlutterExceptionHandler? original = FlutterError.onError;
        FlutterError.onError = (FlutterErrorDetails d) {
          problems.add(
            '[$config] $where: ${d.exceptionAsString().split('\n').first}',
          );
        };

        final ProviderContainer container = ProviderContainer(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            deepLinkSourceProvider.overrideWithValue(_NoDeepLinks()),
            signalTransportProvider.overrideWithValue(MemorySignalTransport()),
            ledgerNodeEnabledProvider.overrideWithValue(true),
            ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
            socialHubSeedProvider.overrideWithValue(SocialHubState.preview()),
            messageTimelineStoreProvider.overrideWithValue(
              MemoryMessageTimelineStore(_threads()),
            ),
            appSettingsInitialStateProvider.overrideWithValue(
              AppSettings(
                palette: palette,
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

        // A few posts on the wall, so Tablica is not an empty state.
        where = 'seed posts';
        final LedgerNode? node = container.read(ledgerNodeProvider);
        if (node != null) {
          bool done = false;
          Object? error;
          Future<void> post(String text) async {
            await node.publish(
              kPostKind,
              await node.seal(
                Audience.all,
                newPostBody(text, audience: Audience.all),
              ),
            );
          }

          unawaited(
            () async {
              await post(
                'Pierwszy przymrozek na działce. Ktoś chętny na '
                'jesienne porządki w sobotę? Będzie zupa dyniowa.',
              );
              await post(
                'Dziękuję wszystkim za wczorajsze ognisko — było '
                'cicho, spokojnie i bardzo po naszemu.',
              );
            }().then(
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
            problems.add('[$config] seed posts: did not finish');
          } else if (error != null) {
            problems.add('[$config] seed posts failed: $error');
          }
          await _settle(tester, 2);
        }

        Future<void> shot(String name) async {
          where = name;
          // ignore: avoid_print
          print('[concepts $config] $name');
          await _settle(tester);
          await expectLater(
            find.byType(MaterialApp).first,
            matchesGoldenFile('../../scratch/concepts/$config/$name.png'),
          );
        }

        Future<bool> tap(Finder f) async {
          if (f.evaluate().isEmpty) {
            problems.add('[$config] $where: not found: $f');
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

        where = 'feed';
        if (await tap(find.byKey(const Key('side-tab-feed')))) {
          await shot('feed');
        }
        where = 'chats';
        if (await tap(find.byKey(const Key('side-tab-chats')))) {
          await shot('chats');
        }
        where = 'conversation';
        unawaited(
          nav().push(
            MaterialPageRoute<void>(
              builder: (_) => const ConversationScreen(
                peerAddress: 'ada.ygg',
                title: 'Ada',
              ),
            ),
          ),
        );
        await shot('conversation');
        nav().pop();
        await _settle(tester);
        if (config == 'neon_dark') {
          // The animation strip: the same conversation opening with motion
          // on (the wipe, the flicker, the bubbles coming in, the glow).
          where = 'animation';
          ZenMotion.enabled = true;
          unawaited(
            nav().push(
              MaterialPageRoute<void>(
                builder: (_) => const ConversationScreen(
                  peerAddress: 'ada.ygg',
                  title: 'Ada',
                ),
              ),
            ),
          );
          for (int i = 0; i < 6; i++) {
            if (i == 0) {
              await tester.pump();
            } else {
              await tester.pump(const Duration(milliseconds: 200));
            }
            final String frame = 'anim_${i.toString().padLeft(2, '0')}';
            // ignore: avoid_print
            print('[concepts $config] $frame');
            await expectLater(
              find.byType(MaterialApp).first,
              matchesGoldenFile('../../scratch/concepts/$config/$frame.png'),
            );
          }
          ZenMotion.enabled = motion;
          nav().pop();
          await _settle(tester);
        }
        where = 'profile';
        if (await tap(find.byKey(const Key('side-tab-profile')))) {
          await shot('profile');
        }
        // The picker itself (Ustawienia → Wygląd).
        where = 'appearance';
        await tap(find.byKey(const Key('side-tab-chats')));
        if (await tap(find.byKey(const Key('chats-status-chip'))) &&
            await tap(find.byKey(const Key('settings-nav-appearance')))) {
          await shot('appearance');
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
          '=== $config: ${unique.length} problem(s)\n',
        );
        for (final String p in unique) {
          out.writeln(p);
        }
        Directory('scratch/concepts').createSync(recursive: true);
        File('scratch/concepts/$config.txt').writeAsStringSync(out.toString());
        // ignore: avoid_print
        print(out);
      });
    }
  }
}

/// No platform plugin in widget tests: the deep-link source never emits.
final class _NoDeepLinks implements DeepLinkSource {
  @override
  Future<Uri?> getInitialLink() async => null;

  @override
  Stream<Uri> get linkStream => const Stream<Uri>.empty();
}
