import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/update/release.dart';

/// A warrant canary (§14.2 point 7): a statement the maintainers sign and
/// renew before [CanaryStatement.until] ("no one has forced us to change
/// the app or hand over keys"). If it is not renewed in time, people can
/// assume they were silenced. It travels like vetoes — friend to friend, or
/// loaded from a file (`canary.json`) — and is never fetched from a server.
///
/// File format (made with `tool/zen_release.dart canary`, signed with
/// `sign` like a release):
///
/// ```json
/// {"m": {"t": "zen_canary", "app": "zen", "at": 0, "until": 0,
///        "text": "…"},
///  "sigs": [{"k": "<maintainer key>", "s": "<signature>"}]}
/// ```
@immutable
final class CanaryStatement {
  const CanaryStatement({
    required this.at,
    required this.until,
    required this.text,
  });

  /// When it was written (maintainers' clock, ms).
  final int at;

  /// When the next statement is due at the latest (ms).
  final int until;
  final String text;

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': 'zen_canary',
    'app': kReleaseApp,
    'at': at,
    'until': until,
    'text': text,
  };

  Uint8List signedBytes() => canonicalJsonBytes(toJson());

  static CanaryStatement? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'zen_canary' ||
        json['app'] != kReleaseApp) {
      return null;
    }
    final Object? at = json['at'];
    final Object? until = json['until'];
    final Object? text = json['text'];
    if (at is! int ||
        until is! int ||
        until <= at ||
        text is! String ||
        text.isEmpty ||
        text.length > 4000) {
      return null;
    }
    return CanaryStatement(at: at, until: until, text: text);
  }
}

/// A canary with the maintainers' signatures.
@immutable
final class SignedCanary {
  const SignedCanary(this.statement, this.signatures);

  final CanaryStatement statement;

  /// Maintainer key → signature (base64url).
  final Map<String, String> signatures;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'm': statement.toJson(),
    'sigs': <Map<String, String>>[
      for (final MapEntry<String, String> e in signatures.entries)
        <String, String>{'k': e.key, 's': e.value},
    ],
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static SignedCanary? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final CanaryStatement? statement = CanaryStatement.fromJson(json['m']);
    final Map<String, String>? signatures = readSignatureList(json['sigs']);
    if (statement == null || signatures == null) {
      return null;
    }
    return SignedCanary(statement, signatures);
  }

  /// Adds the signature of [maintainer].
  Future<SignedCanary> signedBy(LedgerKeyPair maintainer) async {
    final Uint8List sig = await maintainer.sign(statement.signedBytes());
    return SignedCanary(statement, <String, String>{
      ...signatures,
      maintainer.id: b64(sig),
    });
  }

  Future<int> validSignatures(List<String> maintainers) =>
      countMaintainerSignatures(
        message: statement.signedBytes(),
        signatures: signatures,
        maintainers: maintainers,
      );

  /// Signed by [threshold] of [maintainers], like a release.
  Future<bool> isTrusted({
    List<String> maintainers = kReleaseMaintainers,
    int threshold = kReleaseThreshold,
  }) async =>
      maintainers.length >= threshold &&
      await validSignatures(maintainers) >= threshold;

  /// Not renewed in time.
  bool isExpired(int now) => now > statement.until;
}
