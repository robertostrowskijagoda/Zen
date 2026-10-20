import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/settings/app_settings.dart';

// LAN discovery (§5.1 item 6): the account's own devices on one Wi-Fi
// find each other through Yggdrasil multicast and connect directly.
//
// The beacons carry the node key, and any node that knows the multicast
// password may peer, so the password comes from a secret only the
// account's devices hold: friends' and strangers' devices on the same
// network cannot peer. The Go bridge turns the secret into the password
// (lan_discovery.go) and keeps phones on Wi-Fi interfaces.

/// The secret for the next node start, or `null` when LAN discovery is off.
typedef RuntimeLanDiscoveryResolver = Future<String?> Function();

/// The node config key the Go bridge reads the setting from.
const String kLanDiscoveryConfigKey = 'ZenLanDiscovery';

/// HKDF label of the secret.
const String kLanDiscoveryHkdfInfo = 'zen.lan.v1';

/// Android or iOS: LAN discovery is off by default and Wi-Fi only.
bool get isPhonePlatform => Platform.isAndroid || Platform.isIOS;

/// The secret the account's devices share, as hex: HKDF-SHA256 of the
/// account's self key ([LedgerIdentity.selfKey], itself derived from the
/// account key and kept on every device of the account even while the
/// account key is locked by its password).
Future<String> deriveLanDiscoverySecret(Uint8List selfKey) async {
  final SecretKey key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
      .deriveKey(
        secretKey: SecretKey(selfKey),
        info: utf8.encode(kLanDiscoveryHkdfInfo),
        nonce: const <int>[],
      );
  final List<int> bytes = await key.extractBytes();
  return bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// [configJson] with the LAN discovery setting the bridge reads: on with
/// [secretHex], absent (off) without it.
String applyLanDiscoveryToNodeConfig(String configJson, String? secretHex) {
  final Object? decoded = jsonDecode(configJson);
  if (decoded is! Map<String, dynamic>) {
    return configJson;
  }
  final Map<String, dynamic> config = Map<String, dynamic>.of(decoded)
    ..remove(kLanDiscoveryConfigKey);
  if (secretHex != null && secretHex.isNotEmpty) {
    config[kLanDiscoveryConfigKey] = <String, Object>{
      'Enabled': true,
      'Secret': secretHex,
      // The person turned on "Szukaj znajomych w tej samej sieci Wi-Fi";
      // the bridge uses only Wi-Fi interfaces on phones.
      'OnWiFi': true,
    };
  }
  return jsonEncode(config);
}

/// Reads the setting ([loadSettings]) and the account's self key
/// ([ledgerDisk]) at every node start, so a changed setting applies on the
/// next start. `null` (off) while the setting is off or there is no
/// identity yet.
RuntimeLanDiscoveryResolver lanDiscoveryResolver({
  required Future<AppSettings?> Function() loadSettings,
  required LedgerDisk ledgerDisk,
  bool? phone,
}) {
  return () async {
    final AppSettings settings = await loadSettings() ?? const AppSettings();
    if (!settings.lanDiscoveryOn(phone: phone ?? isPhonePlatform)) {
      return null;
    }
    try {
      final Uint8List? selfKey = (await LedgerIdentity.read(
        ledgerDisk,
      ))?.selfKey;
      return selfKey == null ? null : await deriveLanDiscoverySecret(selfKey);
    } on Object catch (error) {
      logZenWarning('LAN discovery stays off: no account key ($error)');
      return null;
    }
  };
}

/// Android delivers multicast on Wi-Fi only to apps holding a
/// `WifiManager.MulticastLock` (ZenMulticastLock.kt). It is held while LAN
/// discovery is on and released when it is off (it costs battery).
abstract final class AndroidMulticastLock {
  static const MethodChannel _channel = MethodChannel('zen/multicast');

  static Future<void> setHeld(bool held) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('setHeld', <String, Object>{
        'held': held,
      });
    } on Object catch (error) {
      logZenWarning('Multicast lock (held: $held) failed: $error');
    }
  }
}
