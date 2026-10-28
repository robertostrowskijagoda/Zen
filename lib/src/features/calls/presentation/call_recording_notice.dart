import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/call_recordings.dart';

/// What the person reads when a recording could not be stored.
String unsavedCallRecordingText() => t(
  'Nagranie rozmowy nie zostało zapisane. Ponów przed zamknięciem '
  'aplikacji, inaczej zniknie.',
);

/// Tells how a recording that was just stopped ended up: "saved" only once
/// it really is encrypted in the app; when it is not, a way to try again.
void showCallRecordingOutcome(
  ScaffoldMessengerState? messenger,
  CallRecordingKeeper keeper,
  CallRecordingOutcome? outcome,
) {
  if (messenger == null || !messenger.mounted) {
    return;
  }
  switch (outcome) {
    case CallRecordingOutcome.saved:
      messenger.showSnackBar(
        SnackBar(content: Text(t('Nagranie zapisane (zaszyfrowane).'))),
      );
    case CallRecordingOutcome.failed:
      messenger.showSnackBar(
        SnackBar(
          content: Text(unsavedCallRecordingText()),
          duration: const Duration(seconds: 10),
          // With an action a snack bar stays until dismissed by default.
          persist: false,
          action: SnackBarAction(
            label: t('Ponów'),
            onPressed: () => unawaited(_retry(messenger, keeper)),
          ),
        ),
      );
    case CallRecordingOutcome.empty:
    case null:
      break;
  }
}

Future<void> _retry(
  ScaffoldMessengerState messenger,
  CallRecordingKeeper keeper,
) async {
  final bool done = await keeper.retry();
  showCallRecordingOutcome(
    messenger,
    keeper,
    done ? CallRecordingOutcome.saved : CallRecordingOutcome.failed,
  );
}

/// Recordings that could not be stored (also those of a call that simply
/// ended): try again or give up. Hidden while there are none.
class UnsavedCallRecordingsBanner extends ConsumerWidget {
  const UnsavedCallRecordingsBanner({
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CallRecordingKeeper keeper = ref.watch(callRecordingKeeperProvider);
    return ListenableBuilder(
      listenable: keeper,
      builder: (BuildContext context, Widget? _) {
        if (keeper.unsaved.isEmpty) {
          return const SizedBox.shrink();
        }
        final ZenColors zen = ZenColors.of(context);
        return Padding(
          padding: padding,
          child: ZenCard(
            key: const Key('unsaved-call-recordings'),
            tone: zen.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ZenInfo(
                  icon: Icons.mic_off_rounded,
                  tone: zen.warning,
                  text: unsavedCallRecordingText(),
                ),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  children: <Widget>[
                    TextButton(
                      key: const Key('unsaved-call-recordings-discard'),
                      onPressed: () => unawaited(keeper.discard()),
                      child: Text(t('Usuń')),
                    ),
                    FilledButton(
                      key: const Key('unsaved-call-recordings-retry'),
                      onPressed: () => unawaited(keeper.retry()),
                      child: Text(t('Ponów')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
