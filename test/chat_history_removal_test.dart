import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/friends_world.dart';

/// What is removed from a phone stays removed: a cleared chat, a message
/// deleted from this device, a group left or declined. Nothing comes back
/// from a late chunk, a chunk sent again or another device of the account,
/// and nothing stays on the phone out of reach.

Map<String, dynamic> _chunk(String id, Uint8List whole, int index, int count) {
  final int size = (whole.length / count).ceil();
  final int start = index * size;
  final int end = (start + size).clamp(0, whole.length);
  return <String, dynamic>{
    'type': 'message_chunk',
    'msgId': id,
    'text': 'lista.txt',
    'messageType': 'file',
    'fileName': 'lista.txt',
    'mimeType': 'text/plain',
    'attachmentSizeBytes': whole.length,
    'attachmentTransferBytes': whole.length,
    'chunkIndex': index,
    'chunkCount': count,
    'chunkData': base64Encode(whole.sublist(start, end)),
  };
}

Future<void> _deliver(
  FriendsPhone to,
  FriendsPhone from,
  Map<String, dynamic> payload,
) async {
  final ZenSignal signal = zenSignalFromTransportPayload(
    sender: from.address,
    payload: payload,
  )!;
  await to.hub.receiveSignal(signal, receivedAtMillis: to.world.now);
  await to.world.settle();
}

/// Whether [vault] still holds a file at [path].
Future<bool> _held(MediaVault vault, String path) async {
  try {
    return (await vault.read(path)).isNotEmpty;
  } on Object {
    return false;
  }
}

/// The entries of [p]'s list of notifications that lead to group [id].
List<InboxEntry> _groupEntries(FriendsPhone p, String id) => <InboxEntry>[
  for (final InboxEntry e in <InboxEntry>[
    ...p.state.inbox,
    ...p.state.backgroundAlerts,
  ])
    if (e.routeKey?.contains(id) ?? false) e,
];

