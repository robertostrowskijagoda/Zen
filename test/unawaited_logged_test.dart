import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/reaction_digest.dart';

// Work left to run in the background logs its failures instead of leaving
// them unhandled, whatever the work returns.

final class _UnreadableDisk implements LedgerDisk {
  @override
  Future<Uint8List?> read(String key) async =>
      throw const FormatException('too big');

  @override
  Future<void> write(String key, Uint8List data) async {}

  @override
  Future<void> delete(String key) async {}
}

void main() {
  test('a failing Future<int> is logged, not left unhandled', () async {
    final List<Object> unhandled = <Object>[];
    await runZonedGuarded(() async {
      Future<int> work() async {
        await Future<void>.delayed(Duration.zero);
        throw StateError('broken');
      }

      unawaitedLogged(work(), context: 'A test task failed');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }, (Object error, StackTrace _) => unhandled.add(error));
    expect(unhandled, isEmpty);
  });

  test('the reactions seen of an unreadable file start afresh', () async {
    final ReactionsSeen seen = await ReactionsSeen.load(_UnreadableDisk());
    expect(seen.fresh, isTrue);
  });
}
