import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

enum RuntimeRouteTarget {
  inbox,
  conversation,
  call,
  addFriend,
  groupConversation,
}

@immutable
final class RuntimeRouteIntent {
  const RuntimeRouteIntent({
    required this.id,
    required this.target,
    this.peerAddress,
    this.title,
    this.rawInput,
    this.autoAcceptCall = false,
    this.acceptToken,
  });

  factory RuntimeRouteIntent.inbox({required String id}) {
    return RuntimeRouteIntent(id: id, target: RuntimeRouteTarget.inbox);
  }

  factory RuntimeRouteIntent.conversation({
    required String id,
    required String peerAddress,
    String? title,
  }) {
    return RuntimeRouteIntent(
      id: id,
      target: RuntimeRouteTarget.conversation,
      peerAddress: peerAddress,
      title: title,
    );
  }

  factory RuntimeRouteIntent.groupConversation({
    required String id,
    required String groupId,
    String? title,
  }) {
    return RuntimeRouteIntent(
      id: id,
      target: RuntimeRouteTarget.groupConversation,
      peerAddress: groupId,
      title: title,
    );
  }

  factory RuntimeRouteIntent.call({
    required String id,
    required String peerAddress,
    String? title,
    bool autoAcceptCall = false,
    String? acceptToken,
  }) {
    return RuntimeRouteIntent(
      id: id,
      target: RuntimeRouteTarget.call,
      peerAddress: peerAddress,
      title: title,
      autoAcceptCall: autoAcceptCall,
      acceptToken: acceptToken,
    );
  }

  factory RuntimeRouteIntent.addFriend({
    required String id,
    required String rawInput,
  }) {
    return RuntimeRouteIntent(
      id: id,
      target: RuntimeRouteTarget.addFriend,
      rawInput: rawInput,
    );
  }

  final String id;
  final RuntimeRouteTarget target;
  final String? peerAddress;
  final String? title;
  final String? rawInput;

  /// True when the user already accepted this call (the notification's
  /// "Odbierz" button) and the UI only has to perform the accept, not ask
  /// again.
  ///
  /// Only ever true for a route this app built itself: a call route's
  /// `accept` parameter must carry a secret token (see
  /// [buildCallRouteKey]), which nothing outside the app can know.
  final bool autoAcceptCall;

  /// The `accept` token a call route carried, kept so the controller can
  /// check it against the ringing call's own token when this isolate did not
  /// issue it. Never persisted.
  final String? acceptToken;

  /// This intent with [autoAcceptCall] set.
  RuntimeRouteIntent withAutoAcceptCall() {
    return RuntimeRouteIntent(
      id: id,
      target: target,
      peerAddress: peerAddress,
      title: title,
      rawInput: rawInput,
      autoAcceptCall: true,
      acceptToken: acceptToken,
    );
  }

  String? get groupId =>
      target == RuntimeRouteTarget.groupConversation ? peerAddress : null;

  String get actionLabel => switch (target) {
    RuntimeRouteTarget.inbox => 'Otwórz powiadomienia',
    RuntimeRouteTarget.conversation => 'Otwórz czat',
    RuntimeRouteTarget.call => 'Otwórz połączenie',
    RuntimeRouteTarget.addFriend => 'Dodaj znajomego',
    RuntimeRouteTarget.groupConversation => 'Otwórz grupę',
  };
}

String buildInboxRouteKey() => 'zen://inbox';

String buildConversationRouteKey({required String peerAddress, String? title}) {
  final String? trimmedTitle = title?.trim();
  return Uri(
    scheme: 'zen',
    host: 'chat',
    pathSegments: <String>[peerAddress],
    queryParameters: trimmedTitle == null || trimmedTitle.isEmpty
        ? null
        : <String, String>{'title': trimmedTitle},
  ).toString();
}

String buildGroupRouteKey({required String groupId, String? title}) {
  final String? trimmedTitle = title?.trim();
  return Uri(
    scheme: 'zen',
    host: 'group',
    pathSegments: <String>[groupId],
    queryParameters: trimmedTitle == null || trimmedTitle.isEmpty
        ? null
        : <String, String>{'title': trimmedTitle},
  ).toString();
}

/// Route to the call with [peerAddress].
///
/// With [autoAccept] the route answers a ringing call without asking again,
/// which turns the microphone on. Such a route is honoured only with a
/// secret token in it, so that a link from outside the app (a web page,
/// another app: `zen://` is a public scheme) can never pick up a call. The
/// token is [acceptToken] when given - the ringing call's own token, known
/// to every isolate through the stored call - or else a fresh one issued
/// for this isolate (see [issueCallAcceptToken]).
String buildCallRouteKey({
  required String peerAddress,
  String? title,
  bool autoAccept = false,
  String? acceptToken,
}) {
  final String? trimmedTitle = title?.trim();
  final String? token = autoAccept
      ? (acceptToken != null && acceptToken.isNotEmpty
            ? acceptToken
            : issueCallAcceptToken(peerAddress))
      : null;
  final Map<String, String> queryParameters = <String, String>{
    if (trimmedTitle != null && trimmedTitle.isNotEmpty) 'title': trimmedTitle,
    'accept': ?token,
  };
  return Uri(
    scheme: 'zen',
    host: 'call',
    pathSegments: <String>[peerAddress],
    queryParameters: queryParameters.isEmpty ? null : queryParameters,
  ).toString();
}

