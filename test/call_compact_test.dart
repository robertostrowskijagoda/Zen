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
import 'package:zen/src/features/social/social_hub_state.dart';

// The call's length is read from this fixed moment, not the wall clock, so a
// slow machine cannot tick it over to the next second mid-test.
final DateTime _now = DateTime(2026, 1, 1, 12);

CallSession _call(CallSessionStatus status, {bool incoming = false}) =>
    CallSession(
      id: 'c1',
      peerAddress: 'ania.ygg',
      displayName: 'Ania',
      kind: CallInviteKind.audio,
      status: status,
      startedAtMillis: _now.millisecondsSinceEpoch - 65 * 1000,
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

  group('the floating window on Android follows the call', () {
    late List<(bool, bool)> pip;

    setUp(() {
      pip = <(bool, bool)>[];
      CallCompactMode.instance
        ..androidForTest = true
        ..pipSetter = ({required bool active, required bool video}) async {
          pip.add((active, video));
        };
    });

    test('armed when a call starts, disarmed (which closes the small window '
        'if it floats) when it ends', () {
      final CallCompactMode mode = CallCompactMode.instance;
      mode.updateCall(running: true, video: true);
      mode.reportPictureInPicture(true);
      expect(mode.active.value, isTrue);
      mode.updateCall(running: false, video: true);
      expect(pip, <(bool, bool)>[(true, true), (false, true)]);
    });

    test('the same call reported again changes nothing; every start and end '
        'of many calls goes through exactly once', () {
      final CallCompactMode mode = CallCompactMode.instance;
      for (int i = 0; i < 5; i++) {
        mode
          ..updateCall(running: true, video: i.isEven)
          ..updateCall(running: true, video: i.isEven)
          ..updateCall(running: false, video: i.isEven)
          ..updateCall(running: false, video: i.isEven);
      }
      expect(pip, hasLength(10));
      for (int i = 0; i < 10; i++) {
        expect(pip[i].$1, i.isEven, reason: 'start, end, start, end…');
      }
    });

    testWidgets('a call ending from the layer disarms it: no window left '
        'behind with a corner of the app in it', (WidgetTester tester) async {
      final ProviderContainer container = ProviderContainer(
        overrides: [
          callMediaSessionControllerProvider.overrideWithValue(
            NoopCallMediaSessionController(),
          ),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              activeCall: _call(CallSessionStatus.active),
            ),
          ),
          socialHubAutoHydrateProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: CallCompactLayer(child: Text('app'))),
        ),
      );
      expect(pip.last.$1, isTrue, reason: 'armed for the running call');
      // The media say the call ended (the other side hung up).
      container.read(callMediaSessionControllerProvider).onStatusChanged!(
        'c1',
        CallMediaSessionLifecycle.ended,
      );
      await tester.pump();
      expect(container.read(socialHubControllerProvider).activeCall, isNull);
      expect(pip.last.$1, isFalse, reason: 'the call ended: disarmed');
    });
  });

  Future<void> pumpView(
    WidgetTester tester,
    Size size, {
    CallSession? session,
    bool? interactive,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
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
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: CallCompactView(
            session: session ?? _call(CallSessionStatus.active),
            interactive: interactive,
            now: () => _now,
          ),
        ),
      ),
    );
  }

  // The desktop window's sizes (200x260 is the smallest) with the view's
  // own buttons.
  for (final Size size in const <Size>[Size(200, 260), Size(240, 320)]) {
    for (final double scale in const <double>[1, 1.3, 2]) {
      testWidgets(
        'the small call window ${size.width.toInt()}x${size.height.toInt()} '
        'at text scale $scale shows who and how long',
        (WidgetTester tester) async {
          await pumpView(tester, size, interactive: true, textScale: scale);
          expect(find.text('Ania'), findsOneWidget);
          expect(find.text('01:05'), findsOneWidget);
          expect(find.byKey(const Key('call-compact-mute')), findsOneWidget);
          expect(find.byKey(const Key('call-compact-expand')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('a long name and a long status fit the smallest window', (
    WidgetTester tester,
  ) async {
    await pumpView(
      tester,
      const Size(200, 260),
      interactive: true,
      session: const CallSession(
        id: 'c2',
        peerAddress: 'k.ygg',
        displayName: 'Konstantynopolitańczykowianeczka Wielopolska',
        kind: CallInviteKind.audio,
        status: CallSessionStatus.connecting,
        startedAtMillis: 0,
      ),
    );
    expect(find.byKey(const Key('call-compact-status')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Android's picture-in-picture (about 108x135 dp at 4:5): no buttons of
  // its own, the name goes under the picture.
  for (final double scale in const <double>[1, 1.3]) {
    testWidgets('picture-in-picture 108x135 at text scale $scale', (
      WidgetTester tester,
    ) async {
      await pumpView(
        tester,
        const Size(108, 135),
        interactive: false,
        textScale: scale,
      );
      expect(find.text('Ania'), findsOneWidget);
      expect(find.text('01:05'), findsOneWidget);
      expect(find.byKey(const Key('call-compact-who-narrow')), findsOneWidget);
      expect(find.byKey(const Key('call-compact-mute')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

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
