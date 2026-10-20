import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';

/// How close a friend is (§8). Private: the other side never learns it.
enum FriendLevel {
  /// "Słaby znajomy": public posts and "Wszyscy znajomi".
  weak,

  /// "Znajomy" (default): also "Znajomi i przyjaciele".
  friend,

  /// "Przyjaciel": also "Tylko przyjaciele".
  close,
}

/// Who may read a post. Everything but [public] is encrypted with a key of
/// that audience, held only by friends of a high enough level.
enum Audience {
  public,

  /// "Wszyscy znajomi".
  all,

  /// "Znajomi i przyjaciele".
  mid,

  /// "Tylko przyjaciele".
  close,
}

Map<Audience, String> get kAudienceLabels => <Audience, String>{
  Audience.public: t('Publiczny'),
  Audience.all: t('Wszyscy znajomi'),
  Audience.mid: t('Znajomi i przyjaciele'),
  Audience.close: t('Tylko przyjaciele'),
};

Map<FriendLevel, String> get kFriendLevelLabels => <FriendLevel, String>{
  FriendLevel.weak: t('Słaby znajomy'),
  FriendLevel.friend: t('Znajomy'),
  FriendLevel.close: t('Przyjaciel'),
};

/// Encrypted audiences a friend of [level] may read.
Set<Audience> audiencesFor(FriendLevel level) => switch (level) {
  FriendLevel.weak => <Audience>{Audience.all},
  FriendLevel.friend => <Audience>{Audience.all, Audience.mid},
  FriendLevel.close => <Audience>{Audience.all, Audience.mid, Audience.close},
};

Audience? audienceByName(Object? name) {
  for (final Audience a in Audience.values) {
    if (a.name == name) {
      return a;
    }
  }
  return null;
}

FriendLevel? friendLevelByName(Object? name) {
  for (final FriendLevel l in FriendLevel.values) {
    if (l.name == name) {
      return l;
    }
  }
  return null;
}

@immutable
final class AudienceKey {
  const AudienceKey({
    required this.id,
    required this.audience,
    required this.key,
    required this.created,
  });

  final String id;
  final Audience audience;
  final Uint8List key;
  final int created;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'aud': audience.name,
    'key': b64(key),
    'at': created,
  };

  static AudienceKey? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Audience? audience = audienceByName(json['aud']);
    final Uint8List? key = unb64(json['key'], length: 32);
    final Object? at = json['at'];
    if (id is! String ||
        !isHex(id, 32) ||
        audience == null ||
        audience == Audience.public ||
        key == null ||
        at is! int) {
      return null;
    }
    return AudienceKey(id: id, audience: audience, key: key, created: at);
  }
}

/// This account's audience keys (every generation, newest last, so old
/// posts stay readable) and the keys friends gave us.
final class AudienceKeyring {
  final Map<Audience, List<AudienceKey>> _own = <Audience, List<AudienceKey>>{};
  final Map<String, Map<String, AudienceKey>> _received =
      <String, Map<String, AudienceKey>>{};

  /// Keys kept per friend account (old generations included).
  static const int maxKeysPerAccount = 200;

  AudienceKey _newKey(Audience audience, int now) => AudienceKey(
    id: randomId(),
    audience: audience,
    key: randomBytes(32),
    created: now,
  );

  /// Creates missing keys; true if anything changed.
  bool ensureOwn(int now) {
    bool changed = false;
    for (final Audience a in Audience.values) {
      if (a == Audience.public) {
        continue;
      }
      final List<AudienceKey> list = _own[a] ??= <AudienceKey>[];
      if (list.isEmpty) {
        list.add(_newKey(a, now));
        changed = true;
      }
    }
    return changed;
  }

  AudienceKey current(Audience audience) {
    final List<AudienceKey>? list = _own[audience];
    if (list == null || list.isEmpty) {
      throw StateError('Brak klucza dla $audience.');
    }
    return list.last;
  }

  /// New generation for [audience]: those who lost access keep only the
  /// old keys, so they cannot read anything written from now on.
  void rotate(Audience audience, int now) {
    (_own[audience] ??= <AudienceKey>[]).add(_newKey(audience, now));
  }

  /// Every generation of the audiences a friend of [level] may read.
  List<AudienceKey> entitled(FriendLevel level) => <AudienceKey>[
    for (final Audience a in audiencesFor(level)) ...?_own[a],
  ];

  /// Stores keys [account] sent us; returns how many were new.
  int acceptFrom(String account, Object? items) {
    if (items is! List) {
      return 0;
    }
    final Map<String, AudienceKey> known = _received[account] ??=
        <String, AudienceKey>{};
    int added = 0;
    for (final Object? item in items.take(maxKeysPerAccount)) {
      final AudienceKey? key = AudienceKey.fromJson(item);
      if (key != null && !known.containsKey(key.id)) {
        if (known.length >= maxKeysPerAccount) {
          break;
        }
        known[key.id] = key;
        added++;
      }
    }
    return added;
  }

  /// Takes the own keys another device of this account made (§6, several
  /// devices): every device can then read and write for the same
  /// audiences. Returns how many were new.
  int mergeOwn(Object? items) {
    if (items is! List) {
      return 0;
    }
    final Set<String> known = <String>{
      for (final List<AudienceKey> list in _own.values)
        for (final AudienceKey k in list) k.id,
    };
    int added = 0;
    for (final Object? item in items.take(maxKeysPerAccount * 4)) {
      final AudienceKey? k = AudienceKey.fromJson(item);
      if (k == null || k.audience == Audience.public || !known.add(k.id)) {
        continue;
      }
      (_own[k.audience] ??= <AudienceKey>[]).add(k);
      added++;
    }
    if (added > 0) {
      for (final List<AudienceKey> list in _own.values) {
        list.sort((AudienceKey a, AudienceKey b) => a.created - b.created);
      }
    }
    return added;
  }

