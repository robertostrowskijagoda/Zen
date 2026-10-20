import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/shamir.dart';

/// Account password and recovery through the circle (§6.1, §6.3).
///
/// The account key (its 32-byte seed) can be got back in two ways:
///
/// * **normal**: 2 people from the circle + the account password, released
///   by them 24 h after they agree to help (the old devices get an alarm
///   and can stop it);
/// * **emergency** (password forgotten): 4 people from the circle, 7 days.
///
/// Each person holds one [RecoveryPiece]: a share of each of two random
/// secrets plus the two encrypted copies of the seed. One piece alone
/// reveals nothing; the delays are kept by the helpers' apps.
///
/// Known limits (by design, documented):
///
/// * The delays and the alarm on the old devices are kept by honest apps
///   only. Helpers who modify their app can hand their halves over at once.
/// * Two helpers who collude hold the whole circle secret of the normal
///   half; what is left between them and the account is the account
///   password, which they can then guess offline at their own pace. Every
///   guess costs one Argon2id run ([kRecoveryPasswordCost], heavier than
///   the device's own); a long passphrase is what really protects it.
/// * Four colluding helpers recover the account without any password (the
///   emergency half), which is the point of that path.
const int kNormalThreshold = 2;
const int kEmergencyThreshold = 4;
const Duration kNormalDelay = Duration(hours: 24);
const Duration kEmergencyDelay = Duration(days: 7);

/// Argon2id cost of the account password. Defaults follow OWASP
/// (19 MiB, 2 passes); tests pass lighter ones.
@immutable
final class PasswordCost {
  const PasswordCost({
    this.memoryKiB = 19456,
    this.iterations = 2,
    this.parallelism = 1,
  });

  final int memoryKiB;
  final int iterations;
  final int parallelism;

  @override
  bool operator ==(Object other) =>
      other is PasswordCost &&
      other.memoryKiB == memoryKiB &&
      other.iterations == iterations &&
      other.parallelism == parallelism;

  @override
  int get hashCode => Object.hash(memoryKiB, iterations, parallelism);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'm': memoryKiB,
    't': iterations,
    'p': parallelism,
  };

  static PasswordCost? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? m = json['m'];
    final Object? t = json['t'];
    final Object? p = json['p'];
    if (m is! int || t is! int || p is! int) {
      return null;
    }
    // Refuse absurd costs (a hostile piece could try to freeze the app).
    if (m < 8 || m > 262144 || t < 1 || t > 10 || p < 1 || p > 8) {
      return null;
    }
    return PasswordCost(memoryKiB: m, iterations: t, parallelism: p);
  }
}

/// Argon2id cost of the password half of new recovery pieces (64 MiB,
/// 2 passes, ~3.4× the default): those pieces leave the device, so two
/// colluding helpers could guess the password offline.
const PasswordCost kRecoveryPasswordCost = PasswordCost(
  memoryKiB: 65536,
  iterations: 2,
);

/// The only Argon2 cost a received `normal` half may ask for: the one
/// pieces are written with. A half asking for anything else is refused, so
/// nobody can make a recovering device run a heavy Argon2 for nothing.
const List<PasswordCost> kAcceptedRecoveryCosts = <PasswordCost>[
  kRecoveryPasswordCost,
];

/// Minimum length of the account password.
const int kMinAccountPasswordLength = 8;

