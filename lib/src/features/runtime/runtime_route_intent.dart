import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/zen_web.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

enum RuntimeRouteTarget {
  inbox,
  conversation,
  call,
  addFriend,
  groupConversation,

  /// A flat's door code (`zen://m/<code>`, the sticker's `/m#<code>` page):
  /// the neighbours section knocks on that door.
  flatDoor,

  /// The Tablica with a filter (`zen://feed?f=pyramid`); [rawInput] holds
  /// the filter's name, [postId] the post to show (`&p=<id>`), if any.
  feed,

  /// The knocks waiting at the flat's door (`zen://knocks`): the
  /// neighbours section.
  flatKnocks,

  /// "Aktualizacje i Podaj dalej" (`zen://updates`): the notification
  /// about a new version.
  updates,

  /// "Skrzynki offline" (`zen://mailboxes`): a mailbox stopped answering.
  mailboxes,

  /// "Dane i pamięć" (`zen://storage`): Zen took more than its limit.
  storage,
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
    this.callId,
    this.postId,
    this.messageId,
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
    String? messageId,
  }) {
    return RuntimeRouteIntent(
      id: id,
      target: RuntimeRouteTarget.groupConversation,
      peerAddress: groupId,
      title: title,
      messageId: messageId == null || messageId.isEmpty ? null : messageId,
    );
  }

  factory RuntimeRouteIntent.call({
    required String id,
    required String peerAddress,
    String? title,
    bool autoAcceptCall = false,
    String? acceptToken,
    String? callId,
  }) {
    return RuntimeRouteIntent(
      id: id,
      target: RuntimeRouteTarget.call,
      peerAddress: peerAddress,
      title: title,
      autoAcceptCall: autoAcceptCall,
      acceptToken: acceptToken,
      callId: callId,
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

  /// A door code from a sticker link; [rawInput] holds it as
  /// `zen-flat:<code>` ([FlatDoorCode.parse] reads it).
  factory RuntimeRouteIntent.flatDoor({
    required String id,
    required String rawInput,
  }) {
    return RuntimeRouteIntent(
      id: id,
      target: RuntimeRouteTarget.flatDoor,
      rawInput: rawInput,
    );
  }

  /// The knocks at the flat's door ("Ktoś puka do drzwi").
  factory RuntimeRouteIntent.flatKnocks({required String id}) {
    return RuntimeRouteIntent(id: id, target: RuntimeRouteTarget.flatKnocks);
  }

  /// "Aktualizacje i Podaj dalej" (a new version's notification).
  factory RuntimeRouteIntent.updates({required String id}) {
    return RuntimeRouteIntent(id: id, target: RuntimeRouteTarget.updates);
  }

  /// "Skrzynki offline" (a mailbox that stopped answering).
  factory RuntimeRouteIntent.mailboxes({required String id}) {
    return RuntimeRouteIntent(id: id, target: RuntimeRouteTarget.mailboxes);
  }

  /// "Dane i pamięć" (Zen took more than its limit).
  factory RuntimeRouteIntent.storage({required String id}) {
    return RuntimeRouteIntent(id: id, target: RuntimeRouteTarget.storage);
  }

  /// The Tablica, filtered by [filter] (a name of the feed's filters), at
  /// the post [postId] when given.
  factory RuntimeRouteIntent.feed({
    required String id,
    required String filter,
    String? postId,
  }) {
    return RuntimeRouteIntent(
      id: id,
      target: RuntimeRouteTarget.feed,
      rawInput: filter,
      postId: postId == null || postId.isEmpty ? null : postId,
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

  /// The call a call route was built for (its `call` parameter), when the
  /// route names one. An answering route only answers that very call, not a
  /// later one from the same person. Never persisted.
  final String? callId;

  /// The post a feed route shows (a new post's notification). Never
  /// persisted.
  final String? postId;

  /// The message a group route shows (a mention's notification). Never
  /// persisted.
  final String? messageId;

  /// Whether this route may answer [ringingCallId]: a route that names a
  /// call answers only that call; one without a call id (older routes)
  /// only by its token, as before.
  bool answersCall(String ringingCallId) {
    final String? wanted = callId;
    return wanted == null || wanted.isEmpty || wanted == ringingCallId;
  }

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
      callId: callId,
      postId: postId,
      messageId: messageId,
    );
  }

  String? get groupId =>
      target == RuntimeRouteTarget.groupConversation ? peerAddress : null;

  String get actionLabel => switch (target) {
    RuntimeRouteTarget.inbox => t('Otwórz powiadomienia'),
    RuntimeRouteTarget.conversation => t('Otwórz czat'),
    RuntimeRouteTarget.call => t('Otwórz połączenie'),
    RuntimeRouteTarget.addFriend => t('Dodaj znajomego'),
    RuntimeRouteTarget.groupConversation => t('Otwórz grupę'),
    RuntimeRouteTarget.flatDoor => t('Zapukaj do sąsiadów'),
    RuntimeRouteTarget.feed => t('Otwórz Tablicę'),
    RuntimeRouteTarget.flatKnocks => t('Otwórz Sąsiadów'),
    RuntimeRouteTarget.updates => t('Aktualizuj'),
    RuntimeRouteTarget.mailboxes => t('Wybierz skrzynkę'),
    RuntimeRouteTarget.storage => t('Otwórz Dane i pamięć'),
  };
}

String buildInboxRouteKey() => 'zen://inbox';

/// "Aktualizacje i Podaj dalej" (a new version's notification).
String buildUpdatesRouteKey() => 'zen://updates';

/// "Skrzynki offline" (a mailbox that stopped answering).
String buildMailboxesRouteKey() => 'zen://mailboxes';

/// "Dane i pamięć" (Zen took more than its limit).
String buildStorageRouteKey() => 'zen://storage';

/// The knocks at the flat's door (a knock's notification).
String buildFlatKnocksRouteKey() => 'zen://knocks';

/// The Tablica on [filter] (`zen://feed?f=pyramid`), at the post [postId]
/// when given (`zen://feed?f=all&p=<id>`).
String buildFeedRouteKey(String filter, {String? postId}) => Uri(
  scheme: 'zen',
  host: 'feed',
  queryParameters: <String, String>{
    'f': filter,
    if (postId != null && postId.isNotEmpty) 'p': postId,
  },
).toString();

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

/// The group chat [groupId]; at the message [messageId] when given
/// (`&m=<id>`: a mention's notification).
String buildGroupRouteKey({
  required String groupId,
  String? title,
  String? messageId,
}) {
  final String? trimmedTitle = title?.trim();
  final Map<String, String> query = <String, String>{
    if (trimmedTitle != null && trimmedTitle.isNotEmpty) 'title': trimmedTitle,
    if (messageId != null && messageId.isNotEmpty) 'm': messageId,
  };
  return Uri(
    scheme: 'zen',
    host: 'group',
    pathSegments: <String>[groupId],
    queryParameters: query.isEmpty ? null : query,
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
///
/// [callId] names the call the route is for; an answering route then
/// answers only that call (a token issued here is bound to it too), not a
/// later call from the same person.
String buildCallRouteKey({
  required String peerAddress,
  String? title,
  bool autoAccept = false,
  String? acceptToken,
  String? callId,
}) {
  final String? trimmedTitle = title?.trim();
  final String? trimmedCallId = callId?.trim();
  final String? boundCallId = trimmedCallId == null || trimmedCallId.isEmpty
      ? null
      : trimmedCallId;
  final String? token = autoAccept
      ? (acceptToken != null && acceptToken.isNotEmpty
            ? acceptToken
            : issueCallAcceptToken(peerAddress, callId: boundCallId))
      : null;
  final Map<String, String> queryParameters = <String, String>{
    if (trimmedTitle != null && trimmedTitle.isNotEmpty) 'title': trimmedTitle,
    'accept': ?token,
    'call': ?boundCallId,
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
    // The door sticker's page (`…/m#<code>`) opened in Zen: knock there.
    if (isZenPage(uri, path: 'm') && uri.fragment.isNotEmpty) {
      return _flatDoorIntent(id, uri.fragment);
    }
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
  if (uri.host == 'knocks') {
    return RuntimeRouteIntent.flatKnocks(id: id);
  }
  if (uri.host == 'updates') {
    return RuntimeRouteIntent.updates(id: id);
  }
  if (uri.host == 'mailboxes') {
    return RuntimeRouteIntent.mailboxes(id: id);
  }
  if (uri.host == 'storage') {
    return RuntimeRouteIntent.storage(id: id);
  }
  if (uri.host == 'feed') {
    return RuntimeRouteIntent.feed(
      id: id,
      filter: uri.queryParameters['f'] ?? '',
      postId: uri.queryParameters['p'],
    );
  }
  if (uri.host == 'call' && uri.pathSegments.isNotEmpty) {
    final String peerAddress = uri.pathSegments.first;
    final String? acceptToken = uri.queryParameters['accept'];
    final String? callId = uri.queryParameters['call'];
    return RuntimeRouteIntent.call(
      id: id,
      peerAddress: peerAddress,
      title: uri.queryParameters['title'],
      // The old `accept=1` - or anything else a link could carry - is not
      // a token this isolate issued: the call is only opened, never answered.
      autoAcceptCall: isIssuedCallAcceptToken(
        acceptToken,
        peerAddress,
        callId: callId,
      ),
      acceptToken: acceptToken,
      callId: callId == null || callId.isEmpty ? null : callId,
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
      messageId: uri.queryParameters['m'],
    );
  }
  // `zen://m/CODE`: a flat's door code (the sticker page's "Otwórz w Zen").
  if (uri.host == 'm' && uri.pathSegments.isNotEmpty) {
    return _flatDoorIntent(id, uri.pathSegments.first);
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

/// The knock route for a door [code], when it is one.
RuntimeRouteIntent? _flatDoorIntent(String id, String code) {
  final String text = '${FlatDoorCode.qrPrefix}${code.trim()}';
  return FlatDoorCode.parse(text) == null
      ? null
      : RuntimeRouteIntent.flatDoor(id: id, rawInput: text);
}

/// How long an accept token issued by [issueCallAcceptToken] stays valid.
/// A call rings for well under a minute; this leaves time to unlock the
/// phone after tapping "Odbierz".
const Duration kCallAcceptTokenLifetime = Duration(minutes: 5);

const int _maxIssuedCallAcceptTokens = 32;

typedef _CallAcceptGrant = ({
  String peerAddress,
  String? callId,
  int expiresAtMillis,
});

final Map<String, _CallAcceptGrant> _issuedCallAcceptTokens =
    <String, _CallAcceptGrant>{};

/// A fresh random token for a call's accept route (128 bits, hex).
String generateCallAcceptToken() {
  final Random random = Random.secure();
  return List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Issues an accept token for a call with [peerAddress], valid in this
/// isolate for [kCallAcceptTokenLifetime]. With [callId] the token answers
/// only that call.
String issueCallAcceptToken(String peerAddress, {String? callId}) {
  final int now = DateTime.now().millisecondsSinceEpoch;
  _issuedCallAcceptTokens.removeWhere(
    (String _, _CallAcceptGrant grant) => grant.expiresAtMillis <= now,
  );
  while (_issuedCallAcceptTokens.length >= _maxIssuedCallAcceptTokens) {
    _issuedCallAcceptTokens.remove(_issuedCallAcceptTokens.keys.first);
  }
  final String token = generateCallAcceptToken();
  _issuedCallAcceptTokens[token] = (
    peerAddress: peerAddress,
    callId: callId == null || callId.isEmpty ? null : callId,
    expiresAtMillis: now + kCallAcceptTokenLifetime.inMilliseconds,
  );
  return token;
}

/// Whether [token] was issued here, is still valid, and was issued for a
/// call with [peerAddress] - and, when it was bound to a call, for the call
/// [callId] (a token for one call never answers another call
/// from the same person).
bool isIssuedCallAcceptToken(
  String? token,
  String peerAddress, {
  String? callId,
}) {
  if (token == null || token.isEmpty) {
    return false;
  }
  final _CallAcceptGrant? grant = _issuedCallAcceptTokens[token];
  if (grant == null ||
      grant.expiresAtMillis <= DateTime.now().millisecondsSinceEpoch) {
    return false;
  }
  final String? boundCallId = grant.callId;
  if (boundCallId != null && boundCallId != callId) {
    return false;
  }
  return PeerShareCodec.addressesEqual(grant.peerAddress, peerAddress);
}
