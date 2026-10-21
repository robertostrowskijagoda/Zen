import 'package:flutter/foundation.dart';
import 'package:zen/src/domain/messages/chat_message.dart';

/// Where an outgoing message is on its way, as the chat bubble shows it.
enum MessageDeliveryStage {
  /// The first direct try is on its way.
  sending,

  /// In this device's outbox: the recipient is offline and none of its
  /// trusted friends holds a copy (it has none, none is reachable, or the
  /// message is too large for them). Retried until delivered.
  waitingHere,

  /// Held by the recipient's trusted friends (its mailboxes) until the
  /// recipient collects it; this device keeps retrying too.
  inMailboxes,

  /// Too large for the recipient's mailboxes (a big attachment where they
  /// hold none): it waits on this device and goes over while both are
  /// online at the same time.
  waitingForBoth,

  /// Handed to the network; nothing more is known.
  sent,

  /// On the recipient's device.
  delivered,

  /// Opened by the recipient (only where read receipts arrive).
  read,

  /// Did not get through (or never reached the queue); can be sent again.
  failed,
}

/// The relay layer's live view of one outgoing chat message, over all its
/// recipients: one for a chat (or each device of that friend), every other
/// member for a group.
@immutable
final class MessageDeliveryProgress {
  const MessageDeliveryProgress({
    this.recipients = 0,
    this.delivered = 0,
    this.failed = 0,
    this.sending = 0,
    this.waitingHere = 0,
    this.inMailboxes = 0,
    this.mailboxCopies = 0,
    this.heldBySelf = false,
    this.waitingForBoth = 0,
  });

  final int recipients;

  /// Recipients that confirmed it.
  final int delivered;

  /// Recipients it expired for, unconfirmed.
  final int failed;

  /// Recipients whose first direct try is still under way.
  final int sending;

  /// Recipients for whom only this device holds it.
  final int waitingHere;

  /// Recipients whose trusted friends hold a copy.
  final int inMailboxes;

  /// Copies held by mailboxes, summed over [inMailboxes] recipients (this
  /// device's own copy included when it is one of them).
  final int mailboxCopies;

  /// This device holds a copy as one of the recipient's mailboxes.
  final bool heldBySelf;

  /// Recipients it can only reach while both devices are online (too
  /// large for their mailboxes).
  final int waitingForBoth;

  int get pending => sending + waitingHere + inMailboxes + waitingForBoth;

  @override
  bool operator ==(Object other) =>
      other is MessageDeliveryProgress &&
      other.recipients == recipients &&
      other.delivered == delivered &&
      other.failed == failed &&
      other.sending == sending &&
      other.waitingHere == waitingHere &&
      other.inMailboxes == inMailboxes &&
      other.mailboxCopies == mailboxCopies &&
      other.heldBySelf == heldBySelf &&
      other.waitingForBoth == waitingForBoth;

  @override
  int get hashCode => Object.hash(
    recipients,
    delivered,
    failed,
    sending,
    waitingHere,
    inMailboxes,
    mailboxCopies,
    heldBySelf,
    waitingForBoth,
  );
}

/// How long a text message may stay "sending" while the queue does not know
/// it before it is shown as failed: it never reached the queue (the app was
/// closed in between), so nothing would ever send it.
const Duration kUnqueuedMessageGrace = Duration(minutes: 2);

/// What the bubble of one outgoing message shows.
@immutable
final class MessageDeliveryStatus {
  const MessageDeliveryStatus(
    this.stage, {
    this.isGroup = false,
    this.recipients = 0,
    this.delivered = 0,
    this.failed = 0,
    this.waitingHere = 0,
    this.inMailboxes = 0,
    this.mailboxCopies = 0,
    this.heldBySelf = false,
    this.waitingForBoth = 0,
  });

  final MessageDeliveryStage stage;
  final bool isGroup;

  /// Counts from [MessageDeliveryProgress]; 0 when unknown.
  final int recipients;
  final int delivered;
  final int failed;
  final int waitingHere;
  final int inMailboxes;
  final int mailboxCopies;
  final bool heldBySelf;
  final int waitingForBoth;

  bool get canRetry => stage == MessageDeliveryStage.failed;

  /// A group message some members have and some do not (yet).
  bool get isPartial =>
      isGroup && recipients > 0 && delivered > 0 && delivered < recipients;

