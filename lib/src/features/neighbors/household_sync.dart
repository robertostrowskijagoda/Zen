import 'dart:async';

import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';

/// Keys of the household copy kept whole between the account's devices:
/// the signed profile and which phone runs the household (a mix of two
/// devices' halves would be neither).
const Set<String> kHouseholdWholeKeys = <String>{'p', 'run', 'view'};

/// The account's household between its devices ([AccountStateSync]): the
/// device that runs it (the door) gives its state, the others keep the
/// newest copy to take it over ("Przenieś mieszkanie na to urządzenie"),
/// and a device that ran it steps down once another one took it over
/// ([NeighborsService.takeAccountCopy]).
final class HouseholdSyncDomain implements AccountSyncDomain {
  HouseholdSyncDomain(this.id, this.neighbors) {
    neighbors.addListener(_poke);
  }

  @override
  final String id;
  final NeighborsService neighbors;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  void _poke() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  @override
  Set<String> get wholeKeys => kHouseholdWholeKeys;

  @override
  Future<Map<String, Object?>?> read() async => neighbors.accountCopy();

  @override
  Future<void> write(Map<String, Object?> state) =>
      neighbors.takeAccountCopy(state);

  @override
  Stream<void> get changes => _changes.stream;

  Future<void> close() async {
    neighbors.removeListener(_poke);
    await _changes.close();
  }
}
