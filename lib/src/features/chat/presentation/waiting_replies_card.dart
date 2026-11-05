import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/waiting_replies.dart';
import 'package:zen/src/features/profile/presentation/mini_profile.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// "Czekają na Twoją odpowiedź": on the chats list, the friends whose last
/// message waits two days or more ([waitingRepliesProvider]); a tap opens
/// the chat, the cross beside one hides that one, "Ukryj wszystkie" all of
/// them, each until a newer message comes from that friend.
class WaitingRepliesCard extends ConsumerWidget {
  const WaitingRepliesCard({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<WaitingReply> waiting =
        ref.watch(waitingRepliesProvider).value ?? const <WaitingReply>[];
    if (waiting.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final DateTime now = ref.read(waitingRepliesClockProvider)();
    final List<WaitingReply> shown = waiting.take(3).toList();
    Future<void> hide(WaitingReply w) => ref
        .read(appSettingsControllerProvider.notifier)
        .markTipSeen(waitingReplyTip(w.friend.address, w.sinceMillis));
    return Padding(
      padding: padding,
      child: ZenCard(
        key: const Key('waiting-replies-card'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t('Czekają na Twoją odpowiedź'),
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: zen.textPrimary,
              ),
            ),
            for (final WaitingReply w in shown)
              ListTile(
                key: Key('waiting-reply-${w.friend.address}'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.mark_chat_unread_outlined),
                title: Text(
                  ref.read(socialHubControllerProvider).nameFor(w.friend),
                ),
                subtitle: Text(
                  tn(
                    now
                        .difference(
                          DateTime.fromMillisecondsSinceEpoch(w.sinceMillis),
                        )
                        .inDays,
                    one: 'od {n} dnia',
                    few: 'od {n} dni',
                    many: 'od {n} dni',
                  ),
                ),
                trailing: IconButton(
                  key: Key('waiting-reply-hide-${w.friend.address}'),
                  tooltip: t('Ukryj tę rozmowę'),
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => unawaited(hide(w)),
                ),
                onTap: () => unawaited(
                  openConversationWith(
                    context,
                    w.friend.address,
                    ref.read(socialHubControllerProvider).nameFor(w.friend),
                  ),
                ),
              ),
            if (waiting.length > shown.length)
              Text(
                t('i jeszcze {n}', <String, Object?>{
                  'n': waiting.length - shown.length,
                }),
                style: TextStyle(color: zen.textSecondary),
              ),
            // One alone has its cross; with more, all at once too.
            if (waiting.length > 1)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  key: const Key('waiting-replies-hide'),
                  onPressed: () async {
                    for (final WaitingReply w in waiting) {
                      await hide(w);
                    }
                  },
                  child: Text(t('Ukryj wszystkie')),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
