import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

void main() {
  test('builds and parses conversation route keys', () {
    final String routeKey = buildConversationRouteKey(
      peerAddress: 'ada.ygg',
      title: 'Ada',
    );

    expect(routeKey, 'zen://chat/ada.ygg?title=Ada');
    final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
      id: 'launch-1',
      routeKey: routeKey,
    );
    expect(intent, isNotNull);
    expect(intent!.target, RuntimeRouteTarget.conversation);
    expect(intent.peerAddress, 'ada.ygg');
    expect(intent.title, 'Ada');
  });

  test('parses inbox route keys into inbox intents', () {
    final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
      id: 'launch-2',
      routeKey: buildInboxRouteKey(),
    );

    expect(intent, isNotNull);
    expect(intent!.target, RuntimeRouteTarget.inbox);
    expect(intent.actionLabel, 'Otwórz powiadomienia');
  });

  test('parses add-friend deep links into add-friend intents', () {
    final String code = PeerShareCodec.inviteCodeForAddress(
      '200:1111:2222:3333:4444:5555:6666:7777',
    )!.replaceAll('-', '');
    final String routeKey = 'zen://c/$code';
    final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
      id: 'launch-3',
      routeKey: routeKey,
    );

    expect(intent, isNotNull);
    expect(intent!.target, RuntimeRouteTarget.addFriend);
    expect(intent.rawInput, routeKey);
    expect(intent.actionLabel, 'Dodaj znajomego');
  });

  test('an answering route is bound to its call (S17)', () {
    const String peer = '200:1111:2222:3333:4444:5555:6666:7777';
    final String routeKey = buildCallRouteKey(
      peerAddress: peer,
      title: 'Ada',
      autoAccept: true,
      callId: 'call-1',
    );
    final RuntimeRouteIntent intent = runtimeRouteIntentFromRouteKey(
      id: 'launch-5',
      routeKey: routeKey,
    )!;
    expect(intent.target, RuntimeRouteTarget.call);
    expect(intent.autoAcceptCall, isTrue);
    expect(intent.callId, 'call-1');
    expect(intent.answersCall('call-1'), isTrue);
    expect(intent.answersCall('call-2'), isFalse);
    expect(intent.withAutoAcceptCall().callId, 'call-1');

    // The same token with another call id (or none) answers nothing.
    final String token = Uri.parse(routeKey).queryParameters['accept']!;
    expect(isIssuedCallAcceptToken(token, peer, callId: 'call-1'), isTrue);
    expect(isIssuedCallAcceptToken(token, peer, callId: 'call-2'), isFalse);
    expect(isIssuedCallAcceptToken(token, peer), isFalse);
    final RuntimeRouteIntent forged = runtimeRouteIntentFromRouteKey(
      id: 'launch-6',
      routeKey: routeKey.replaceAll('call=call-1', 'call=call-2'),
    )!;
    expect(forged.autoAcceptCall, isFalse);
  });

  test('a token issued without a call id keeps working (older routes)', () {
    const String peer = '200:1111:2222:3333:4444:5555:6666:7777';
    final String token = issueCallAcceptToken(peer);
    expect(isIssuedCallAcceptToken(token, peer), isTrue);
    expect(isIssuedCallAcceptToken(token, peer, callId: 'any'), isTrue);
    const RuntimeRouteIntent intent = RuntimeRouteIntent(
      id: 'launch-7',
      target: RuntimeRouteTarget.call,
      peerAddress: peer,
      autoAcceptCall: true,
    );
    expect(intent.answersCall('call-9'), isTrue);
    expect(
      buildCallRouteKey(peerAddress: peer, title: 'Ada'),
      isNot(contains('call=')),
    );
  });

  test('older add-friend links with an address and a name are ignored', () {
    for (final String routeKey in <String>[
      // base64url of `ada.ygg|Ada`, and the old `peer` host.
      'zen://c/YWRhLnlnZ3xBZGE',
      'zen://peer?d=eyJhIjoiMjAwOjoxIiwibiI6IkFkYSJ9',
      'https://example.com/zen#ABCDE',
    ]) {
      expect(
        runtimeRouteIntentFromRouteKey(id: 'launch-4', routeKey: routeKey),
        isNull,
        reason: routeKey,
      );
    }
  });

  test('door sticker links open the neighbours knock (§18.2)', () {
    final FlatDoorCode door = FlatDoorCode(
      key: base64Url.encode(List<int>.filled(32, 7)),
      door: 'abc',
      inbox: PeerShareCodec.normalizeAddress('200::d1'),
      name: 'Nowakowie, m. 12',
    );
    final String code = door.encode();
    for (final String routeKey in <String>[
      'zen://m/$code',
      door.toLink(),
      '${PeerShareCodec.invitePageUrl}m#$code',
    ]) {
      final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
        id: 'door',
        routeKey: routeKey,
      );
      expect(intent?.target, RuntimeRouteTarget.flatDoor, reason: routeKey);
      final FlatDoorCode? back = FlatDoorCode.parse(intent!.rawInput!);
      expect(back?.key, door.key, reason: routeKey);
      expect(back?.inbox, door.inbox, reason: routeKey);
    }
    for (final String routeKey in <String>[
      'zen://m/nonsense',
      'zen://m/',
      'https://example.org/m#$code',
      '${PeerShareCodec.invitePageUrl}m#nonsense',
    ]) {
      expect(
        runtimeRouteIntentFromRouteKey(id: 'door', routeKey: routeKey)?.target,
        isNot(RuntimeRouteTarget.flatDoor),
        reason: routeKey,
      );
    }
  });
}