/// 32-byte key from [password] (Argon2id, off the UI thread). Tiny costs
/// (tests) run in place.
Future<Uint8List> derivePasswordKey(
  String password,
  Uint8List salt, {
  PasswordCost cost = const PasswordCost(),
}) {
  Future<Uint8List> derive() async {
    final Argon2id kdf = Argon2id(
      parallelism: cost.parallelism,
      memory: cost.memoryKiB,
      iterations: cost.iterations,
      hashLength: 32,
    );
    final SecretKey key = await kdf.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  return cost.memoryKiB <= 1024 ? derive() : Isolate.run(derive);
}

final Chacha20 _aead = Chacha20.poly1305Aead();

Future<Map<String, dynamic>> _seal(Uint8List key, Uint8List plain) async {
  final Uint8List nonce = randomBytes(12);
  final SecretBox box = await _aead.encrypt(
    plain,
    secretKey: SecretKey(key),
    nonce: nonce,
  );
  return <String, dynamic>{
    'n': b64(nonce),
    'c': b64(<int>[...box.cipherText, ...box.mac.bytes]),
  };
}

Future<Uint8List?> _open(Uint8List key, Object? sealed) async {
  if (sealed is! Map) {
    return null;
  }
  final Uint8List? nonce = unb64(sealed['n'], length: 12);
  final Uint8List? data = unb64(sealed['c']);
  if (nonce == null || data == null || data.length < 16) {
    return null;
  }
  try {
    return Uint8List.fromList(
      await _aead.decrypt(
        SecretBox(
          data.sublist(0, data.length - 16),
          nonce: nonce,
          mac: Mac(data.sublist(data.length - 16)),
        ),
        secretKey: SecretKey(key),
      ),
    );
  } on SecretBoxAuthenticationError {
    return null;
  }
}

Uint8List _mix(Uint8List a, Uint8List b) => Uint8List.fromList(
  // Both are needed: the password key and the circle secret.
  crypto.sha256.convert(<int>[
    ...utf8.encode('zen.recovery.normal'),
    ...a,
    ...b,
  ]).bytes,
);

/// The account seed wrapped by the account password, kept on the device.
@immutable
final class PasswordWrappedSeed {
  const PasswordWrappedSeed({
    required this.salt,
    required this.cost,
    required this.sealed,
  });

  final Uint8List salt;
  final PasswordCost cost;
  final Map<String, dynamic> sealed;

  static Future<PasswordWrappedSeed> wrap(
    Uint8List seed,
    String password, {
    PasswordCost cost = const PasswordCost(),
  }) async {
    checkAccountPassword(password);
    final Uint8List salt = randomBytes(16);
    final Uint8List key = await derivePasswordKey(password, salt, cost: cost);
    return PasswordWrappedSeed(
      salt: salt,
      cost: cost,
      sealed: await _seal(key, seed),
    );
  }

  /// The seed, or `null` for a wrong password.
  Future<Uint8List?> unwrap(String password) async =>
      _open(await derivePasswordKey(password, salt, cost: cost), sealed);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'salt': b64(salt),
    'cost': cost.toJson(),
    'sealed': sealed,
  };

  static PasswordWrappedSeed? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Uint8List? salt = unb64(json['salt'], length: 16);
    final PasswordCost? cost = PasswordCost.fromJson(json['cost']);
    final Object? sealed = json['sealed'];
    if (salt == null || cost == null || sealed is! Map<String, dynamic>) {
      return null;
    }
    return PasswordWrappedSeed(salt: salt, cost: cost, sealed: sealed);
  }
}

/// Throws [ArgumentError] (with a Polish message) for a weak password.
void checkAccountPassword(String password) {
  if (password.length < kMinAccountPasswordLength) {
    throw ArgumentError(
      tn(
        kMinAccountPasswordLength,
        one: 'Hasło konta musi mieć co najmniej {n} znak.',
        few: 'Hasło konta musi mieć co najmniej {n} znaki.',
        many: 'Hasło konta musi mieć co najmniej {n} znaków.',
      ),
    );
  }
}

/// What one helper keeps for one account. [normal] and [emergency] are the
/// two halves released separately (after [kNormalDelay] and
/// [kEmergencyDelay]).
@immutable
final class RecoveryPiece {
  const RecoveryPiece({
    required this.account,
    required this.created,
    required this.normal,
    required this.emergency,
  });

  final String account;
  final int created;

  /// `{salt, cost, box, share}`: needs the password and one more piece.
  final Map<String, dynamic> normal;

  /// `{box, share}`: needs three more pieces, no password.
  final Map<String, dynamic> emergency;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'account': account,
    'created': created,
    'normal': normal,
    'emergency': emergency,
  };

  static RecoveryPiece? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? account = json['account'];
    final Object? created = json['created'];
    final Object? normal = json['normal'];
    final Object? emergency = json['emergency'];
    if (account is! String ||
        account.isEmpty ||
        account.length > 100 ||
        created is! int ||
        normal is! Map<String, dynamic> ||
        emergency is! Map<String, dynamic> ||
        unb64(normal['share']) == null ||
        unb64(emergency['share']) == null) {
      return null;
    }
    return RecoveryPiece(
      account: account,
      created: created,
      normal: normal,
      emergency: emergency,
    );
  }
}

