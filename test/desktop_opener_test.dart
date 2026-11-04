import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/desktop_opener.dart';
import 'package:zen/src/core/utils/system_actions.dart';

void main() {
  test('a test never opens a page or a folder on the computer', () async {
    expect(runningUnderFlutterTest, isTrue);
    // A name no system has: were it run, Process.run would throw.
    expect(
      await runDesktopOpener('zen-no-such-opener', <String>['https://x.y']),
      isFalse,
    );
    // A link tapped in a widget test goes nowhere either.
    await openWebLink('https://github.com/robertostrowskijagoda/Zen');
  });
}
