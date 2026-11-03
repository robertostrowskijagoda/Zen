import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';

/// "Powiadomienia z tego konta" for the open additional account (the setup's
/// notifications step): whether it posts notifications while it receives in
/// the background, as in Konta i odzyskiwanie. Waits for "Odbieraj w tle",
/// without which the account receives nothing while it is not open.
class AccountNotifySwitch extends ConsumerStatefulWidget {
  const AccountNotifySwitch({super.key});

  @override
  ConsumerState<AccountNotifySwitch> createState() =>
      _AccountNotifySwitchState();
}

class _AccountNotifySwitchState extends ConsumerState<AccountNotifySwitch> {
  bool? _background;
  bool? _notify;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final ZenAccountScope account = ref.read(zenAccountProvider);
    final ZenBackgroundAccounts settings = ref.read(
      zenBackgroundAccountsProvider,
    );
    try {
      final bool background = await settings.isOn(account);
      final bool notify = await settings.notifies(account);
      if (mounted) {
        setState(() {
          _background = background;
          _notify = notify;
        });
      }
    } on Object {
      // Not readable: the switch stays off.
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool background = _background ?? false;
    return SwitchListTile(
      key: const Key('setup-account-notify'),
      contentPadding: EdgeInsets.zero,
      value: background && (_notify ?? true),
      onChanged: !background || _notify == null
          ? null
          : (bool value) {
              setState(() => _notify = value);
              unawaited(
                ref
                    .read(zenBackgroundAccountsProvider)
                    .setNotify(ref.read(zenAccountProvider), value),
              );
            },
      title: Text(t('Powiadomienia z tego konta')),
      subtitle: Text(
        background
            ? t(
                'Gdy to konto odbiera w tle. Powiadomienie nie mówi, od kogo '
                'ani co przyszło, a stuknięcie otwiera to konto. Wyłączone: '
                'nic nie zdradza, że coś przyszło.',
              )
            : t(
                'Najpierw włącz „Odbieraj w tle” w Konta i odzyskiwanie: '
                'bez tego zamknięte konto nic nie odbiera.',
              ),
      ),
    );
  }
}
