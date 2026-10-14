import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
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
/// colluding helpers could guess the password offline. Older pieces keep
/// the cost written in them and still open.
const PasswordCost kRecoveryPasswordCost = PasswordCost(
  memoryKiB: 65536,
  iterations: 2,
);

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
      'Hasło konta musi mieć co najmniej $kMinAccountPasswordLength znaków.',
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
      'Do odzyskiwania potrzeba co najmniej $kEmergencyThreshold osób '
      'w kręgu.',
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

/// Groups halves of the same set (same encrypted copy of the seed), so a
/// stranger's fake half cannot spoil a recovery: each group is tried alone.
Map<String, List<Map<String, dynamic>>> _bySet(
  List<Map<String, dynamic>> halves,
) {
  final Map<String, List<Map<String, dynamic>>> groups =
      <String, List<Map<String, dynamic>>>{};
  for (final Map<String, dynamic> h in halves) {
    (groups[jsonEncode(h['box'])] ??= <Map<String, dynamic>>[]).add(h);
  }
  return groups;
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

/// The seed from the `normal` halves of at least two pieces of the same set
/// and the password; `null` if nothing fits or the password is wrong.
Future<Uint8List?> recoverWithPassword(
  List<Map<String, dynamic>> normals,
  String password,
) async {
  for (final List<Map<String, dynamic>> group in _bySet(normals).values) {
    if (group.length < kNormalThreshold) {
      continue;
    }
    final Uint8List? salt = unb64(group.first['salt'], length: 16);
    final PasswordCost? cost = PasswordCost.fromJson(group.first['cost']);
    if (salt == null || cost == null) {
      continue;
    }
    final Uint8List passwordKey = await derivePasswordKey(
      password,
      salt,
      cost: cost,
    );
    for (final List<Map<String, dynamic>> pair in _subsets(
      group,
      kNormalThreshold,
    )) {
      final List<Uint8List> shares = <Uint8List>[
        for (final Map<String, dynamic> n in pair) ?unb64(n['share']),
      ];
      try {
        final Uint8List? seed = await _open(
          _mix(passwordKey, shamirCombine(shares)),
          group.first['box'],
        );
        if (seed != null) {
          return seed;
        }
      } on Object {
        continue; // a malformed or fake share
      }
    }
  }
  return null;
}

/// The seed from at least four `emergency` halves of one set, or `null`.
Future<Uint8List?> recoverWithoutPassword(
  List<Map<String, dynamic>> emergencies,
) async {
  for (final List<Map<String, dynamic>> group in _bySet(emergencies).values) {
    for (final List<Map<String, dynamic>> four in _subsets(
      group,
      kEmergencyThreshold,
    )) {
      final List<Uint8List> shares = <Uint8List>[
        for (final Map<String, dynamic> e in four) ?unb64(e['share']),
      ];
      try {
        final Uint8List? seed = await _open(
          shamirCombine(shares),
          group.first['box'],
        );
        if (seed != null) {
          return seed;
        }
      } on Object {
        continue; // a malformed or fake share
      }
    }
  }
  return null;
}
