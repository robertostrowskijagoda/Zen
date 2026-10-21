import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/crypto/hybrid_signature_core.dart';
import 'package:zen/src/core/crypto/hybrid_signature_ffi.dart';
import 'package:zen/src/core/logging/zen_log.dart';

export 'package:zen/src/core/crypto/hybrid_signature_core.dart';

HybridSigner? _override;
HybridSigner? _loaded;

/// The signer of this process: the bridge's. Throws when the bridge cannot
/// be loaded — nothing is then signed or taken (there is no classical
/// fallback), except in `flutter test` runs without a built bridge, which
/// use [kStandInHybridSigner] (never in a release build). Under
/// `flutter test` the bridge is called on the test's own isolate.
HybridSigner get hybridSigner => _override ?? (_loaded ??= _loadSigner());

/// Replaces [hybridSigner] (tests); `null` restores it.
@visibleForTesting
void debugOverrideHybridSigner(HybridSigner? signer) {
  _override = signer;
}

HybridSigner _loadSigner() {
  final bool test =
      !kReleaseMode && Platform.environment.containsKey('FLUTTER_TEST');
  try {
    return test ? BridgeHybridSigner.loadInline() : BridgeHybridSigner.load();
  } on Object catch (error) {
    if (test) {
      logZenWarning(
        'No bridge in this test run; signatures use the stand-in ML-DSA: '
        '$error',
      );
      return kStandInHybridSigner;
    }
    rethrow;
  }
}
