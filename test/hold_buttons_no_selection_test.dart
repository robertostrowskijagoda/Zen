import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/hold_to_confirm.dart'
    as pyramid;
import 'package:zen/src/features/security/hold_to_confirm_button.dart'
    as security;

void main() {
  /// Holds the middle of [target] for a second (past the long-press delay)
  /// inside a page-wide selection area and tells what got selected.
  Future<String?> holdAndRead(WidgetTester tester, Widget target) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: Scaffold(
          body: SelectionArea(
            onSelectionChanged: (SelectedContent? content) =>
                selected = content?.plainText,
            child: Center(child: target),
          ),
        ),
      ),
    );
    await tester.pump();
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('held'))),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    return selected;
  }

  testWidgets('the check sees a long press select plain text', (
    WidgetTester tester,
  ) async {
    final String? selected = await holdAndRead(
      tester,
      const SizedBox(key: Key('held'), child: Text('Przytrzymaj')),
    );
    expect(selected, isNotEmpty);
  });

  testWidgets('holding the delete button of a page selects nothing', (
    WidgetTester tester,
  ) async {
    final String? selected = await holdAndRead(
      tester,
      KeyedSubtree(
        key: const Key('held'),
        child: security.HoldToConfirmButton(
          idleLabel: 'Przytrzymaj',
          holdingLabel: (int seconds) => 'Jeszcze $seconds s',
          onConfirmed: () {},
        ),
      ),
    );
    expect(selected ?? '', isEmpty);
  });

  testWidgets('holding the pyramid button selects nothing', (
    WidgetTester tester,
  ) async {
    final String? selected = await holdAndRead(
      tester,
      KeyedSubtree(
        key: const Key('held'),
        child: pyramid.HoldToConfirmButton(
          label: 'Przytrzymaj',
          onConfirmed: () {},
        ),
      ),
    );
    expect(selected ?? '', isEmpty);
  });
}
