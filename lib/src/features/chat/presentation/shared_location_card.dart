import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/domain/messages/chat_location.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/location_sharing.dart';

String _clock(int millis) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.hour}:${d.minute.toString().padLeft(2, '0')}';
}

String _lengthLabel(Duration d) => d.inHours >= 1
    ? tn(d.inHours, one: '{n} godzina', few: '{n} godz.', many: '{n} godz.')
    : tn(d.inMinutes, one: '{n} min', few: '{n} min', many: '{n} min');

/// Asks how to share where the device is in [conversationKey] (once, or
/// live for a while) and shares it.
Future<void> shareLocationFrom(
  BuildContext context,
  WidgetRef ref,
  String conversationKey,
) async {
  final Duration? chosen = await showModalBottomSheet<Duration>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ListTile(
              key: const Key('location-once'),
              leading: const Icon(Icons.place_outlined),
              title: Text(t('Wyślij moje położenie')),
              onTap: () => Navigator.of(sheet).pop(Duration.zero),
            ),
            for (final Duration d in kLocationShareChoices)
              ListTile(
                key: Key('location-live-${d.inMinutes}'),
                leading: const Icon(Icons.share_location_rounded),
                title: Text(
                  t('Na żywo przez {length}', <String, Object?>{
                    'length': _lengthLabel(d),
                  }),
                ),
                onTap: () => Navigator.of(sheet).pop(d),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                t(
                  'Na żywo Zen wysyła nowe położenie co kilka minut, gdy '
                  'się przemieszczasz, i tylko wtedy, gdy działa. Możesz '
                  'przestać w każdej chwili.',
                ),
                style: Theme.of(sheet).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (chosen == null || !context.mounted) {
    return;
  }
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(locationSharingProvider)
        .share(
          conversationKey,
          length: chosen == Duration.zero ? null : chosen,
        );
  } on StateError catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } on Object catch (error) {
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          t('Nie udało się wysłać położenia: {error}', <String, Object?>{
            'error': error,
          }),
        ),
      ),
    );
  }
}

/// A shared position in a chat: when and how precise, live or not, the
/// map; on one's own live one, ending it.
class SharedLocationCard extends ConsumerWidget {
  const SharedLocationCard({
    super.key,
    required this.message,
    this.onGradient = false,
  });

  final ChatMessage message;

  /// Drawn on one's own (accent) bubble.
  final bool onGradient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ChatLocation location = message.location!;
    final ZenColors zen = ZenColors.of(context);
    final Color text = onGradient ? zen.onAccent : zen.textPrimary;
    final Color muted = onGradient
        ? zen.onAccent.withValues(alpha: 0.78)
        : zen.textMuted;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool live = location.isLiveAt(now);
    final LocationSharingService sharing = ref.watch(locationSharingProvider);
    return ListenableBuilder(
      listenable: sharing,
      builder: (BuildContext context, Widget? _) {
        final bool mineLive =
            message.isOutgoing && live && sharing.isSharing(message.id);
        return Column(
          key: Key('shared-location-${message.id}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  live ? Icons.share_location_rounded : Icons.place_outlined,
                  size: 20,
                  color: text,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    live
                        ? t('Położenie na żywo do {time}', <String, Object?>{
                            'time': _clock(location.untilMillis),
                          })
                        : t('Położenie'),
                    style: TextStyle(
                      color: text,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              t('Z {time}, dokładność ok. {m} m', <String, Object?>{
                'time': _clock(location.atMillis),
                'm': location.accuracy.round(),
              }),
              key: const Key('shared-location-when'),
              style: TextStyle(color: muted, fontSize: 12),
            ),
            if (!live && location.untilMillis > location.atMillis)
              Text(
                t('Udostępnianie zakończone'),
                style: TextStyle(color: muted, fontSize: 12),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const Key('shared-location-map'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: text,
                    side: BorderSide(color: muted),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () =>
                      unawaited(openMap(location.lat, location.lon)),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(t('Otwórz mapę')),
                ),
                if (mineLive)
                  OutlinedButton.icon(
                    key: const Key('shared-location-stop'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: text,
                      side: BorderSide(color: muted),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => unawaited(sharing.stop(message.id)),
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: Text(t('Przestań udostępniać')),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
