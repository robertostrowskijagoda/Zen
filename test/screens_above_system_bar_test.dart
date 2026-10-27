import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/presentation/account_backup_screen.dart';
import 'package:zen/src/features/account/presentation/account_copy_screen.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/plan/plan_service.dart';
import 'package:zen/src/features/meet/presentation/plan_screen.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

/// Nobody around: the board is empty, which is enough to scroll it.
final class _Host implements EventHost {
  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => const <String>[];

  @override
  bool isFriend(String a) => false;

  @override
  String ownAddress() => '200::a1';

  @override
  String ownName() => 'Ania';

  @override
  String nameOf(String a) => '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}
}

/// A small phone (360 x 480 dp) with a system navigation bar of 52 dp at the
/// bottom, the home screen widget under test, and the page scrolled to the
/// very end.
Future<void> _pumpScrolledToEnd(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(720, 960);
  tester.view.devicePixelRatio = 2;
  tester.view.padding = const FakeViewPadding(bottom: 104);
  tester.view.viewPadding = const FakeViewPadding(bottom: 104);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(theme: ZenTheme.light(), home: home),
    ),
  );
  await tester.pump();
  await tester.drag(find.byType(ListView), const Offset(0, -6000));
  await tester.pumpAndSettle();
}

/// The list ends above the system bar, and so does its last row.
void _expectAboveSystemBar(WidgetTester tester) {
  const double usableBottom = 480 - 52;
  final Finder list = find.byType(ListView);
  expect(list, findsOneWidget);
  expect(tester.getRect(list).bottom, lessThanOrEqualTo(usableBottom));
  final ListView view = tester.widget<ListView>(list);
  final SliverChildListDelegate rows =
      view.childrenDelegate as SliverChildListDelegate;
  final Finder last = find.byWidget(rows.children.last);
  expect(last, findsOneWidget);
  expect(tester.getBottomLeft(last).dy, lessThanOrEqualTo(usableBottom));
}

void main() {
  testWidgets('"Mam kopie": the last row is above the system bar', (
    WidgetTester tester,
  ) async {
    await _pumpScrolledToEnd(tester, const AccountBackupRestoreScreen());
    _expectAboveSystemBar(tester);
  });

  testWidgets('"Odzyskaj z innego urzadzenia": the last row is above the '
      'system bar', (WidgetTester tester) async {
    await _pumpScrolledToEnd(tester, const AccountCopyReceiveScreen());
    _expectAboveSystemBar(tester);
  });

  testWidgets('"Plan na weekend": the last row is above the system bar', (
    WidgetTester tester,
  ) async {
    final PlanService plans = PlanService(
      host: _Host(),
      disk: MemoryLedgerDisk(),
      now: () => DateTime(2026, 10, 14, 12).millisecondsSinceEpoch,
    );
    await _pumpScrolledToEnd(tester, PlanBoard(plans: plans));
    _expectAboveSystemBar(tester);
  });
}
