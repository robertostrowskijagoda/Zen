import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/hold_to_confirm.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// The changes of the emission limit announced and still waiting: a
/// notice pinned for every member (on the pyramid's first tab and in the
/// wallet), with "Anuluj zmianę" for the top.
class EmitChangeNotices extends StatelessWidget {
  const EmitChangeNotices({required this.pyr, required this.s, super.key});

  final PyramidService pyr;
  final PyramidState s;

  @override
  Widget build(BuildContext context) {
    final List<PyrEmitChange> pending = s.pendingEmitChanges;
    if (pending.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final String? me = pyr.myKey;
    final bool top = me != null && s.topCell.contains(me);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final PyrEmitChange c in pending) ...<Widget>[
          ZenInfo(
            key: Key('emit-change-${c.id}'),
            icon: Icons.campaign_rounded,
            tone: zen.warning,
            title: t('Zapowiedziana zmiana limitów'),
            text: pyrEmitChangeText(c),
          ),
          if (top)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: Key('emit-change-cancel-${c.id}'),
                onPressed: () => unawaited(() async {
                  if (await confirm(
                    context,
                    t('Anulować zmianę limitu?'),
                    t('Potrzebny podpis drugiej osoby ze szczytu.'),
                  )) {
                    await pyr.cancelEmitChange(c.id);
                  }
                }()),
                icon: const Icon(Icons.cancel_outlined, size: 18),
                label: Text(t('Anuluj zmianę')),
              ),
            ),
        ],
      ],
    );
  }
}

/// The top changes the emission limit, the wait and the payments a
/// member may order a day: a lower limit (a longer wait, fewer payments)
/// applies at once, after "Czy na pewno?" and holding the button; a
/// higher one is announced to everybody and applies 30 days later.
Future<void> changeEmissionLimit(
  BuildContext context,
  PyramidService pyr,
  PyramidState s,
) async {
  final TextEditingController limit = TextEditingController(
    text: formatMoney(s.params.emitLimit),
  );
  final TextEditingController hours = TextEditingController(
    text: '${s.params.emitDelayHours}',
  );
  final TextEditingController xfers = TextEditingController(
    text: '${s.params.xferLimit}',
  );
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(t('Limity')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZenInfo(
              icon: Icons.info_outline_rounded,
              text: t(
                'Niższy limit (albo dłuższe czekanie) obowiązuje od razu. '
                'Wyższy jest ogłaszany wszystkim i obowiązuje dopiero po 30 '
                'dniach; do tego czasu szczyt może go anulować.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('emit-limit-field'),
              controller: limit,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t('Limit na 30 dni'),
                prefixIcon: const Icon(Icons.savings_outlined),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('emit-hours-field'),
              controller: hours,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: t('Emisja czeka (godziny)'),
                helperText: t(
                  'Od {min} do {max} h; w tym czasie można ją '
                  'zawetować.',
                  <String, Object?>{
                    'min': kPyrMinEmitDelayHours,
                    'max': kPyrMaxEmitDelayHours,
                  },
                ),
                helperMaxLines: 3,
                prefixIcon: const Icon(Icons.schedule_rounded),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              key: const Key('emit-xfers-field'),
              controller: xfers,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: t('Przelewy na osobę dziennie'),
                helperText: t(
                  'Od {min} do {max}; chroni skarbników przed zalewem zleceń.',
                  <String, Object?>{'min': kPyrMinXfers, 'max': kPyrMaxXfers},
                ),
                helperMaxLines: 3,
                prefixIcon: const Icon(Icons.swap_horiz_rounded),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('emit-limit-next'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t('Dalej')),
        ),
      ],
    ),
  );
  final int? newLimit = parseMoney(limit.text);
  final int? newHours = int.tryParse(hours.text.trim());
  final int? newXfers = int.tryParse(xfers.text.trim());
  disposeLater(<TextEditingController>[limit, hours, xfers]);
  if (ok != true || !context.mounted) {
    return;
  }
  if (newLimit == null ||
      newHours == null ||
      newXfers == null ||
      newHours < kPyrMinEmitDelayHours ||
      newHours > kPyrMaxEmitDelayHours ||
      newXfers < kPyrMinXfers ||
      newXfers > kPyrMaxXfers) {
    snack(context, t('Podaj wartości w granicach.'));
    return;
  }
  final int? l = newLimit == s.params.emitLimit ? null : newLimit;
  final int? h = newHours == s.params.emitDelayHours ? null : newHours;
  final int? x = newXfers == s.params.xferLimit ? null : newXfers;
  if (l == null && h == null && x == null) {
    snack(context, t('Nic się nie zmienia.'));
    return;
  }
  final bool lowers = pyr.emitRuleLowers(limit: l, delayHours: h, xfers: x);
  final bool sure = lowers
      ? await confirmByHolding(
          context,
          body: t(
            'Nowe limity: {limit} na 30 dni, emisja czeka {hours} h, {xfers} przelewów na osobę dziennie. Zmiana obowiązuje od razu po podpisie drugiej osoby ze szczytu.',
            <String, Object?>{
              'limit': formatMoney(newLimit),
              'hours': newHours,
              'xfers': newXfers,
            },
          ),
          action: t('Przytrzymaj, aby obniżyć limit'),
        )
      : await confirm(
          context,
          t('Zapowiedzieć zmianę?'),
          t(
            'Nowe limity: {limit} na 30 dni, emisja czeka {hours} h, {xfers} przelewów na osobę dziennie. Zmiana zostanie ogłoszona wszystkim członkom i zacznie obowiązywać po 30 dniach. Do tego czasu szczyt może ją anulować.',
            <String, Object?>{
              'limit': formatMoney(newLimit),
              'hours': newHours,
              'xfers': newXfers,
            },
          ),
        );
  if (!sure) {
    return;
  }
  await pyr.proposeEmitRule(limit: l, delayHours: h, xfers: x);
  if (context.mounted) {
    snack(context, t('Potrzebny podpis drugiej osoby ze szczytu.'));
  }
}
