import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Parts of Zen a build can leave out. In the app every feature is simply
/// on: there is no switch for them. Only a build can leave one out
/// (`--dart-define=ZEN_FEATURE_PYRAMID=false`); then its tabs and entry
/// points are hidden and `ZenCore` does not start the feature's module (its
/// services, timers and reloads). Neighbours are core and have no flag.
enum ZenFeature {
  pyramid(
    'pyramid',
    bool.fromEnvironment('ZEN_FEATURE_PYRAMID', defaultValue: true),
  ),
  wallet(
    'wallet',
    bool.fromEnvironment('ZEN_FEATURE_WALLET', defaultValue: true),
  ),
  dating(
    'dating',
    bool.fromEnvironment('ZEN_FEATURE_DATING', defaultValue: true),
  );

  const ZenFeature(this.tabId, this.compiledDefault);

  /// The id of the feature's tab in the side rail.
  final String tabId;

  /// The default chosen at build time, e.g.
  /// `--dart-define=ZEN_FEATURE_PYRAMID=false`.
  final bool compiledDefault;

  static ZenFeature? ofTab(String tabId) {
    for (final ZenFeature f in values) {
      if (f.tabId == tabId) {
        return f;
      }
    }
    return null;
  }
}

/// Which optional features run: the build's defaults, unless a test leaves
/// one out ([choices]).
@immutable
final class FeatureFlags {
  const FeatureFlags([this.choices = const <ZenFeature, bool>{}]);

  /// Overrides of the build defaults, by feature (absent = build default).
  final Map<ZenFeature, bool> choices;

  bool isEnabled(ZenFeature feature) =>
      choices[feature] ?? feature.compiledDefault;

  /// Whether the side-rail tab [tabId] shows (tabs of no feature always do).
  bool showsTab(String tabId) {
    final ZenFeature? feature = ZenFeature.ofTab(tabId);
    return feature == null || isEnabled(feature);
  }

  FeatureFlags withFeature(ZenFeature feature, bool enabled) =>
      FeatureFlags(<ZenFeature, bool>{...choices, feature: enabled});

  @override
  bool operator ==(Object other) =>
      other is FeatureFlags &&
      ZenFeature.values.every((ZenFeature f) => other.choices[f] == choices[f]);

  @override
  int get hashCode =>
      Object.hashAll(ZenFeature.values.map((ZenFeature f) => choices[f]));
}

final NotifierProvider<FeatureFlagsController, FeatureFlags>
featureFlagsProvider = NotifierProvider<FeatureFlagsController, FeatureFlags>(
  FeatureFlagsController.new,
);

/// Holds the flags: the build's defaults. Nothing is stored and nothing in
/// the app changes them.
final class FeatureFlagsController extends Notifier<FeatureFlags> {
  @override
  FeatureFlags build() => const FeatureFlags();

  /// Leaves [feature] out (or brings it back) while the app runs.
  @visibleForTesting
  void setEnabled(ZenFeature feature, bool enabled) {
    state = state.withFeature(feature, enabled);
  }
}
