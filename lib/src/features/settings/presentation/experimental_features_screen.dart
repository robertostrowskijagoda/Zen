import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';

/// Ustawienia → "Funkcje eksperymentalne" (A15): show or hide the parts of
/// Zen that a "core" release leaves out. Hiding keeps their data.
class ExperimentalFeaturesScreen extends ConsumerWidget {
  const ExperimentalFeaturesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const ExperimentalFeaturesScreen(),
    ),
  );

  static String labelOf(ZenFeature feature) => switch (feature) {
    ZenFeature.pyramid => t('Piramida'),
    ZenFeature.wallet => t('Portfel i waluta'),
    ZenFeature.dating => t('Randki'),
    ZenFeature.neighbors => t('Sąsiedzi'),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FeatureFlags flags = ref.watch(featureFlagsProvider);
    return Scaffold(
      key: const Key('experimental-features-screen'),
      appBar: AppBar(title: Text(t('Funkcje eksperymentalne'))),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            ZenInfo(
              text: t(
                'Wyłączona funkcja znika z paska i menu. Jej dane zostają na '
                'urządzeniu i wracają po ponownym włączeniu.',
              ),
            ),
            ZenGroup(
              children: <Widget>[
                for (final ZenFeature feature in ZenFeature.values)
                  SwitchListTile(
                    key: Key('feature-flag-${feature.name}'),
                    title: Text(labelOf(feature)),
                    value: flags.isEnabled(feature),
                    onChanged: kFeatureFlagsLocked
                        ? null
                        : (bool value) => unawaited(
                            ref
                                .read(featureFlagsProvider.notifier)
                                .setEnabled(feature, value),
                          ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
