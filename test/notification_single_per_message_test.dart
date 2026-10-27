import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_notification_center.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

// One received message must leave exactly one system notification and one
// sound, in a 1:1 chat and in a group chat, however many times the same
// message reaches the device: directly and from a mailbox, re-sent, at the
// same moment, long after the first copy, or after the app was restarted.

const String _ada = 'ada.ygg';
const String _groupId = 'grp-1';

const LifecycleSnapshot _background = LifecycleSnapshot(
  visibility: AppVisibilityState.background,
  generation: 1,
  capturedAtMillis: 0,
);
const LifecycleSnapshot _visibleNotFocused = LifecycleSnapshot(
  visibility: AppVisibilityState.foreground,
  generation: 1,
  capturedAtMillis: 0,
);
const LifecycleSnapshot _focused = LifecycleSnapshot(
  visibility: AppVisibilityState.foregroundFocused,
  generation: 1,
  capturedAtMillis: 0,
);

const GroupProfile _group = GroupProfile(
  id: _groupId,
  name: 'Ekipa',
  createdById: _ada,
  createdAtMillis: 0,
  memberAddresses: <String>[_ada, 'bob.ygg'],
);

ZenSignal _direct(String id, [String text = 'Hej!']) => ZenSignal(
  type: ZenSignalType.message,
  sender: _ada,
  displayName: 'Ada',
  messageId: id,
  content: text,
);

ZenSignal _inGroup(String id, [String text = 'Hej!']) => ZenSignal(
  type: ZenSignalType.groupMessage,
  sender: _ada,
  displayName: 'Ada',
  groupId: _groupId,
  groupName: 'Ekipa',
  messageId: id,
  content: text,
);

/// What differs between the two kinds of chat.
class _Chat {
  const _Chat(this.name, this.signal, this.title, this.bodyOf, this.slot);

  final String name;
  final ZenSignal Function(String id, [String text]) signal;
  final String title;
  final String Function(String text) bodyOf;
  final String slot;
}

final List<_Chat> _chats = <_Chat>[
  _Chat('czat 1:1', _direct, 'Ada', (String t) => t, 'message:$_ada'),
  _Chat(
    'czat grupowy',
    _inGroup,
    'Ekipa',
    (String t) => 'Ada: $t',
    'group-message:$_groupId',
  ),
];

/// The things a phone keeps between two runs of the app.
final class _Storage {
  final MemorySignalQueueStore queue = MemorySignalQueueStore();
  final MemorySocialSnapshotStore snapshots = MemorySocialSnapshotStore();
  final MemoryMessageTimelineStore timeline = MemoryMessageTimelineStore();
}

SocialHubState _seed(LifecycleSnapshot lifecycle) =>
    SocialHubState.empty(lifecycle: lifecycle).copyWith(
      friends: const <String, FriendProfile>{
        _ada: FriendProfile(
          address: _ada,
          displayName: 'Ada',
          status: FriendRelationshipStatus.accepted,
        ),
      },
      groups: const <String, GroupProfile>{_groupId: _group},
    );

