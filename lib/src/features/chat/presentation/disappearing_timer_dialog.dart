import 'package:flutter/material.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';

/// Picks the disappearing-messages timer of a conversation (§14.1 point
/// 10). Returns the chosen seconds (0 = off), or `null` when cancelled.
Future<int?> showDisappearingTimerDialog(
  BuildContext context, {
  required int current,
}) {
  return showDialog<int>(
    context: context,
    builder: (BuildContext dialogContext) {
      return SimpleDialog(
        key: const Key('disappearing-timer-dialog'),
        title: const Text('Znikające wiadomości'),
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Nowe wiadomości znikną u wszystkich po wybranym czasie, razem '
              'z plikami. Zmiana jest widoczna dla rozmówców.',
            ),
          ),
          for (final int seconds in kDisappearChoices)
            ListTile(
              key: Key('disappearing-timer-$seconds'),
              leading: Icon(
                seconds == current
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
              ),
              title: Text(seconds == 0 ? 'Wyłączone' : disappearLabel(seconds)),
              onTap: () => Navigator.of(dialogContext).pop(seconds),
            ),
        ],
      );
    },
  );
}
