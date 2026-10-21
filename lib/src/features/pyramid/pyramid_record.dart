import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';

/// How far a record's own time may be from this phone's clock: ahead of it
/// when the record arrives (anything later waits — a "time bomb" is never
/// kept), behind it when this phone signs or publishes it.
const int kPyrMaxSkewMs = 10 * 60 * 1000;

/// A record whose time rules count from ([PyrT.timed]) is late on a phone
/// when it is dated more than this before records the phone already kept:
/// back-dated, or held back. There its delays and limits count from when
/// the phone first saw it.
const int kPyrLateMs = 30 * 60 * 1000;

/// The largest record kept (its canonical body): generous, a revocation
/// listing thousands of acts fits.
const int kPyrMaxRecordBytes = 2 * 1024 * 1024;

/// The most signatures (and treasurer signatures) one record may carry.
const int kPyrMaxSigners = 100;

/// Kinds of pyramid records. Every change to the pyramid is one
/// signed record; the state is what follows from the records.
abstract final class PyrT {
  static const String genesis = 'genesis';
  static const String admit = 'admit';
  static const String swap = 'swap';
  static const String voteRequest = 'vreq';
  static const String vote = 'vote';

  /// The voting cards of a cell vote: one one-time hybrid key per member
  /// who registered one, signed by the members themselves
  /// ([PyramidState.ballotTokens]).
  static const String ballot = 'ballot';
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

  /// A question the top (2 of 3) asks the members; the result advises.
  static const String referendum = 'ref';
  static const String tally = 'tally';

  /// New rules in numbers, signed by the top (2 of 3), applied a day
  /// later.
  static const String constitution = 'const';
  static const String emit = 'emit';
  static const String veto = 'veto';
  static const String transfer = 'xfer';
  static const String settle = 'settle';
  static const String alarm = 'alarm';
  static const String offer = 'offer';

  /// The first head of the pyramid takes the top, signed by the power key
  /// of the genesis (only while nobody is in the pyramid).
  static const String found = 'found';

  /// The power key passes to the head now at the top: signed by the old
  /// power key — or, 72 h after the head took the top, by most of the top
  /// cell — and by the new key and the new head. The power key only
  /// certifies that this is the original pyramid and who its heads were.
  static const String handover = 'hand';

  /// The national section's lead pins (or unpins) a post.
  static const String natPin = 'natpin';

  /// A member shows (or hides) their age and gender badge: the
  /// birth year, gender and salt behind their data commitment.
  static const String badge = 'badge';

  /// A member of someone's cell says "we know each other": from then on
  /// that person votes in the cell and in referenda (without it, 14 days
  /// after joining).
  static const String known = 'known';

  /// The emission limit (and the wait before an emission counts) changes
  /// only by this record, signed by the top (2 of 3): lower at once, any
  /// change that lets more money out announced to everybody and in force
  /// 30 days later, unless the top cancels it ([emitCancel]) before.
  static const String emitRule = 'emitrule';
  static const String emitCancel = 'emitcancel';

  /// A member's complaint against another member ("Sąd"), judged first by
  /// the head of the accused's cell ([verdict]).
  static const String suit = 'suit';
  static const String verdict = 'verdict';

  /// An appeal against a decision (a ban, a removal, a verdict, a dismissed
  /// complaint): it goes one level above whoever decided, each time twice
  /// as long to answer ([appealAnswer]), up to the top.
  static const String appeal = 'appeal';
  static const String appealAnswer = 'appans';

  /// Kinds signed anonymously with a ring signature.
  static const Set<String> anonymous = <String>{voteRequest};

  /// Kinds published through a friend outside the cell, so the first phone
  /// to show them is not the author's: the anonymous request and the vote
  /// (signed by a one-time key on the cell's ballot).
  static const Set<String> relayed = <String>{voteRequest, vote};

  /// Kinds most treasurers sign before they count.
  static const Set<String> treasured = <String>{transfer, settle};