/// One run of the app over [storage].
ProviderContainer _boot(
  _Storage storage, {
  required LifecycleSnapshot lifecycle,
  required RuntimeSystemNotificationService service,
  RuntimeNotificationCenter? center,
  bool hideContent = false,
  ZenSoundEffects? sounds,
}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      ...buildAppSettingsProviderOverrides(
        store: MemoryAppSettingsStore(),
        initialState: AppSettings(hideNotificationContent: hideContent),
        hydrationEnabled: false,
      ),
      signalQueueStoreProvider.overrideWithValue(storage.queue),
      socialSnapshotStoreProvider.overrideWithValue(storage.snapshots),
      messageTimelineStoreProvider.overrideWithValue(storage.timeline),
      runtimeSystemNotificationServiceProvider.overrideWithValue(service),
      if (center != null)
        runtimeNotificationCenterProvider.overrideWithValue(center),
      if (sounds != null) zenSoundEffectsProvider.overrideWithValue(sounds),
      socialHubSeedProvider.overrideWithValue(_seed(lifecycle)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

SocialHubController _controller(ProviderContainer container) =>
    container.read(socialHubControllerProvider.notifier);

/// Stands in for the system: remembers what it was asked to show.
final class _FakePlugin implements FlutterLocalNotificationsPlugin {
  final List<({String? title, String? body, int? id})> shown =
      <({String? title, String? body, int? id})>[];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #show) {
      shown.add((
        title: invocation.namedArguments[#title] as String?,
        body: invocation.namedArguments[#body] as String?,
        id: invocation.namedArguments[#id] as int?,
      ));
      return Future.value(null);
    }
    if (invocation.isMethod && invocation.typeArguments.isEmpty) {
      // Future<Null>: fits any `Future<T?>` the service awaits.
      return Future.value(null);
    }
    // resolvePlatformSpecificImplementation: no Android implementation here.
    return null;
  }
}

final class _FakeHandle implements ZenSoundHandle {
  @override
  Future<void> stop() async {}
}

final class _FakeOutput implements ZenSoundOutput {
  final List<String> played = <String>[];

  @override
  Future<ZenSoundHandle?> play(String asset, {required bool loop}) async {
    played.add(asset);
    return _FakeHandle();
  }
}

void main() {
  for (final _Chat chat in _chats) {
    for (final (String where, LifecycleSnapshot lifecycle)
        in <(String, LifecycleSnapshot)>[
          ('w tle', _background),
          ('przy oknie widocznym, ale nieaktywnym', _visibleNotFocused),
        ]) {
      group('${chat.name}, aplikacja $where', () {
        late _Storage storage;
        late MemoryRuntimeSystemNotificationService service;
        late ProviderContainer container;

        setUp(() {
          storage = _Storage();
          service = MemoryRuntimeSystemNotificationService();
          container = _boot(storage, lifecycle: lifecycle, service: service);
        });

        void expectSingle({String text = 'Hej!'}) {
          expect(service.activeNotifications, hasLength(1));
          final RuntimeSystemNotification shown =
              service.activeNotifications.single;
          expect(shown.title, chat.title);
          expect(shown.body, chat.bodyOf(text));
          expect(shown.stackCount, 1, reason: 'nic nie jest doklejone');
          expect(shown.lines, isEmpty);
          expect(service.audibleAlertCount, 1, reason: 'jeden dźwięk');
        }

        test('jedna wiadomość: jedno powiadomienie i jeden dźwięk', () async {
          await _controller(
            container,
          ).receiveSignal(chat.signal('m-1'), receivedAtMillis: 1000);

          expectSingle();
          expect(service.activeNotifications.single.slotKey, chat.slot);
        });

        test('ta sama wiadomość jeszcze raz (skrzynka/relay) w oknie '
            'wyciszania', () async {
          final SocialHubController controller = _controller(container);
          await controller.receiveSignal(
            chat.signal('m-1'),
            receivedAtMillis: 1000,
          );
          await controller.receiveSignal(
            chat.signal('m-1'),
            receivedAtMillis: 1500,
          );

          expectSingle();
        });

        test('ta sama wiadomość długo po oknie wyciszania (powtórka '
            'dostarczenia)', () async {
          final SocialHubController controller = _controller(container);
          await controller.receiveSignal(
            chat.signal('m-1'),
            receivedAtMillis: 1000,
          );
          // Past the 60 s suppression window: only the stored chat can still
          // tell it is the same message.
          await controller.receiveSignal(
            chat.signal('m-1'),
            receivedAtMillis: 1000 + 5 * 60 * 1000,
          );

          expectSingle();
        });

        test('obie kopie naraz (bezpośrednio i ze skrzynki)', () async {
          final SocialHubController controller = _controller(container);
          await Future.wait(<Future<void>>[
            controller.receiveSignal(
              chat.signal('m-1'),
              receivedAtMillis: 1000,
            ),
            controller.receiveSignal(
              chat.signal('m-1'),
              receivedAtMillis: 1001,
            ),
          ]);

          expectSingle();
        });

        test('kopia po zdjęciu powiadomienia nie wraca', () async {
          final SocialHubController controller = _controller(container);
          await controller.receiveSignal(
            chat.signal('m-1'),
            receivedAtMillis: 1000,
          );
          final String shownId = service.activeNotifications.single.id;
          await service.dismiss(shownId);
          expect(service.activeNotifications, isEmpty);

          await controller.receiveSignal(
            chat.signal('m-1'),
            receivedAtMillis: 2000,
          );

          expect(service.activeNotifications, isEmpty);
          expect(service.audibleAlertCount, 1);
        });

        test('kopia po wyczyszczeniu powiadomień nie wraca (czyszczenie '
            'kasuje też okno wyciszania)', () async {
          final SocialHubController controller = _controller(container);
          await controller.receiveSignal(
            chat.signal('m-1'),
            receivedAtMillis: 1000,
          );
          await service.clear();

          await controller.receiveSignal(
            chat.signal('m-1'),
            receivedAtMillis: 1500,
          );

          expect(service.activeNotifications, isEmpty);
          expect(service.audibleAlertCount, 1);
        });

        test('ponowne odtworzenie po restarcie aplikacji nie powiadamia '
            'drugi raz', () async {
          await _controller(
            container,
          ).receiveSignal(chat.signal('m-1'), receivedAtMillis: 1000);
          expect(service.audibleAlertCount, 1);
          container.dispose();

          // A new run: new controller, new (empty) notification service, the
          // same stored chat. The mailbox hands the message over again.
          final MemoryRuntimeSystemNotificationService afterRestart =
              MemoryRuntimeSystemNotificationService();
          final ProviderContainer restarted = _boot(
            storage,
            lifecycle: lifecycle,
            service: afterRestart,
          );
          await _controller(
            restarted,
          ).receiveSignal(chat.signal('m-1'), receivedAtMillis: 9000);

          expect(afterRestart.activeNotifications, isEmpty);
          expect(afterRestart.audibleAlertCount, 0);
        });

        test('dwie różne wiadomości: wpis się łączy, a każda dostaje swój '
            'ślad dopiero po oknie ponownego alertu', () async {
          final SocialHubController controller = _controller(container);
          await controller.receiveSignal(
            chat.signal('m-1', 'Pierwsza'),
            receivedAtMillis: 1000,
          );
          await controller.receiveSignal(
            chat.signal('m-2', 'Druga'),
            receivedAtMillis: 2000,
          );

          // One entry that stands for two messages, and one sound.
          expect(service.activeNotifications, hasLength(1));
          expect(service.activeNotifications.single.stackCount, 2);
          expect(service.audibleAlertCount, 1);

          // A message much later makes its own sound, once.
          await controller.receiveSignal(
            chat.signal('m-3', 'Trzecia'),
            receivedAtMillis: 1000 + kNotificationRealertWindow.inMilliseconds,
          );
          expect(service.audibleAlertCount, 2);

          // And a copy of the third one adds nothing.
          await controller.receiveSignal(
            chat.signal('m-3', 'Trzecia'),
            receivedAtMillis: 1000 + kNotificationRealertWindow.inMilliseconds,
          );
          expect(service.audibleAlertCount, 2);
          expect(service.activeNotifications.single.stackCount, 3);
        });
      });
    }

    group('${chat.name}, ukryta treść powiadomień', () {
      test('kopia nadal jest wyciszana po zasłonięciu treści', () async {
        final _Storage storage = _Storage();
        final MemoryRuntimeSystemNotificationService memory =
            MemoryRuntimeSystemNotificationService();
        final PrivacyRedactingNotificationService service =
            PrivacyRedactingNotificationService(
              memory,
              hideContent: () => true,
            );
        final ProviderContainer container = _boot(
          storage,
          lifecycle: _background,
          service: service,
          hideContent: true,
        );
        final SocialHubController controller = _controller(container);

        await controller.receiveSignal(
          chat.signal('m-1', 'Tajne'),
          receivedAtMillis: 1000,
        );
        await controller.receiveSignal(
          chat.signal('m-1', 'Tajne'),
          receivedAtMillis: 1200,
        );
        await Future.wait(<Future<void>>[
          controller.receiveSignal(
            chat.signal('m-2', 'Inne'),
            receivedAtMillis: 1300,
          ),
          controller.receiveSignal(
            chat.signal('m-2', 'Inne'),
            receivedAtMillis: 1301,
          ),
        ]);

        // Two different messages, each once: one folded entry, one sound.
        expect(memory.activeNotifications, hasLength(1));
        expect(memory.activeNotifications.single.stackCount, 2);
        expect(memory.audibleAlertCount, 1);
        for (final RuntimeSystemNotification shown
            in memory.activeNotifications) {
          expect(shown.body, isNot(contains('Tajne')));
          expect(shown.body, isNot(contains('Inne')));
        }
      });
    });

    group('${chat.name}, aplikacja na pierwszym planie', () {
      test('nie ma powiadomienia systemowego, a w aplikacji jest jedno '
          'na wiadomość, także przy kopii', () async {
        final MemoryRuntimeSystemNotificationService service =
            MemoryRuntimeSystemNotificationService();
        final MemoryRuntimeNotificationCenter center =
            MemoryRuntimeNotificationCenter();
        final ProviderContainer container = _boot(
          _Storage(),
          lifecycle: _focused,
          service: service,
          center: center,
        );
        final SocialHubController controller = _controller(container);

        await controller.receiveSignal(
          chat.signal('m-1'),
          receivedAtMillis: 1000,
        );
        await controller.receiveSignal(
          chat.signal('m-1'),
          receivedAtMillis: 1500,
        );

        expect(service.activeNotifications, isEmpty);
        expect(service.audibleAlertCount, 0);
        expect(center.activeNotifications, hasLength(1));
      });
    });

    group('${chat.name}, prawdziwa usługa powiadomień i dźwięków', () {
      // The whole way down to the platform: the system is asked to show a
      // toast once and Zen plays its own sound once (Windows/Linux).
      late _FakePlugin plugin;
      late _FakeOutput output;
      late DateTime now;
      late FlutterLocalRuntimeSystemNotificationService service;

      ProviderContainer boot(_Storage storage) {
        plugin = _FakePlugin();
        output = _FakeOutput();
        now = DateTime(2026, 10, 21, 12);
        final ZenSoundEffects sounds = ZenSoundEffects(
          output: output,
          inAppSoundsOn: () => true,
          deviceKeepsQuiet: () async => false,
          platform: TargetPlatform.windows,
          clock: () {
            // Every look at the clock is later than the last one, so the
            // sound player's own "same sound again" guard (a quarter of a
            // second) cannot hide a second sound from this test.
            now = now.add(const Duration(seconds: 1));
            return now;
          },
        );
        service = FlutterLocalRuntimeSystemNotificationService(
          plugin: plugin,
          soundEffects: sounds,
        );
        return _boot(
          storage,
          lifecycle: _background,
          service: service,
          sounds: sounds,
        );
      }

      test('wiadomość i jej kopie: jeden toast i jeden dźwięk', () async {
        final ProviderContainer container = boot(_Storage());
        final SocialHubController controller = _controller(container);

        await controller.receiveSignal(
          chat.signal('m-1'),
          receivedAtMillis: 1000,
        );
        await pumpEventQueue();
        expect(plugin.shown, hasLength(1));
        expect(plugin.shown.single.title, chat.title);
        expect(plugin.shown.single.body, chat.bodyOf('Hej!'));
        expect(output.played, hasLength(1));

        // Mailbox copy, a re-send long after, and two more at once.
        await controller.receiveSignal(
          chat.signal('m-1'),
          receivedAtMillis: 1500,
        );
        await controller.receiveSignal(
          chat.signal('m-1'),
          receivedAtMillis: 1000 + 10 * 60 * 1000,
        );
        await Future.wait(<Future<void>>[
          controller.receiveSignal(chat.signal('m-1'), receivedAtMillis: 3000),
          controller.receiveSignal(chat.signal('m-1'), receivedAtMillis: 3001),
        ]);
        await pumpEventQueue();

        expect(plugin.shown, hasLength(1));
        expect(output.played, hasLength(1));
      });

      test('dwie kopie naraz od pierwszej chwili: jeden toast i jeden '
          'dźwięk', () async {
        final ProviderContainer container = boot(_Storage());
        final SocialHubController controller = _controller(container);

        await Future.wait(<Future<void>>[
          controller.receiveSignal(chat.signal('m-7'), receivedAtMillis: 500),
          controller.receiveSignal(chat.signal('m-7'), receivedAtMillis: 501),
        ]);
        await pumpEventQueue();

        expect(plugin.shown, hasLength(1));
        expect(output.played, hasLength(1));
      });

      test('powtórka po restarcie (nowa usługa, ten sam zapis czatu): '
          'cisza', () async {
        final _Storage storage = _Storage();
        final ProviderContainer first = boot(storage);
        await _controller(
          first,
        ).receiveSignal(chat.signal('m-1'), receivedAtMillis: 1000);
        await pumpEventQueue();
        expect(plugin.shown, hasLength(1));
        first.dispose();

        final ProviderContainer second = boot(storage);
        await _controller(
          second,
        ).receiveSignal(chat.signal('m-1'), receivedAtMillis: 70000);
        await pumpEventQueue();

        expect(plugin.shown, isEmpty);
        expect(output.played, isEmpty);
      });
    });
  }

  group('ten sam identyfikator w dwóch różnych czatach', () {
    test('wiadomość 1:1 i grupowa o tym samym id to dwie wiadomości, każda '
        'z własnym powiadomieniem', () async {
      final MemoryRuntimeSystemNotificationService service =
          MemoryRuntimeSystemNotificationService();
      final ProviderContainer container = _boot(
        _Storage(),
        lifecycle: _background,
        service: service,
      );
      final SocialHubController controller = _controller(container);

      await controller.receiveSignal(_direct('same'), receivedAtMillis: 1000);
      await controller.receiveSignal(_inGroup('same'), receivedAtMillis: 1100);

      expect(service.activeNotifications, hasLength(2));
      expect(
        service.activeNotifications.map(
          (RuntimeSystemNotification n) => n.title,
        ),
        containsAll(<String>['Ada', 'Ekipa']),
      );
    });
  });
}
