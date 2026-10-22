import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/neighbors/presentation/flat_door_screen.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';

/// "Przenieś mieszkanie na to urządzenie": asks first (with [lead] above
/// the explanation, when given), moves the household here with a new door
/// key, and offers to print the new sticker right after. True when the
/// household runs here now.
Future<bool> takeOverFlat(
  BuildContext context,
  NeighborsService service, {
  String? lead,
}) async {
  final FlatProfile? flat = service.heldFlat;
  if (flat == null) {
    return false;
  }
  final String why = t(
    'Drzwi „{name}” zaczną działać na tym urządzeniu, z nowym kluczem. '
    'Stary telefon przestanie otwierać drzwi, a domownicy i sąsiedzi będą '
    'pukać tutaj. Stara naklejka prowadzi do starych drzwi — wydrukuj nową.',
    {'name': flat.name},
  );
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      icon: const Icon(Icons.home_work_rounded),
      title: Text(t('Przenieść mieszkanie na to urządzenie?')),
      content: SingleChildScrollView(
        child: Text(lead == null ? why : '$lead\n\n$why'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('flat-takeover-confirm'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(t('Przenieś')),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) {
    return false;
  }
  final FlatTakeover result = await service.takeOver();
  if (!context.mounted) {
    return result == FlatTakeover.done;
  }
  if (result != FlatTakeover.done) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result == FlatTakeover.offline
              ? t('Najpierw połącz się z siecią.')
              : t('Nie udało się przenieść mieszkania.'),
        ),
      ),
    );
    return false;
  }
  final bool? sticker = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      icon: const Icon(Icons.print_rounded),
      title: Text(t('Mieszkanie działa na tym urządzeniu')),
      content: SingleChildScrollView(
        child: Text(
          t(
            'Wydrukuj nową naklejkę i zamień starą na drzwiach — tamta '
            'prowadzi do starych drzwi.',
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(t('Później')),
        ),
        FilledButton(
          key: const Key('flat-takeover-print'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(t('Nowa naklejka')),
        ),
      ],
    ),
  );
  if (sticker == true && context.mounted) {
    await FlatDoorScreen.open(context);
  }
  return true;
}

/// Where a device of the account keeps a copy of the household it does not
/// run (another device runs the door, or it came back from a backup): the
/// household's name and "Przenieś mieszkanie na to urządzenie". Nothing
/// otherwise. [runsOn] names the device that runs it, when known.
class FlatTakeoverCard extends ConsumerWidget {
  const FlatTakeoverCard({this.runsOn, super.key});

  final String? runsOn;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NeighborsService service = ref.watch(neighborsServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (BuildContext context, Widget? _) {
        final FlatProfile? flat = service.heldFlat;
        if (flat == null || !service.canTakeOver) {
          return const SizedBox.shrink();
        }
        final ZenColors zen = ZenColors.of(context);
        final Color tone = neighborsTone(zen);
        final String? device = runsOn;
        return ZenCard(
          key: const Key('flat-takeover-card'),
          tone: tone,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ZenIconBadge(icon: Icons.home_work_rounded, tone: tone),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t('„{name}” działa na innym urządzeniu', {
                            'name': flat.name,
                          }),
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                        if (device != null && device.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(
                            device,
                            style: TextStyle(
                              color: zen.textSecondary,
                              fontSize: 13.5,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                t(
                  'Mieszkanie działa naraz tylko na jednym urządzeniu konta — '
                  'to ono otwiera drzwi. Gdy tamto zginęło, zepsuło się albo '
                  'zmieniasz telefon, przenieś mieszkanie tutaj.',
                ),
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('flat-takeover'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => unawaited(takeOverFlat(context, service)),
                icon: const Icon(Icons.swap_horiz_rounded),
                label: Text(
                  t('Przenieś mieszkanie na to urządzenie'),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
