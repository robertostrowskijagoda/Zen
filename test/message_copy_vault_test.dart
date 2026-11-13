import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';

import 'support/friends_world.dart';

/// A message may be handed to the app more than once (a retry whose
/// confirmation got lost, a mailbox's copy, the relay layer handing it over
/// again when the app did not answer in time): its file is kept once.

int _vaultFiles(FriendsPhone p) => p.directory
    .listSync(recursive: true)
    .whereType<File>()
    .where((File f) => f.path.endsWith(kMediaVaultExtension))
    .length;

void main() {
  test('copies of a file message handed over again write no second file '
      'into the vault, and the message is there once', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    // A small file message as it travels inline (plain base64).
    final Map<String, dynamic> copy = <String, dynamic>{
      'type': 'message',
      'msgId': 'plik-1',
      'text': '📎 plan.bin',
      'messageType': 'file',
      'attachmentData': base64Encode(Uint8List(2000)..fillRange(0, 2000, 7)),
      'fileName': 'plan.bin',
      'mimeType': 'application/octet-stream',
      'attachmentSizeBytes': 2000,
      'createdAt': w.now,
    };
    final int empty = _vaultFiles(b);
    await b.hub.receiveSignal(
      zenSignalFromTransportPayload(sender: a.address, payload: copy)!,
      receivedAtMillis: w.now,
    );
    await w.settle();
    final int once = _vaultFiles(b);
    expect(once, empty + 1, reason: 'the file is kept once');
    final int noticesBefore = b.messageNotices.length;
    for (int i = 0; i < 3; i++) {
      await b.hub.receiveSignal(
        zenSignalFromTransportPayload(sender: a.address, payload: copy)!,
        receivedAtMillis: w.now,
      );
    }
    await w.settle();
    expect(_vaultFiles(b), once);
    expect(b.messageNotices.length, noticesBefore);
    final List<ChatMessage> thread = await b.thread(a);
    expect(thread.where((ChatMessage m) => m.id == 'plik-1'), hasLength(1));
    // The file kept is the one the message names.
    expect(
      isMediaVaultPath(
        thread.firstWhere((ChatMessage m) => m.id == 'plik-1').attachmentPath,
      ),
      isTrue,
    );
  });

  test('a copy of a file message deleted here writes no file either', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final Map<String, dynamic> copy = <String, dynamic>{
      'type': 'message',
      'msgId': 'plik-2',
      'text': '📎 notatka.bin',
      'messageType': 'file',
      'attachmentData': base64Encode(Uint8List(1500)..fillRange(0, 1500, 3)),
      'fileName': 'notatka.bin',
      'mimeType': 'application/octet-stream',
      'attachmentSizeBytes': 1500,
      'createdAt': w.now,
    };
    final int empty = _vaultFiles(b);
    await b.hub.receiveSignal(
      zenSignalFromTransportPayload(sender: a.address, payload: copy)!,
      receivedAtMillis: w.now,
    );
    await w.settle();
    expect(_vaultFiles(b), empty + 1);
    expect(
      await b.hub.deleteMessageLocally(key: a.address, messageId: 'plik-2'),
      isTrue,
    );
    expect(_vaultFiles(b), empty);
    await b.hub.receiveSignal(
      zenSignalFromTransportPayload(sender: a.address, payload: copy)!,
      receivedAtMillis: w.now,
    );
    await w.settle();
    expect(_vaultFiles(b), empty);
    expect(
      (await b.thread(a)).where((ChatMessage m) => m.id == 'plik-2'),
      isEmpty,
    );
  });
}
