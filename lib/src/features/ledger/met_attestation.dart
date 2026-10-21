import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';

/// Entry kind of a "met in person" attestation in the attester's
/// `acts/<account>` space: `{a: the other account, d: 'YYYY-MM-DD'}`. The
/// entry is signed by a device the attester's account certified, so it is
/// the account's word; friends keep and follow the attester's `acts`, so it
/// reaches them. Both sides of a meeting sign one each.
const String kMetKind = 'met';

/// Body of an attestation that this account met [account] on the day of
/// [atMillis] (UTC; only the day, not the hour, is said).
Map<String, dynamic> metBody(String account, int atMillis) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(atMillis, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return <String, dynamic>{
    'a': account,
    'd': '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}',
  };
}

/// Accounts the author of [acts] attested as met in person: entries of
/// [kMetKind] in the author's own `acts` space, about a well-formed account
/// key other than the author's.
Set<String> metAccountsIn(Iterable<LogEntry> acts) => <String>{
  for (final LogEntry e in acts)
    if (e.kind == kMetKind &&
        e.space == accountSpace('acts', e.account) &&
        _isAccountKey(e.body['a']) &&
        e.body['a'] != e.account)
      e.body['a'] as String,
};

bool _isAccountKey(Object? key) {
  if (key is! String || key.length != 44) {
    return false;
  }
  final Uint8List? bytes = unb64(key, length: 32);
  return bytes != null && b64(bytes) == key;
}
