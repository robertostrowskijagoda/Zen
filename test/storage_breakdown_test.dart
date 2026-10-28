import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/storage_retention.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/presentation/storage_usage_section.dart';
import 'package:zen/src/features/settings/storage_breakdown.dart';

const int _mb = 1024 * 1024;

void main() {
  test('the default limit is 1 GB, with no separate limit for the wall', () {
    const AppSettings settings = AppSettings();
    expect(settings.inboxLimitMb, 1024);
    expect(settings.inboxLimitLabel, '1 GB');
    expect(settings.feedLimitMb, 0);
    expect(AppSettings.storageLimitLabel(512), '512 MB');
    expect(AppSettings.storageLimitLabel(1536), '1.5 GB');
    final AppSettings back = AppSettings.fromJson(
      const AppSettings(feedLimitMb: 250).toJson(),
    );
    expect(back.feedLimitMb, 250);
    expect(back.inboxLimitMb, 1024);
  });

  test('the slider snaps to the nearest step', () {
    expect(StorageLimitSlider.indexOf(1024), 6);
    expect(StorageLimitSlider.indexOf(80), 3);
    expect(StorageLimitSlider.indexOf(100000), 9);
  });

  group('measureStorage', () {
    late Directory support;

    setUp(() {
      support = Directory.systemTemp.createTempSync('zen_breakdown');
      addTearDown(() => support.deleteSync(recursive: true));
    });

    void file(String relative, int bytes) {
      final File f = File(
        '${support.path}${Platform.pathSeparator}'
        '${relative.replaceAll('/', Platform.pathSeparator)}',
      )..createSync(recursive: true);
      f.writeAsBytesSync(List<int>.filled(bytes, 1));
    }

    test('splits media, the wall, exports and the rest', () async {
      file('data/hidden/ab/x.zenbin', 5000);
      file('data/transfers/t.zenbin', 2000);
      file('vault/a.zmedia', 3000);
      file('settings/s.zenbin', 100);
      // Other accounts are not this account's room.
      file('accounts/second/data/y.zenbin', 9000);
      final File exported = File(
        '${support.path}${Platform.pathSeparator}..${Platform.pathSeparator}'
        'zen_export_${support.hashCode}.bin',
      )..writeAsBytesSync(List<int>.filled(700, 1));
      addTearDown(() {
        if (exported.existsSync()) {
          exported.deleteSync();
        }
      });
      final StorageBreakdown out = await measureStorage(
        support: support,
        usage: const StorageUsage(friendBytes: 1500, cacheBytes: 500),
        exportedPaths: <String>[
          exported.path,
          'content://some/document',
          '${support.path}${Platform.pathSeparator}gone.bin',
        ],
      );
      expect(out.mediaBytes, 5000);
      expect(out.feedBytes, 2000);
      expect(out.backupsBytes, 700);
      // 5000 + 2000 + 3000 + 100 in the account's folder, minus the rest.
      expect(out.otherBytes, 10100 - 5000 - 2000);
      expect(out.totalBytes, 10100 + 700);
    });

    test('an empty or missing folder is zero', () async {
      final StorageBreakdown out = await measureStorage(
        support: Directory('${support.path}${Platform.pathSeparator}nope'),
        usage: const StorageUsage(),
      );
      expect(out.totalBytes, 0);
    });
  });

  group('the "Dane i pamięć" usage block', () {
    Future<MemoryAppSettingsStore> pump(
      WidgetTester tester,
      StorageBreakdown? usage, {
      AppSettings settings = const AppSettings(),
    }) async {
      final MemoryAppSettingsStore store = MemoryAppSettingsStore(settings);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsStoreProvider.overrideWithValue(store),
            storageBreakdownProvider.overrideWith((Ref ref) async => usage),
          ],
          child: MaterialApp(
            theme: ZenTheme.light(),
            home: const Scaffold(
              body: SingleChildScrollView(child: StorageUsageSection()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return store;
    }

    testWidgets('shows the total against the limit with a bar and the parts', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        const StorageBreakdown(
          feedBytes: 300 * _mb,
          mediaBytes: 200 * _mb,
          backupsBytes: 10 * _mb,
          otherBytes: 14 * _mb,
        ),
      );
      expect(find.text('Zen zajmuje 524 MB z 1 GB'), findsOneWidget);
      final LinearProgressIndicator bar = tester.widget(
        find.byKey(const Key('storage-usage-bar')),
      );
      expect(bar.value, closeTo(524 / 1024, 0.001));
      expect(find.byKey(const Key('storage-usage-feed')), findsOneWidget);
      expect(find.byKey(const Key('storage-usage-media')), findsOneWidget);
      expect(find.byKey(const Key('storage-usage-backups')), findsOneWidget);
      expect(find.byKey(const Key('storage-usage-other')), findsOneWidget);
      // No limit of its own for the wall: just the switch.
      expect(find.byKey(const Key('storage-feed-limit-editor')), findsNothing);
    });

    testWidgets('without a limit there is no bar', (WidgetTester tester) async {
      await pump(
        tester,
        const StorageBreakdown(otherBytes: 3 * _mb),
        settings: const AppSettings(inboxLimitMb: 0),
      );
      expect(find.text('Zen zajmuje 3 MB'), findsOneWidget);
      expect(find.byKey(const Key('storage-usage-bar')), findsNothing);
    });

    testWidgets('says so when it cannot be measured', (
      WidgetTester tester,
    ) async {
      await pump(tester, null);
      expect(find.byKey(const Key('storage-usage-unknown')), findsOneWidget);
    });

    testWidgets('a limit for the wall is switched on and saved', (
      WidgetTester tester,
    ) async {
      final MemoryAppSettingsStore store = await pump(
        tester,
        const StorageBreakdown(feedBytes: 10 * _mb),
      );
      await tester.tap(find.byKey(const Key('storage-feed-limit-switch')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('storage-feed-limit-editor')),
        findsOneWidget,
      );
      expect((await store.load())!.feedLimitMb, 1024);
      expect(find.text('Limit postów znajomych: 1 GB'), findsOneWidget);

      final Slider slider = tester.widget(
        find.descendant(
          of: find.byKey(const Key('storage-feed-limit-slider')),
          matching: find.byType(Slider),
        ),
      );
      slider.onChanged!(3);
      await tester.pumpAndSettle();
      expect((await store.load())!.feedLimitMb, 100);

      await tester.tap(find.byKey(const Key('storage-feed-limit-switch')));
      await tester.pumpAndSettle();
      expect((await store.load())!.feedLimitMb, 0);
      expect(find.byKey(const Key('storage-feed-limit-editor')), findsNothing);
    });
  });
}
