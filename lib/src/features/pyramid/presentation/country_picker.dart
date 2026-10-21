import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/pyramid/pyramid_countries.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// "🇵🇱 Polska" in the app's language.
String countryLabel(String code) =>
    '${flagOf(code)} ${countryName(code)}'.trim();

/// Picks the countries "Kraj" follows: a searchable list of flags and
/// names, several at once (at most [kPyrFollowMax]). The chosen list, an
/// empty one for "Domyślne" (back to the default), or null when closed.
Future<List<String>?> pickCountries(
  BuildContext context, {
  required List<String> selected,
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (BuildContext context) => FractionallySizedBox(
    heightFactor: 0.85,
    child: CountryPicker(selected: selected),
  ),
);

/// The list behind [pickCountries].
class CountryPicker extends StatefulWidget {
  const CountryPicker({required this.selected, super.key});

  final List<String> selected;

  @override
  State<CountryPicker> createState() => _CountryPickerState();
}

class _CountryPickerState extends State<CountryPicker> {
  late final List<String> _chosen = List<String>.of(widget.selected);
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// The countries matching the search (by name in the app's language or
  /// by code), the chosen ones first, then by name.
  List<String> get _shown {
    final String q = _query.trim().toLowerCase();
    final List<String> all = <String>[
      for (final String c in <String>{..._chosen, ...kPyrCountryCodes})
        if (q.isEmpty ||
            c.toLowerCase().contains(q) ||
            countryName(c).toLowerCase().contains(q))
          c,
    ];
    return all..sort((String a, String b) {
      final bool ca = _chosen.contains(a);
      final bool cb = _chosen.contains(b);
      if (ca != cb) {
        return ca ? -1 : 1;
      }
      return countryName(
        a,
      ).toLowerCase().compareTo(countryName(b).toLowerCase());
    });
  }

  void _toggle(String code) {
    setState(() {
      if (!_chosen.remove(code) && _chosen.length < kPyrFollowMax) {
        _chosen.add(code);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<String> shown = _shown;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t('Kraje w „Kraj”'),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t(
              'Posty sekcji krajowych przekazują Ci znajomi z piramidy. Najwyżej {count}.',
              <String, Object?>{'count': kPyrFollowMax},
            ),
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('country-search'),
            controller: _search,
            onChanged: (String v) => setState(() => _query = v),
            decoration: InputDecoration(
              labelText: t('Szukaj kraju'),
              prefixIcon: const Icon(Icons.search_rounded),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              key: const Key('country-list'),
              itemCount: shown.length,
              itemBuilder: (BuildContext context, int i) {
                final String code = shown[i];
                final bool on = _chosen.contains(code);
                return CheckboxListTile(
                  key: Key('country-$code'),
                  value: on,
                  onChanged: on || _chosen.length < kPyrFollowMax
                      ? (bool? _) => _toggle(code)
                      : null,
                  title: Text(countryLabel(code)),
                  subtitle: Text(code),
                  controlAffinity: ListTileControlAffinity.trailing,
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              TextButton(
                key: const Key('country-default'),
                onPressed: () => Navigator.of(context).pop(const <String>[]),
                child: Text(t('Domyślne')),
              ),
              FilledButton(
                key: const Key('country-done'),
                onPressed: () =>
                    Navigator.of(context).pop(List<String>.of(_chosen)),
                child: Text(t('Gotowe')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The countries "Kraj" shows, with "Wybierz kraje" (the picker).
class FollowedCountries extends StatelessWidget {
  const FollowedCountries({required this.pyr, super.key});

  final PyramidService pyr;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<String> shown = pyr.feedCountries;
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 6,
      children: <Widget>[
        Text(
          shown.isEmpty
              ? t('Nie wybrano kraju.')
              : shown.map(countryLabel).join(', '),
          key: const Key('feed-nat-countries-shown'),
          style: TextStyle(color: zen.textSecondary, fontSize: 13),
        ),
        OutlinedButton.icon(
          key: const Key('feed-nat-countries'),
          onPressed: () async {
            final List<String>? picked = await pickCountries(
              context,
              selected: pyr.followedCountries.isEmpty
                  ? pyr.feedCountries
                  : pyr.followedCountries,
            );
            if (picked != null) {
              await pyr.followCountries(picked);
            }
          },
          icon: const Icon(Icons.public_rounded),
          label: Text(t('Wybierz kraje')),
        ),
      ],
    );
  }
}
