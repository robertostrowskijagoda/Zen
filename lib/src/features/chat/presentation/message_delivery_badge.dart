import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// The delivery status of [message] for its bubble, from the stored state
/// and the relay layer's live view.
MessageDeliveryStatus? messageDeliveryStatusFor(
  WidgetRef ref,
  ChatMessage message, {
  required bool isGroup,
}) {
  if (!message.isOutgoing) {
    return null;
  }
  // Only this message's part: the other bubbles do not rebuild with it.
  final MessageDeliveryProgress? progress = ref.watch(
    relayDeliveryProgressProvider.select(
      (RelayProgressSnapshot s) => s.messages[message.id],
    ),
  );
  final bool queueKnown = ref.watch(
    relayDeliveryProgressProvider.select((RelayProgressSnapshot s) => s.ready),
  );
  return MessageDeliveryStatus.of(
    message,
    progress: progress,
    queueKnown: queueKnown,
    isGroup: isGroup,
    nowMillis: DateTime.now().millisecondsSinceEpoch,
  );
}

IconData messageDeliveryIcon(MessageDeliveryStage stage) {
  return switch (stage) {
    MessageDeliveryStage.sending => Icons.schedule_rounded,
    MessageDeliveryStage.waitingHere => Icons.outbox_rounded,
    MessageDeliveryStage.inMailboxes => Icons.markunread_mailbox_outlined,
    MessageDeliveryStage.waitingForBoth => Icons.sync_alt_rounded,
    // One tick: it reached the friend's phone; two: they read it.
    MessageDeliveryStage.sent => Icons.arrow_upward_rounded,
    MessageDeliveryStage.delivered => Icons.done_rounded,
    MessageDeliveryStage.read => Icons.done_all_rounded,
    MessageDeliveryStage.failed => Icons.error_outline_rounded,
  };
}

/// The theme colour of [stage]; [onAccent] for a bubble drawn in the accent
/// gradient.
Color messageDeliveryColor(
  ZenColors zen,
  MessageDeliveryStage stage, {
  bool onAccent = false,
}) {
  if (onAccent) {
    return switch (stage) {
      MessageDeliveryStage.read || MessageDeliveryStage.failed => zen.onAccent,
      _ => zen.onAccent.withValues(alpha: 0.72),
    };
  }
  return switch (stage) {
    MessageDeliveryStage.failed => zen.warning,
    MessageDeliveryStage.read => zen.accent,
    MessageDeliveryStage.inMailboxes => zen.accentSecondary,
    _ => zen.textSecondary,
  };
}

/// The short label of [status], as shown on long press and in the details.
String messageDeliveryLabel(MessageDeliveryStatus status) {
  if (status.isGroup && status.recipients > 0) {
    if (status.stage == MessageDeliveryStage.failed && status.failed > 0) {
      return tn(
        status.failed,
        one: 'Nie dotarło do {n} osoby — ponów',
        few: 'Nie dotarło do {n} osób — ponów',
        many: 'Nie dotarło do {n} osób — ponów',
      );
    }
    if (status.stage != MessageDeliveryStage.delivered &&
        status.stage != MessageDeliveryStage.failed) {
      return t('Dostarczono {delivered} z {total}', <String, Object?>{
        'delivered': status.delivered,
        'total': status.recipients,
      });
    }
  }
  return messageDeliveryStageLabel(
    status.stage,
    mailboxes: status.mailboxCopies,
  );
}

/// This device is an iPhone: it sends (and retries) only while Zen is open,
/// never in the background, and the texts say so.
bool get messageDeliveryOnIPhone =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

/// The label of [stage] alone (the legend uses it with a placeholder count).
String messageDeliveryStageLabel(
  MessageDeliveryStage stage, {
  Object? mailboxes,
  bool? iPhone,
}) {
  return switch (stage) {
    MessageDeliveryStage.sending => t('Wysyłanie…'),
    MessageDeliveryStage.waitingHere =>
      (iPhone ?? messageDeliveryOnIPhone)
          ? t('Czeka na Twoim iPhonie — odbiorca offline')
          : t('Czeka u Ciebie — odbiorca offline'),
    MessageDeliveryStage.inMailboxes => t(
      'Czeka w skrzynkach u znajomych odbiorcy ({n})',
      <String, Object?>{'n': mailboxes ?? 'N'},
    ),
    MessageDeliveryStage.waitingForBoth => t(
      'Czeka u Ciebie — dojdzie, gdy oboje będziecie online',
    ),
    MessageDeliveryStage.sent => t('Wysłano'),
    MessageDeliveryStage.delivered => t('Dostarczono'),
    MessageDeliveryStage.read => t('Przeczytano'),
    MessageDeliveryStage.failed => t('Nie udało się — ponów'),
  };
}