/// Splits the account [seed] into one piece per helper (the circle).
Future<List<RecoveryPiece>> createRecoveryPieces({
  required String account,
  required Uint8List seed,
  required String password,
  required int helpers,
  required int now,
  PasswordCost cost = kRecoveryPasswordCost,
}) async {
  checkAccountPassword(password);
  if (helpers < kEmergencyThreshold) {
    throw ArgumentError(
      tn(
        kEmergencyThreshold,
        one: 'Do odzyskiwania potrzeba co najmniej {n} osoby w kręgu.',
        few: 'Do odzyskiwania potrzeba co najmniej {n} osób w kręgu.',
        many: 'Do odzyskiwania potrzeba co najmniej {n} osób w kręgu.',
      ),
    );
  }
  final Uint8List salt = randomBytes(16);
  final Uint8List passwordKey = await derivePasswordKey(
    password,
    salt,
    cost: cost,
  );
  final Uint8List circleSecret = randomBytes(32);
  final Uint8List emergencyKey = randomBytes(32);
  final Map<String, dynamic> normalBox = await _seal(
    _mix(passwordKey, circleSecret),
    seed,
  );
  final Map<String, dynamic> emergencyBox = await _seal(emergencyKey, seed);
  final List<Uint8List> normalShares = shamirSplit(
    circleSecret,
    kNormalThreshold,
    helpers,
  );
  final List<Uint8List> emergencyShares = shamirSplit(
    emergencyKey,
    kEmergencyThreshold,
    helpers,
  );
  return <RecoveryPiece>[
    for (int i = 0; i < helpers; i++)
      RecoveryPiece(
        account: account,
        created: now,
        normal: <String, dynamic>{
          'salt': b64(salt),
          'cost': cost.toJson(),
          'box': normalBox,
          'share': b64(normalShares[i]),
        },
        emergency: <String, dynamic>{
          'box': emergencyBox,
          'share': b64(emergencyShares[i]),
        },
      ),
  ];
}

/// Whether [value] looks like an account id (an Ed25519 public key).
bool isRecoveryAccountId(Object? value) => unb64(value, length: 32) != null;

/// A short fingerprint of [account] to compare by voice: 16 digits in
/// groups of four. A helper sees it next to the piece they keep, the new
/// device next to the account the received pieces open.
String accountFingerprint(String account) {
  final List<int> h = crypto.sha256
      .convert(utf8.encode('zen.account.fingerprint:$account'))
      .bytes;
  return <String>[
    for (int g = 0; g < 16; g += 4)
      (((h[g] << 24) | (h[g + 1] << 16) | (h[g + 2] << 8) | h[g + 3]) % 10000)
          .toString()
          .padLeft(4, '0'),
  ].join(' ');
}

/// The fields of a received half that recovery uses, or `null` when [half]
/// is malformed or (a `normal` half) asks for an Argon2 cost outside
/// [acceptedCosts]. Anything else in it is dropped.
Map<String, dynamic>? recoveryHalfFields(
  Object? half, {
  required bool normal,
  List<PasswordCost> acceptedCosts = kAcceptedRecoveryCosts,
}) {
  if (half is! Map) {
    return null;
  }
  final Object? box = half['box'];
  final Object? share = half['share'];
  // A sealed 32-byte seed (+16 bytes of tag); a share of a 32-byte secret.
  if (box is! Map ||
      unb64(box['n'], length: 12) == null ||
      unb64(box['c'], length: 48) == null ||
      unb64(share, length: 33) == null) {
    return null;
  }
  final Map<String, dynamic> fields = <String, dynamic>{
    'box': <String, dynamic>{'n': box['n'], 'c': box['c']},
    'share': share,
  };
  if (!normal) {
    return fields;
  }
  final PasswordCost? cost = PasswordCost.fromJson(half['cost']);
  if (unb64(half['salt'], length: 16) == null ||
      cost == null ||
      !acceptedCosts.contains(cost)) {
    return null;
  }
  return fields
    ..['salt'] = half['salt']
    ..['cost'] = cost.toJson();
}

