// Golden protocol samples (STAN A13/A17).
//
// Frozen frames as peers send them. They must keep decoding the same way:
// a change that breaks one of these breaks talking to phones that are not
// updated yet. Never edit a sample to make a test pass - add a new one for
// a new format and keep the old one as long as such peers may exist.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';

const String _ada = '200:1111:2222:3333:4444:5555:6666:7777';
const String _bob = '200:aaaa:bbbb:cccc:dddd:eeee:ffff:1111';

/// A ping as 1.10.0 sends it to a friend: hello digests, no version.
const String _ping110 = '{"type":"ping","mf":"3f2a9c1d","ms":0}';

/// A ping from 1.11 on: the same plus `ver` / `build` / `caps`.
const String _ping111 =
    '{"type":"ping","ver":"1.11.0","build":11,'
    '"caps":["ledger1","relay1","group_call1","disappear1","meet1"],'
    '"mf":"3f2a9c1d","mk":"0b7e","ms":1790000000000}';

/// A pong as 1.10.0 sends it.
const String _pong110 = '{"type":"pong","state":"foreground","ms":0}';

/// A pong from 1.11 on.
const String _pong111 =
    '{"type":"pong","state":"background","ver":"1.11.0","build":11,'
    '"caps":["ledger1","relay1"],"ms":0}';

const String _message =
    '{"type":"message","msgId":"m-golden-1","text":"Cześć, to próbka",'
    '"createdAt":"2026-09-21T14:13:20.000Z","ttl":3600}';

const String _groupInvite =
    '{"type":"group_invite","groupId":"g-golden","groupName":"Paczka",'
    '"description":"Wspólne wyjście","avatarPreset":"zen_avatar_2",'
    '"memberAddresses":["$_ada","$_bob"],"senderName":"Ada",'
    '"inviteId":"inv-golden-1"}';

/// A signed ledger entry (feed post), as replicated between devices. The
/// keys come from fixed seeds, so the signature and the id never change.
const String _ledgerEntry = '''
{
  "v": 1,
  "space": "feed/iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=",
  "writer": "0123456789abcdef0123456789abcdef",
  "seq": 1,
  "prev": "",
  "hlc": 117309440000000000,
  "kind": "post",
  "body": {"text": "Golden sample", "aud": "friends"},
  "blobs": [],
  "account": "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=",
  "device": "gTl3Dqh9F19Wo1Rmw0x-zMuNipG07jeiXfYPW4_Js5Q=",
  "cert": {
    "t": "dev_cert",
    "account": "iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=",
    "device": "gTl3Dqh9F19Wo1Rmw0x-zMuNipG07jeiXfYPW4_Js5Q=",
    "name": "Telefon",
    "issued": 1790000000000,
    "sig": "RhARaGYP92Ka5HrVg9-ksTTV-w-Gmi9vwQ8JlHEpxKd315IyQvO3tJ6qPQZ3ihHF4bVOhKl4do8tu3eYESApDQ=="
  },
  "sig": "n0wZS3NydFH3Eqs3jV7TeJlAvrvVbGsEPnhlvU2qB9kP-6iIB_WwywtEc0GgPZdqveIyjhH7nWS49kJRxRrdAA=="
}
''';

const String _ledgerEntryId =
    '8e2ed35c0223ce0cc5f04821ababc612fb9cbce692e670cb01b76e0b2d6d5166';

Map<String, dynamic> _frame(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

void main() {
  group('ping / pong', () {
    test('a 1.10.0 ping or pong carries no version, and that is fine', () {
      expect(PeerVersion.fromPayload(_frame(_ping110)), isNull);
      expect(PeerVersion.fromPayload(_frame(_pong110)), isNull);
    });

    test('a ping from 1.11 names its version and capabilities', () {
      final PeerVersion version = PeerVersion.fromPayload(_frame(_ping111))!;
      expect(version.version, '1.11.0');
      expect(version.build, 11);
      expect(version.caps, contains('ledger1'));
      expect(version.hasCap('meet1'), isTrue);
    });

    test('a pong from 1.11 names its version', () {
      final Map<String, dynamic> pong = _frame(_pong111);
      expect(pong['state'], 'background');
      expect(PeerVersion.fromPayload(pong)!.version, '1.11.0');
    });

    test('what this build sends uses the frozen keys', () {
      final Map<String, dynamic> hello = versionHello();
      expect(hello.keys, containsAll(<String>['ver', 'build', 'caps']));
      expect(hello['ver'], kAppVersion);
      expect(hello['build'], kAppBuild);
      final PeerVersion? back = PeerVersion.fromPayload(<String, dynamic>{
        'type': 'ping',
        ...jsonDecode(jsonEncode(hello)) as Map<String, dynamic>,
      });
      expect(back?.version, kAppVersion);
      expect(back?.caps, kZenCaps);
    });
  });

  test('message', () {
    final ZenSignal signal = zenSignalFromTransportPayload(
      sender: _ada,
      payload: _frame(_message),
    )!;
    expect(signal.type, ZenSignalType.message);
    expect(signal.sender, _ada);
    expect(signal.messageId, 'm-golden-1');
    expect(signal.content, 'Cześć, to próbka');
    expect(signal.messageType, ChatMessageType.text);
    expect(signal.sentAtMillis, 1790000000000);
    expect(signal.disappearSeconds, 3600);
  });

  test('group_invite', () {
    final ZenSignal signal = zenSignalFromTransportPayload(
      sender: _ada,
      payload: _frame(_groupInvite),
    )!;
    expect(signal.type, ZenSignalType.groupInvite);
    expect(signal.groupId, 'g-golden');
    expect(signal.groupName, 'Paczka');
    expect(signal.content, 'Wspólne wyjście');
    expect(signal.avatarPreset, 'zen_avatar_2');
    expect(signal.memberAddresses, <String>[_ada, _bob]);
    expect(signal.displayName, 'Ada');
    expect(signal.inviteId, 'inv-golden-1');
  });

  group('ledger entry', () {
    test('parses, keeps its id and its signatures still verify', () async {
      final LogEntry entry = LogEntry.fromJson(jsonDecode(_ledgerEntry))!;
      expect(entry.id, _ledgerEntryId);
      expect(entry.version, 1);
      expect(entry.kind, 'post');
      expect(entry.body['text'], 'Golden sample');
      expect(await entry.verifySignature(), isTrue);
      expect(await entry.certificate.verify(), isTrue);
    });

    test('a fresh store takes it', () async {
      final LedgerStore store = LedgerStore(
        clock: HlcClock(wallClock: () => 1790000000000),
      );
      final IngestResult result = await store.ingestJson(
        jsonDecode(_ledgerEntry),
      );
      expect(result.status, IngestStatus.added);
    });

    test('a newer format version is still kept', () {
      final Map<String, dynamic> newer =
          jsonDecode(_ledgerEntry) as Map<String, dynamic>;
      newer['v'] = 2;
      // Parsed (and stored, passed on); only the signature no longer fits,
      // because `v` is signed - which is what a forged bump must hit.
      expect(LogEntry.fromJson(newer), isNotNull);
    });
  });
}
