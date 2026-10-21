import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/social/social_event_text.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// Saved texts kept as events and put into words when shown:
/// system lines in chats and inbox entries follow the app's language.
void main() {
  tearDown(ZenI18n.debugReset);

  const Map<String, Object?> english = <String, Object?>{
    'Połączenie z {name} jest gotowe.': 'Connected with {name}.',
    '{name} zaakceptował(a) zaproszenie': '{name} accepted the invitation',
    'Możecie już pisać i dzwonić.': 'You can write and call now.',
    'Odrzucono rozmowę {kind}.': 'Declined the {kind} call.',
    'wideo': 'video',
    'Ktoś': 'Someone',
  };

  group('SocialEventText', () {
    test('renders the same Polish text the code wrote before', () {
      expect(
        const SocialEventText('chat.connected', <String, String>{
          'name': 'Ada',
        }).render(),
        'Połączenie z Ada jest gotowe.',
      );
      expect(
        const SocialEventText('call.busy', <String, String>{
          'name': 'Ada',
          'kind': 'video',
        }).render(),
        'Ada jest aktualnie zajęty(a) i nie może odebrać rozmowy wideo.',
      );
      expect(
        const SocialEventText('call.declined', <String, String>{
          'kind': 'audio',
        }).render(),
        'Odrzucono rozmowę audio.',
      );
      expect(
        const SocialEventText('inbox.groupInvite').render(),
        'Zaproszenie do grupy: Nowa grupa',
      );
      expect(
        const SocialEventText('inbox.groupMessage', <String, String>{
          'name': 'Ada',
        }).render(),
        'Grupa: Ada',
      );
    });

    test('follows the language of the moment, defaults included', () {
      const SocialEventText event = SocialEventText(
        'call.declined',
        <String, String>{'kind': 'video'},
      );
      expect(event.render(), 'Odrzucono rozmowę wideo.');
      ZenI18n.debugUse('en', english);
      expect(event.render(), 'Declined the video call.');
      expect(
        const SocialEventText('chat.connected').render(),
        'Connected with Someone.',
      );
    });

    test('an unknown code gives the saved text', () {
      const SocialEventText event = SocialEventText('from.a.newer.build');
      expect(event.renderOrNull(), isNull);
      expect(event.render('Zapisany tekst'), 'Zapisany tekst');
    });

    test('encodes and decodes; junk is no event', () {
      const SocialEventText event = SocialEventText(
        'group.added',
        <String, String>{'name': 'Ada', 'members': 'Bob, Cyryl'},
      );
      expect(SocialEventText.decode(event.encode()), event);
      expect(SocialEventText.decode(null), isNull);
      expect(SocialEventText.decode('not json'), isNull);
      expect(SocialEventText.decode('{"c": 5}'), isNull);
      expect(SocialEventText.decode('[]'), isNull);
      final SocialEventText? cut = SocialEventText.decode(
        '{"c":"chat.connected","a":{"name":"${'x' * 5000}","n":1}}',
      );
      expect(cut!.args['name'], hasLength(2000));
      expect(cut.args.containsKey('n'), isFalse);
    });
  });

  group('system messages', () {
    test('carry their event and are shown in the current language', () {
      const SocialEventText event = SocialEventText(
        'chat.connected',
        <String, String>{'name': 'Ada'},
      );
      final ChatMessage message = chatMessageWithEvent(
        ChatMessage(
          id: 'system-1',
          sender: 'system',
          text: event.render(),
          sentAtMillis: 1,
          direction: ChatMessageDirection.system,
        ),
        event,
      );
      expect(message.text, 'Połączenie z Ada jest gotowe.');
      expect(message.hasAttachment, isFalse);
      expect(message.isGif, isFalse);
      expect(chatMessageText(message), 'Połączenie z Ada jest gotowe.');
      ZenI18n.debugUse('en', english);
      expect(chatMessageText(message), 'Connected with Ada.');
    });

    test('older ones (plain text) and other messages stay as saved', () {
      ZenI18n.debugUse('en', english);
      const ChatMessage old = ChatMessage(
        id: 'system-0',
        sender: 'system',
        text: 'Połączenie z Ada jest gotowe.',
        sentAtMillis: 1,
        direction: ChatMessageDirection.system,
      );
      expect(chatMessageText(old), 'Połączenie z Ada jest gotowe.');
      const ChatMessage incoming = ChatMessage(
        id: 'm-1',
        sender: 'ada.ygg',
        text: 'hej',
        sentAtMillis: 1,
        direction: ChatMessageDirection.incoming,
        fileName: '{"c":"chat.connected"}',
        mimeType: kSocialEventMimeType,
      );
      expect(chatMessageText(incoming), 'hej');
    });
  });

  group('inbox entries', () {
    InboxEntry accepted() => InboxEntry.fromEvents(
      id: 'friend-accept-1-ada.ygg',
      type: InboxEntryType.friendAccepted,
      title: const SocialEventText('inbox.friendAccepted', <String, String>{
        'name': 'Ada',
      }),
      body: const SocialEventText('inbox.friendAccepted.body'),
      createdAtMillis: 1,
      peerAddress: 'ada.ygg',
    );

    test('keep the text of their making and show the current language', () {
      final InboxEntry entry = accepted();
      expect(entry.title, 'Ada zaakceptował(a) zaproszenie');
      expect(entry.body, 'Możecie już pisać i dzwonić.');
      ZenI18n.debugUse('en', english);
      expect(entry.displayTitle, 'Ada accepted the invitation');
      expect(entry.displayBody, 'You can write and call now.');
    });

    test("a friend's own words are not an event", () {
      final InboxEntry entry = InboxEntry.fromEvents(
        id: 'friend-request-1-ada.ygg',
        type: InboxEntryType.friendRequest,
        title: const SocialEventText('inbox.friendRequest', <String, String>{
          'name': 'Ada',
        }),
        body: const SocialEventText('inbox.friendRequest.body'),
        bodyText: 'Cześć, to ja!',
        createdAtMillis: 1,
      );
      expect(entry.bodyEvent, isNull);
      ZenI18n.debugUse('en', english);
      expect(entry.displayBody, 'Cześć, to ja!');
    });

    test(
      'the events survive the snapshot; older entries read as before',
      () async {
        final Directory dir = await Directory.systemTemp.createTemp(
          'zen-social-event-test-',
        );
        addTearDown(() => dir.delete(recursive: true));
        final FileSocialSnapshotStore store = FileSocialSnapshotStore(
          store: FileBinaryStore(
            dir,
            codec: BinaryCodec(compressor: const _PassThroughCompressor()),
          ),
        );
        await store.save(
          SocialHubState(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.foreground,
              generation: 1,
              capturedAtMillis: 1,
            ),
            friends: const <String, FriendProfile>{},
            inbox: <InboxEntry>[
              accepted(),
              const InboxEntry(
                id: 'old-1',
                type: InboxEntryType.message,
                title: 'Nowa wiadomość od Ady',
                body: 'hej',
                createdAtMillis: 0,
              ),
            ],
            pendingSignalCount: 0,
            backgroundAlerts: <InboxEntry>[accepted()],
          ),
        );
        final SocialHubState restored = (await store.load())!;
        expect(restored.inbox.first.titleEvent, accepted().titleEvent);
        expect(restored.inbox.first.bodyEvent, accepted().bodyEvent);
        expect(restored.backgroundAlerts.single.titleEvent, isNotNull);
        expect(restored.inbox.last.titleEvent, isNull);
        ZenI18n.debugUse('en', english);
        expect(
          restored.inbox.first.displayTitle,
          'Ada accepted the invitation',
        );
        expect(restored.inbox.last.displayTitle, 'Nowa wiadomość od Ady');
      },
    );
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async => input;

  @override
  Future<Uint8List?> decompress(Uint8List input) async => input;
}