/// What [stage] means, in a sentence or two. On an iPhone ([iPhone], by
/// default this device) nothing is retried while Zen is closed.
String messageDeliveryExplanation(MessageDeliveryStage stage, {bool? iPhone}) {
  final bool ios = iPhone ?? messageDeliveryOnIPhone;
  return switch (stage) {
    MessageDeliveryStage.sending => t(
      'Zen próbuje dostarczyć wiadomość bezpośrednio.',
    ),
    MessageDeliveryStage.waitingHere =>
      ios
          ? t(
              'Odbiorca jest offline i żadna z jego skrzynek u znajomych nie '
              'ma jeszcze kopii. Wiadomość czeka na Twoim iPhonie. Wyjdzie, '
              'gdy Zen będzie otwarty, a odbiorca w sieci — iPhone nie '
              'wysyła w tle.',
            )
          : t(
              'Odbiorca jest offline i żadna z jego skrzynek u znajomych nie '
              'ma jeszcze kopii. Wiadomość czeka na tym urządzeniu i jest '
              'ponawiana, aż dotrze.',
            ),
    MessageDeliveryStage.inMailboxes =>
      ios
          ? t(
              'Odbiorca jest offline. Zaszyfrowane kopie trzymają jego '
              'znajomi (skrzynki) i oddadzą je, gdy wróci. Ten iPhone ponawia '
              'wysyłkę tylko przy otwartym Zen.',
            )
          : t(
              'Odbiorca jest offline. Zaszyfrowane kopie trzymają jego '
              'znajomi (skrzynki) i oddadzą je, gdy wróci. To urządzenie też '
              'ponawia wysyłkę.',
            ),
    MessageDeliveryStage.waitingForBoth => t(
      'Za duża dla skrzynek u znajomych odbiorcy. Plik czeka na tym '
      'urządzeniu i przejdzie, gdy oba urządzenia będą online w tym samym '
      'czasie (iPhone: z otwartym Zen).',
    ),
    MessageDeliveryStage.sent =>
      ios
          ? t(
              'Wiadomość jest w kolejce. Ten iPhone ponawia wysyłkę, gdy Zen '
              'jest otwarty.',
            )
          : t('Wiadomość jest w kolejce i będzie ponawiana, aż dotrze.'),
    MessageDeliveryStage.delivered => t('Wiadomość jest u odbiorcy.'),
    MessageDeliveryStage.read => t('Odbiorca otworzył wiadomość.'),
    MessageDeliveryStage.failed => t(
      'Wiadomość nie dotarła. Możesz wysłać ją jeszcze raz.',
    ),
  };
}

/// The status icon of an outgoing bubble: long press shows the short label,
/// a tap the details with the legend (and "Ponów" when it failed).
class MessageDeliveryBadge extends ConsumerWidget {
  const MessageDeliveryBadge({
    super.key,
    required this.message,
    required this.conversationKey,
    this.isGroup = false,
    this.onAccent = false,
    this.size = 14,
  });

  final ChatMessage message;

  /// The friend's address, or `group:<id>`.
  final String conversationKey;
  final bool isGroup;

