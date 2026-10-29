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

List<String> _idsOf(List<ChatMessage> messages) => <String>[
  for (final ChatMessage m in messages) m.id,
];

const String _bridge = 'native/yggdrasil_bridge';

/// The bridge's Go sources, without its tests.
List<File> _goSources() =>
    Directory(_bridge)
        .listSync()
        .whereType<File>()
        .where(
          (File f) => f.path.endsWith('.go') && !f.path.endsWith('_test.go'),
        )
        .toList()
      ..sort((File a, File b) => a.path.compareTo(b.path));

String _nameOf(File file) => file.path.split(RegExp(r'[/\\]')).last;

/// [source] without its `//` comments (they name what the code no longer
/// does).
String _withoutComments(String source) =>
    source.replaceAll(RegExp(r'//[^\n]*'), '');

/// Each Go test function named in [tests] is in its file.
void _expectGoTests(Map<String, List<String>> tests) {
  for (final MapEntry<String, List<String>> e in tests.entries) {
    final String source = File('$_bridge/${e.key}').readAsStringSync();
    for (final String name in e.value) {
      expect(
        source,
        contains('func $name(t *testing.T)'),
        reason: '${e.key}: $name',
      );
    }
  }
}

/// The seconds of the Go constant [name] (`const name = 3 * time.Second`).
int _goSeconds(String source, String name) {
  final RegExpMatch? match = RegExp(
    'const $name = (\\d+) \\* time\\.Second',
  ).firstMatch(source);
  expect(match, isNotNull, reason: name);
  return int.parse(match!.group(1)!);
}

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

  group('R5-F2: a damaged conversation file does not block that '
      'conversation', () {
    // Before: FileMessageTimelineStore._open rethrew the index's read error
    // (message_timeline_store.dart), so every append to and load of that
    // conversation failed for good.
    const String ada = '200:1111:2222:3333:4444:5555:6666:7777';

    test('the index damaged: rebuilt from the pieces, nothing lost', () async {
      await FileMessageTimelineStore(
        store: store,
      ).append(ada, _message('old', 1));
      await damageStored(store, 'threads/${_b64(ada)}/idx');

      final FileMessageTimelineStore timelines = FileMessageTimelineStore(
        store: store,
      );
      await timelines.append(ada, _message('new', 2));

      expect(_idsOf(await timelines.load(ada)), <String>['old', 'new']);
      expect(setAsideUnder(root), hasLength(1));
      // After a restart too.
      expect(
        _idsOf(await FileMessageTimelineStore(store: store).load(ada)),
        <String>['old', 'new'],
      );
    });

    test('the index and its piece damaged: the conversation goes on with a '
        'note on what was lost', () async {
      await FileMessageTimelineStore(
        store: store,
      ).append(ada, _message('old', 1));
      await damageStored(store, 'threads/${_b64(ada)}/idx');
      await damageStored(store, 'threads/${_b64(ada)}/seg/0');

      final FileMessageTimelineStore timelines = FileMessageTimelineStore(
        store: store,
      );
      await timelines.append(
        ada,
        _message('new', DateTime.now().millisecondsSinceEpoch + 1),
      );
      final List<ChatMessage> shown = await timelines.load(ada);

      expect(shown.last.id, 'new');
      expect(shown.first.isSystem, isTrue, reason: 'a note on what was lost');
    });
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

  // R5-F4 and R5-F5 live in the Go bridge, whose tests (native/
  // yggdrasil_bridge, the bridge job of CI) guard the fixes on loopback
  // nodes, and the real-node tests (test/e2e) on whole apps. Here: that
  // those Go tests stay, and that nothing writes to the mesh core past the
  // writer.
  //
  // R5-F4, before: the bridge packet loop (bridge_signaling.go,
  // startPacketLoop -> openSignal) wrote the session reply from inside the
  // read loop (pq_session.go open(): e.write(source, reply), through
  // ipv6rwc); when ironwood's session actor waited for that same reader,
  // every later call into the core blocked for good, YggGetNodeInfo on the
  // app's UI thread included: the app froze (tool/e2e.dart, about one run in
  // three on Windows). Fixed by mesh_io.go (a writer queue of its own,
  // 7e03d33c) and node_view.go (the app's questions answered from a view of
  // the core taken off its thread, 8f2621be).
  test('R5-F4: the Go bridge never deadlocks when a session opens while '
      'packets come in: only the mesh writer writes to the core', () {
    final List<String> writers = <String>[
      for (final File go in _goSources())
        if (RegExp(
          r'\.WriteTo\(|ipv6rwc\.',
        ).hasMatch(_withoutComments(go.readAsStringSync())))
          _nameOf(go),
    ];
    expect(writers, <String>['mesh_io.go']);
  });

  test('R5-F4: the Go tests of the deadlock are there', () {
    _expectGoTests(<String, List<String>>{
      'packet_loop_test.go': <String>[
        'TestPacketLoopNeverWaitsForTheMesh',
        'TestNodeInfoAnswersWhileTheMeshCoreIsStalled',
        'TestNodesUnderLoadKeepAnswering',
      ],
      'mesh_io_test.go': <String>[
        'TestMeshSendNeverWaitsForTheCore',
        'TestMeshIOUnderLoad',
      ],
      'node_view_test.go': <String>[
        'TestCoreQueryNeverWaitsLongerThanItsWait',
        'TestCoreActionGivesUpOnAStuckCore',
      ],
    });
  });

  // R5-F5, before: two devices that never talked (or one just restarted)
  // exchanged nothing for about 14 s on one computer: the post-quantum
  // session's key frames went in several packets while every layer below
  // keeps one per destination still being set up. Fixed in mesh_io.go (one
  // packet opens the way, what a restarted peer lost goes again: 7e03d33c,
  // 73f076a3, 564205e9) and pq_session.go (c2bc5347, 492046b9); also
  // test/e2e (kInvitationWithin, kAfterRestartWithin).
  test('R5-F5: a first contact (and the first after a restart) takes '
      'seconds, not 14', () {
    _expectGoTests(<String, List<String>>{
      'packet_loop_test.go': <String>[
        'TestFirstContactArrivesQuickly',
        'TestMessagesFlowQuicklyAfterARestart',
        'TestFriendReachesARestartedDeviceQuickly',
        'TestFriendReachesASilentlyRestartedDevice',
        'TestAMessageSoonAfterARestartIsNotLost',
      ],
      'mesh_io_test.go': <String>[
        'TestMeshOpensTheWayWithOnePacketAndThenSendsTheRest',
        'TestMeshSendsAgainWhatWentAlongAPathThatBroke',
        'TestMeshEchoesWhatGoesToANodeThatCameBack',
        'TestMeshHailsANodeThatReachedItUnasked',
      ],
      'pq_session_test.go': <String>[
        'TestPQFramesLostToARestartGoAgainWhenThePeerAsksForKeys',
        'TestPQPeerThatRestartedHasItsWaySettle',
        'TestPQHailedFriendSendsAgainWhatAPeerLostToARestart',
      ],
    });
    final String loop = File('$_bridge/packet_loop_test.go').readAsStringSync();
    expect(_goSeconds(loop, 'firstContactBound'), lessThanOrEqualTo(5));
    expect(_goSeconds(loop, 'afterRestartBound'), lessThanOrEqualTo(5));
  });
}
