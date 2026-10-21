import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby_look_policy.dart';

/// "co 5 min · 8 s".
String nearbyLookChoiceText(int minutes, int seconds) => t(
  'co {minutes} min · {seconds} s',
  {'minutes': minutes, 'seconds': seconds},
);

/// What a choice costs: "ok. 0,6 mAh na dobę (0,02% baterii)".
String nearbyLookCostText(int minutes, int seconds) {
  final Duration every = Duration(minutes: minutes);
  final Duration window = Duration(seconds: seconds);
  return t('ok. {mah} mAh na dobę ({percent}% baterii)', {
    'mah': ZenFormat.number(
      nearbyLookMilliampHoursPerDay(every: every, window: window),
      decimals: 1,
    ),
    'percent': ZenFormat.number(
      nearbyLookBatteryPercentPerDay(every: every, window: window),
      decimals: 2,
    ),
  });
}

/// "Jak często": how often the background look around runs and how long
/// it lasts, with what each choice costs the battery. Shown while the look
/// around is on.
class NearbyLookSettingsTile extends StatelessWidget {
  const NearbyLookSettingsTile({required this.meet, super.key});

  final MeetService meet;

  Future<void> _pick(BuildContext context) => showDialog<void>(
    context: context,
    builder: (BuildContext context) => ListenableBuilder(
      listenable: meet,
      builder: (BuildContext context, Widget? _) {
        final ZenColors zen = ZenColors.of(context);
        final int minutes = meet.book.nearbyLookMinutes;
        final int seconds = meet.book.nearbyLookSeconds;
        return AlertDialog(
          title: Text(t('Rozglądanie w tle')),
          content: SizedBox(
            width: 380,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                Text(t('Jak często'), style: zen.label(color: zen.textMuted)),
                for (final int m in kNearbyLookEveryChoices)
                  ListTile(
                    key: Key('nearby-look-every-$m'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    selected: m == minutes,
                    title: Text(t('co {n} min', {'n': m})),
                    subtitle: Text(nearbyLookCostText(m, seconds)),
                    trailing: m == minutes
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => unawaited(meet.setNearbyLook(minutes: m)),
                  ),
                const SizedBox(height: 10),
                Text(t('Jak długo'), style: zen.label(color: zen.textMuted)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final int s in kNearbyLookForChoices)
                      ChoiceChip(
                        key: Key('nearby-look-for-$s'),
                        label: Text(t('{n} s', {'n': s})),
                        selected: s == seconds,
                        onSelected: (_) =>
                            unawaited(meet.setNearbyLook(seconds: s)),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  t(
                    'Dłużej i częściej — pewniej zauważysz znajomych obok, ale '
                    'radio pracuje więcej. Przy baterii poniżej 15%, w '
                    'oszczędzaniu baterii i we śnie telefonu rozglądanie '
                    'czeka.',
                  ),
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            FilledButton(
              key: const Key('nearby-look-done'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t('Gotowe')),
            ),
          ],
        );
      },
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: meet,
    builder: (BuildContext context, Widget? _) {
      final int minutes = meet.book.nearbyLookMinutes;
      final int seconds = meet.book.nearbyLookSeconds;
      return ListTile(
        key: const Key('nearby-look-settings'),
        enabled: meet.book.nearbyBackgroundScan,
        leading: const Icon(Icons.timer_outlined),
        title: Text(
          t('Jak często: {choice}', {
            'choice': nearbyLookChoiceText(minutes, seconds),
          }),
        ),
        subtitle: Text(nearbyLookCostText(minutes, seconds)),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => unawaited(_pick(context)),
      );
    },
  );
}

/// The look around in the settings: on/off and how often, with the cost.
class NearbyLookSettingsSection extends ConsumerWidget {
  const NearbyLookSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MeetService meet = ref.watch(meetServiceProvider);
    return ListenableBuilder(
      listenable: meet,
      builder: (BuildContext context, Widget? _) => ZenGroup(
        children: <Widget>[
          SwitchListTile(
            key: const Key('settings-nearby-look'),
            value: meet.book.nearbyBackgroundScan,
            title: Text(t('Rozglądaj się też w tle')),
            subtitle: Text(
              t(
                'Krótkie, oszczędne sprawdzanie przez Bluetooth, czy obok są '
                'znajomi („Mijani”). Nie przy baterii poniżej 15%, w '
                'oszczędzaniu baterii ani we śnie telefonu.',
              ),
            ),
            onChanged: (bool v) => unawaited(meet.setNearbyBackgroundScan(v)),
          ),
          NearbyLookSettingsTile(meet: meet),
        ],
      ),
    );
  }
}
