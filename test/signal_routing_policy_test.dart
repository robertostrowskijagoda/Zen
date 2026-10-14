import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_routing_policy.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';

void main() {
  const SignalRoutingPolicy policy = SignalRoutingPolicy();

  test('friend accept is delivered immediately in focused foreground', () {
    final SignalHandlingPlan plan = policy.planFor(
      signal: const ZenSignal(
        type: ZenSignalType.friendAccept,
        sender: 'peer-a',
      ),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.foregroundFocused,
        generation: 4,
        capturedAtMillis: 100,
      ),
    );

    expect(plan.priority, SignalPriority.friendLifecycle);
    expect(plan.persist, isTrue);
    expect(plan.deliverToUi, isTrue);
    expect(plan.showSystemNotification, isFalse);
    expect(plan.queueNavigation, isFalse);
  });

  test('friend accept becomes persistent notification work in background', () {
    final SignalHandlingPlan plan = policy.planFor(
      signal: const ZenSignal(
        type: ZenSignalType.friendAccept,
        sender: 'peer-a',
      ),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.background,
        generation: 5,
        capturedAtMillis: 120,
      ),
    );

    expect(plan.persist, isTrue);
    expect(plan.deliverToUi, isFalse);
    expect(plan.showSystemNotification, isTrue);
  });

  test('transfer cancel is always durable and never notification-driven', () {
    final SignalHandlingPlan plan = policy.planFor(
      signal: const ZenSignal(
        type: ZenSignalType.transferCancel,
        sender: 'peer-a',
      ),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.hidden,
        generation: 7,
        capturedAtMillis: 140,
      ),
    );

    expect(plan.priority, SignalPriority.transfer);
    expect(plan.persist, isTrue);
    expect(plan.deliverToUi, isFalse);
    expect(plan.showSystemNotification, isFalse);
  });

  test('message read receipts stay durable without raising notifications', () {
    final SignalHandlingPlan plan = policy.planFor(
      signal: const ZenSignal(
        type: ZenSignalType.messageRead,
        sender: 'peer-a',
        messageId: 'm-1',
      ),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.background,
        generation: 7,
        capturedAtMillis: 145,
      ),
    );

    expect(plan.priority, SignalPriority.messaging);
    expect(plan.persist, isTrue);
    expect(plan.deliverToUi, isFalse);
    expect(plan.showSystemNotification, isFalse);
  });

  test('realtime transfer offer stays in transfer lane without UI alerts', () {
    final SignalHandlingPlan plan = policy.planFor(
      signal: const ZenSignal(
        type: ZenSignalType.transferOffer,
        sender: 'peer-a',
      ),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.background,
        generation: 8,
        capturedAtMillis: 150,
      ),
    );

    expect(plan.priority, SignalPriority.transfer);
    expect(plan.persist, isFalse);
    expect(plan.deliverToUi, isFalse);
    expect(plan.showSystemNotification, isFalse);
  });

  test('incoming call invite never raises a ringing system notification', () {
    final SignalHandlingPlan foreground = policy.planFor(
      signal: const ZenSignal(type: ZenSignalType.callInvite, sender: 'peer-a'),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.foregroundFocused,
        generation: 4,
        capturedAtMillis: 100,
      ),
    );
    final SignalHandlingPlan background = policy.planFor(
      signal: const ZenSignal(type: ZenSignalType.callInvite, sender: 'peer-a'),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.background,
        generation: 5,
        capturedAtMillis: 120,
      ),
    );

    expect(foreground.showSystemNotification, isFalse);
    expect(foreground.deliverToUi, isTrue);
    expect(
      background.showSystemNotification,
      isFalse,
      reason: 'the popup is the ringing UI; the shade is for a missed call',
    );
    expect(
      background.deliverToUi,
      isFalse,
      reason: 'the background isolate queues the invite for the UI isolate',
    );
  });

  test('call offer updates live call state without queueing notifications', () {
    final SignalHandlingPlan plan = policy.planFor(
      signal: const ZenSignal(type: ZenSignalType.callOffer, sender: 'peer-a'),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.background,
        generation: 9,
        capturedAtMillis: 155,
      ),
    );

    expect(plan.priority, SignalPriority.messaging);
    expect(plan.persist, isFalse);
    expect(plan.deliverToUi, isTrue);
    expect(plan.showSystemNotification, isFalse);
  });

  test('deep links queue navigation when app is not interactive', () {
    final SignalHandlingPlan plan = policy.planFor(
      signal: const ZenSignal(
        type: ZenSignalType.deepLink,
        sender: 'system',
        routeKey: 'zen://friend/abc',
      ),
      lifecycle: const LifecycleSnapshot(
        visibility: AppVisibilityState.detached,
        generation: 8,
        capturedAtMillis: 160,
      ),
    );

    expect(plan.persist, isTrue);
    expect(plan.deliverToUi, isFalse);
    expect(plan.queueNavigation, isTrue);
  });

  test(
    'call teardown and end signals do not raise noisy system notifications',
    () {
      for (final ZenSignalType type in <ZenSignalType>[
        ZenSignalType.callAccept,
        ZenSignalType.callDecline,
        ZenSignalType.callEnd,
      ]) {
        final SignalHandlingPlan plan = policy.planFor(
          signal: ZenSignal(type: type, sender: 'peer-a'),
          lifecycle: const LifecycleSnapshot(
            visibility: AppVisibilityState.background,
            generation: 10,
            capturedAtMillis: 170,
          ),
        );

        expect(plan.showSystemNotification, isFalse);
        expect(plan.persist, isTrue);
      }
    },
  );
}