  /// Drawn on the accent gradient of the bubble.
  final bool onAccent;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MessageDeliveryStatus? status = messageDeliveryStatusFor(
      ref,
      message,
      isGroup: isGroup,
    );
    if (status == null) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final String label = messageDeliveryLabel(status);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        triggerMode: TooltipTriggerMode.longPress,
        child: InkResponse(
          key: Key('message-delivery-${message.id}'),
          radius: 18,
          onTap: () => unawaited(
            showMessageDeliveryDetails(
              context,
              status: status,
              onRetry: status.canRetry
                  ? () => ref
                        .read(socialHubControllerProvider.notifier)
                        .retryOutgoingMessage(
                          conversationKey: conversationKey,
                          messageId: message.id,
                        )
                  : null,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(
              messageDeliveryIcon(status.stage),
              size: size,
              color: messageDeliveryColor(
                zen,
                status.stage,
                onAccent: onAccent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The details of one message's status: label, what it means, the group's
/// counts, "Ponów" when [onRetry] is given, and the legend of all icons.
Future<void> showMessageDeliveryDetails(
  BuildContext context, {
  required MessageDeliveryStatus status,
  Future<void> Function()? onRetry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) {
      final ZenColors zen = ZenColors.of(sheetContext);
      final TextTheme text = Theme.of(sheetContext).textTheme;
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: SelectionArea(
            child: Column(
              key: const Key('message-delivery-details'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      messageDeliveryIcon(status.stage),
                      color: messageDeliveryColor(zen, status.stage),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        messageDeliveryLabel(status),
                        style: text.titleMedium,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  messageDeliveryExplanation(status.stage),
                  style: text.bodyMedium?.copyWith(color: zen.textSecondary),
                ),
                if (status.heldBySelf &&
                    status.stage ==
                        MessageDeliveryStage.inMailboxes) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    t('Jedną z kopii trzymasz Ty — jesteś skrzynką odbiorcy.'),
                    style: text.bodyMedium?.copyWith(color: zen.textSecondary),
                  ),
                ],
                if (status.isGroup && status.recipients > 0) ...<Widget>[
                  const SizedBox(height: 12),
                  _GroupCounts(status: status),
                ],
                if (onRetry != null) ...<Widget>[
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('message-delivery-retry'),
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      unawaited(
                        onRetry().catchError((Object error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  t('Nie udało się wysłać ponownie: {error}', {
                                    'error': error,
                                  }),
                                ),
                              ),
                            );
                          }
                        }),
                      );
                    },
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(t('Ponów')),
                  ),
                ],
                const SizedBox(height: 20),
                Divider(color: zen.outlineSoft),
                const SizedBox(height: 8),
                Text(t('Co oznaczają ikony'), style: text.titleSmall),
                const SizedBox(height: 8),
                const MessageDeliveryLegend(),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _GroupCounts extends StatelessWidget {
  const _GroupCounts({required this.status});

  final MessageDeliveryStatus status;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final TextStyle? style = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: zen.textSecondary);
    final List<(MessageDeliveryStage, String)> rows =
        <(MessageDeliveryStage, String)>[
          (
            MessageDeliveryStage.delivered,
            t('Dostarczono: {n}', <String, Object?>{'n': status.delivered}),
          ),
          if (status.inMailboxes > 0)
            (
              MessageDeliveryStage.inMailboxes,
              t('W skrzynkach u znajomych: {n}', <String, Object?>{
                'n': status.inMailboxes,
              }),
            ),
          if (status.waitingForBoth > 0)
            (
              MessageDeliveryStage.waitingForBoth,
              t('Czeka, aż oboje będziecie online: {n}', <String, Object?>{
                'n': status.waitingForBoth,
              }),
            ),
          if (status.waitingHere > 0)
            (
              MessageDeliveryStage.waitingHere,
              t('Czeka u Ciebie: {n}', <String, Object?>{
                'n': status.waitingHere,
              }),
            ),
          if (status.failed > 0)
            (
              MessageDeliveryStage.failed,
              t('Nie dotarło: {n}', <String, Object?>{'n': status.failed}),
            ),
        ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (MessageDeliveryStage stage, String line) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: <Widget>[
                Icon(
                  messageDeliveryIcon(stage),
                  size: 16,
                  color: messageDeliveryColor(zen, stage),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(line, style: style)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Every delivery icon with its label and what it means.
class MessageDeliveryLegend extends StatelessWidget {
  const MessageDeliveryLegend({super.key});

  static const List<MessageDeliveryStage> stages = <MessageDeliveryStage>[
    MessageDeliveryStage.sending,
    MessageDeliveryStage.waitingHere,
    MessageDeliveryStage.inMailboxes,
    MessageDeliveryStage.waitingForBoth,
    MessageDeliveryStage.sent,
    MessageDeliveryStage.delivered,
    MessageDeliveryStage.read,
    MessageDeliveryStage.failed,
  ];

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      key: const Key('message-delivery-legend'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final MessageDeliveryStage stage in stages)
          Padding(
            key: Key('message-delivery-legend-${stage.name}'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    messageDeliveryIcon(stage),
                    size: 18,
                    color: messageDeliveryColor(zen, stage),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        messageDeliveryStageLabel(stage),
                        style: text.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        messageDeliveryExplanation(stage),
                        style: text.bodySmall?.copyWith(
                          color: zen.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
