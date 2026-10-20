import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

/// Whether this is the store build of the app (Google Play, Galaxy Store;
/// STAN D12): `flutter build appbundle --flavor store` (Android), or any
/// build with `--dart-define=ZEN_STORE=true`.
///
/// Stores update the app themselves and forbid installing or handing out
/// APKs, so such a build has no self-update and passes Zen on as a link
/// instead of a file. The Android "store" flavor also drops the
/// REQUEST_INSTALL_PACKAGES permission (android/app/src/store).
bool get isStoreBuild => isStoreBuildFor(
  flavor: appFlavor,
  define: const bool.fromEnvironment('ZEN_STORE'),
);

/// [isStoreBuild] for a given flavor and `ZEN_STORE` define.
@visibleForTesting
bool isStoreBuildFor({required String? flavor, bool define = false}) =>
    define || flavor == 'store';

/// Where a store build sends someone Zen is passed on to: the project page,
/// which links to the stores and the other downloads. A store-specific
/// build can point elsewhere with `--dart-define=ZEN_STORE_URL=…`.
const String kStoreShareUrl = String.fromEnvironment(
  'ZEN_STORE_URL',
  defaultValue: 'https://robertostrowskijagoda.github.io/Zen/',
);
