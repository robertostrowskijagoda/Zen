import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// The points wallet: its own place on the rail, next to Piramida. The
/// money lives in the pyramid a person belongs to, so this shows that
/// wallet when they are in one, and otherwise says plainly what points are
/// for today.
class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  /// The wallet as a page of its own.
  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const WalletScreen(),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final PyramidService pyr = ref.watch(pyramidServiceProvider);
    return ListenableBuilder(
      listenable: pyr,
      builder: (BuildContext context, Widget? _) {
        final PyramidState? s = pyr.state;
        final String? me = pyr.myKey;
        final bool member = s != null && me != null && s.isMember(me);
        return Scaffold(
          key: const Key('wallet-screen'),
          appBar: ZenSectionBar(title: t('Portfel')),
          // The wallet is a scrolling list of its own.
          body: member
              ? PyramidWallet(pyr: pyr, s: s, me: me)
              : _EmptyWallet(zen: zen),
        );
      },
    );
  }
}

class _EmptyWallet extends StatelessWidget {
  const _EmptyWallet({required this.zen});

  final ZenColors zen;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: <Widget>[
        Center(
          child: ZenIconBadge(
            icon: Icons.attach_money_rounded,
            tone: zen.accent,
            size: 64,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          t('Twój portfel jest pusty'),
          textAlign: TextAlign.center,
          style: zen.display(
            color: zen.textPrimary,
            size: 24,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          t(
            'Punkty to waluta piramidy, do której należysz — każda piramida '
            'ma własne. Gdy dołączysz do piramidy (zakładka „Piramida”), '
            'zobaczysz tu saldo, historię i przelewy.',
          ),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: zen.textSecondary,
            height: 1.5,
            fontSize: 14.5,
          ),
        ),
        const SizedBox(height: 20),
        ZenInfo(
          icon: Icons.bolt_rounded,
          title: t('Po co punkty'),
          text: t(
            'Płacisz nimi innym osobom z piramidy: przelew, napiwek za '
            'odpowiedź w „Zapytaj sieć” albo po wydarzeniu, podziękowanie '
            'w randkach. W rynku dostępu: płatna wiadomość, prośba '
            'o przedstawienie, udostępnienie i ogłoszenie — płatność '
            'warunkowa wraca, jeśli odbiorca jej nie przyjmie.',
          ),
        ),
        ZenInfo(
          icon: Icons.info_outline_rounded,
          title: t('Skąd się biorą'),
          text: t(
            'Nowe punkty jawnie wydaje szczyt piramidy (z limitem i prawem '
            'weta). W aplikacji nie da się ich kupić ani wypłacić.',
          ),
        ),
      ],
    );
  }
}
