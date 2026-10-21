import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

/// Whether this is the store build of the app (Google Play, Galaxy Store):
/// `flutter build appbundle --flavor appStoreOnly` (Android), or
/// any build with `--dart-define=ZEN_STORE=true`.
///
/// Stores update the app themselves and forbid installing or handing out
/// APKs, so such a build has no self-update and passes Zen on as a link
/// instead of a file. It is called "Zen" everywhere; only the About screen
/// says "Wersja ze sklepu". The Android "appStoreOnly" flavor (files named
/// `Zen-APP-STORE-ONLY-do-not-install-manually`) also drops the
/// REQUEST_INSTALL_PACKAGES permission (android/app/src/appStoreOnly).
bool get isStoreBuild => isStoreBuildFor(
  flavor: appFlavor,
  define: const bool.fromEnvironment('ZEN_STORE'),
);

/// [isStoreBuild] for a given flavor and `ZEN_STORE` define.
@visibleForTesting
bool isStoreBuildFor({required String? flavor, bool define = false}) =>
    define || flavor == 'appStoreOnly';

/// Where a store build sends someone Zen is passed on to: the project page,
/// which links to the stores and the other downloads. A store-specific
/// build can point elsewhere with `--dart-define=ZEN_STORE_URL=…`.
const String kStoreShareUrl = String.fromEnvironment(
  'ZEN_STORE_URL',
  defaultValue: 'https://robertostrowskijagoda.github.io/Zen/',
);
