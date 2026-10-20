import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';

/// How far a record's own time may be from this phone's clock: ahead of it
/// when the record arrives (anything later waits — a "time bomb" is never
/// kept), behind it when this phone signs or publishes it (§20.5).
const int kPyrMaxSkewMs = 10 * 60 * 1000;

/// The largest record kept (its canonical body): generous, a merge
/// snapshot of a big branch fits.
const int kPyrMaxRecordBytes = 2 * 1024 * 1024;

/// The most signatures (and treasurer signatures) one record may carry.
const int kPyrMaxSigners = 100;

/// Kinds of pyramid records (§20–24). Every change to the pyramid is one
/// signed record; the state is what follows from the records (§20.5).
abstract final class PyrT {
  static const String genesis = 'genesis';
  static const String admit = 'admit';
  static const String swap = 'swap';
  static const String voteRequest = 'vreq';
  static const String vote = 'vote';
  static const String leave = 'leave';
  static const String fill = 'fill';
  static const String absent = 'absent';
  static const String remove = 'remove';
  static const String migrate = 'migrate';
  static const String alive = 'alive';
  static const String address = 'addr';
  static const String delegate = 'deleg';
  static const String revoke = 'revoke';
  static const String ban = 'ban';
  static const String unban = 'unban';
  static const String decision = 'decision';
  static const String post = 'post';
  static const String comment = 'comment';
  static const String natPost = 'natpost';
  static const String natGrant = 'natgrant';
  static const String referendum = 'ref';
  static const String tally = 'tally';
  static const String constitution = 'const';
  static const String emit = 'emit';
  static const String veto = 'veto';
  static const String transfer = 'xfer';
  static const String settle = 'settle';
  static const String alarm = 'alarm';
  static const String merge = 'merge';
  static const String merged = 'merged';
  static const String offer = 'offer';

  /// An exchange rate a member offers for money of another pyramid
  /// (pays out here, takes the money there).
  static const String fxRate = 'fx';

  /// The national section's lead pins (or unpins) a post (§22.2).
  static const String natPin = 'natpin';

  /// A member shows (or hides) their age and gender badge (§20.2a): the
  /// birth year, gender and salt behind their data commitment.
  static const String badge = 'badge';

  /// A member says they met another member in person (§6.2, §20.6), made
  /// from their signed "met in person" attestation in the ledger: votes in
  /// referenda count only from members met by [kPyrMetToVote] others.
  static const String met = 'met';

  /// Kinds signed anonymously with a ring signature (§20.3a).
  static const Set<String> anonymous = <String>{voteRequest, vote};

  /// Kinds most treasurers sign before they count (§23.2, §23.5).
  static const Set<String> treasured = <String>{transfer, settle};
}

/// One signed record. [body] is everything but the signatures; [sigs] maps
/// signer key → Ed25519 signature of the canonical body; [ring] is a ring
/// signature for the anonymous kinds (§20.3a); [tsigs] are treasurers'
/// signatures on a transfer or a settlement (§23.2).
@immutable
final class PyramidRecord {
  const PyramidRecord({
    required this.body,
    this.sigs = const <String, String>{},
    this.ring,
    this.tsigs = const <String, String>{},
  });

  final Map<String, dynamic> body;
  final Map<String, String> sigs;
  final RingSignature? ring;
  final Map<String, String> tsigs;

  /// Canonical bytes and id, worked out once per record (sorting and
  /// folding ask for them again and again).
  static final Expando<Uint8List> _bytes = Expando<Uint8List>(
    'pyramidRecordBytes',
  );
  static final Expando<String> _ids = Expando<String>('pyramidRecordId');
  static final Expando<String> _contents = Expando<String>(
    'pyramidRecordContent',
  );

  String get type => body['t'] as String;
  String get pyramid => body['py'] is String ? body['py'] as String : '';
  int get at => body['at'] as int;

