import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_compact_mode.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/noop_call_media_session.dart';
import 'package:zen/src/features/calls/presentation/call_compact_layer.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

CallSession _call(CallSessionStatus status, {bool incoming = false}) =>
    CallSession(
      id: 'c1',
      peerAddress: 'ania.ygg',
      displayName: 'Ania',
      kind: CallInviteKind.audio,
      status: status,
      startedAtMillis: DateTime.now().millisecondsSinceEpoch - 65 * 1000,
      isIncoming: incoming,
    );

void main() {
  tearDown(CallCompactMode.instance.resetForTest);

  test('only a running call floats over other apps', () {
    expect(callWantsFloatingWindow(null), isFalse);
    expect(callWantsFloatingWindow(_call(CallSessionStatus.active)), isTrue);
    expect(
      callWantsFloatingWindow(_call(CallSessionStatus.connecting)),
      isTrue,
    );
    // Calling someone: yes; being called (still ringing): not yet.
    expect(callWantsFloatingWindow(_call(CallSessionStatus.ringing)), isTrue);
    expect(
      callWantsFloatingWindow(_call(CallSessionStatus.ringing, incoming: true)),
      isFalse,
    );
  });

  test('picture-in-picture shows the call only while there is one', () {
    final CallCompactMode mode = CallCompactMode.instance;
    mode.reportPictureInPicture(true);
    expect(mode.active.value, isFalse, reason: 'no call');
    mode.updateCall(running: true, video: false);
    mode.reportPictureInPicture(true);
    expect(mode.active.value, isTrue);
    mode.reportPictureInPicture(false);
    expect(mode.active.value, isFalse);
  });

  testWidgets('the small call view shows who and how long', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          callMediaSessionControllerProvider.overrideWithValue(
            NoopCallMediaSessionController(),
          ),
        ],
        child: MaterialApp(
          home: CallCompactView(session: _call(CallSessionStatus.active)),
        ),
      ),
    );
    expect(find.text('Ania'), findsOneWidget);
    expect(find.text('01:05'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('without a call the layer shows the app', (
    WidgetTester tester,
  ) async {
    CallCompactMode.instance.active.value = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          callMediaSessionControllerProvider.overrideWithValue(
            NoopCallMediaSessionController(),
          ),
        ],
        child: const MaterialApp(
          home: CallCompactLayer(child: Text('aplikacja')),
        ),
      ),
    );
    expect(find.text('aplikacja'), findsOneWidget);
    expect(find.byKey(const Key('call-compact-view')), findsNothing);
  });
}
