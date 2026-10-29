// The whole app on an Android emulator (or a phone), as a person starts it:
//   flutter test integration_test/app_start_test.dart -d <device>
// CI: .github/workflows/android-emulator.yml, on a fresh install and over
// the previous release's data (ZEN_OLD_NODE_CONFIG_SHA, the SHA-256 of the
// node's config file the previous version wrote: the person's identity).
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zen/main.dart' as app;
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/zen_instance.dart';

/// Past the logo by then, or the start is stuck (R5-#8, #22).
const Duration kFirstScreenWithin = Duration(seconds: 60);

const String _oldNodeConfigSha = String.fromEnvironment(
  'ZEN_OLD_NODE_CONFIG_SHA',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the app gets past the logo, and keeps the data it had', (
    WidgetTester tester,
  ) async {
    app.main(const <String>[]);
    final Stopwatch watch = Stopwatch()..start();
    while (watch.elapsed < kFirstScreenWithin &&
        find.byType(ZenRewriteApp).evaluate().isEmpty) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(
      find.byType(ZenRewriteApp),
      findsOneWidget,
      reason: 'still on the logo after ${kFirstScreenWithin.inSeconds} s',
    );
    // ignore: avoid_print
    print('First screen after ${watch.elapsedMilliseconds} ms.');
    // A few seconds of the running app: nothing may throw meanwhile.
    for (int i = 0; i < 20; i++) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    expect(tester.takeException(), isNull);

    if (_oldNodeConfigSha.isNotEmpty) {
      // The same person after the update: the node's identity is the one
      // the previous version made, not a new one.
      final Directory support = await ZenInstance.supportDirectory();
      final File config = File('${support.path}/runtime/yggdrasil.config.json');
      expect(config.existsSync(), isTrue, reason: '${config.path} is gone');
      expect(
        sha256.convert(config.readAsBytesSync()).toString(),
        _oldNodeConfigSha,
        reason: 'the update replaced the node identity',
      );
    }
  });
}