/// The account a received half names (`account`), or `null` when it names
/// none.
String? claimedRecoveryAccount(Map<String, dynamic> half) {
  final Object? account = half['account'];
  return account is String && account.isNotEmpty ? account : null;
}

/// The distinct accounts [halves] name.
Set<String> claimedRecoveryAccounts(Iterable<Map<String, dynamic>> halves) =>
    <String>{
      for (final Map<String, dynamic> h in halves) ?claimedRecoveryAccount(h),
    };

/// An account the received halves open.
@immutable
final class RecoveredAccount {
  const RecoveredAccount({
    required this.seed,
    required this.account,
    required this.helpers,
  });

  /// The account key's seed.
  final Uint8List seed;

  /// The account [seed] is the key of (computed from it, never taken from
  /// a half).
  final String account;

  /// Distinct senders whose halves really belong to this account.
  final Set<String> helpers;

  String get fingerprint => accountFingerprint(account);
}

/// Opens one sealed seed with the secret its shares give back.
typedef _Opener = Future<Uint8List?> Function(Uint8List secret, Object? box);

/// Candidate sets: halves of the same encrypted copy of the seed ([setKey])
/// that name the same account, so a stranger's fake half cannot spoil a
/// recovery and halves for different accounts never mix. Halves that name
/// no account are not used.
List<List<Map<String, dynamic>>> _candidateSets(
  List<Map<String, dynamic>> halves,
  String Function(Map<String, dynamic> half) setKey,
) {
  final Map<String, List<Map<String, dynamic>>> byCopy =
      <String, List<Map<String, dynamic>>>{};
  for (final Map<String, dynamic> h in halves) {
    (byCopy[setKey(h)] ??= <Map<String, dynamic>>[]).add(h);
  }
  final List<List<Map<String, dynamic>>> sets = <List<Map<String, dynamic>>>[];
  for (final List<Map<String, dynamic>> copy in byCopy.values) {
    for (final String account in claimedRecoveryAccounts(copy)) {
      sets.add(<Map<String, dynamic>>[
        for (final Map<String, dynamic> h in copy)
          if (claimedRecoveryAccount(h) == account) h,
      ]);
    }
  }
  return sets;
}

/// The seed [halves] open together, or `null`.
Future<Uint8List?> _openHalves(
  List<Map<String, dynamic>> halves,
  _Opener open,
) async {
  final List<Uint8List> shares = <Uint8List>[
    for (final Map<String, dynamic> h in halves) ?unb64(h['share']),
  ];
  if (shares.length != halves.length) {
    return null;
  }
  try {
    return await open(shamirCombine(shares), halves.first['box']);
  } on Object {
    return null; // a malformed or fake share
  }
}

/// Every account [halves] open: each candidate set is tried alone, the seed
/// is checked against the account its halves name, and halves for the same
/// account (several copies) are merged.
Future<List<RecoveredAccount>> _recoverAccounts(
  List<Map<String, dynamic>> halves, {
  required int threshold,
  required String Function(Map<String, dynamic> half) setKey,
  required Future<_Opener?> Function(List<Map<String, dynamic>> set) opener,
  int limit = 600,
}) async {
  final Map<String, RecoveredAccount> found = <String, RecoveredAccount>{};
  for (final List<Map<String, dynamic>> set in _candidateSets(halves, setKey)) {
    if (set.length < threshold) {
      continue;
    }
    final _Opener? open = await opener(set);
    if (open == null) {
      continue;
    }
    for (final List<Map<String, dynamic>> subset in _subsets(
      set,
      threshold,
      limit: limit,
    )) {
      final Uint8List? seed = await _openHalves(subset, open);
      if (seed == null) {
        continue;
      }
      final String account = (await LedgerKeyPair.fromSeed(seed)).id;
      bool names(Map<String, dynamic> h) =>
          claimedRecoveryAccount(h) == account;

      if (!subset.every(names)) {
        // The halves say they are another account's key: not taken.
        continue;
      }
      // The other halves of the set that open the same seed with the rest
      // of this subset: those helpers really hold this account's pieces.
      final List<Map<String, dynamic>> rest = subset.sublist(1);
      final List<Map<String, dynamic>> belonging = <Map<String, dynamic>>[
        for (final Map<String, dynamic> h in set)
          if (subset.contains(h) ||
              (names(h) &&
                  _sameBytes(
                    await _openHalves(<Map<String, dynamic>>[h, ...rest], open),
                    seed,
                  )))
            h,
      ];
      final RecoveredAccount? had = found[account];
      found[account] = RecoveredAccount(
        seed: seed,
        account: account,
        helpers: <String>{
          ...?had?.helpers,
          for (final Map<String, dynamic> h in belonging)
            if (h['from'] is String) h['from'] as String,
        },
      );
      break; // one copy opens to one seed
    }
  }
  return found.values.toList();
}

