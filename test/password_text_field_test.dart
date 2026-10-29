import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/password_text_field.dart';

void main() {
  testWidgets('the eye shows the password and hides it again', (
    WidgetTester tester,
  ) async {
    final TextEditingController controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PasswordTextField(
            controller: controller,
            fieldKey: const Key('pw'),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('pw')), 'sekret');
    TextField field() => tester.widget<TextField>(find.byKey(const Key('pw')));
    expect(field().obscureText, isTrue);
    expect(field().enableIMEPersonalizedLearning, isFalse);
    await tester.tap(find.byIcon(Icons.visibility_off_rounded));
    await tester.pump();
    expect(field().obscureText, isFalse);
    expect(controller.text, 'sekret');
    await tester.tap(find.byIcon(Icons.visibility_rounded));
    await tester.pump();
    expect(field().obscureText, isTrue);
  });
}
