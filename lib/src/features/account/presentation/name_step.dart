import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

/// The name as it is kept: trimmed, inner runs of spaces made one, at most
/// [kMaxProfileName] characters; `null` when nothing is left.
String? normalizeChosenName(String input) {
  final String name = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (name.isEmpty) {
    return null;
  }
  return name.length > kMaxProfileName
      ? name.substring(0, kMaxProfileName).trimRight()
      : name;
}

/// "Jak mają Cię widzieć znajomi?" on the first start of a new account:
/// the name that goes with invitations and messages. Without it friends
/// see the code instead (never a placeholder like "Ja").
class FirstNameStep extends ConsumerStatefulWidget {
  const FirstNameStep({super.key, required this.onDone});

  /// Called after the name was saved or the person skipped the step.
  final VoidCallback onDone;

  @override
  ConsumerState<FirstNameStep> createState() => _FirstNameStepState();
}

class _FirstNameStepState extends ConsumerState<FirstNameStep> {
  final TextEditingController _name = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String? name = normalizeChosenName(_name.text);
    if (name == null || _saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(userProfileControllerProvider.notifier)
          .updateProfile(displayName: name);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
    if (mounted) {
      widget.onDone();
    }
  }

  Future<void> _skip() async {
    final bool? skip = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        scrollable: true,
        key: const Key('first-name-skip-dialog'),
        title: Text(t('Bez imienia?')),
        content: Text(
          t(
            'Znajomi zobaczą zamiast imienia Twój kod, np. „Zen 1A2B-3C4D-5E6F”, '
            'i trudniej im będzie Cię rozpoznać. Imię ustawisz też później '
            'w profilu.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('first-name-skip-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Pomiń')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Wpiszę imię')),
          ),
        ],
      ),
    );
    if (skip == true && mounted) {
      widget.onDone();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool ready = normalizeChosenName(_name.text) != null;
    return Scaffold(
      key: const Key('first-name-step'),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            ZenHero(
              title: t('Jak mają Cię widzieć znajomi?'),
              icon: Icons.badge_outlined,
              text: t(
                'To imię zobaczą osoby, które zaprosisz, i Twoje grupy. '
                'Możesz je potem zmienić w profilu.',
              ),
            ),
            TextField(
              key: const Key('first-name-field'),
              controller: _name,
              autofocus: true,
              maxLength: kMaxProfileName,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => unawaited(_save()),
              decoration: InputDecoration(
                labelText: t('Imię lub pseudonim'),
                hintText: t('np. Ania K.'),
                prefixIcon: const Icon(Icons.person_outline_rounded),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('first-name-save'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: ready && !_saving ? () => unawaited(_save()) : null,
              child: Text(t('Dalej')),
            ),
            const SizedBox(height: 4),
            TextButton(
              key: const Key('first-name-skip'),
              onPressed: _saving ? null : () => unawaited(_skip()),
              child: Text(t('Pomiń'), style: TextStyle(color: zen.textMuted)),
            ),
          ],
        ),
      ),
    );
  }
}
