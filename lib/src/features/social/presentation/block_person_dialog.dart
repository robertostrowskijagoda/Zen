import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// What blocking a person covers, as every block dialog says it: one block,
/// in every feature and on every device of the account.
String blockCoversText(String name) => t(
  'Czy na pewno chcesz zablokować {name}? Blokada obejmuje tę osobę w całym '
  'Zen i na wszystkich Twoich urządzeniach: wiadomości i połączenia, '
  'zaproszenia do grup, Randki (nie zobaczy Twojego profilu, także przez '
  'wspólnych znajomych, a Ty jej), W pobliżu, tablicę i filmy, kamyki, '
  'przedstawienia i wzmianki.',
  {'name': name},
);

/// What blocking cannot do, said plainly: an account costs nothing.
String blockLimitText() => t(
  'Zen rozpozna jej znane adresy, urządzenia i klucze randkowe. Nowego '
  'konta, które ta osoba może założyć, nie rozpozna.',
);

/// Asks whether to block [name] everywhere ([blockCoversText]); true when
/// confirmed.
Future<bool> confirmBlockPerson(BuildContext context, String name) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => BlockPersonDialog(name: name),
  );
  return confirmed ?? false;
}

/// The dialog of [confirmBlockPerson].
class BlockPersonDialog extends StatelessWidget {
  const BlockPersonDialog({required this.name, super.key});

  final String name;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return AlertDialog(
      scrollable: true,
      icon: Icon(Icons.block_rounded, color: zen.danger, size: 30),
      title: Text(t('Zablokować użytkownika?')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(blockCoversText(name)),
          const SizedBox(height: 10),
          Text(
            blockLimitText(),
            style: TextStyle(color: zen.textSecondary, fontSize: 13),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('block-person-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: zen.danger,
            foregroundColor: ZenColors.foregroundFor(zen.danger),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t('Zablokuj')),
        ),
      ],
    );
  }
}
