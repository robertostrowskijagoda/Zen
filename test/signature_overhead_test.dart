// What hybrid signatures cost a small ledger entry (docs/PROTOCOL.md §4.1).

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';

const int _now = 1790000000000;

int _jsonBytes(Object? json) => utf8.encode(jsonEncode(json)).length;

void main() {
  test('a like carries one signature that names its key, not the device '
      'certificate and two signatures that carry keys', () async {
    final LedgerAccountSetup setup = await LedgerAccountSetup.create(
      deviceName: 'Telefon',
      issued: _now,
    );
    final LedgerStore store = LedgerStore(
      clock: HlcClock(wallClock: () => _now),
    );
    final LedgerAuthor author = LedgerAuthor(
      deviceKey: setup.deviceKey,
      certificate: setup.certificate,
      store: store,
    );
    final LogEntry like = await author.append(
      accountSpace('acts', author.account),
      'like',
      <String, dynamic>{'post': 'ab' * 32, 'on': 1},
    );

    final int content = _jsonBytes(like.unsigned);
    final int now = _jsonBytes(like.toJson()) - content;
    // The layout before: the device's signature carrying its ML-DSA key,
    // and the certificate (naming the key by fingerprint, with the
    // account's signature carrying the account's key) in every entry.
    final Map<String, dynamic> oldCertificate = <String, dynamic>{
      ...setup.certificate.toJson(),
    }..remove('dpk');
    oldCertificate['dpq'] = setup.deviceKey.pqId;
    final int before =
        _jsonBytes(<String, dynamic>{
          ...like.unsigned,
          'cert': oldCertificate,
          'sig': 'x' * kKeyedHybridSignatureChars,
        }) -
        content;
    final int certificate = _jsonBytes(setup.certificate.toJson());
    debugPrint(
      'like ($content B of content): signatures took $before B, now '
      '$now B (raw $kHybridSignatureBytes B); the device certificate '
      '($certificate B) is kept and sent once per device',
    );

    expect(like.toJson().containsKey('cert'), isFalse);
    expect(isHybridSignatureText(like.signature), isTrue);
    expect(like.signature, hasLength(kHybridSignatureChars));
    // One signature: 3405 bytes, 4540 base64url characters in JSON (the
    // ML-DSA-65 signature alone is 3309 bytes).
    expect(kHybridSignatureBytes, lessThan(4 * 1024));
    expect(now, lessThan(4 * 1024 + 512));
    expect(before, greaterThan(14 * 1024));
    expect(now * 3, lessThan(before));
    expect(certificate, lessThan(10 * 1024));
    // What the store counts (and the archive writes) shrank alike.
    expect(like.encodedLength, lessThan(content + 4 * 1024 + 512));

    // Another device takes it once it has the certificate, and from then
    // on every entry of that device with no more than the signature.
    final LedgerStore other = LedgerStore(
      clock: HlcClock(wallClock: () => _now),
    );
    expect(
      (await other.ingestJson(like.toJson())).status,
      IngestStatus.awaitingCertificate,
    );
    expect(await other.addCertificate(setup.certificate), 1);
    final LogEntry next = await author.append(
      accountSpace('acts', author.account),
      'like',
      <String, dynamic>{'post': 'cd' * 32, 'on': 1},
    );
    expect((await other.ingestJson(next.toJson())).status, IngestStatus.added);
  });
}