RuntimeRouteIntent? runtimeRouteIntentFromRouteKey({
  required String id,
  String? routeKey,
}) {
  final String? trimmed = routeKey?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  final Uri? uri = Uri.tryParse(trimmed);
  if (uri == null) {
    return null;
  }
  // A universal invite link (https://…#CODE) opened in Zen: go straight to
  // adding that friend, the same as an in-app QR scan.
  if (uri.scheme == 'https' || uri.scheme == 'http') {
    return PeerShareCodec.inviteCodeFromLink(trimmed) == null
        ? null
        : RuntimeRouteIntent.addFriend(id: id, rawInput: trimmed);
  }
  if (uri.scheme != 'zen') {
    return null;
  }
  if (uri.host == 'inbox') {
    return RuntimeRouteIntent.inbox(id: id);
  }
  if (uri.host == 'call' && uri.pathSegments.isNotEmpty) {
    final String peerAddress = uri.pathSegments.first;
    final String? acceptToken = uri.queryParameters['accept'];
    return RuntimeRouteIntent.call(
      id: id,
      peerAddress: peerAddress,
      title: uri.queryParameters['title'],
      // The old `accept=1` - or anything else a link could carry - is not
      // a token this isolate issued: the call is only opened, never answered.
      autoAcceptCall: isIssuedCallAcceptToken(acceptToken, peerAddress),
      acceptToken: acceptToken,
    );
  }
  if (uri.host == 'chat' && uri.pathSegments.isNotEmpty) {
    return RuntimeRouteIntent.conversation(
      id: id,
      peerAddress: uri.pathSegments.first,
      title: uri.queryParameters['title'],
    );
  }
  if (uri.host == 'group' && uri.pathSegments.isNotEmpty) {
    return RuntimeRouteIntent.groupConversation(
      id: id,
      groupId: uri.pathSegments.first,
      title: uri.queryParameters['title'],
    );
  }
  // `zen://c/CODE`: only an invitation code (older links that carried an
  // address and a name are not taken).
  if (uri.host == 'c' &&
      uri.pathSegments.isNotEmpty &&
      PeerShareCodec.addressFromInviteCode(uri.pathSegments.first) != null) {
    return RuntimeRouteIntent.addFriend(id: id, rawInput: trimmed);
  }
  return null;
}

/// How long an accept token issued by [issueCallAcceptToken] stays valid.
/// A call rings for well under a minute; this leaves time to unlock the
/// phone after tapping "Odbierz".
const Duration kCallAcceptTokenLifetime = Duration(minutes: 5);

const int _maxIssuedCallAcceptTokens = 32;

final Map<String, ({String peerAddress, int expiresAtMillis})>
_issuedCallAcceptTokens =
    <String, ({String peerAddress, int expiresAtMillis})>{};

/// A fresh random token for a call's accept route (128 bits, hex).
String generateCallAcceptToken() {
  final Random random = Random.secure();
  return List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Issues an accept token for a call with [peerAddress], valid in this
/// isolate for [kCallAcceptTokenLifetime].
String issueCallAcceptToken(String peerAddress) {
  final int now = DateTime.now().millisecondsSinceEpoch;
  _issuedCallAcceptTokens.removeWhere(
    (String _, ({String peerAddress, int expiresAtMillis}) grant) =>
        grant.expiresAtMillis <= now,
  );
  while (_issuedCallAcceptTokens.length >= _maxIssuedCallAcceptTokens) {
    _issuedCallAcceptTokens.remove(_issuedCallAcceptTokens.keys.first);
  }
  final String token = generateCallAcceptToken();
  _issuedCallAcceptTokens[token] = (
    peerAddress: peerAddress,
    expiresAtMillis: now + kCallAcceptTokenLifetime.inMilliseconds,
  );
  return token;
}

/// Whether [token] was issued here, is still valid, and was issued for a
/// call with [peerAddress].
bool isIssuedCallAcceptToken(String? token, String peerAddress) {
  if (token == null || token.isEmpty) {
    return false;
  }
  final ({String peerAddress, int expiresAtMillis})? grant =
      _issuedCallAcceptTokens[token];
  if (grant == null ||
      grant.expiresAtMillis <= DateTime.now().millisecondsSinceEpoch) {
    return false;
  }
  return PeerShareCodec.addressesEqual(grant.peerAddress, peerAddress);
}
