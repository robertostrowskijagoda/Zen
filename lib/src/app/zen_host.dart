import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a `ZenCore` runs: in the app with its screens, or in the Android
/// background service while the app is away. Both build the same modules
/// (`zenAppModules`); the few duties that depend on the place ask this.
enum ZenHost {
  /// The app (any platform).
  app,

  /// The Android background service's own isolate: no screens, owns the
  /// node and the ledger while the app is away.
  backgroundService,
}

/// The app by default; the background service overrides it.
final Provider<ZenHost> zenHostProvider = Provider<ZenHost>(
  (Ref ref) => ZenHost.app,
);
