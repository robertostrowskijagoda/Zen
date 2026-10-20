import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/meet/presentation/circle_screen.dart';
import 'package:zen/src/features/meet/presentation/events_screen.dart';
import 'package:zen/src/features/meet/presentation/intent_widgets.dart';
import 'package:zen/src/features/meet/presentation/plan_screen.dart';
import 'package:zen/src/features/meet/presentation/table_screen.dart';

/// "Spotkania" (§15–17): what friends are up for now, the alarm, people
/// nearby, events and the rest of meeting people through people.
class MeetHubScreen extends ConsumerWidget {
  const MeetHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    Widget tile(
      String key,
      int tone,
      IconData icon,
      String title,
      String subtitle,
      Future<void> Function(BuildContext) open,
    ) => ZenGridTile(
      key: Key(key),
      icon: icon,
      title: title,
      subtitle: subtitle,
      tone: zenTone(zen, tone),
      onTap: () => unawaited(open(context)),
    );
    return Scaffold(
      key: const Key('meet-hub'),
      appBar: ZenSectionBar(title: t('Spotkania')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: <Widget>[
          ZenSection(t('Na teraz'), top: 4),
          const IntentPanel(),
          ZenSection(t('Poznawaj ludzi przez ludzi')),
          ZenTileGrid(
            children: <Widget>[
              tile(
                'meet-events',
                1,
                Icons.celebration_rounded,
                t('Wydarzenia'),
                t('Imprezy i spotkania tylko dla ludzi przez znajomych'),
                EventsScreen.open,
              ),
              tile(
                'meet-table',
                2,
                Icons.dinner_dining_rounded,
                t('Stół na sześć'),
                t('Kolacja ze znajomymi Twoich znajomych'),
                TableScreen.open,
              ),
              tile(
                'meet-circles',
                3,
                Icons.soup_kitchen_rounded,
                t('Kółka obiadowe'),
                t('Gotujecie na zmianę, Zen pilnuje kolejki'),
                CirclesScreen.open,
              ),
              tile(
                'meet-plans',
                5,
                Icons.wb_sunny_rounded,
                t('Plan na weekend'),
                t('Luźny plan — gdy zbierze się ekipa, robi się wydarzenie'),
                PlanScreen.open,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
