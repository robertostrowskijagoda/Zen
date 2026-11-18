import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/media/media_vault_sweep.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

import 'support/friends_world.dart';

/// Files of the media vault that nothing refers to any more: the ways a
/// chat used to leave them behind, and the sweep that removes what is left
/// without ever taking a file in use.

Future<void> _deliverFile(FriendsPhone to, FriendsPhone from, String id) async {
  final Uint8List whole = Uint8List.fromList(utf8.encode('plik $id'));
  final ZenSignal signal = zenSignalFromTransportPayload(
    sender: from.address,
    payload: <String, dynamic>{
      'type': 'message_chunk',
      'msgId': id,
      'text': 'lista.txt',
      'messageType': 'file',
      'fileName': 'lista.txt',
      'mimeType': 'text/plain',
      'attachmentSizeBytes': whole.length,
      'attachmentTransferBytes': whole.length,
      'chunkIndex': 0,
      'chunkCount': 1,
      'chunkData': base64Encode(whole),
    },
  )!;
  await to.hub.receiveSignal(signal, receivedAtMillis: to.world.now);
  await to.world.settle();
}

Future<String> _fileOf(FriendsPhone p, FriendsPhone peer, String id) async =>
    (await p.thread(
      peer,
    )).singleWhere((ChatMessage m) => m.id == id).attachmentPath!;

/// The vault files of [p] on disk.
Set<String> _onDisk(FriendsPhone p) {
  final Directory folder = Directory(
    '${p.directory.path}${Platform.pathSeparator}$kMediaVaultFolder',
  );
  if (!folder.existsSync()) {
    return <String>{};
  }
  return <String>{
    for (final FileSystemEntity e in folder.listSync()) e.uri.pathSegments.last,
  };
}

/// A clock three days ahead: every file is old enough.
DateTime _later() => DateTime.now().add(const Duration(days: 3));

bool _none(String _) => false;

/// [address] (an IPv6 address) written out in full and in capitals: the
/// same address, spelled another way.
String _otherSpelling(String address) {
  final Uint8List bytes = InternetAddress(address).rawAddress;
  return <String>[
    for (int i = 0; i < 16; i += 2)
      ((bytes[i] << 8) | bytes[i + 1]).toRadixString(16).padLeft(4, '0'),
  ].join(':').toUpperCase();
}

void main() {
  test('removing a friend deletes the files of the chat with them', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await _deliverFile(w['B'], w['A'], 'f1');
    final String path = await _fileOf(w['B'], w['A'], 'f1');
    expect(File(path).existsSync(), isTrue);

    await w['B'].hub.removeFriend(peerAddress: w['A'].address);
    expect(File(path).existsSync(), isFalse);
  });

  test('a friend who removes you leaves no files of the chat behind', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await _deliverFile(w['B'], w['A'], 'f2');
    final String path = await _fileOf(w['B'], w['A'], 'f2');

    await w['A'].hub.removeFriend(peerAddress: w['B'].address);
    await w.deliver();
    expect(await w['B'].thread(w['A']), isEmpty);
    expect(File(path).existsSync(), isFalse);
  });

  test('the sweep removes a file nothing refers to and keeps the ones in '
      'use', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await _deliverFile(w['B'], w['A'], 'f3');
    final String used = await _fileOf(w['B'], w['A'], 'f3');
    final MediaVault vault = w['B'].container.read(mediaVaultProvider);
    // Written, then the app stopped before anything recorded it.
    final String stray = await vault.put(Uint8List.fromList(<int>[1, 2, 3]));

    final MediaVaultSweepResult result = await w['B'].hub.sweepOrphanedMedia(
      inFlight: _none,
      now: _later,
    );
    expect(result.outcome, MediaVaultSweepOutcome.swept);
    expect(result.removed, 1);
    expect(File(stray).existsSync(), isFalse);
    expect(await vault.read(used), utf8.encode('plik f3'));
  });

  test('a file written in this run is never swept', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final MediaVault vault = w['B'].container.read(mediaVaultProvider);
    final String fresh = await vault.put(Uint8List.fromList(<int>[4, 5]));
    expect(MediaVault.madeThisRun(MediaVault.fileNameOf(fresh)), isTrue);

    await w['B'].hub.sweepOrphanedMedia(now: _later);
    expect(File(fresh).existsSync(), isTrue);
  });

  test('when what is in use cannot be read nothing is swept', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await _deliverFile(w['B'], w['A'], 'f4');
    final MediaVault vault = w['B'].container.read(mediaVaultProvider);
    await vault.put(Uint8List.fromList(<int>[6]));
    final Set<String> before = _onDisk(w['B']);
    // The index of the call recordings is damaged.
    await w['B'].container
        .read(ledgerDiskProvider)
        .write('recordings/index', Uint8List.fromList(utf8.encode('{"x"')));

    final MediaVaultSweepResult result = await w['B'].hub.sweepOrphanedMedia(
      inFlight: _none,
      now: _later,
    );
    expect(result.outcome, MediaVaultSweepOutcome.unreadable);
    expect(_onDisk(w['B']), before);
  });

  test('a conversation that does not read whole stops the sweep', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final FileMessageTimelineStore store = FileMessageTimelineStore.onDisk(
      disk,
    );
    await store.append(
      'peer',
      const ChatMessage(
        id: 'm1',
        sender: 'peer',
        text: 'x',
        sentAtMillis: 1,
        direction: ChatMessageDirection.incoming,
      ),
    );
    final String index = disk.files.keys.singleWhere(
      (String k) => k.endsWith('/idx'),
    );
    await disk.write(index, Uint8List.fromList(<int>[9, 9, 9]));
    await expectLater(store.loadStrict('peer'), throwsA(anything));
  });

  test('a file of a chat written under another spelling of the friend\'s '
      'address is found by the sweep and kept', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final String spelled = _otherSpelling(w['A'].address);
    expect(spelled, isNot(w['A'].address));
    expect(PeerShareCodec.addressesEqual(spelled, w['A'].address), isTrue);
    final MediaVault vault = w['B'].container.read(mediaVaultProvider);
    await w['B'].hub.sendLocalAttachment(
      peerAddress: spelled,
      attachmentPath: await vault.put(
        Uint8List.fromList(utf8.encode('plik f6')),
      ),
      fileName: 'lista.txt',
      mimeType: 'text/plain',
    );
    await w.settle();
    final MessageTimelineStore store = w['B'].container.read(
      messageTimelineStoreProvider,
    );
    final String path = (await store.load(
      spelled,
    )).singleWhere((ChatMessage m) => m.attachmentPath != null).attachmentPath!;

    await w['B'].hub.sweepOrphanedMedia(inFlight: _none, now: _later);
    expect(File(path).existsSync(), isTrue);
    // One chat with the friend, whichever spelling it is asked by.
    expect(
      (await w['B'].thread(w['A'])).map((ChatMessage m) => m.attachmentPath),
      contains(path),
    );
  });
}
