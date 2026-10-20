import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/update/presentation/store_share_dialog.dart';
import 'package:zen/src/features/update/store_build.dart';

void main() {
  test('only the appStoreOnly flavor or ZEN_STORE make a store build', () {
    expect(isStoreBuildFor(flavor: null), isFalse);
    expect(isStoreBuildFor(flavor: 'full'), isFalse);
    expect(isStoreBuildFor(flavor: 'appStoreOnly'), isTrue);
    expect(isStoreBuildFor(flavor: null, define: true), isTrue);
    expect(isStoreBuildFor(flavor: 'full', define: true), isTrue);
  });

  test('tests run as the direct build', () {
    expect(isStoreBuild, isFalse);
  });

  test('the store build is called "Zen" on the home screen too', () {
    // Only the About screen names it; no flavor overrides the label.
    final Directory res = Directory('android/app/src/appStoreOnly/res');
    final List<String> overriding = res.existsSync()
        ? <String>[
            for (final FileSystemEntity f in res.listSync(recursive: true))
              if (f is File && f.readAsStringSync().contains('launcher_label'))
                f.path,
          ]
        : const <String>[];
    expect(overriding, isEmpty);
    expect(
      File('android/app/src/main/res/values/strings.xml').readAsStringSync(),
      contains(
        '<string name="launcher_label" translatable="false">Zen</string>',
      ),
    );
  });

  test('the shared link is the project page by default', () {
    expect(kStoreShareUrl, 'https://robertostrowskijagoda.github.io/Zen/');
  });

  testWidgets('the store share dialog shows and copies the link', (
    WidgetTester tester,
  ) async {
    final List<MethodCall> calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showStoreShareDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('store-share-dialog')), findsOneWidget);
    expect(
      tester
          .widget<SelectableText>(find.byKey(const Key('store-share-url')))
          .data,
      kStoreShareUrl,
    );

    await tester.tap(find.byKey(const Key('store-share-copy')));
    await tester.pumpAndSettle();
    final MethodCall copy = calls.singleWhere(
      (MethodCall call) => call.method == 'Clipboard.setData',
    );
    expect((copy.arguments as Map<Object?, Object?>)['text'], kStoreShareUrl);
    expect(find.byKey(const Key('store-share-dialog')), findsNothing);
  });
}
