import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/media/media_vault.dart';

import 'support/friends_world.dart';

/// A file to a friend whose account has two devices reaches both whole:
/// the pieces are acknowledged for the account as a whole, so the transfer
/// ended once one device had it all, and the other showed the file without
/// its content (or, offline then, nothing). The device that has it passes
/// it on to the account's other devices (device_chat_sync.dart).

Future<Uint8List?> _fileOn(FriendsPhone phone, FriendsPhone from) async {
  for (final ChatMessage m in await phone.thread(from)) {
    if (m.direction == ChatMessageDirection.incoming &&
        m.fileName == 'plan.bin') {
      final String? path = m.attachmentPath;
      return m.attachmentBytes ??
          (path == null
              ? null
              : await phone.container.read(mediaVaultProvider).read(path));
    }
  }
  return null;
}

void main() {
  for (final int size in <int>[2000, 150000]) {
    for (final bool offline in <bool>[false, true]) {
      test('a file of $size bytes reaches the second device too'
          '${offline ? ', which was offline when it was sent' : ''}', () async {
        final FriendsWorld w = await FriendsWorld.create(<String>[
          'A',
          'B',
          'C',
        ], ledgers: true);
        final FriendsPhone b2 = await w.addDevice(w['B'], 'B2');
        await w.advance(const Duration(minutes: 2));
        if (offline) {
          await w.setOnline(b2, false);
        }
        final Uint8List file = Uint8List(size)..fillRange(0, size, 7);
        await w['A'].hub.sendLocalAttachment(
          peerAddress: w['B'].address,
          bytes: file,
          fileName: 'plan.bin',
          mimeType: 'application/octet-stream',
          sentAtMillis: w.now,
        );
        await w.advance(const Duration(minutes: 2));
        if (offline) {
          await w.setOnline(b2, true);
        }
        await w.until(
          () async => (await _fileOn(b2, w['A']))?.length == size,
          within: const Duration(minutes: 30),
          reason: 'the file on the second device',
        );
        expect(await _fileOn(w['B'], w['A']), file);
        expect(await _fileOn(b2, w['A']), file);
      });
    }
  }
}