  @override
  bool operator ==(Object other) =>
      other is MessageDeliveryStatus &&
      other.stage == stage &&
      other.isGroup == isGroup &&
      other.recipients == recipients &&
      other.delivered == delivered &&
      other.failed == failed &&
      other.waitingHere == waitingHere &&
      other.inMailboxes == inMailboxes &&
      other.mailboxCopies == mailboxCopies &&
      other.heldBySelf == heldBySelf &&
      other.waitingForBoth == waitingForBoth;

  @override
  int get hashCode => Object.hash(
    stage,
    isGroup,
    recipients,
    delivered,
    failed,
    waitingHere,
    inMailboxes,
    mailboxCopies,
    heldBySelf,
    waitingForBoth,
  );

  /// The status of [message] (`null` for anything that is not outgoing).
  ///
  /// [progress] is the relay layer's live view, when it has one;
  /// [queueKnown] says the relay layer has loaded its queue, so a missing
  /// [progress] means the queue really does not know the message.
  static MessageDeliveryStatus? of(
    ChatMessage message, {
    MessageDeliveryProgress? progress,
    bool queueKnown = false,
    bool isGroup = false,
    required int nowMillis,
  }) {
    if (!message.isOutgoing) {
      return null;
    }
    final MessageDeliveryProgress? p =
        progress != null && progress.recipients > 0 ? progress : null;
    MessageDeliveryStatus make(MessageDeliveryStage stage) =>
        MessageDeliveryStatus(
          stage,
          isGroup: isGroup,
          recipients: p?.recipients ?? 0,
          delivered: p?.delivered ?? 0,
          failed: p?.failed ?? 0,
          waitingHere: p?.waitingHere ?? 0,
          inMailboxes: p?.inMailboxes ?? 0,
          mailboxCopies: p?.mailboxCopies ?? 0,
          heldBySelf: p?.heldBySelf ?? false,
          waitingForBoth: p?.waitingForBoth ?? 0,
        );
    // Read receipts exist for chats only; a group never says who read what.
    final bool read = !isGroup && message.isRead;
    switch (message.deliveryState) {
      case ChatMessageDeliveryState.failed:
        return make(MessageDeliveryStage.failed);
      case ChatMessageDeliveryState.delivered:
        return make(
          read ? MessageDeliveryStage.read : MessageDeliveryStage.delivered,
        );
      case ChatMessageDeliveryState.sending:
      case ChatMessageDeliveryState.sent:
      case ChatMessageDeliveryState.none:
        break;
    }
    if (read) {
      return make(MessageDeliveryStage.read);
    }
    if (p != null) {
      if (p.pending == 0) {
        return make(
          p.failed > 0 && (isGroup || p.delivered == 0)
              ? MessageDeliveryStage.failed
              : MessageDeliveryStage.delivered,
        );
      }
      if (!isGroup) {
        // One friend, maybe on several devices: the furthest copy counts.
        if (p.delivered > 0) {
          return make(MessageDeliveryStage.delivered);
        }
        if (p.inMailboxes > 0) {
          return make(MessageDeliveryStage.inMailboxes);
        }
        if (p.waitingHere > 0) {
          return make(MessageDeliveryStage.waitingHere);
        }
        return make(
          p.waitingForBoth > 0
              ? MessageDeliveryStage.waitingForBoth
              : MessageDeliveryStage.sending,
        );
      }
      // A group: whoever is furthest behind sets the icon.
      if (p.waitingForBoth > 0) {
        return make(MessageDeliveryStage.waitingForBoth);
      }
      if (p.waitingHere > 0) {
        return make(MessageDeliveryStage.waitingHere);
      }
      if (p.inMailboxes > 0) {
        return make(MessageDeliveryStage.inMailboxes);
      }
      return make(MessageDeliveryStage.sending);
    }
    switch (message.deliveryState) {
      case ChatMessageDeliveryState.sending:
        if (queueKnown &&
            message.type == ChatMessageType.text &&
            nowMillis - message.sentAtMillis >
                kUnqueuedMessageGrace.inMilliseconds) {
          return make(MessageDeliveryStage.failed);
        }
        return make(MessageDeliveryStage.sending);
      case ChatMessageDeliveryState.sent:
        return make(MessageDeliveryStage.sent);
      case ChatMessageDeliveryState.none:
        // An attachment waiting here for a transfer while both are online
        // (the recipient's mailboxes hold no files, or it is too large).
        return make(MessageDeliveryStage.waitingForBoth);
      case ChatMessageDeliveryState.delivered:
        return make(MessageDeliveryStage.delivered);
      case ChatMessageDeliveryState.failed:
        return make(MessageDeliveryStage.failed);
    }
  }
}
