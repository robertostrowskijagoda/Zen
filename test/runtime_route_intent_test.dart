import 'package:flutter_test/flutter_test.dart';
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
}