  /// Key [id] of [account] (own keys when [account] is [self]).
  AudienceKey? find(String account, String id, {required String self}) {
    if (account == self) {
      for (final List<AudienceKey> list in _own.values) {
        for (final AudienceKey k in list) {
          if (k.id == id) {
            return k;
          }
        }
      }
      return null;
    }
    return _received[account]?[id];
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'own': <Map<String, dynamic>>[
      for (final List<AudienceKey> list in _own.values)
        for (final AudienceKey k in list) k.toJson(),
    ],
    'received': <String, dynamic>{
      for (final MapEntry<String, Map<String, AudienceKey>> e
          in _received.entries)
        e.key: <Map<String, dynamic>>[
          for (final AudienceKey k in e.value.values) k.toJson(),
        ],
    },
  };

  void restore(Object? json) {
    if (json is! Map) {
      return;
    }
    final Object? own = json['own'];
    if (own is List) {
      for (final Object? item in own) {
        final AudienceKey? k = AudienceKey.fromJson(item);
        if (k != null) {
          (_own[k.audience] ??= <AudienceKey>[]).add(k);
        }
      }
      for (final List<AudienceKey> list in _own.values) {
        list.sort((AudienceKey a, AudienceKey b) => a.created - b.created);
      }
    }
    final Object? received = json['received'];
    if (received is Map) {
      received.forEach((Object? account, Object? items) {
        if (account is String) {
          acceptFrom(account, items);
        }
      });
    }
  }
}

final Chacha20 _aead = Chacha20.poly1305Aead();

/// Encrypts [plain] (a JSON body) for [key]'s audience. [account] is bound
/// in, so a sealed body cannot be passed off as another account's.
Future<Map<String, dynamic>> sealBody(
  Map<String, dynamic> plain,
  AudienceKey key, {
  required String account,
}) async {
  final Uint8List nonce = randomBytes(12);
  final SecretBox box = await _aead.encrypt(
    utf8.encode(jsonEncode(plain)),
    secretKey: SecretKey(key.key),
    nonce: nonce,
    aad: utf8.encode('$account|${key.id}'),
  );
  return <String, dynamic>{
    'aud': key.audience.name,
    'kid': key.id,
    'n': b64(nonce),
    'c': b64(<int>[...box.cipherText, ...box.mac.bytes]),
  };
}

/// True for a body written by [sealBody].
bool isSealed(Map<String, dynamic> body) =>
    body['c'] is String && body['kid'] is String;

/// Decrypts a sealed [body] of [account], or `null` without the key.
Future<Map<String, dynamic>?> openBody(
  Map<String, dynamic> body,
  AudienceKeyring keyring, {
  required String account,
  required String self,
}) async {
  final Object? kid = body['kid'];
  final Uint8List? nonce = unb64(body['n'], length: 12);
  final Uint8List? sealed = unb64(body['c']);
  if (kid is! String || nonce == null || sealed == null || sealed.length < 16) {
    return null;
  }
  final AudienceKey? key = keyring.find(account, kid, self: self);
  if (key == null) {
    return null;
  }
  try {
    final List<int> plain = await _aead.decrypt(
      SecretBox(
        sealed.sublist(0, sealed.length - 16),
        nonce: nonce,
        mac: Mac(sealed.sublist(sealed.length - 16)),
      ),
      secretKey: SecretKey(key.key),
      aad: utf8.encode('$account|$kid'),
    );
    final Object? json = jsonDecode(utf8.decode(plain));
    return json is Map<String, dynamic> ? json : null;
  } on Object {
    return null;
  }
}

/// `kid` of bodies sealed for this account's own devices only.
const String kSelfKeyId = 'self';

/// Encrypts [plain] with [selfKey] (see `LedgerIdentity.selfKey`): only
/// the account's own devices can read it; friends keep the ciphertext as a
/// backup.
Future<Map<String, dynamic>> sealForSelf(
  Map<String, dynamic> plain,
  Uint8List selfKey, {
  required String account,
}) async {
  final Uint8List nonce = randomBytes(12);
  final SecretBox box = await _aead.encrypt(
    utf8.encode(jsonEncode(plain)),
    secretKey: SecretKey(selfKey),
    nonce: nonce,
    aad: utf8.encode('$account|$kSelfKeyId'),
  );
  return <String, dynamic>{
    'kid': kSelfKeyId,
    'n': b64(nonce),
    'c': b64(<int>[...box.cipherText, ...box.mac.bytes]),
  };
}

Future<Map<String, dynamic>?> openForSelf(
  Map<String, dynamic> body,
  Uint8List selfKey, {
  required String account,
}) async {
  final Uint8List? nonce = unb64(body['n'], length: 12);
  final Uint8List? sealed = unb64(body['c']);
  if (body['kid'] != kSelfKeyId ||
      nonce == null ||
      sealed == null ||
      sealed.length < 16) {
    return null;
  }
  try {
    final List<int> plain = await _aead.decrypt(
      SecretBox(
        sealed.sublist(0, sealed.length - 16),
        nonce: nonce,
        mac: Mac(sealed.sublist(sealed.length - 16)),
      ),
      secretKey: SecretKey(selfKey),
      aad: utf8.encode('$account|$kSelfKeyId'),
    );
    final Object? json = jsonDecode(utf8.decode(plain));
    return json is Map<String, dynamic> ? json : null;
  } on Object {
    return null;
  }
}
