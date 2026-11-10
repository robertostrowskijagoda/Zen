import 'dart:async';

import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';

/// The passwords between the account's devices: the stored vault, cut by
/// the sync into its versions (one unit each, never changed once written),
/// so edits on two devices at once both arrive and a deletion goes
/// everywhere. Read and written through the vault's own queue, never
/// beside it; nothing is read while Zen is locked.
final class PasswordVaultSyncDomain implements AccountSyncDomain {
  PasswordVaultSyncDomain(this.vault) {
    vault.edits.addListener(_poke);
  }

  final PasswordVaultService vault;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  void _poke() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  @override
  String get id => kPasswordVaultKey;

  @override
  Set<String> get wholeKeys => const <String>{};

  @override
  Future<Map<String, Object?>?> read() => vault.syncState();

  @override
  Future<void> write(Map<String, Object?> state) => vault.takeSyncState(state);

  @override
  Stream<void> get changes => _changes.stream;

  Future<void> close() {
    vault.edits.removeListener(_poke);
    return _changes.close();
  }
}
