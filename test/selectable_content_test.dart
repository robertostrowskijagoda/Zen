import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Content can be selected and copied: every content screen puts its text
/// in a SelectionArea (or uses SelectableText), and the hold-to-confirm
/// buttons stay out of a selection.
void main() {
  const List<String> contentScreens = <String>[
    'lib/src/features/about/presentation/about_screen.dart',
    'lib/src/features/about/presentation/legal_document_screen.dart',
    'lib/src/features/dating/presentation/dating_screen.dart',
    'lib/src/features/films/presentation/film_page.dart',
    'lib/src/features/meet/presentation/ask_screen.dart',
    'lib/src/features/meet/presentation/circle_screen.dart',
    'lib/src/features/meet/presentation/events_screen.dart',
    'lib/src/features/meet/presentation/food_screen.dart',
    'lib/src/features/meet/presentation/gate_widgets.dart',
    'lib/src/features/meet/presentation/graph_screen.dart',
    'lib/src/features/meet/presentation/intro_widgets.dart',
    'lib/src/features/meet/presentation/meet_hub_screen.dart',
    'lib/src/features/meet/presentation/nearby_screen.dart',
    'lib/src/features/meet/presentation/plan_screen.dart',
    'lib/src/features/meet/presentation/table_screen.dart',
    'lib/src/features/neighbors/presentation/flat_door_screen.dart',
    'lib/src/features/neighbors/presentation/neighbor_screen.dart',
    'lib/src/features/neighbors/presentation/neighbors_screen.dart',
    'lib/src/features/profile/presentation/profile_screen.dart',
    'lib/src/features/pyramid/presentation/pyramid_screen.dart',
    'lib/src/features/pyramid/presentation/wallet_screen.dart',
    'lib/src/features/shell/presentation/app_shell_screen_views.dart',
    'lib/src/features/shell/presentation/health_screen.dart',
  ];

  test('every content screen lets its text be selected', () {
    for (final String path in contentScreens) {
      final String source = File(path).readAsStringSync();
      expect(
        source.contains('SelectionArea(') || source.contains('SelectableText'),
        isTrue,
        reason: path,
      );
    }
  });

  test('holding a confirm button never starts a selection', () {
    for (final String path in <String>[
      'lib/src/features/pyramid/presentation/hold_to_confirm.dart',
      'lib/src/features/security/hold_to_confirm_button.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        contains('SelectionContainer.disabled('),
        reason: path,
      );
    }
  });
}