  /// Who may sign (a proposal lists everyone whose signature counts, e.g.
  /// the whole top cell for a "2 of 3" decision).
  List<String> get candidates => body['by'] is List
      ? (body['by'] as List).whereType<String>().toList()
      : const <String>[];

  /// Who did sign (checked on arrival).
  List<String> get signers => sigs.keys.toList()..sort();

  Uint8List get signedBytes => _bytes[this] ??= canonicalJsonBytes(body);

  String get id => _ids[this] ??= sha256Hex(signedBytes);

  /// The content without its time: fresh copies of one proposal (signed
  /// again later, §20.5) share it.
  String get contentKey => _contents[this] ??= sha256Hex(
    canonicalJsonBytes(<String, dynamic>{...body}..remove('at')),
  );

  String str(String k) => body[k] is String ? body[k] as String : '';
  int integer(String k) => body[k] is int ? body[k] as int : 0;

  PyramidRecord withSig(String key, String sig) => PyramidRecord(
    body: body,
    sigs: <String, String>{...sigs, key: sig},
    ring: ring,
    tsigs: tsigs,
  );

  /// Adds [key]'s treasurer signature, unless the record already carries
  /// one of [key]: a signature kept here is never replaced by another one
  /// (a stranger could otherwise swap a valid one for junk).
  PyramidRecord withTreasurerSig(String key, String sig) =>
      tsigs.containsKey(key)
      ? this
      : PyramidRecord(
          body: body,
          sigs: sigs,
          ring: ring,
          tsigs: <String, String>{...tsigs, key: sig},
        );

  Future<PyramidRecord> signedBy(LedgerKeyPair pair) async =>
      withSig(pair.id, b64(await pair.sign(signedBytes)));

  /// Whether [key] is a public key in its one canonical spelling (what
  /// [LedgerKeyPair.id] gives). Another spelling of the same 32 bytes —
  /// no padding, the other alphabet — would be a second identity for
  /// rules that compare keys as text (bans, places), so it is refused.
  static bool isCanonicalKey(Object? key) {
    if (key is! String || key.length != 44) {
      return false;
    }
    final Uint8List? bytes = unb64(key, length: 32);
    return bytes != null && b64(bytes) == key;
  }

  /// The signatures that are valid: canonical keys among the [candidates],
  /// each checked on its own (one bad signature does not throw away the
  /// good ones).
  Future<Map<String, String>> validSigs() async {
    final List<String> allowed = candidates;
    final Map<String, String> ok = <String, String>{};
    for (final MapEntry<String, String> e in sigs.entries) {
      if (allowed.contains(e.key) &&
          isCanonicalKey(e.key) &&
          await verifyLedgerSignature(
            publicKey: e.key,
            message: signedBytes,
            signature: e.value,
          )) {
        ok[e.key] = e.value;
      }
    }
    return ok;
  }

  /// Whether there is at least one signature and every one is valid and by
  /// a listed candidate. How many are needed is the fold's business. An
  /// anonymous record (no signatures) is checked against its ring by the
  /// service, never here.
  Future<bool> verifySigners() async {
    if (sigs.isEmpty) {
      return false;
    }
    return (await validSigs()).length == sigs.length;
  }

  /// Valid treasurer signatures (checked one by one).
  Future<Set<String>> validTreasurerSigs() async =>
      (await validTreasurerSigMap()).keys.toSet();

  /// Valid treasurer signatures with the signatures themselves.
  Future<Map<String, String>> validTreasurerSigMap() async {
    final Map<String, String> ok = <String, String>{};
    for (final MapEntry<String, String> e in tsigs.entries) {
      if (isCanonicalKey(e.key) &&
          await verifyLedgerSignature(
            publicKey: e.key,
            message: treasurerBytes(id),
            signature: e.value,
          )) {
        ok[e.key] = e.value;
      }
    }
    return ok;
  }

  /// What a treasurer signs to approve a transfer or a settlement.
  static Uint8List treasurerBytes(String transferId) =>
      Uint8List.fromList(utf8.encode('zen-treasurer|$transferId'));

