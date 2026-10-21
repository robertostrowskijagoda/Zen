import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';

/// Parts of Zen that a "core" release can leave out of sight.
/// The pyramid (with its access market) and the wallet are on by default
/// and can be switched off in "Funkcje eksperymentalne";
/// neighbours are core and have no flag.
///
/// A flag hides the feature's tabs and entry points, and `ZenCore` does not
/// start the feature's module (its services, timers and reloads). The data
/// stays on the device: turning the feature back on shows everything as it
/// was.
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

/// `--dart-define=ZEN_FEATURES_LOCKED=true`: the build-time choice is final
/// and "Funkcje eksperymentalne" is not offered.
const bool kFeatureFlagsLocked = bool.fromEnvironment('ZEN_FEATURES_LOCKED');

/// Which optional features show. Defaults come from the build; the user's
/// own choices (Settings → "Funkcje eksperymentalne") override them unless
/// the build locks them.
@immutable
final class FeatureFlags {
  const FeatureFlags([this.choices = const <ZenFeature, bool>{}]);

  /// What the user switched, by feature (absent = build default).
  final Map<ZenFeature, bool> choices;

  bool isEnabled(ZenFeature feature) => kFeatureFlagsLocked
      ? feature.compiledDefault
      : choices[feature] ?? feature.compiledDefault;

  /// Whether the side-rail tab [tabId] shows (tabs of no feature always do).
  bool showsTab(String tabId) {
    final ZenFeature? feature = ZenFeature.ofTab(tabId);
    return feature == null || isEnabled(feature);
  }

  FeatureFlags withFeature(ZenFeature feature, bool enabled) =>
      FeatureFlags(<ZenFeature, bool>{...choices, feature: enabled});

  Map<String, Object?> toJson() => withFormatVersion(<String, Object?>{
    'on': <String, bool>{
      for (final MapEntry<ZenFeature, bool> e in choices.entries)
        e.key.name: e.value,
    },
  });

  /// Unknown features and malformed values are skipped: the defaults stay.
  static FeatureFlags fromJson(Object? json) {
    if (json is! Map) {
      return const FeatureFlags();
    }
    final Object? on = json['on'];
    if (on is! Map) {
      return const FeatureFlags();
    }
    return FeatureFlags(<ZenFeature, bool>{
      for (final ZenFeature f in ZenFeature.values)
        if (on[f.name] is bool) f: on[f.name] as bool,
    });
  }

  @override
  bool operator ==(Object other) =>
      other is FeatureFlags &&
      ZenFeature.values.every((ZenFeature f) => other.choices[f] == choices[f]);

  @override
  int get hashCode =>
      Object.hashAll(ZenFeature.values.map((ZenFeature f) => choices[f]));
}

/// Where the choices are kept (next to the rail's own setting).
const String kFeatureFlagsKey = 'ui/features';

final NotifierProvider<FeatureFlagsController, FeatureFlags>
featureFlagsProvider = NotifierProvider<FeatureFlagsController, FeatureFlags>(
  FeatureFlagsController.new,
);

final class FeatureFlagsController extends Notifier<FeatureFlags> {
  /// Set once the user changed something: a slow load must not undo it.
  bool _touched = false;

  Completer<void> _loaded = Completer<void>();

  /// Completes once the stored choices were read (or found missing or
  /// unreadable): `ZenCore` waits for it before it picks feature modules.
  Future<void> get loaded => _loaded.future;

  @override
  FeatureFlags build() {
    _loaded = Completer<void>();
    unawaitedLogged(
      Future<void>.microtask(_load),
      context: 'Loading feature flags failed',
    );
    return const FeatureFlags();
  }

  Future<void> _load() async {
    final Completer<void> loaded = _loaded;
    try {
      final Uint8List? raw = await ref
          .read(ledgerDiskProvider)
          .read(kFeatureFlagsKey);
      if (raw == null || raw.isEmpty || _touched || !ref.mounted) {
        return;
      }
      try {
        state = FeatureFlags.fromJson(jsonDecode(utf8.decode(raw)));
      } on FormatException {
        // Unreadable: the build defaults stay.
      }
    } finally {
      if (!loaded.isCompleted) {
        loaded.complete();
      }
    }
  }

  Future<void> setEnabled(ZenFeature feature, bool enabled) async {
    if (kFeatureFlagsLocked) {
      return;
    }
    _touched = true;
    state = state.withFeature(feature, enabled);
    await ref
        .read(ledgerDiskProvider)
        .write(
          kFeatureFlagsKey,
          Uint8List.fromList(utf8.encode(jsonEncode(state.toJson()))),
        );
  }
}
