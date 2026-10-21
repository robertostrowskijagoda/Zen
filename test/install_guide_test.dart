import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/update/presentation/install_guide_screen.dart';

Widget _app(InstallSystem initial) => MaterialApp(
  theme: ZenTheme.dark(),
  home: InstallGuideScreen(initial: initial),
);

void main() {
  test('every system has steps, and the links point to GitHub Pages', () {
    for (final InstallSystem s in InstallSystem.values) {
      expect(installStepsFor(s), isNotEmpty, reason: s.name);
      expect(installNotesFor(s), isNotEmpty, reason: s.name);
    }
    expect(
      installStepsFor(InstallSystem.iphone).length,
      inInclusiveRange(6, 8),
    );
    expect(
      kInstallPageUrl,
      startsWith('https://robertostrowskijagoda.github.io/Zen/'),
    );
    expect(kSideStoreSourceUrl, endsWith('/apps.json'));
    expect(
      installStepsFor(InstallSystem.linux).map((InstallStep s) => s.command),
      contains('sudo apt install ./Zen-Linux-x64.deb'),
    );
  });

  testWidgets('the guide shows a QR code to the install page and switches '
      'systems', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(InstallSystem.android));
    await tester.pump();

    // qr_flutter keeps the encoded text private: compare the code the
    // widget paints with one painted from the install page address.
    final CustomPaint paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const Key('install-page-qr')),
        matching: find.byWidgetPredicate(
          (Widget w) => w is CustomPaint && w.painter is QrPainter,
        ),
      ),
    );
    final QrPainter shown = paint.painter! as QrPainter;
    QrPainter painterFor(String data) => QrPainter(
      data: data,
      version: shown.version,
      errorCorrectionLevel: shown.errorCorrectionLevel,
      gapless: shown.gapless,
      eyeStyle: shown.eyeStyle,
      dataModuleStyle: shown.dataModuleStyle,
    );
    Future<List<int>?> pixels(QrPainter painter) =>
        painter.toImageData(180).then((b) => b?.buffer.asUint8List());
    final List<List<int>?> pictures = (await tester.runAsync(
      () => Future.wait(<Future<List<int>?>>[
        pixels(shown),
        pixels(painterFor(kInstallPageUrl)),
        // Shorter, so it fits the same QR version.
        pixels(painterFor('https://example.org/')),
      ]),
    ))!;
    expect(pictures[0], isNotNull);
    expect(pictures[0], pictures[1]);
    expect(pictures[0], isNot(pictures[2]));
    expect(find.byKey(const Key('install-steps-android')), findsOneWidget);
    expect(find.byKey(const Key('install-copy-source')), findsNothing);

    await tester.tap(find.byKey(const Key('install-system-iphone')));
    await tester.pump();
    expect(find.byKey(const Key('install-steps-iphone')), findsOneWidget);
    // The source address comes after the eight illustrated steps: the
    // list builds it once it is scrolled to.
    await tester.scrollUntilVisible(
      find.byKey(const Key('install-copy-source')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('install-copy-source')), findsOneWidget);
    expect(find.text(kSideStoreSourceUrl), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('install-system-linux')),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byKey(const Key('install-system-linux')));
    await tester.pump();
    expect(find.byKey(const Key('install-steps-linux')), findsOneWidget);
    expect(find.text('sudo apt install ./Zen-Linux-x64.deb'), findsOneWidget);
  });
}
