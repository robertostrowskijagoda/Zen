import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/friend_levels.dart';
import 'package:zen/src/features/meet/meet_providers.dart';

/// After adding someone met in person (a scanned QR, "W pobliżu", an
/// event): signs the "met in person" attestation (§6.2) and asks how close
/// they are (§8). "Znajomy" stays when skipped. Returns the level chosen,
/// or `null` when skipped.
Future<FriendLevel?> showMetLevelPrompt(
  BuildContext context, {
  required String address,
  String name = '',
}) async {
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final LedgerNode? ledger = container.read(ledgerNodeProvider);
  if (ledger != null) {
    unawaitedLogged(ledger.attestMet(address), context: 'Spotkani osobiście');
  }
  final FriendLevel? level = await showDialog<FriendLevel>(
    context: context,
    builder: (BuildContext context) => MetLevelDialog(name: name),
  );
  if (level == null || !context.mounted) {
    return null;
  }
  final LedgerNode? node = container.read(ledgerNodeProvider);
  if (node != null) {
    unawaitedLogged(
      setFriendLevel(
        node: node,
        meet: container.read(meetServiceProvider),
        address: address,
        level: level,
      ),
      context: 'Poziom znajomości',
    );
  }
  return level;
}

/// "Jak blisko się znacie?" with the three levels (§8).
class MetLevelDialog extends StatefulWidget {
  const MetLevelDialog({this.name = '', super.key});

  final String name;

  @override
  State<MetLevelDialog> createState() => _MetLevelDialogState();
}

class _MetLevelDialogState extends State<MetLevelDialog> {
  FriendLevel _level = FriendLevel.friend;

  String _hint(FriendLevel l) => switch (l) {
    FriendLevel.weak => t(
      'Widzi posty dla wszystkich znajomych. Bez Twojej listy znajomych '
      'i statusów.',
    ),
    FriendLevel.friend => t(
      'Widzi też Twoją listę znajomych i statusy, może zapraszać do grup.',
    ),
    FriendLevel.close => t(
      'Widzi wszystko, dostaje alarm, może być w Twoim kręgu zaufanych.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return AlertDialog(
      key: const Key('met-level-dialog'),
      title: Text(t('Jak blisko się znacie?')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.name.isEmpty
                ? t('Spotkaliście się osobiście. Poziom widzisz tylko Ty.')
                : t(
                    'Spotkaliście się osobiście z: {name}. Poziom widzisz '
                    'tylko Ty.',
                    {'name': widget.name},
                  ),
            style: TextStyle(color: zen.textSecondary, height: 1.35),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final FriendLevel l in FriendLevel.values)
                ChoiceChip(
                  key: Key('met-level-${l.name}'),
                  showCheckmark: false,
                  label: Text(kFriendLevelLabels[l]!),
                  selected: _level == l,
                  onSelected: (_) => setState(() => _level = l),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            _hint(_level),
            style: TextStyle(color: zen.textMuted, fontSize: 13, height: 1.35),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('met-level-skip'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Pomiń')),
        ),
        FilledButton(
          key: const Key('met-level-save'),
          onPressed: () => Navigator.of(context).pop(_level),
          child: Text(t('Zapisz')),
        ),
      ],
    );
  }
}
