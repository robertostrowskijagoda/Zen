import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

PyrMember _member(String key, String addr) => PyrMember(
  key: key,
  name: key,
  nat: 'PL',
  dataCommit: 'c',
  joinedAt: 0,
  addr: addr,
);

void main() {
  test('an address maps to the pyramid key of the member using it', () {
    final List<PyrMember> members = <PyrMember>[
      _member('k-ada', '200::a'),
      _member('k-bob', ''),
      _member('k-cyd', '0200:0000:0000:0000:0000:0000:0000:000c'),
    ];
    expect(pyramidKeyForAddress(members, '200::a'), 'k-ada');
    // Expanded and compressed forms are the same device.
    expect(pyramidKeyForAddress(members, '200::c'), 'k-cyd');
    expect(pyramidKeyForAddress(members, '200::b'), '');
    expect(pyramidKeyForAddress(members, ''), '');
    expect(pyramidKeyForAddress(const <PyrMember>[], '200::a'), '');
  });

  test('evidence carries a header and is cut to the limit', () {
    expect(reportEvidence('  Hej  '), 'Hej');
    expect(reportEvidence('Hej', header: 'Post — Ada'), 'Post — Ada\nHej');
    final String long = 'x' * 5000;
    final String cut = reportEvidence(long);
    expect(cut.length, kReportEvidenceMax + 1);
    expect(cut.endsWith('…'), isTrue);
    expect(reportEvidence('abcdef', max: 3), 'abc…');
  });

  test('banned content is hidden until revealed', () {
    const String bad = 'Kup tanio!!!';
    final Set<String> banned = <String>{contentHash(bad)};
    expect(isContentBanned(banned, bad), isTrue);
    expect(isContentBanned(banned, 'Dzień dobry'), isFalse);
    expect(isContentBanned(const <String>{}, bad), isFalse);
    expect(isContentBanned(banned, ''), isFalse);
    expect(isContentHidden(banned, bad, id: 'p1'), isTrue);
    expect(
      isContentHidden(banned, bad, id: 'p1', revealed: <String>{'p1'}),
      isFalse,
    );
    expect(
      isContentHidden(banned, bad, id: 'p2', revealed: <String>{'p1'}),
      isTrue,
    );
    expect(isContentHidden(banned, 'Dzień dobry', id: 'p3'), isFalse);
  });

  testWidgets('a message menu offers "Zgłoś" only with a report action', (
    WidgetTester tester,
  ) async {
    int reported = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              CopyableText(
                'Cudza',
                style: const TextStyle(),
                onReport: () => reported++,
              ),
              const CopyableText('Moja', style: TextStyle()),
            ],
          ),
        ),
      ),
    );
    await tester.longPress(find.text('Moja'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bubble-copy')), findsOneWidget);
    expect(find.byKey(const Key('bubble-report')), findsNothing);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Cudza'));
    await tester.pumpAndSettle();
    expect(find.text('Zgłoś'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bubble-report')));
    await tester.pumpAndSettle();
    expect(reported, 1);
  });
}
