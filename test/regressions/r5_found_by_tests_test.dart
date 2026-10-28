// Bugs the new automatic tests of round R5 found (not reported from the
// field yet), as R5-F<n>. Each skipped test is replaced by the real one with
// the fix; docs/TESTING.md, "Field report -> regression test".
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';

import '../support/damaged_files.dart';

String _b64(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

ChatMessage _message(String id, int at) => ChatMessage(
  id: id,
  sender: 'ada',
  text: id,
  sentAtMillis: at,
  direction: ChatMessageDirection.incoming,
);

void main() {
  late Directory root;
  late FileBinaryStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zen-r5-f-');
    store = sealedStore(root);
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps a file open a moment longer.
    }
  });

  group('R5-F1: a damaged relay state does not stop sending', () {
    // Before: FileRelayStateStore.load read `relay/state` outside its
    // try (relay_state_store.dart), so a file whose seal no longer opens
    // threw out of RelayEngine._load on every send; and one damaged mail
    // file threw the whole state away.
    Future<RelayState> saved() async {
      final RelayState state = RelayState(
        identity: await RelayIdentity.generate(),
        mailbox: <String, Map<String, Map<String, dynamic>>>{
          'ada': <String, Map<String, dynamic>>{
            'e1': <String, dynamic>{'id': 'e1', 'b': 'AAAA'},
          },
          'bob': <String, Map<String, dynamic>>{
            'e2': <String, dynamic>{'id': 'e2', 'b': 'BBBB'},
          },
        },
      );
      await FileRelayStateStore(store: store).save(state);
      return state;
    }

    test('the state itself damaged: a fresh state, set aside', () async {
      await saved();
      await damageStored(store, 'relay/state');

      final FileRelayStateStore relay = FileRelayStateStore(store: store);
      final RelayState loaded = await relay.load();

      expect(loaded.mailbox, isEmpty);
      expect(setAsideUnder(root), isNotEmpty);
      // And it saves again.
      await relay.save(loaded..identity = await RelayIdentity.generate());
      expect((await relay.load()).identity, isNotNull);
    });

    test('one friend\'s mail damaged: only that is left out', () async {
      final RelayState state = await saved();
      await damageStored(store, 'relay/mail/${_b64('ada')}');

      final RelayState loaded = await FileRelayStateStore(store: store).load();

      expect(loaded.identity!.publicKey, state.identity!.publicKey);
      expect(loaded.mailbox.keys, <String>['bob']);
      expect(setAsideUnder(root), hasLength(1));
    });
  });

  test('R5-F2: a damaged conversation file does not block that '
      'conversation', () async {
    // Before: FileMessageTimelineStore._open rethrew the index's read error
    // (message_timeline_store.dart), so every append to and load of that
    // conversation failed for good.
    const String ada = '200:1111:2222:3333:4444:5555:6666:7777';
    await FileMessageTimelineStore(
      store: store,
    ).append(ada, _message('old', 1));
    await damageStored(store, 'threads/${_b64(ada)}/idx');

    final FileMessageTimelineStore timelines = FileMessageTimelineStore(
      store: store,
    );
    await timelines.append(
      ada,
      _message('new', DateTime.now().millisecondsSinceEpoch + 1),
    );
    final List<ChatMessage> shown = await timelines.load(ada);

    expect(shown.map((ChatMessage m) => m.id).last, 'new');
    expect(shown.first.isSystem, isTrue, reason: 'a note on the old history');
    expect(setAsideUnder(root), hasLength(1));
    // After a restart too.
    final List<ChatMessage> again = await FileMessageTimelineStore(
      store: store,
    ).load(ada);
    expect(again.map((ChatMessage m) => m.id), shown.map((m) => m.id));
  });

  test('R5-F3: logging an error with a chained stack trace never throws', () {
    // Before: logZenError handed the trace to debugPrintStack, whose frame
    // parser asserts on package:stack_trace's '===== asynchronous gap',
    // so the error being logged was lost and a new one thrown.
    final StackTrace chained = StackTrace.fromString(
      '#0      LedgerArchive._load (package:zen/src/a.dart:1:1)\n'
      '===== asynchronous gap ===========================\n'
      'package:zen/src/b.dart 2:3  LedgerNode._start\n',
    );
    final List<String> printed = <String>[];
    final DebugPrintCallback previous = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        printed.add(message);
      }
    };
    try {
      logZenError('Starting the ledger failed', StateError('x'), chained);
      logZenUncaught('Unhandled', StateError('y'), chained);
    } finally {
      debugPrint = previous;
    }
    expect(printed.join('\n'), contains('Starting the ledger failed'));
    expect(printed.join('\n'), contains('asynchronous gap'));
  });

  test(
    'R5-F4: the Go bridge never deadlocks when a session opens while '
    'packets come in',
    () {},
    skip:
        'R5-F4 open: the bridge packet loop (bridge_signaling.go, '
        'startPacketLoop -> openSignal) writes the session reply from inside '
        'the read loop (pq_session.go open(): e.write(source, reply)); when '
        "ironwood's session actor waits for that same reader, every later "
        'call into the core blocks for good, YggGetNodeInfo on the app UI '
        'thread included (traffic_meter.go sampleTrafficAt -> GetSessions): '
        'the app freezes. Found by tool/e2e.dart (test/e2e), about one run '
        'in three on Windows; the goroutines are in the job log.',
  );

  test(
    'R5-F5: a first contact (and the first after a restart) takes seconds, '
    'not 14',
    () {},
    skip:
        'R5-F5 open: two devices that never talked (or one just restarted) '
        'exchange nothing for about 14 s on one computer: the post-quantum '
        'session is set up first and its multi-packet key frames meet the '
        "one-packet buffer of Yggdrasil's ipv6rwc for a destination whose key "
        'is still being looked up (likely; see R5-#9, #15). Measured by '
        'test/e2e (kInvitationWithin, kAfterRestartWithin).',
  );
}
