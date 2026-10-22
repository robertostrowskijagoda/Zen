import 'package:flutter/foundation.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';

@immutable
final class SignalHandlingPlan {
  const SignalHandlingPlan({
    required this.priority,
    required this.persist,
    required this.deliverToUi,
    required this.showSystemNotification,
    required this.queueNavigation,
  });

  final SignalPriority priority;
  final bool persist;
  final bool deliverToUi;
  final bool showSystemNotification;
  final bool queueNavigation;
}

final class SignalRoutingPolicy {
  const SignalRoutingPolicy();

  SignalHandlingPlan planFor({
    required ZenSignal signal,
    required LifecycleSnapshot lifecycle,
  }) {
    final SignalPriority priority = switch (signal.type) {
      ZenSignalType.ack => SignalPriority.criticalAck,
      ZenSignalType.messageRead => SignalPriority.messaging,
      ZenSignalType.friendRequest ||
      ZenSignalType.friendAccept ||
      ZenSignalType.friendRemove ||
      ZenSignalType.friendReject ||
      ZenSignalType.friendCancel => SignalPriority.friendLifecycle,
      ZenSignalType.message ||
      ZenSignalType.groupMessage ||
      ZenSignalType.groupInvite ||
      ZenSignalType.groupUpdate ||
      ZenSignalType.groupLeave ||
      ZenSignalType.groupInviteAck ||
      ZenSignalType.groupCallInvite ||
      ZenSignalType.groupCallJoin ||
      ZenSignalType.groupCallLeave ||
      ZenSignalType.groupCallState ||
      ZenSignalType.groupCallOffer ||
      ZenSignalType.groupCallAnswer ||
      ZenSignalType.groupCallDecline ||
      ZenSignalType.profileUpdate ||
      ZenSignalType.disappearTimer ||
      ZenSignalType.messageReaction ||
      ZenSignalType.messageEdit ||
      ZenSignalType.messageDelete ||
      ZenSignalType.callInvite ||
      ZenSignalType.callAccept ||
      ZenSignalType.callDecline ||
      ZenSignalType.callEnd => SignalPriority.messaging,
      ZenSignalType.callOffer ||
      ZenSignalType.callAnswer ||
      ZenSignalType.callRinging ||
      ZenSignalType.callBusy ||
      ZenSignalType.callOfferRequest => SignalPriority.messaging,
      ZenSignalType.transferOffer ||
      ZenSignalType.transferAnswer => SignalPriority.transfer,
      ZenSignalType.messageChunk ||
      ZenSignalType.messageChunkAck => SignalPriority.transfer,
      ZenSignalType.transferCancel => SignalPriority.transfer,
      ZenSignalType.deepLink ||
      ZenSignalType.presence ||
      ZenSignalType.typing ||
      ZenSignalType.unknown => SignalPriority.background,
    };

    switch (signal.type) {
      case ZenSignalType.ack:
        return const SignalHandlingPlan(
          priority: SignalPriority.criticalAck,
          persist: false,
          deliverToUi: true,
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.typing:
        return SignalHandlingPlan(
          priority: priority,
          persist: false,
          deliverToUi: lifecycle.isInteractive,
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.messageRead:
        return SignalHandlingPlan(
          priority: priority,
          persist: true,
          deliverToUi: lifecycle.isInteractive,
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.transferCancel:
        return SignalHandlingPlan(
          priority: priority,
          persist: true,
          deliverToUi: lifecycle.isInteractive,
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.transferOffer:
      case ZenSignalType.transferAnswer:
      case ZenSignalType.messageChunk:
      case ZenSignalType.messageChunkAck:
        return SignalHandlingPlan(
          priority: priority,
          persist: false,
          deliverToUi: false,
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.callOffer:
      case ZenSignalType.callAnswer:
      case ZenSignalType.callRinging:
      case ZenSignalType.callBusy:
      case ZenSignalType.callOfferRequest:
      case ZenSignalType.groupCallJoin:
      case ZenSignalType.groupCallLeave:
      case ZenSignalType.groupCallState:
      case ZenSignalType.groupCallOffer:
      case ZenSignalType.groupCallAnswer:
      case ZenSignalType.groupCallDecline:
      case ZenSignalType.profileUpdate:
        return SignalHandlingPlan(
          priority: priority,
          persist: false,
          deliverToUi: true,
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.deepLink:
        return SignalHandlingPlan(
          priority: priority,
          persist: !lifecycle.isInteractive,
          deliverToUi: lifecycle.isInteractive,
          showSystemNotification: false,
          queueNavigation: !lifecycle.isInteractive,
        );
      case ZenSignalType.callInvite:
      case ZenSignalType.groupCallInvite:
        return SignalHandlingPlan(
          priority: SignalPriority.messaging,
          persist: true,
          deliverToUi: lifecycle.isInteractive,
          // The incoming-call popup is the ringing UI. A shade entry is
          // reserved for a missed call after nobody answered.
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.groupUpdate:
      case ZenSignalType.groupLeave:
      case ZenSignalType.groupInviteAck:
      case ZenSignalType.disappearTimer:
      case ZenSignalType.messageReaction:
      case ZenSignalType.messageEdit:
      case ZenSignalType.messageDelete:
        // Membership bookkeeping only: applied right away in every lifecycle,
        // never worth a notification of its own.
        return SignalHandlingPlan(
          priority: priority,
          persist: true,
          deliverToUi: lifecycle.isInteractive,
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.friendRequest:
      case ZenSignalType.friendAccept:
      case ZenSignalType.friendReject:
      case ZenSignalType.friendCancel:
      case ZenSignalType.friendRemove:
      case ZenSignalType.message:
      case ZenSignalType.groupMessage:
      case ZenSignalType.groupInvite:
        return SignalHandlingPlan(
          priority: priority,
          persist: true,
          deliverToUi: lifecycle.isInteractive,
          showSystemNotification: lifecycle.isBackgroundLike,
          queueNavigation: false,
        );
      case ZenSignalType.callAccept:
      case ZenSignalType.callDecline:
      case ZenSignalType.callEnd:
        return SignalHandlingPlan(
          priority: priority,
          persist: true,
          deliverToUi: lifecycle.isInteractive,
          showSystemNotification: false,
          queueNavigation: false,
        );
      case ZenSignalType.presence:
      case ZenSignalType.unknown:
        return SignalHandlingPlan(
          priority: priority,
          persist: lifecycle.isBackgroundLike,
          deliverToUi: lifecycle.isInteractive,
          showSystemNotification: false,
          queueNavigation: false,
        );
    }
  }
}
