import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/dating/presentation/dating_screen.dart';

/// Opens the filter of new profiles; every change is kept at once (on this
/// phone only).
Future<void> showDatingFilter(BuildContext context, DatingService dating) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => DatingFilterSheet(
        initial: dating.filter,
        onChanged: (DatingFilter f) => unawaited(dating.setFilter(f)),
      ),
    );

/// Mutual friends one can ask for, at least.
const List<int> _mutualSteps = <int>[0, 1, 2, 3, 5];

/// The filter of new profiles: what kind of meeting, how far, genders,
/// interests, a photo, mutual friends. Nobody else ever sees it.
class DatingFilterSheet extends StatefulWidget {
  const DatingFilterSheet({
    required this.initial,
    required this.onChanged,
    super.key,
  });

  final DatingFilter initial;
  final ValueChanged<DatingFilter> onChanged;

  @override
  State<DatingFilterSheet> createState() => _DatingFilterSheetState();
}

class _DatingFilterSheetState extends State<DatingFilterSheet> {
  late DatingIntent? _intent = widget.initial.intent;
  late int _hops = widget.initial.hops;
  late Set<DatingGender> _genders = <DatingGender>{...widget.initial.genders};
  late Set<String> _interests = <String>{...widget.initial.interests};
  late bool _withPhoto = widget.initial.withPhoto;
  late int _minMutual = widget.initial.minMutual;

  void _changed() => widget.onChanged(
    DatingFilter(
      intent: _intent,
      hops: _hops,
      genders: _genders,
      interests: _interests,
      withPhoto: _withPhoto,
      minMutual: _minMutual,
    ),
  );

  void _set(VoidCallback change) {
    setState(change);
    _changed();
  }

  void _clear() => _set(() {
    _intent = null;
    _hops = kDatingMaxHops;
    _genders = <DatingGender>{...kDatingAllGenders};
    _interests = <String>{};
    _withPhoto = false;
    _minMutual = 0;
  });

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: ListView(
          key: const Key('dating-filter-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    t('Filtry'),
                    style: zen.display(
                      color: zen.textPrimary,
                      size: 22,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  key: const Key('dating-filter-clear'),
                  onPressed: _clear,
                  child: Text(t('Wyczyść')),
                ),
              ],
            ),
            ZenInfo(
              icon: Icons.lock_rounded,
              tone: tone,
              text: t(
                'Filtry działają tylko na Twoim telefonie — nikt inny ich '
                'nie widzi ani się o nich nie dowie.',
              ),
            ),
            ZenSection(t('Szukam'), top: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                ChoiceChip(
                  key: const Key('dating-filter-intent-any'),
                  label: Text(t('Wszyscy')),
                  selected: _intent == null,
                  onSelected: (_) => _set(() => _intent = null),
                ),
                for (final DatingIntent i in <DatingIntent>[
                  DatingIntent.dates,
                  DatingIntent.friends,
                ])
                  ChoiceChip(
                    key: Key('dating-filter-intent-${i.code}'),
                    label: Text(i.label),
                    selected: _intent == i,
                    onSelected: (_) => _set(() => _intent = i),
                  ),
              ],
            ),
            ZenSection(t('Jak daleko'), top: 16),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (int h = 1; h <= kDatingMaxHops; h++)
                  ChoiceChip(
                    key: Key('dating-filter-hops-$h'),
                    label: Text(
                      h == 1
                          ? t('Tylko moi znajomi')
                          : t('Też znajomi znajomych'),
                    ),
                    selected: _hops == h,
                    onSelected: (_) => _set(() => _hops = h),
                  ),
              ],
            ),
            ZenSection(t('Płeć'), top: 16),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final DatingGender g in DatingGender.values)
                  FilterChip(
                    key: Key('dating-filter-gender-${g.code}'),
                    label: Text(g.label),
                    selected: _genders.contains(g),
                    // At least one stays: an empty choice would show nobody.
                    onSelected: (bool v) {
                      if (!v && _genders.length <= 1) {
                        return;
                      }
                      _set(() {
                        _genders = <DatingGender>{..._genders};
                        if (v) {
                          _genders.add(g);
                        } else {
                          _genders.remove(g);
                        }
                      });
                    },
                  ),
              ],
            ),
            ZenSection(t('Zainteresowania'), top: 16),
            Text(
              t('Pokaż osoby, które mają choć jedno z zaznaczonych.'),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String code in kDatingInterests)
                  FilterChip(
                    key: Key('dating-filter-interest-$code'),
                    label: Text(datingInterestLabel(code)),
                    selected: _interests.contains(code),
                    onSelected: (bool v) => _set(() {
                      _interests = <String>{..._interests};
                      if (v) {
                        _interests.add(code);
                      } else {
                        _interests.remove(code);
                      }
                    }),
                  ),
              ],
            ),
            ZenSection(t('Wspólni znajomi'), top: 16),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final int n in _mutualSteps)
                  ChoiceChip(
                    key: Key('dating-filter-mutual-$n'),
                    label: Text(
                      n == 0 ? t('Dowolnie') : t('co najmniej {n}', {'n': n}),
                    ),
                    selected: _minMutual == n,
                    onSelected: (_) => _set(() => _minMutual = n),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const Key('dating-filter-photo'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              value: _withPhoto,
              title: Text(t('Tylko ze zdjęciem')),
              onChanged: (bool v) => _set(() => _withPhoto = v),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('dating-filter-done'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: tone,
                foregroundColor: ZenColors.foregroundFor(tone),
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t('Gotowe')),
            ),
          ],
        ),
      ),
    );
  }
}
