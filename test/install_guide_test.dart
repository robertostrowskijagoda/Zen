import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/qr_sticker/presentation/zen_qr_view.dart';
import 'package:zen/src/features/update/presentation/install_guide_screen.dart';
import 'package:zen/src/features/update/presentation/sidestore_source_option.dart';

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
    // iPhone: SideStore, in the order of the install page's steps: the
    // VPN, iloader on the computer, trust, SideStore, the source, the
    // automatic refresh.
    final List<String> iphone = <String>[
      for (final InstallStep s in installStepsFor(InstallSystem.iphone)) s.text,
    ];
    expect(iphone, hasLength(6));
    expect(iphone[0], allOf(contains('LocalDevVPN'), contains('„Connect”')));
    expect(
      iphone[1],
      allOf(contains('iloader'), contains('„Install SideStore (Stable)”')),
    );
    expect(
      iphone[2],
      allOf(contains('VPN i zarządzanie urządzeniem'), contains('Tryb')),
    );
    expect(iphone[3], allOf(contains('„My Apps”'), contains('„7 DAYS”')));
    expect(iphone[4], contains('„Dodaj Zen do SideStore”'));
    expect(
      iphone[5],
      allOf(contains('Skrótach'), contains('„Refresh All Apps”')),
    );
    final String notes = installNotesFor(InstallSystem.iphone).join(' ');
    // A computer only once, the 7 days and the limit of a free account.
    expect(notes, allOf(contains('tylko raz'), contains('7 dni')));
    expect(notes, contains('3'));
    expect(
      kInstallPageUrl,
      startsWith('https://robertostrowskijagoda.github.io/Zen/'),
    );
    expect(
      installStepsFor(InstallSystem.linux).map((InstallStep s) => s.command),
      contains('sudo apt install ./Zen-Linux-x64.deb'),
    );
  });

  testWidgets('on an iPhone the iPhone steps offer the SideStore source, '
      'elsewhere not', (WidgetTester tester) async {
    for (final (InstallSystem system, bool onIphone, bool shown)
        in <(InstallSystem, bool, bool)>[
          (InstallSystem.iphone, true, true),
          (InstallSystem.iphone, false, false),
          (InstallSystem.android, true, false),
        ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ZenTheme.dark(),
          home: InstallGuideScreen(
            key: ValueKey<String>('${system.name} $onIphone'),
            initial: system,
            onIphone: onIphone,
          ),
        ),
      );
      expect(
        find.byType(SideStoreSourceOption, skipOffstage: false),
        shown ? findsOneWidget : findsNothing,
        reason: '${system.name} $onIphone',
      );
      // The steps stay the main way.
      if (system == InstallSystem.iphone) {
        expect(
          find.textContaining(
            'Install SideStore (Stable)',
            skipOffstage: false,
          ),
          findsOneWidget,
        );
      }
    }
  });

  testWidgets('the guide shows a QR code to the install page and switches '
      'systems', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(InstallSystem.android));
    await tester.pump();

    final ZenQrView shown = tester.widget<ZenQrView>(
      find.byKey(const Key('install-page-qr')),
    );
    expect(shown.data, kInstallPageUrl);
    expect(find.byKey(const Key('install-steps-android')), findsOneWidget);

    await tester.tap(find.byKey(const Key('install-system-iphone')));
    await tester.pump();
    expect(find.byKey(const Key('install-steps-iphone')), findsOneWidget);
    expect(find.textContaining('LocalDevVPN'), findsWidgets);
    expect(find.textContaining('Install SideStore (Stable)'), findsOneWidget);

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
