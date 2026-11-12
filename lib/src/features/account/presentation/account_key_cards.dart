import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/account/presentation/account_recovery_screen.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/security/sensitive_access.dart';

/// Rebuilds [builder] with the account's node whenever its devices or its
/// account key's wrapping change; nothing while there is no ready node.
class _OnNode extends ConsumerStatefulWidget {
  const _OnNode({required this.builder});

  final Widget Function(BuildContext context, LedgerNode node) builder;

  @override
  ConsumerState<_OnNode> createState() => _OnNodeState();
}

class _OnNodeState extends ConsumerState<_OnNode> {
  LedgerNode? _node;
  final List<StreamSubscription<void>> _subs = <StreamSubscription<void>>[];

  void _listen(LedgerNode? node) {
    if (identical(node, _node)) {
      return;
    }
    for (final StreamSubscription<void> s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    _node = node;
    if (node == null) {
      return;
    }
    void changed(void _) {
      if (mounted) {
        setState(() {});
      }
    }

    _subs
      ..add(node.devicesChanged.listen(changed))
      ..add(node.keyChanged.listen(changed));
    unawaited(
      node.settled.then((_) {
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  @override
  void dispose() {
    for (final StreamSubscription<void> s in _subs) {
      unawaited(s.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LedgerNode? node = ref.watch(ledgerNodeEnabledProvider)
        ? ref.watch(ledgerNodeProvider)
        : null;
    _listen(node);
    if (node == null || !node.isReady) {
      return const SizedBox.shrink();
    }
    return widget.builder(context, node);
  }
}

/// "Nowe urządzenie na Twoim koncie": a device of the account appeared
/// after one was cut off, and nobody confirmed it yet. It gets nothing from
/// this device until the person says it is theirs, in "Urządzenia".
class UnconfirmedDevicesCard extends StatelessWidget {
  const UnconfirmedDevicesCard({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => _OnNode(
    builder: (BuildContext context, LedgerNode node) {
      final List<AccountDevice> waiting = node.unconfirmedDevices;
      if (waiting.isEmpty) {
        return const SizedBox.shrink();
      }
      final ZenColors zen = ZenColors.of(context);
      return Padding(
        padding: padding,
        child: ZenCard(
          key: const Key('unconfirmed-devices-card'),
          tone: zen.danger,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ZenInfo(
                icon: Icons.devices_other_rounded,
                tone: zen.danger,
                title: t('Nowe urządzenie na Twoim koncie: „{name}”', {
                  'name': waiting.first.name,
                }),
                text: t(
                  'Czy to Ty je dodałeś? Dopóki tego nie potwierdzisz, Twoje '
                  'urządzenia nic mu nie wysyłają i nie biorą niczego, co na '
                  'nim zapisano.',
                ),
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  key: const Key('unconfirmed-devices-open'),
                  onPressed: () =>
                      unawaited(AccountDevicesScreen.open(context)),
                  child: Text(t('Sprawdź')),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// "Chroń klucz konta": offered on a device whose account key is not kept
/// the way the account password keeps it ([LedgerIdentity.offersKeyGuard]):
/// one that took the account without the password's wrapping (set the
/// password: it protects the key on every device), or one whose wrapping
/// the account's other devices cannot take yet (the password typed once
/// signs it and they take it).
class AccountKeyGuardCard extends StatelessWidget {
  const AccountKeyGuardCard({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => _OnNode(
    builder: (BuildContext context, LedgerNode node) {
      if (!node.identity.offersKeyGuard) {
        return const SizedBox.shrink();
      }
      final bool wrapped = node.identity.hasPassword;
      if (wrapped && node.ownDevices.length < 2) {
        // Nothing to pass on yet.
        return const SizedBox.shrink();
      }
      final ZenColors zen = ZenColors.of(context);
      return Padding(
        padding: padding,
        child: ZenCard(
          key: const Key('account-key-guard-card'),
          tone: zen.warning,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ZenInfo(
                icon: Icons.key_rounded,
                tone: zen.warning,
                title: wrapped
                    ? t('Hasło konta na pozostałych urządzeniach')
                    : t('Chroń klucz konta na tym urządzeniu'),
                text: wrapped
                    ? t(
                        'Podaj raz hasło konta na tym urządzeniu, a będzie '
                        'chronić klucz konta także na Twoich pozostałych '
                        'urządzeniach.',
                      )
                    : t(
                        'Klucz konta jest tu chroniony tylko blokadą '
                        'aplikacji: kto odblokuje to urządzenie, może przejąć '
                        'konto. Ustaw hasło konta — ochroni klucz na '
                        'wszystkich Twoich urządzeniach.',
                      ),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                children: <Widget>[
                  TextButton(
                    key: const Key('account-key-guard-later'),
                    onPressed: () => unawaited(node.dismissKeyGuard()),
                    child: Text(t('Nie teraz')),
                  ),
                  FilledButton(
                    key: const Key('account-key-guard-open'),
                    onPressed: () => unawaited(
                      wrapped
                          ? _signWrapping(context, node)
                          : AccountRecoveryScreen.open(context),
                    ),
                    child: Text(
                      wrapped ? t('Podaj hasło konta') : t('Ustaw hasło konta'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );

  /// The password typed once: the wrapping gets the account's signature
  /// ([LedgerIdentity.unlock]) and goes to the other devices.
  static Future<void> _signWrapping(
    BuildContext context,
    LedgerNode node,
  ) async {
    final String? password = await askAccountPassword(
      context,
      t('Hasło konta'),
    );
    if (password == null || !context.mounted) {
      return;
    }
    final String? problem = await tryAccountPassword(
      context,
      () => node.identity.unlock(password),
    );
    node.identity.lock();
    if (problem != null) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(problem)));
      }
      return;
    }
    await node.shareWrapping();
  }
}