  /// Kinds whose time starts a wait or counts against a limit (new rules
  /// a day later, an emission's veto time and its 30-day limit, a raise of
  /// the limit 30 days later, the time a complaint or an appeal gives to
  /// answer it): a phone that sees one late ([kPyrLateMs]) counts them
  /// from then.
  static const Set<String> timed = <String>{
    constitution,
    emit,
    emitRule,
    suit,
    appeal,
  };

  /// Kinds whose signatures carry their ML-DSA keys (the keyed form,
  /// [PyramidRecord.signsWithKeys]): the records that introduce a key —
  /// the genesis, founding, admissions, handovers of the power key — and
  /// those read outside the pyramid by people who hold none of its records
  /// (national-section posts, crisis alarms, verdicts with the appeals and
  /// answers that overturn them, the addresses a verdict is shown at).
  /// Every other signature names its key, which a phone keeping the pyramid
  /// has from those records.
  static const Set<String> keyed = <String>{
    genesis,
    found,
    admit,
    handover,
    natPost,
    alarm,
    verdict,
    appeal,
    appealAnswer,
    address,
    vote,
  };
}

/// One signed record. [body] is everything but the signatures; [sigs] maps
/// signer key → hybrid signature of the canonical body (Ed25519 +
/// ML-DSA-65, see hybrid_signature.dart); [ring] is a ring signature for
/// the anonymous request of a cell vote (classical, see
/// ring_signature.dart; the votes themselves are hybrid-signed by one-time
/// keys, [PyrT.ballot]); [tsigs] are
/// treasurers' hybrid signatures on a transfer or a settlement.
///
/// A signature names the signer's ML-DSA key by fingerprint; the key is
/// published by a keyed signature on the record that introduced it
/// ([signsWithKeys]) and looked up in [HybridKeyBook], where the service
/// files the keys of the records it keeps ([fileKeys]).
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
  static final Expando<Map<String, String?>> _pqIds =
      Expando<Map<String, String?>>('pyramidRecordPqIds');

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
  /// again later) share it.
  String get contentKey => _contents[this] ??= sha256Hex(
    canonicalJsonBytes(<String, dynamic>{...body}..remove('at')),
  );

  String str(String k) => body[k] is String ? body[k] as String : '';
  int integer(String k) => body[k] is int ? body[k] as int : 0;

  /// The fingerprint of the ML-DSA key that [key]'s signature carries
  /// (its treasurer signature with [treasurer]); null without one. Worked
  /// out once per record: the fold compares it with the key the signer
  /// was admitted with.
  String? pqIdOf(String key, {bool treasurer = false}) {
    final Map<String, String?> cache = _pqIds[this] ??= <String, String?>{};
    final String slot = treasurer ? 't|$key' : key;
    if (!cache.containsKey(slot)) {
      cache[slot] = hybridSignaturePqId((treasurer ? tsigs : sigs)[key]);
    }
    return cache[slot];
  }

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

  /// Whether signatures of this record carry their ML-DSA keys: the kinds
  /// of [PyrT.keyed] and the top's posts to the whole pyramid (level 0),
  /// which are read outside it too.
  bool get signsWithKeys =>
      PyrT.keyed.contains(type) || (type == PyrT.post && integer('lvl') == 0);

  Future<PyramidRecord> signedBy(LedgerKeyPair pair) async => withSig(
    pair.id,
    b64(
      await (signsWithKeys
          ? pair.signWithKey(signedBytes)
          : pair.sign(signedBytes)),
    ),
  );

  /// Files the ML-DSA keys its keyed signatures carry ([HybridKeyBook]):
  /// for a record that is kept (checked when it came).
  void fileKeys() {
    sigs.values.forEach(HybridKeyBook.addFromSignature);
    tsigs.values.forEach(HybridKeyBook.addFromSignature);
  }

  /// Whether a signature of a listed signer (or a treasurer) names an
  /// ML-DSA key this phone does not hold yet: the record that publishes
  /// it has not come, so the record waits rather than being refused.
  bool get lacksKeys {
    final List<String> allowed = candidates;
    for (final MapEntry<String, String> e in sigs.entries) {
      if (allowed.contains(e.key) && hybridSignatureLacksKey(e.value)) {
        return true;
      }
    }
    return tsigs.values.any(hybridSignatureLacksKey);
  }

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
