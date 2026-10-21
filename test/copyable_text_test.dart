import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';

void main() {
  testWidgets('a long press copies the text, and it expires like every copy', (
    WidgetTester tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': copied};
        }
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
      const MaterialApp(
        home: Scaffold(
          body: Center(child: CopyableText('Hej!', style: TextStyle())),
        ),
      ),
    );
    await tester.longPress(find.text('Hej!'));
    await tester.pumpAndSettle();
    expect(find.text('Przetłumacz'), findsNothing);
    await tester.tap(find.byKey(const Key('bubble-copy')));
    await tester.pumpAndSettle();
    expect(copied, 'Hej!');

    // Nothing copied from the app lingers in the clipboard.
    await tester.pump(kClipboardTtl + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(copied, '');
  });
}
