import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// One account on this device: the default account, or an additional one
/// known by its ID.
///
/// Everything of an additional account is found from its ID and the
/// device's salt ([ZenAccountScope.derive]), never from a list: its
/// folder's name and the secret that names its entries in the system's
/// secret store are keyed hashes of the ID. Without the ID nothing on the
/// device says which folder is whose, or that an account exists at all.
@immutable
final class ZenAccountScope {
  const ZenAccountScope._(this.id, this.folder, this.secret);

  /// The account the app opens at start.
  static const ZenAccountScope defaultAccount = ZenAccountScope._(
    null,
    null,
    null,
  );

  /// The additional account with [id] (normalized) on the device with
  /// [deviceSalt]: its folder is 32 hex digits of
  /// HMAC-SHA256(salt, "zen.account.folder.v1|" + id), its secret
  /// HMAC-SHA256(salt, "zen.account.secrets.v1|" + id).
  static ZenAccountScope derive(String id, Uint8List deviceSalt) {
    List<int> mac(String label) => crypto.Hmac(
      crypto.sha256,
      deviceSalt,
    ).convert(utf8.encode('$label|$id')).bytes;
    final String folder = mac(
      'zen.account.folder.v1',
    ).map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
    return ZenAccountScope._(
      id,
      folder.substring(0, 32),
      Uint8List.fromList(mac('zen.account.secrets.v1')),
    );
  }

  /// The normalized ID; `null` for the default account.
  final String? id;

  /// The folder name inside [ZenInstance.accountsFolder]; `null` for the
  /// default account (its data is the instance's own folder).
  final String? folder;

  /// Names its entries in the system's secret store; `null` for the
  /// default account (plain names).
  final Uint8List? secret;

  bool get isDefault => id == null;

  @override
  bool operator ==(Object other) =>
      other is ZenAccountScope && other.id == id && other.folder == folder;

  @override
  int get hashCode => Object.hash(id, folder);
}

/// The account open in this isolate.
abstract final class ZenAccounts {
  static ZenAccountScope _current = ZenAccountScope.defaultAccount;

  static ZenAccountScope get current => _current;

  /// Opens [scope] for this isolate: the data folder
  /// ([ZenInstance.supportDirectory]) and the secret store's entries
  /// ([SecureStorageCredentialsStore]) are that account's from now on.
  /// Only the app's isolate switches; the Android background service
  /// always serves the default account.
  static void activate(ZenAccountScope scope) {
    _current = scope;
    ZenInstance.useAccountFolder(scope.folder);
    SecureStorageCredentialsStore.activeNamespace = scope.secret;
  }
}

/// The account this app session is for (fixed for the life of the
/// providers: another account is opened with fresh ones).
final Provider<ZenAccountScope> zenAccountProvider = Provider<ZenAccountScope>(
  (Ref ref) => ZenAccounts.current,
);
