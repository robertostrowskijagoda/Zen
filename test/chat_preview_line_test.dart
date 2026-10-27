import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
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

SocialHubState _seedWithAda() => SocialHubState.empty().copyWith(
  friends: const <String, FriendProfile>{
    'ada.ygg': FriendProfile(
      address: 'ada.ygg',
      displayName: 'Ada',
      status: FriendRelationshipStatus.accepted,
    ),
  },
);

const LifecycleSnapshot _background = LifecycleSnapshot(
  visibility: AppVisibilityState.background,
  generation: 1,
  capturedAtMillis: 0,
);
const LifecycleSnapshot _focused = LifecycleSnapshot(
  visibility: AppVisibilityState.foregroundFocused,
  generation: 1,
  capturedAtMillis: 0,
);

const GroupProfile _ekipa = GroupProfile(
  id: 'grp-1',
  name: 'Ekipa',
  createdById: 'ada.ygg',
  createdAtMillis: 0,
  memberAddresses: <String>['ada.ygg', 'bob.ygg'],
);

/// One kind of message the way it arrives: its type, file and the text the
/// sender put with it (the caption, or the file name when there is none).
class _Incoming {
  const _Incoming(this.name, this.type, this.fileName, this.mimeType);

  final String name;
  final ChatMessageType type;
  final String? fileName;
  final String? mimeType;

  bool get isPlainText => type == ChatMessageType.text;

  /// What every surface shows for it, whatever the text.
  String get shown => isPlainText
      ? 'Hej, co slychac?'
      : chatMessageLabelForType(type, fileName: fileName, mimeType: mimeType);

  /// The texts the message may carry: a caption, or the file name.
  List<String> get texts => isPlainText
      ? <String>['Hej, co slychac?']
      : <String>['Spojrz na to', fileName!];
}

const List<_Incoming> _incomings = <_Incoming>[
  _Incoming('tekst', ChatMessageType.text, null, null),
  _Incoming('zdjecie', ChatMessageType.image, 'zdjecie.jpg', 'image/jpeg'),
  _Incoming('gif', ChatMessageType.image, 'kot.gif', 'image/gif'),
  _Incoming('wideo', ChatMessageType.video, 'film.mp4', 'video/mp4'),
  _Incoming(
    'wiadomosc glosowa',
    ChatMessageType.voice,
    'glos.m4a',
    'audio/mp4',
  ),
  _Incoming('plik', ChatMessageType.file, 'raport.pdf', 'application/pdf'),
];

/// What differs between a one-to-one chat and a group chat.
class _Where {
  const _Where(this.name, this.isGroup);

  final String name;
  final bool isGroup;

  ZenSignal signal(_Incoming kind, String text, {String id = 'm-1'}) => isGroup
      ? ZenSignal(
          type: ZenSignalType.groupMessage,
          sender: 'ada.ygg',
          displayName: 'Ada',
          groupId: 'grp-1',
          groupName: 'Ekipa',
          messageId: id,
          content: text,
          messageType: kind.isPlainText ? null : kind.type,
          fileName: kind.fileName,
          mimeType: kind.mimeType,
        )
      : ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          displayName: 'Ada',
          messageId: id,
          content: text,
          messageType: kind.type,
          fileName: kind.fileName,
          mimeType: kind.mimeType,
        );

  String systemBody(String shown) => isGroup ? 'Ada: $shown' : shown;

  String preview(SocialHubState state) => isGroup
      ? state.groups['grp-1']!.lastMessagePreview!
      : state.friends['ada.ygg']!.lastMessagePreview;
}

const List<_Where> _wheres = <_Where>[
  _Where('czat 1:1', false),
  _Where('czat grupowy', true),
];

