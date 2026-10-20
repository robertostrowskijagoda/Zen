import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/presentation/own_avatar.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

/// Ready-made statuses (a tap is enough), in groups people think in: can
/// they write to me now, what am I doing, how am I. Gender-neutral wording
/// where Polish allows it.
List<({String title, List<String> items})> get kStatusGroups =>
    <({String title, List<String> items})>[
      (
        title: t('Czy można do mnie pisać'),
        items: <String>[
          t('🟢 Dostępny(-a)'),
          t('💼 W pracy'),
          t('⏳ Zaraz wracam'),
          t('🔕 Nie przeszkadzać'),
          t('📵 Rzadko zaglądam'),
          t('😴 Śpię'),
        ],
      ),
      (
        title: t('Co robię'),
        items: <String>[
          t('🚗 W drodze'),
          t('✈️ W podróży'),
          t('🏖️ Na urlopie'),
          t('📚 Uczę się'),
          t('🏋️ Na treningu'),
          t('🍳 Gotuję'),
          t('🎬 Oglądam film'),
          t('🎮 Gram'),
        ],
      ),
      (
        title: t('Jak się mam'),
        items: <String>[
          t('🍿 Odpoczywam'),
          t('🙌 Chętnie pogadam'),
          t('🎉 Świętuję'),
          t('🤒 Choruję'),
          t('🫶 Potrzebuję chwili dla siebie'),
        ],
      ),
    ];

/// All ready-made statuses, in order (the key of each chip is its index).
List<String> get kStatusPresets => <String>[
  for (final ({String title, List<String> items}) g in kStatusGroups)
    ...g.items,
];

/// Sets the short status friends see next to your name — from your
/// profile, not from the profile editor (it changes often, the profile
/// rarely).
Future<void> showStatusSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => const _StatusSheet(),
    );

class _StatusSheet extends ConsumerStatefulWidget {
  const _StatusSheet();

  @override
  ConsumerState<_StatusSheet> createState() => _StatusSheetState();
}

class _StatusSheetState extends ConsumerState<_StatusSheet> {
  late final TextEditingController _text = TextEditingController(
    text: ref.read(userProfileControllerProvider).customStatus,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _set(String status) async {
    await ref
        .read(userProfileControllerProvider.notifier)
        .updateProfile(customStatus: status.trim());
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return SafeArea(
      child: Padding(
        key: const Key('status-sheet'),
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const OwnAvatar(size: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        t('Twój status'),
                        style: zen.display(
                          color: zen.textPrimary,
                          size: 22,
                          weight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t('Widzą go znajomi obok Twojego imienia.'),
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final ({String title, List<String> items}) g
                        in kStatusGroups) ...<Widget>[
                      ZenSection(g.title, top: 14),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          for (final String st in g.items)
                            ChoiceChip(
                              key: Key(
                                'status-preset-${kStatusPresets.indexOf(st)}',
                              ),
                              label: Text(st),
                              selected: _text.text.trim() == st,
                              showCheckmark: false,
                              onSelected: (_) => unawaited(_set(st)),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('status-field'),
              controller: _text,
              maxLength: kMaxProfileStatus,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: t('Własny status'),
                hintText: t('Np. „Na urlopie do piątku 🏖️”'),
                prefixIcon: const Icon(Icons.edit_note_rounded),
              ),
              onSubmitted: (String v) => unawaited(_set(v)),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Flexible(
                  child: TextButton.icon(
                    key: const Key('status-clear'),
                    onPressed: () => unawaited(_set('')),
                    icon: const Icon(Icons.block_rounded, size: 18),
                    label: Text(t('Bez statusu')),
                  ),
                ),
                const Spacer(),
                FilledButton.icon(
                  key: const Key('status-save'),
                  onPressed: () => unawaited(_set(_text.text)),
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: Text(t('Ustaw')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
