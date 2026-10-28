import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/presentation/comment_composer.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  final Map<String, ThemeData> themes = <String, ThemeData>{
    'dark': ZenTheme.dark(),
    'light': ZenTheme.light(),
    for (final AppPalette p in AppPalette.values)
      p.name: ZenTheme.forPalette(
        p,
        AppAccentTheme.values.first,
        Brightness.dark,
      ),
  };

  Future<void> pumpComposer(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: CommentComposer(
                fieldKey: const Key('field'),
                sendKey: const Key('send'),
                onSend: (String text, List<CommentPicture> pictures) async =>
                    null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final MapEntry<String, ThemeData> entry in themes.entries) {
    testWidgets('the send and attach buttons are 44 px and level with the '
        'field (${entry.key})', (WidgetTester tester) async {
      await pumpComposer(tester, entry.value);
      final Rect field = tester.getRect(find.byKey(const Key('field')));
      final Rect send = tester.getRect(find.byKey(const Key('send')));
      final Rect attach = tester.getRect(
        find.byKey(const Key('comment-attach')),
      );
      for (final Rect button in <Rect>[send, attach]) {
        expect(button.width, 44);
        expect(button.height, 44);
        expect(button.center.dy, closeTo(field.center.dy, 0.5));
      }
      expect(send.left, greaterThanOrEqualTo(field.right));
      expect(attach.right, lessThanOrEqualTo(field.left));
    });

    testWidgets('the send button shows its icon in a colour that stands '
        'out from the button (${entry.key})', (WidgetTester tester) async {
      await pumpComposer(tester, entry.value);
      final Finder icon = find.descendant(
        of: find.byKey(const Key('send')),
        matching: find.byIcon(Icons.send_rounded),
      );
      expect(icon, findsOneWidget);
      final Rect button = tester.getRect(find.byKey(const Key('send')));
      final Rect glyph = tester.getRect(icon);
      expect(glyph.size, const Size.square(24));
      expect(button.contains(glyph.topLeft), isTrue);
      expect(button.contains(glyph.bottomRight), isTrue);

      final ZenColors zen = ZenColors.of(
        tester.element(find.byKey(const Key('send'))),
      );
      final Color? iconColor = IconTheme.of(tester.element(icon)).color;
      expect(iconColor, zen.onAccent);
      expect(iconColor, isNot(zen.accent));
    });
  }
}
