import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';

/// The spans of the one rich text under [finder].
List<TextSpan> _spans(WidgetTester tester) {
  final RichText rich = tester.widget<RichText>(find.byType(RichText).first);
  final List<TextSpan> out = <TextSpan>[];
  rich.text.visitChildren((InlineSpan span) {
    if (span is TextSpan && span.text != null) {
      out.add(span);
    }
    return true;
  });
  return out;
}

void main() {
  testWidgets('a link in a message shows as a link a tap opens; the rest '
      'stays plain text', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: const Scaffold(
          body: CopyableText(
            'Zobacz https://example.org/a?b=1, fajne!',
            style: TextStyle(fontSize: 15),
          ),
        ),
      ),
    );
    final List<TextSpan> spans = _spans(tester);
    expect(spans.map((TextSpan s) => s.text), <String>[
      'Zobacz ',
      'https://example.org/a?b=1',
      ', fajne!',
    ]);
    expect(spans[1].recognizer, isA<TapGestureRecognizer>());
    expect(spans[1].style?.decoration, TextDecoration.underline);
    expect(spans[0].recognizer, isNull);
  });

  testWidgets('a message without a link is plain text', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: const Scaffold(
          body: CopyableText('Bez linku', style: TextStyle(fontSize: 15)),
        ),
      ),
    );
    expect(find.text('Bez linku'), findsOneWidget);
    expect(_spans(tester).where((TextSpan s) => s.recognizer != null), isEmpty);
  });

  test('only web links open, http only when asked for', () async {
    expect(await openWebLink('javascript:alert(1)', allowHttp: true), isFalse);
    expect(await openWebLink('file:///etc/passwd', allowHttp: true), isFalse);
    expect(await openWebLink('http:///nohost', allowHttp: true), isFalse);
    expect(await openWebLink('http://example.org'), isFalse);
  });
}