  Map<String, dynamic> toJson() => <String, dynamic>{
    'b': body,
    if (sigs.isNotEmpty) 's': sigs,
    if (ring != null) 'r': ring!.toJson(),
    if (tsigs.isNotEmpty) 'ts': tsigs,
  };

  /// Parses a record; null for anything that could not be signed the same
  /// way on every phone: fractions, lone UTF-16 surrogates (two different
  /// texts with one hash), keys that are not text, too deep or too big, a
  /// ring signature that does not parse, too many signatures.
  static PyramidRecord? fromJson(Object? json) {
    if (json is! Map || json['b'] is! Map) {
      return null;
    }
    final Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(json['b'] as Map);
    } on Object {
      return null;
    }
    if (body['t'] is! String || body['at'] is! int || !_wellFormed(body, 0)) {
      return null;
    }
    if (body['by'] is List && (body['by'] as List).length > kPyrMaxSigners) {
      return null;
    }
    Map<String, String>? strings(Object? m) {
      if (m == null) {
        return const <String, String>{};
      }
      if (m is! Map || m.length > kPyrMaxSigners) {
        return null;
      }
      return <String, String>{
        for (final MapEntry<dynamic, dynamic> e in m.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    }

    final Map<String, String>? sigs = strings(json['s']);
    final Map<String, String>? tsigs = strings(json['ts']);
    final RingSignature? ring = json['r'] == null
        ? null
        : RingSignature.fromJson(json['r']);
    if (sigs == null || tsigs == null || (json['r'] != null && ring == null)) {
      return null;
    }
    final PyramidRecord r = PyramidRecord(
      body: body,
      sigs: sigs,
      ring: ring,
      tsigs: tsigs,
    );
    try {
      if (r.signedBytes.length > kPyrMaxRecordBytes) {
        return null;
      }
    } on Object {
      return null;
    }
    return r;
  }

  /// Plain JSON only: null, true/false, whole numbers, text without lone
  /// surrogates, lists, objects with text keys; at most 24 levels deep.
  static bool _wellFormed(Object? v, int depth) {
    if (depth > 24) {
      return false;
    }
    if (v == null || v is bool || v is int) {
      return true;
    }
    if (v is String) {
      return !_loneSurrogate(v);
    }
    if (v is List) {
      for (final Object? x in v) {
        if (!_wellFormed(x, depth + 1)) {
          return false;
        }
      }
      return true;
    }
    if (v is Map) {
      for (final MapEntry<dynamic, dynamic> e in v.entries) {
        final Object? k = e.key;
        if (k is! String ||
            _loneSurrogate(k) ||
            !_wellFormed(e.value, depth + 1)) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  static bool _loneSurrogate(String s) {
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      if (c >= 0xD800 && c <= 0xDBFF) {
        if (i + 1 >= s.length) {
          return true;
        }
        final int next = s.codeUnitAt(i + 1);
        if (next < 0xDC00 || next > 0xDFFF) {
          return true;
        }
        i++;
      } else if (c >= 0xDC00 && c <= 0xDFFF) {
        return true;
      }
    }
    return false;
  }
}

/// Path of a position from the top: '' is the head of the pyramid, '0'
/// and '1' the other two in the top cell, '01' the second under '0', …
abstract final class PyrPath {
  static String parent(String p) =>
      p.isEmpty ? '' : p.substring(0, p.length - 1);
  static int level(String p) => p.length;
  static List<String> children(String p) => <String>['${p}0', '${p}1'];
  static String sibling(String p) =>
      p.isEmpty ? '' : '${parent(p)}${p.endsWith('0') ? '1' : '0'}';

  /// [p] is [root] or under it.
  static bool within(String p, String root) => p.startsWith(root);

  /// Only '0' and '1' (a real place in the tree).
  static bool valid(String p) {
    for (int i = 0; i < p.length; i++) {
      final int c = p.codeUnitAt(i);
      if (c != 0x30 && c != 0x31) {
        return false;
      }
    }
    return true;
  }
}