bool _sameBytes(List<int>? a, List<int> b) {
  if (a == null || a.length != b.length) {
    return false;
  }
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// All [k]-element subsets of [items] (at most [limit] of them).
Iterable<List<T>> _subsets<T>(List<T> items, int k, {int limit = 600}) sync* {
  int produced = 0;
  final List<int> idx = List<int>.generate(k, (int i) => i);
  if (k > items.length) {
    return;
  }
  while (produced < limit) {
    yield <T>[for (final int i in idx) items[i]];
    produced++;
    int i = k - 1;
    while (i >= 0 && idx[i] == items.length - k + i) {
      i--;
    }
    if (i < 0) {
      return;
    }
    idx[i]++;
    for (int j = i + 1; j < k; j++) {
      idx[j] = idx[j - 1] + 1;
    }
  }
}

/// The accounts that the `normal` halves of at least two pieces of the same
/// set open with [password]; empty if nothing fits or the password is
/// wrong. Each seed is checked against the account its halves name (see
/// [RecoveredAccount]); the person still confirms the account before
/// taking it. Halves asking for a cost outside [acceptedCosts] are skipped.
Future<List<RecoveredAccount>> recoverWithPassword(
  List<Map<String, dynamic>> normals,
  String password, {
  List<PasswordCost> acceptedCosts = kAcceptedRecoveryCosts,
}) {
  // One Argon2 run per salt and cost, however many sets share them.
  final Map<String, Uint8List> keys = <String, Uint8List>{};
  return _recoverAccounts(
    normals,
    threshold: kNormalThreshold,
    // Halves of one copy share the salt and the cost too; a half that only
    // copies the box cannot spoil the others' Argon2 run.
    setKey: (Map<String, dynamic> h) =>
        jsonEncode(<Object?>[h['box'], h['salt'], h['cost']]),
    opener: (List<Map<String, dynamic>> set) async {
      final Object? rawSalt = set.first['salt'];
      final Uint8List? salt = unb64(rawSalt, length: 16);
      final PasswordCost? cost = PasswordCost.fromJson(set.first['cost']);
      if (salt == null || cost == null || !acceptedCosts.contains(cost)) {
        return null;
      }
      final Uint8List passwordKey =
          keys[jsonEncode(<Object?>[rawSalt, cost.toJson()])] ??=
              await derivePasswordKey(password, salt, cost: cost);
      return (Uint8List secret, Object? box) =>
          _open(_mix(passwordKey, secret), box);
    },
  );
}

/// The accounts that at least four `emergency` halves of one set open;
/// empty if none. As with [recoverWithPassword], the person confirms the
/// account before taking it.
Future<List<RecoveredAccount>> recoverWithoutPassword(
  List<Map<String, dynamic>> emergencies,
) => _recoverAccounts(
  emergencies,
  threshold: kEmergencyThreshold,
  setKey: (Map<String, dynamic> h) => jsonEncode(h['box']),
  opener: (_) async => _open,
  // Trying a set is cheap: every 4 of 24 halves (one per sender) fit.
  limit: 12000,
);
