import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// The price list of a pyramid member on their profile: each service
/// on its own, by level of acquaintance where it differs. Nothing when the
/// person is not in this phone's pyramid or asks nothing; the pyramid is
/// never started just for this.
class PyramidPriceList extends ConsumerWidget {
  const PyramidPriceList({required this.address, this.own = false, super.key});

  /// The device address of the profile's person ('' for one's own).
  final String address;

  /// One's own profile.
  final bool own;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.exists(pyramidServiceProvider)) {
      return const SizedBox.shrink();
    }
    final PyramidService pyr = ref.read(pyramidServiceProvider);
    return ListenableBuilder(
      listenable: pyr,
      builder: (BuildContext context, _) {
        final PyramidState? s = pyr.state;
        if (s == null) {
          return const SizedBox.shrink();
        }
        final String key = own
            ? pyr.myKey ?? ''
            : pyramidKeyForAddress(s.members.values, address);
        final List<PyrPriceRow> rows = pyrPriceRows(s, key);
        if (rows.isEmpty) {
          return const SizedBox.shrink();
        }
        // The level this phone can tell for the person (the receiver
        // decides the real one when the message comes).
        final String? mine = own
            ? null
            : pyr.levelOfAddress(address, sure: false);
        return PyramidPriceCard(rows: rows, level: mine);
      },
    );
  }
}

/// One service of a price list: its name and the price for each level of
/// acquaintance ([kPriceLevels]); one entry under '' when the same for all.
typedef PyrPriceRow = ({String kind, String label, Map<String, int> prices});

/// The price list of member [key] in [s], in the order of [kMarketKinds].
List<PyrPriceRow> pyrPriceRows(PyramidState s, String key) {
  if (key.isEmpty || !s.isMember(key)) {
    return const <PyrPriceRow>[];
  }
  final Map<String, int> flat = s.offers[key] ?? const <String, int>{};
  final Map<String, Map<String, int>> levels =
      s.offerLevels[key] ?? const <String, Map<String, int>>{};
  return <PyrPriceRow>[
    for (final MapEntry<String, String> k in kMarketKinds.entries)
      if (flat.containsKey(k.key))
        (
          kind: k.key,
          label: k.value,
          // By level when they differ, or when some level is left out
          // (it may not use the service: a first message from strangers).
          prices:
              levels[k.key] != null &&
                  (levels[k.key]!.values.toSet().length > 1 ||
                      levels[k.key]!.length < kPriceLevels.length)
              ? levels[k.key]!
              : <String, int>{'': flat[k.key]!},
        ),
  ];
}

/// The price list as a card; [level] is the price level this phone sees
/// for the person looking (marked), when known.
class PyramidPriceCard extends StatelessWidget {
  const PyramidPriceCard({required this.rows, this.level, super.key});

  final List<PyrPriceRow> rows;
  final String? level;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    String money(int v) => v == 0 ? t('za darmo') : formatMoney(v);
    return ZenCard(
      key: const Key('pyr-price-list'),
      margin: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.sell_outlined, color: zen.accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('Cennik w piramidzie'),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final PyrPriceRow r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: '${r.label}: ',
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: r.prices.containsKey('')
                          ? money(r.prices['']!)
                          : <String>[
                              for (final MapEntry<String, String> l
                                  in kPriceLevels.entries)
                                if (r.prices[l.key] != null)
                                  '${l.value.toLowerCase()} '
                                      '${money(r.prices[l.key]!)}'
                                      '${l.key == level ? ' ←' : ''}',
                            ].join(' · '),
                    ),
                  ],
                ),
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.35,
                ),
              ),
            ),
          const SizedBox(height: 4),
          Text(
            t(
              'Płatność warunkowa: wraca, gdy odbiorca odmówi albo nie odpowie.',
            ),
            style: TextStyle(color: zen.textMuted, fontSize: 12, height: 1.3),
          ),
        ],
      ),
    );
  }
}
