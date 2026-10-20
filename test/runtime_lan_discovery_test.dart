import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  test('LAN discovery is off by default on every platform', () {
    const AppSettings defaults = AppSettings();
    expect(defaults.lanDiscovery, isNull);
    expect(defaults.lanDiscoveryOn(phone: false), isFalse);
    expect(defaults.lanDiscoveryOn(phone: true), isFalse);
    expect(defaults.toJson().containsKey('lanDiscovery'), isFalse);

    final AppSettings chosen = AppSettings.fromJson(
      defaults.copyWith(lanDiscovery: true).toJson(),
    );
    expect(chosen.lanDiscoveryOn(phone: true), isTrue);
    final AppSettings off = AppSettings.fromJson(
      defaults.copyWith(lanDiscovery: false).toJson(),
    );
    expect(off.lanDiscoveryOn(phone: false), isFalse);
  });

  test('the secret is the same for the same account key only', () async {
    final Uint8List key = Uint8List.fromList(List<int>.generate(32, (i) => i));
    final Uint8List other = Uint8List.fromList(
      List<int>.generate(32, (i) => 255 - i),
    );
    final String secret = await deriveLanDiscoverySecret(key);

    expect(secret, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(await deriveLanDiscoverySecret(key), secret);
    expect(await deriveLanDiscoverySecret(other), isNot(secret));
  });

  test('the node config carries the setting the bridge reads', () {
    const String config = '{"PrivateKey":"abc","Peers":["tls://1.2.3.4:443"]}';

    final Map<String, dynamic> on =
        jsonDecode(applyLanDiscoveryToNodeConfig(config, 'aa' * 32))
            as Map<String, dynamic>;
    expect(on['PrivateKey'], 'abc');
    expect(on['Peers'], <String>['tls://1.2.3.4:443']);
    expect(on[kLanDiscoveryConfigKey], <String, dynamic>{
      'Enabled': true,
      'Secret': 'aa' * 32,
      'OnWiFi': true,
    });

    final Map<String, dynamic> off =
        jsonDecode(applyLanDiscoveryToNodeConfig(jsonEncode(on), null))
            as Map<String, dynamic>;
    expect(off.containsKey(kLanDiscoveryConfigKey), isFalse);
    expect(off['PrivateKey'], 'abc');
  });

  test('the resolver follows the setting and the account', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    AppSettings settings = const AppSettings();
    RuntimeLanDiscoveryResolver resolver({required bool phone}) =>
        lanDiscoveryResolver(
          loadSettings: () async => settings,
          ledgerDisk: disk,
          phone: phone,
        );

    // No identity yet: nothing to derive from.
    expect(await resolver(phone: false)(), isNull);

    final LedgerIdentity identity = await LedgerIdentity.loadOrCreate(disk);
    final String expected = await deriveLanDiscoverySecret(identity.selfKey!);
    // Off by default on every platform.
    expect(await resolver(phone: false)(), isNull);
    expect(await resolver(phone: true)(), isNull);

    settings = settings.copyWith(lanDiscovery: true);
    expect(await resolver(phone: false)(), expected);
    expect(await resolver(phone: true)(), expected);

    settings = settings.copyWith(lanDiscovery: false);
    expect(await resolver(phone: false)(), isNull);
  });
}
