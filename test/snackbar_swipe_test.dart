import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

void main() {
  Future<void> showNotice(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Skopiowano.'),
                  duration: Duration(minutes: 5),
                ),
              ),
              child: const Text('Pokaż'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pokaż'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Skopiowano.'), findsOneWidget);
  }

  for (final MapEntry<String, ThemeData> theme in <String, ThemeData>{
    'light': ZenTheme.light(),
    'dark': ZenTheme.dark(),
  }.entries) {
    testWidgets('a notice at the bottom goes with a swipe to the right '
        '(${theme.key})', (WidgetTester tester) async {
      await showNotice(tester, theme.value);
      await tester.drag(find.text('Skopiowano.'), const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Skopiowano.'), findsNothing);
    });

    testWidgets('a notice at the bottom goes with a swipe to the left '
        '(${theme.key})', (WidgetTester tester) async {
      await showNotice(tester, theme.value);
      await tester.drag(find.text('Skopiowano.'), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Skopiowano.'), findsNothing);
    });
  }
}