void main() {
  test('a chunk that comes after the chat was cleared brings back no file '
      'message that can never finish', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final Uint8List file = Uint8List.fromList(
      utf8.encode('Lista zakupów: chleb, mleko, masło, ser, jajka'),
    );
    await _deliver(w['B'], w['A'], _chunk('f1', file, 0, 2));
    expect(
      (await w['B'].thread(w['A'])).where((ChatMessage m) => m.id == 'f1'),
      hasLength(1),
    );
    await w['B'].hub.clearConversationHistory(peerAddress: w['A'].address);
    expect(await w['B'].thread(w['A']), isEmpty);

    // The sender's second chunk was already on its way.
    await _deliver(w['B'], w['A'], _chunk('f1', file, 1, 2));
    expect(await w['B'].thread(w['A']), isEmpty);
  });

  test('the last chunk again after the file was put together is only '
      'acknowledged, not stored a second time', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final Uint8List file = Uint8List.fromList(utf8.encode('jeden kawałek'));
    await _deliver(w['B'], w['A'], _chunk('f2', file, 0, 1));
    final String first = (await w['B'].thread(
      w['A'],
    )).singleWhere((ChatMessage m) => m.id == 'f2').attachmentPath!;
    // The acknowledgement got lost: the sender sends the chunk again.
    await _deliver(w['B'], w['A'], _chunk('f2', file, 0, 1));
    final String second = (await w['B'].thread(
      w['A'],
    )).singleWhere((ChatMessage m) => m.id == 'f2').attachmentPath!;
    expect(second, first, reason: 'one file, not a second copy');
  });

  test('a message deleted from this device does not come back from another '
      'device of the account', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w.send(w['A'], w['B'], 'Tylko dla Ciebie');
    await w.deliver();
    final ChatMessage got = (await w['B'].thread(
      w['A'],
    )).singleWhere((ChatMessage m) => m.text == 'Tylko dla Ciebie');
    expect(
      await w['B'].hub.deleteMessageLocally(
        key: w['A'].address,
        messageId: got.id,
      ),
      isTrue,
    );

    // Another device of B's account passes the message on (its file came
    // whole there, or its history goes to a device linked later).
    await w['B'].hub.importSyncedMessage(w['A'].address, got);
    expect(
      (await w['B'].thread(w['A'])).where((ChatMessage m) => m.id == got.id),
      isEmpty,
    );
  });

  test('a cleared chat does not come back from another device of the '
      'account', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w.send(w['A'], w['B'], 'Stara rozmowa');
    await w.deliver();
    final List<ChatMessage> before = await w['B'].thread(w['A']);
    expect(before, isNotEmpty);
    await w['B'].hub.clearConversationHistory(peerAddress: w['A'].address);

    for (final ChatMessage m in before) {
      await w['B'].hub.importSyncedMessage(w['A'].address, m);
    }
    expect(await w['B'].thread(w['A']), isEmpty);
  });

  test('after leaving a group its chat, files and notifications are gone '
      'from the phone', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final String id = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
      w['B'],
    ]);
    await w.deliver();
    final Uint8List file = Uint8List.fromList(
      'Lista zakupów: chleb, mleko'.codeUnits,
    );
    await w['A'].hub.sendGroupAttachment(
      groupId: id,
      bytes: file,
      fileName: 'lista.txt',
      mimeType: 'text/plain',
      type: ChatMessageType.file,
    );
    await w.sendGroup(w['A'], id, 'tajny plan');
    await w.deliver();
    final ChatMessage got = (await w['B'].thread(
      'group:$id',
    )).firstWhere((ChatMessage m) => m.attachmentPath != null);
    final MediaVault vault = w['B'].container.read(mediaVaultProvider);
    expect(await vault.read(got.attachmentPath!), file);
    expect(_groupEntries(w['B'], id), isNotEmpty);

    await w['B'].hub.leaveGroup(groupId: id);
    await w.deliver();
    expect(w['B'].state.groups.containsKey(id), isFalse, reason: 'left');

    expect(await w['B'].thread('group:$id'), isEmpty);
    expect(await _held(vault, got.attachmentPath!), isFalse);
    expect(_groupEntries(w['B'], id), isEmpty);
    expect(
      w['B'].shownMessageNotices.where(
        (n) =>
            n.body.contains('tajny plan') ||
            n.lines.any((String l) => l.contains('tajny plan')),
      ),
      isEmpty,
    );
  });

  test(
    'a group left on another device of the account is cleared here too',
    () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      final String id = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
        w['B'],
      ]);
      await w.sendGroup(w['A'], id, 'plan na sobote');
      await w.deliver();
      expect(await w['B'].thread('group:$id'), isNotEmpty);

      await w['B'].hub.forgetGroupFromOtherDevice(id);
      expect(await w['B'].thread('group:$id'), isEmpty);
      expect(_groupEntries(w['B'], id), isEmpty);
    },
  );

  test('"Wyczyść historię" in a group clears its chat on this phone; the '
      'group stays', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final String id = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
      w['B'],
    ]);
    await w.sendGroup(w['A'], id, 'stare ustalenia');
    await w.deliver();
    expect(await w['B'].thread('group:$id'), isNotEmpty);

    await w['B'].hub.clearGroupHistory(groupId: id);
    expect(await w['B'].thread('group:$id'), isEmpty);
    expect(_groupEntries(w['B'], id), isEmpty);
    expect(w['B'].state.groups.containsKey(id), isTrue);

    // The group goes on: what comes next is shown.
    await w.sendGroup(w['A'], id, 'nowe ustalenia');
    await w.deliver();
    expect(await w.groupTexts(w['B'], id), contains('nowe ustalenia'));
  });

  test('declining a group invitation leaves nothing of the group', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final group = await w['A'].hub.createGroup(
      name: 'Ekipa',
      description: '',
      memberAddresses: <String>[w['B'].address],
    );
    await w.deliver();
    expect(w['B'].state.groups[group.id]?.isInvitePending, isTrue);
    await w.sendGroup(w['A'], group.id, 'zanim dolaczysz');
    await w.deliver();

    await w['B'].hub.rejectGroupInvite(
      groupId: group.id,
      inboxEntryId: '',
      senderAddress: w['A'].address,
    );
    await w.deliver();
    expect(await w['B'].thread('group:${group.id}'), isEmpty);
    expect(_groupEntries(w['B'], group.id), isEmpty);
  });
}
