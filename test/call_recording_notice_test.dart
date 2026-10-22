import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/calls/call_recordings.dart';
import 'package:zen/src/features/calls/presentation/call_recording_notice.dart';
import 'package:zen/src/features/media/media_vault.dart';

void main() {
  testWidgets('a recording that was not stored is shown until it is', (
    WidgetTester tester,
  ) async {
    final Directory root = Directory.systemTemp.createTempSync('zen-unsaved-');
    addTearDown(() => root.deleteSync(recursive: true));
    Uint8List? key;
    final CallRecordingKeeper keeper = CallRecordingKeeper(
      CallRecordingStore(
        MemoryLedgerDisk(),
        MediaVault(
          masterKey: () async => key,
          supportDirectory: () async => root,
          temporaryDirectory: () async => root,
        ),
      ),
    );
    final File first = File('${root.path}/zen_rec_1.wav')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final File second = File('${root.path}/zen_rec_2.wav')
      ..writeAsBytesSync(<int>[4, 5]);
    const Key banner = Key('unsaved-call-recordings');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [callRecordingKeeperProvider.overrideWithValue(keeper)],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const Scaffold(body: UnsavedCallRecordingsBanner()),
        ),
      ),
    );
    expect(find.byKey(banner), findsNothing);

    // Locked: the recording cannot be encrypted, so it is not "saved".
    expect(
      await tester.runAsync(
        () => keeper.keep(path: first.path, mime: 'audio/wav', label: 'Ola'),
      ),
      CallRecordingOutcome.failed,
    );
    await tester.pump();
    expect(find.byKey(banner), findsOneWidget);
    expect(find.text(unsavedCallRecordingText()), findsOneWidget);
    expect(first.existsSync(), isTrue);

    // Unlocked: another try stores it and the notice goes.
    key = Uint8List.fromList(List<int>.filled(32, 3));
    expect(await tester.runAsync(keeper.retry), isTrue);
    await tester.pump();
    expect(find.byKey(banner), findsNothing);
    expect(first.existsSync(), isFalse);

    // Given up: the notice goes as well.
    key = null;
    await tester.runAsync(
      () => keeper.keep(path: second.path, mime: 'audio/wav', label: 'Ola'),
    );
    await tester.pump();
    expect(find.byKey(banner), findsOneWidget);
    await tester.tap(find.byKey(const Key('unsaved-call-recordings-discard')));
    await tester.pump();
    expect(find.byKey(banner), findsNothing);
    expect(keeper.unsaved, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    keeper.dispose();
  });
}
