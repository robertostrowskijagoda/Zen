import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/update/own_copy.dart';
import 'package:zen/src/features/update/presentation/own_copy_card.dart';
import 'package:zen/src/features/update/sha256_sums.dart';

final String _official = 'ab' * 32;
final String _other = 'cd' * 32;

void main() {
  group('self-check of the installed copy', () {
    test('matches the pinned fingerprint, in any notation', () {
      expect(
        ownCopyState(own: <String>[_official], official: <String>[_official]),
        OwnCopyState.official,
      );
      expect(
        ownCopyState(
          own: <String>[_official],
          official: <String>[
            _official.toUpperCase().replaceAllMapped(
              RegExp('..'),
              (Match m) => '${m[0]}:',
            ),
          ],
        ),
        OwnCopyState.official,
      );
    });

    test('another certificate is a difference', () {
      expect(
        ownCopyState(own: <String>[_other], official: <String>[_official]),
        OwnCopyState.differs,
      );
    });

    test('nothing pinned or nothing read is neutral, never a warning', () {
      expect(
        ownCopyState(own: <String>[_official], official: const <String>[]),
        OwnCopyState.unknown,
      );
      expect(
        ownCopyState(own: const <String>[], official: <String>[_official]),
        OwnCopyState.unknown,
      );
    });

    test('the build code is the first 12 characters of the file sum', () {
      expect(buildShortCode('a1b2c3d4e5f6a7b8'), 'A1B2-C3D4-E5F6');
    });
  });

  group('SHA256SUMS', () {
    final String zen = '11' * 32;
    final String win = '22' * 32;
    final String sums = '$zen  Zen.apk\n$win *Zen-Windows.zip\nnot a line\n';

    test('the url points at the release of that version', () {
      expect(
        sha256SumsUri('1.11.0').toString(),
        'https://github.com/robertostrowskijagoda/Zen/releases/download/'
        'v1.11.0/SHA256SUMS',
      );
    });

    test('lines are read like sha256sum prints them', () {
      expect(parseSha256Sums(sums), <String, String>{
        'Zen.apk': zen,
        'Zen-Windows.zip': win,
      });
    });

    test('a listed sum matches, a changed one does not', () {
      expect(
        compareWithSha256Sums(
          fileName: 'Zen.apk',
          sha256Hex: zen.toUpperCase(),
          sumsText: sums,
        ),
        Sha256SumsVerdict.match,
      );
      expect(
        compareWithSha256Sums(
          fileName: 'Zen.apk',
          sha256Hex: '33' * 32,
          sumsText: sums,
        ),
        Sha256SumsVerdict.mismatch,
      );
      expect(
        compareWithSha256Sums(
          fileName: 'Other.apk',
          sha256Hex: '33' * 32,
          sumsText: sums,
        ),
        Sha256SumsVerdict.notListed,
      );
      expect(
        compareWithSha256Sums(
          fileName: 'Zen.apk',
          sha256Hex: zen,
          sumsText: '',
        ),
        Sha256SumsVerdict.notListed,
      );
    });

    test('only https is fetched', () async {
      await expectLater(
        fetchSha256Sums(Uri.parse('http://example.com/SHA256SUMS')),
        throwsArgumentError,
      );
    });
  });

  group('the card', () {
    Future<void> pump(
      WidgetTester tester,
      OwnCopyCheck check, {
      bool onlyWarning = false,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ownCopyCheckProvider.overrideWith((Ref ref) async => check),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: Scaffold(body: OwnCopyCard(onlyWarning: onlyWarning)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('an official copy says so, with the code of the build', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        OwnCopyCheck(
          OwnCopyState.official,
          certificates: <String>[_official],
          apkSha256: 'a1b2c3d4e5f6' * 5 + 'abcd',
        ),
      );
      expect(find.byKey(const Key('own-copy-official')), findsOneWidget);
      expect(find.text('Oficjalna kopia'), findsOneWidget);
      expect(find.textContaining('A1B2-C3D4-E5F6'), findsOneWidget);
      expect(find.byKey(const Key('own-copy-differs')), findsNothing);
    });

    testWidgets('another signature is a red warning with the fingerprint', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        OwnCopyCheck(OwnCopyState.differs, certificates: <String>[_other]),
      );
      expect(find.byKey(const Key('own-copy-differs')), findsOneWidget);
      expect(find.textContaining('CD:CD:CD'), findsOneWidget);
    });

    testWidgets('an unpinned fingerprint is neutral, not a warning', (
      WidgetTester tester,
    ) async {
      await pump(tester, const OwnCopyCheck(OwnCopyState.unknown));
      expect(find.byKey(const Key('own-copy-unknown')), findsOneWidget);
      expect(find.text('Nie można sprawdzić'), findsOneWidget);
      expect(find.byKey(const Key('own-copy-differs')), findsNothing);
    });

    testWidgets('where nothing is checked, nothing shows', (
      WidgetTester tester,
    ) async {
      await pump(tester, const OwnCopyCheck(OwnCopyState.notApplicable));
      expect(find.byKey(const Key('own-copy-official')), findsNothing);
      expect(find.byKey(const Key('own-copy-unknown')), findsNothing);
    });

    testWidgets('at start a good copy shows nothing', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        OwnCopyCheck(OwnCopyState.official, certificates: <String>[_official]),
        onlyWarning: true,
      );
      expect(find.byKey(const Key('own-copy-official')), findsNothing);
    });

    testWidgets('at start a different signature shows the warning', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        OwnCopyCheck(OwnCopyState.differs, certificates: <String>[_other]),
        onlyWarning: true,
      );
      expect(find.byKey(const Key('own-copy-differs')), findsOneWidget);
    });
  });
}