ProviderContainer _bootFor(
  LifecycleSnapshot lifecycle, {
  required RuntimeSystemNotificationService service,
  RuntimeNotificationCenter? center,
  MemoryMessageTimelineStore? timeline,
}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      ...buildAppSettingsProviderOverrides(
        store: MemoryAppSettingsStore(),
        initialState: const AppSettings(hideNotificationContent: false),
        hydrationEnabled: false,
      ),
      signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
      socialSnapshotStoreProvider.overrideWithValue(
        MemorySocialSnapshotStore(),
      ),
      messageTimelineStoreProvider.overrideWithValue(
        timeline ?? MemoryMessageTimelineStore(),
      ),
      runtimeSystemNotificationServiceProvider.overrideWithValue(service),
      if (center != null)
        runtimeNotificationCenterProvider.overrideWithValue(center),
      socialHubSeedProvider.overrideWithValue(
        SocialHubState.empty(lifecycle: lifecycle).copyWith(
          friends: const <String, FriendProfile>{
            'ada.ygg': FriendProfile(
              address: 'ada.ygg',
              displayName: 'Ada',
              status: FriendRelationshipStatus.accepted,
            ),
          },
          groups: const <String, GroupProfile>{'grp-1': _ekipa},
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  for (final _Where where in _wheres) {
    for (final _Incoming kind in _incomings) {
      for (final String text in kind.texts) {
        final String label = '${where.name}, ${kind.name}, tekst "$text"';

        test('$label: podglad na liscie rozmow i wpis w centrum powiadomien '
            '(aplikacja na pierwszym planie)', () async {
          final MemoryRuntimeNotificationCenter center =
              MemoryRuntimeNotificationCenter();
          final ProviderContainer container = _bootFor(
            _focused,
            service: MemoryRuntimeSystemNotificationService(),
            center: center,
          );

          await container
              .read(socialHubControllerProvider.notifier)
              .receiveSignal(where.signal(kind, text), receivedAtMillis: 1000);

          final SocialHubState state = container.read(
            socialHubControllerProvider,
          );
          expect(where.preview(state), kind.shown);
          // The in-app banner (the notification center).
          expect(center.activeNotifications, hasLength(1));
          expect(center.activeNotifications.single.body, kind.shown);
          if (!where.isGroup) {
            // The inbox entry of a one-to-one message.
            expect(state.inbox, hasLength(1));
            expect(state.inbox.single.body, kind.shown);
          }
          if (!kind.isPlainText && kind.type != ChatMessageType.file) {
            expect(where.preview(state), isNot(contains(text)));
            expect(where.preview(state), isNot(contains(kind.fileName!)));
          }
        });

        test('$label: powiadomienie systemowe i wpis skrzynki '
            '(aplikacja w tle)', () async {
          final MemoryRuntimeSystemNotificationService service =
              MemoryRuntimeSystemNotificationService();
          final ProviderContainer container = _bootFor(
            _background,
            service: service,
          );

          await container
              .read(socialHubControllerProvider.notifier)
              .receiveSignal(where.signal(kind, text), receivedAtMillis: 1000);

          expect(service.activeNotifications, hasLength(1));
          final String body = service.activeNotifications.single.body;
          expect(body, where.systemBody(kind.shown));
          final SocialHubState state = container.read(
            socialHubControllerProvider,
          );
          expect(state.backgroundAlerts, hasLength(1));
          expect(state.backgroundAlerts.single.body, kind.shown);
          if (!kind.isPlainText && kind.type != ChatMessageType.file) {
            expect(body, isNot(contains(text)));
            expect(body, isNot(contains(kind.fileName!)));
          }
        });
      }

      if (!where.isGroup) {
        test(
          '${where.name}, ${kind.name}: podglad odtworzony z historii',
          () async {
            final int nowMillis = DateTime.now().millisecondsSinceEpoch;
            for (final String text in kind.texts) {
              final ProviderContainer container = _bootFor(
                _focused,
                service: MemoryRuntimeSystemNotificationService(),
                timeline: MemoryMessageTimelineStore(
                  <String, List<ChatMessage>>{
                    'ada.ygg': <ChatMessage>[
                      ChatMessage(
                        id: 'old-text',
                        sender: 'ada.ygg',
                        text: 'Hej!',
                        sentAtMillis: nowMillis - 1000,
                        direction: ChatMessageDirection.incoming,
                      ),
                      ChatMessage(
                        id: 'last',
                        sender: 'ada.ygg',
                        text: text,
                        sentAtMillis: nowMillis,
                        direction: ChatMessageDirection.incoming,
                        type: kind.type,
                        fileName: kind.fileName,
                        mimeType: kind.mimeType,
                      ),
                    ],
                  },
                ),
              );

              await container
                  .read(socialHubControllerProvider.notifier)
                  .configureConversationRetention(
                    peerAddress: 'ada.ygg',
                    inboxLimitMb: 0,
                    autoCleanupDays: 2,
                  );

              expect(
                container
                    .read(socialHubControllerProvider)
                    .friends['ada.ygg']!
                    .lastMessagePreview,
                kind.shown,
              );
            }
          },
        );
      }
    }
  }

  test('plik bez znanej nazwy pokazuje ogolna etykiete pliku', () async {
    final MemoryRuntimeSystemNotificationService service =
        MemoryRuntimeSystemNotificationService();
    final ProviderContainer container = _bootFor(_background, service: service);

    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          const ZenSignal(
            type: ZenSignalType.message,
            sender: 'ada.ygg',
            displayName: 'Ada',
            messageId: 'm-1',
            content: 'jakis podpis',
            messageType: ChatMessageType.file,
          ),
          receivedAtMillis: 1000,
        );

    expect(
      service.activeNotifications.single.body,
      chatMessageLabelForType(ChatMessageType.file),
    );
  });

  group('chatPreviewLine', () {
    test('a GIF gives the neutral label, with a caption or without', () {
      expect(
        chatPreviewLine(
          'kot tańczy',
          type: ChatMessageType.image,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        '🎞 GIF',
      );
      expect(
        chatPreviewLine(
          'gif.gif',
          type: ChatMessageType.image,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        '🎞 GIF',
      );
      expect(
        chatPreviewLine('', type: ChatMessageType.image, mimeType: 'IMAGE/GIF'),
        '🎞 GIF',
      );
      expect(
        chatPreviewLine(
          'podpis',
          type: ChatMessageType.image,
          fileName: 'Smiech.GIF',
        ),
        '🎞 GIF',
      );
    });

    test('plain text keeps its text', () {
      expect(chatPreviewLine('Hej!', type: ChatMessageType.text), 'Hej!');
      expect(chatPreviewLine('Hej!'), 'Hej!');
      expect(
        chatPreviewLine('Hej gif.gif', type: ChatMessageType.text),
        'Hej gif.gif',
      );
    });

    test('a photo, a video and a voice message show only their label', () {
      for (final ChatMessageType type in <ChatMessageType>[
        ChatMessageType.image,
        ChatMessageType.video,
        ChatMessageType.voice,
      ]) {
        for (final String text in <String>['podpis', 'plik.bin', '']) {
          final String line = chatPreviewLine(
            text,
            type: type,
            fileName: 'plik.bin',
            mimeType: 'application/octet-stream',
          );
          expect(line, chatMessageLabelForType(type, fileName: 'plik.bin'));
          expect(line, isNot(contains('plik.bin')));
          expect(line, isNot(contains('podpis')));
        }
      }
    });

    test('a plain file shows its label with the file name, not a caption', () {
      expect(
        chatPreviewLine(
          'zobacz to',
          type: ChatMessageType.file,
          fileName: 'raport.pdf',
          mimeType: 'application/pdf',
        ),
        '📎 raport.pdf',
      );
      expect(
        chatPreviewLine('raport.pdf', type: ChatMessageType.file),
        chatMessageLabelForType(ChatMessageType.file),
      );
      expect(
        chatPreviewLine(
          'gif.gif',
          type: ChatMessageType.file,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        '📎 gif.gif',
      );
    });
  });

  group('conversation preview of a GIF', () {
    test('an incoming GIF with a caption shows "GIF"', () async {
      final MemoryMessageTimelineStore timelineStore =
          MemoryMessageTimelineStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(timelineStore),
          socialHubSeedProvider.overrideWithValue(_seedWithAda()),
        ],
      );
      addTearDown(container.dispose);
      final SocialHubController controller = container.read(
        socialHubControllerProvider.notifier,
      );

      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          displayName: 'Ada',
          content: 'kot tańczy',
          messageType: ChatMessageType.image,
          fileName: 'gif.gif',
          mimeType: 'image/gif',
        ),
        receivedAtMillis: 1,
      );
      expect(
        container
            .read(socialHubControllerProvider)
            .friends['ada.ygg']!
            .lastMessagePreview,
        '🎞 GIF',
      );

      await controller.receiveSignal(
        const ZenSignal(
          type: ZenSignalType.message,
          sender: 'ada.ygg',
          displayName: 'Ada',
          content: 'Hej, już jestem.',
        ),
        receivedAtMillis: 2,
      );
      expect(
        container
            .read(socialHubControllerProvider)
            .friends['ada.ygg']!
            .lastMessagePreview,
        'Hej, już jestem.',
      );
    });

    test('an incoming GIF without a caption shows "GIF"', () async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(_seedWithAda()),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.message,
              sender: 'ada.ygg',
              displayName: 'Ada',
              messageType: ChatMessageType.image,
              fileName: 'klawiatura-1.gif',
              mimeType: 'image/gif',
            ),
            receivedAtMillis: 1,
          );
      expect(
        container
            .read(socialHubControllerProvider)
            .friends['ada.ygg']!
            .lastMessagePreview,
        '🎞 GIF',
      );
    });

    test('the preview rebuilt from the thread shows "GIF" too', () async {
      final int nowMillis = DateTime.now().millisecondsSinceEpoch;
      for (final String caption in <String>['kot tańczy', 'gif.gif']) {
        final MemoryMessageTimelineStore timelineStore =
            MemoryMessageTimelineStore(<String, List<ChatMessage>>{
              'ada.ygg': <ChatMessage>[
                ChatMessage(
                  id: 'old-text',
                  sender: 'ada.ygg',
                  text: 'Hej!',
                  sentAtMillis: nowMillis - 1000,
                  direction: ChatMessageDirection.incoming,
                ),
                ChatMessage(
                  id: 'last-gif',
                  sender: 'ada.ygg',
                  text: caption,
                  sentAtMillis: nowMillis,
                  direction: ChatMessageDirection.incoming,
                  type: ChatMessageType.image,
                  fileName: 'gif.gif',
                  mimeType: 'image/gif',
                ),
              ],
            });
        final ProviderContainer container = ProviderContainer(
          overrides: [
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            socialSnapshotStoreProvider.overrideWithValue(
              MemorySocialSnapshotStore(),
            ),
            messageTimelineStoreProvider.overrideWithValue(timelineStore),
            socialHubSeedProvider.overrideWithValue(_seedWithAda()),
          ],
        );
        addTearDown(container.dispose);

        await container
            .read(socialHubControllerProvider.notifier)
            .configureConversationRetention(
              peerAddress: 'ada.ygg',
              inboxLimitMb: 0,
              autoCleanupDays: 2,
            );
        expect(
          container
              .read(socialHubControllerProvider)
              .friends['ada.ygg']!
              .lastMessagePreview,
          '🎞 GIF',
        );
      }
    });
  });
}
