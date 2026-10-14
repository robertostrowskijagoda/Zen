import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/calls/ongoing_group_call.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/test_harness_features.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Header every harness request has to carry (value `1`).
const String kTestHarnessHeader = 'x-zen-harness';

/// Whether a request's `Host` header names this machine's loopback.
///
/// The harness listens on 127.0.0.1 only, but a web page can still reach it
/// through DNS rebinding: its own host name, re-pointed at 127.0.0.1. Such a
/// request carries that host name, never a loopback one. Any port is fine -
/// `adb forward` maps another local port onto the harness, and the port does
/// not matter for rebinding anyway.
bool isLoopbackHarnessHost(String? hostHeader) {
  final String value = hostHeader?.trim().toLowerCase() ?? '';
  if (value.isEmpty) {
    return false;
  }
  final String host;
  if (value.startsWith('[')) {
    final int end = value.indexOf(']');
    if (end < 0) {
      return false;
    }
    host = value.substring(1, end);
    final String rest = value.substring(end + 1);
    if (rest.isNotEmpty && !RegExp(r'^:\d{1,5}$').hasMatch(rest)) {
      return false;
    }
  } else {
    final int colon = value.indexOf(':');
    host = colon < 0 ? value : value.substring(0, colon);
    final String rest = colon < 0 ? '' : value.substring(colon);
    if (rest.isNotEmpty && !RegExp(r'^:\d{1,5}$').hasMatch(rest)) {
      return false;
    }
  }
  return host == '127.0.0.1' || host == 'localhost' || host == '::1';
}

class TestHarnessServer {
  TestHarnessServer(this._ref);

  final WidgetRef _ref;
  HttpServer? _server;
  int _port = 48888;

  int get port => _port;

  Future<void> start() async {
    for (int p = 48888; p <= 48895; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
        _port = p;
        logZenMessage('TestHarnessServer listening on 127.0.0.1:$_port');
        _listen();
        return;
      } catch (_) {
        // Try next port
      }
    }
    logZenMessage(
      'TestHarnessServer could not bind to any port in 48888-48895',
    );
  }

  void _listen() {
    _server?.listen((HttpRequest request) async {
      request.response.headers.contentType = ContentType.json;

      // No CORS, and a custom header on every call: a web page open in any
      // browser on this device cannot reach the harness (a page can post to
      // localhost, but cannot add this header without a CORS preflight,
      // which is refused). Tools like curl simply send it.
      if (request.headers.value(kTestHarnessHeader) != '1' ||
          !isLoopbackHarnessHost(
            request.headers.value(HttpHeaders.hostHeader),
          )) {
        request.response.statusCode = HttpStatus.forbidden;
        request.response.write(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'Missing $kTestHarnessHeader header or non-loopback Host',
          }),
        );
        await request.response.close();
        return;
      }

      try {
        await _handleRequest(request);
      } catch (error, stack) {
        logZenError(
          'TestHarness error handling ${request.uri.path}',
          error,
          stack,
        );
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write(
          jsonEncode(<String, dynamic>{'ok': false, 'error': '$error'}),
        );
        await request.response.close();
      }
    });
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final String path = request.uri.path;

    if (path == '/health' || path == '/status') {
      await _handleStatus(request);
      return;
    }

    if (request.method == 'GET' && path == '/chat/messages') {
      await _handleGetMessages(request);
      return;
    }

    final String bodyStr = await utf8.decodeStream(request);
    final Map<String, dynamic> body = bodyStr.isNotEmpty
        ? (jsonDecode(bodyStr) as Map<String, dynamic>)
        : <String, dynamic>{};

    switch (path) {
      case '/chat/send':
        await _handleSendMessage(request, body);
        break;
      case '/chat/typing':
        await _handleTyping(request, body);
        break;
      case '/chat/send-attachment':
        await _handleSendAttachment(request, body);
        break;
      case '/friend/request':
        await _handleFriendRequest(request, body);
        break;
      case '/friend/accept':
        await _handleFriendAccept(request, body);
        break;
      case '/friend/reject':
        await _handleFriendReject(request, body);
        break;
      case '/friend/remove':
        await _handleFriendRemove(request, body);
        break;
      case '/friend/block':
        await _handleFriendBlock(request, body);
        break;
      case '/friend/unblock':
        await _handleFriendUnblock(request, body);
        break;
      case '/friend/nickname':
        await _handleFriendNickname(request, body);
        break;
      case '/group/create':
        await _handleGroupCreate(request, body);
        break;
      case '/group/send':
        await _handleGroupSend(request, body);
        break;
      case '/call/start':
        await _handleCallStart(request, body);
        break;
      case '/group/call/start':
        await _handleGroupCallStart(request, body);
        break;
      case '/group/call/join':
        await _handleGroupCallJoin(request, body);
        break;
      case '/call/accept':
        await _handleCallAccept(request, body);
        break;
      case '/call/decline':
        await _handleCallDecline(request, body);
        break;
      case '/call/end':
        await _handleCallEnd(request, body);
        break;
      case '/call/toggle-mute':
        await _handleCallToggleMute(request);
        break;
      case '/call/toggle-speaker':
        await _handleCallToggleSpeaker(request);
        break;
      case '/call/toggle-camera':
        await _handleCallToggleCamera(request);
        break;
      case '/call/switch-camera':
        await _handleCallSwitchCamera(request);
        break;
      case '/settings/theme':
        await _handleThemeChange(request, body);
        break;
      case '/window/close':
        if (!kIsWeb &&
            (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
          await windowManager.close();
          request.response.statusCode = HttpStatus.ok;
          request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
        } else {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': 'Window controls not supported on this platform',
            }),
          );
        }
        await request.response.close();
        break;
      case '/window/show':
        if (!kIsWeb &&
            (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
          await windowManager.setSkipTaskbar(false);
          try {
            await windowManager.restore();
          } catch (_) {}
          await windowManager.show();
          await windowManager.focus();
          request.response.statusCode = HttpStatus.ok;
          request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
        } else {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write(
            jsonEncode(<String, dynamic>{
              'ok': false,
              'error': 'Window controls not supported on this platform',
            }),
          );
        }
        await request.response.close();
        break;
      default:
        final Map<String, dynamic>? feature = await handleFeatureHarness(
          _ref,
          path,
          body,
        );
        if (feature != null) {
          request.response.write(jsonEncode(feature));
          await request.response.close();
          break;
        }
        request.response.statusCode = HttpStatus.notFound;
        request.response.write(
          jsonEncode(<String, dynamic>{
            'ok': false,
            'error': 'Not found: $path',
          }),
        );
        await request.response.close();
    }
  }

  Future<void> _handleStatus(HttpRequest request) async {
    final AppShellState shell = _ref.read(appShellControllerProvider);
    final UserProfile profile = _ref.read(userProfileControllerProvider);
    final SocialHubState social = _ref.read(socialHubControllerProvider);
    final CallMediaSessionController callMedia = _ref.read(
      callMediaSessionControllerProvider,
    );
    final AppSecurityService security = _ref.read(appSecurityServiceProvider);
    final GroupCallMedia groupMedia = _ref.read(groupCallMediaProvider);

    final PeerShareProfile? localProfile = PeerShareCodec.buildLocalProfile(
      address: shell.localAddress,
      displayName: profile.displayName,
    );

    final CallSession? session = social.activeCall;

    final Map<String, dynamic> data = <String, dynamic>{
      'ok': true,
      'platform': defaultTargetPlatform.name,
      'profile': ZenInstance.profile,
      'localAddress': shell.localAddress,
      'displayName': profile.displayName,
      'shareToken': localProfile?.inviteCode,
      'shareCode': localProfile?.shareId,
      'shareUri': localProfile?.qrData,
      'isOnline': shell.isConnected,
      'peers': shell.peers,
      'routingEntries': shell.routingEntries,
      'activeCall': session == null
          ? null
          : <String, dynamic>{
              'id': session.id,
              'peerAddress': session.peerAddress,
              'displayName': session.displayName,
              'kind': session.kind.name,
              'status': session.status.name,
              'isIncoming': session.isIncoming,
              'isSpeakerOn': session.isSpeakerOn,
              'isCameraEnabled': session.isCameraEnabled,
              'isMuted': session.isMuted,
              'isGroup': session.isGroup,
              'groupId': session.groupId,
              'participants': session.participantAddresses,
            },
      'groupCalls': <String, dynamic>{
        for (final OngoingGroupCall call in social.groupCalls.values)
          call.groupId: <String, dynamic>{
            'callId': call.callId,
            'kind': call.kind.name,
            'participants': call.participantAddresses,
            'cameraOn': call.cameraOn.toList(),
          },
      },
      'groupCallMedia': <String, dynamic>{
        'activeCallId': groupMedia.activeCallId,
        'hasLocalVideo': groupMedia.hasLocalVideo,
        'peers': <String, dynamic>{
          for (final GroupCallPeerView peer in groupMedia.peers.values)
            peer.address: <String, dynamic>{
              'state': peer.state.name,
              'hasVideo': peer.hasVideo,
            },
        },
      },
      'callMedia': <String, dynamic>{
        'activeCallId': callMedia.activeCallId,
        'activeKind': callMedia.activeKind?.name,
        'hasLocalVideo': callMedia.hasLocalVideo,
        'hasRemoteVideo': callMedia.hasRemoteVideo,
        'hasLocalStream': callMedia.hasLocalStream,
        'hasRemoteStream': callMedia.hasRemoteStream,
        'diagnostics': await callMedia.dumpDiagnostics(),
      },
      'friends': social.friends.values.map((FriendProfile f) {
        return <String, dynamic>{
          'address': f.address,
          'displayName': f.displayName,
          'displayLabel': f.displayLabel,
          'status': f.status.name,
          'isOnline': f.isOnline,
          'unreadCount': f.unreadCount,
          'lastMessagePreview': f.lastMessagePreview,
        };
      }).toList(),
      'groups': social.groups.values.map((GroupProfile g) {
        return <String, dynamic>{
          'id': g.id,
          'name': g.name,
          'members': g.memberAddresses,
          'isInvitePending': g.isInvitePending,
        };
      }).toList(),
      'security': <String, dynamic>{
        'isLocked': security.isLocked,
        'hasPassword': security.hasPassword,
      },
      'window':
          (!kIsWeb &&
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS))
          ? <String, dynamic>{
              'id': await windowManager.getId(),
              'isVisible': await windowManager.isVisible(),
              'isPreventClose': await windowManager.isPreventClose(),
            }
          : null,
    };

    request.response.write(jsonEncode(data));
    await request.response.close();
  }

  Future<void> _handleGetMessages(HttpRequest request) async {
    final String? peerAddress = request.uri.queryParameters['peerAddress'];
    if (peerAddress == null || peerAddress.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': 'Missing peerAddress parameter',
        }),
      );
      await request.response.close();
      return;
    }

    final MessageTimelineStore store = _ref.read(messageTimelineStoreProvider);
    final List<ChatMessage> list = await store.load(peerAddress);

    request.response.write(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'peerAddress': peerAddress,
        'messages': list
            .map(
              (ChatMessage m) => <String, dynamic>{
                'id': m.id,
                'sender': m.sender,
                'text': m.text,
                'sentAtMillis': m.sentAtMillis,
                'direction': m.direction.name,
                'deliveryState': m.deliveryState.name,
                'type': m.type.name,
              },
            )
            .toList(),
      }),
    );
    await request.response.close();
  }

  Future<void> _handleSendMessage(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    final String text = body['text'] as String? ?? '';
    if (peerAddress.isEmpty || text.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': 'peerAddress and text required',
        }),
      );
      await request.response.close();
      return;
    }

    await _ref
        .read(socialHubControllerProvider.notifier)
        .sendLocalMessage(peerAddress: peerAddress, text: text);

    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleTyping(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    final bool isTyping = body['isTyping'] as bool? ?? false;
    await _ref
        .read(socialHubControllerProvider.notifier)
        .sendTypingState(peerAddress: peerAddress, isTyping: isTyping);

    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleSendAttachment(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    final String fileName = body['fileName'] as String? ?? 'test.txt';
    final String content = body['content'] as String? ?? 'attachment content';

    await _ref
        .read(socialHubControllerProvider.notifier)
        .sendLocalAttachment(
          peerAddress: peerAddress,
          fileName: fileName,
          bytes: Uint8List.fromList(utf8.encode(content)),
        );

    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleFriendRequest(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String rawTarget =
        body['target'] as String? ?? body['peerAddress'] as String? ?? '';
    final String? displayName = body['displayName'] as String?;

    String targetAddress = rawTarget;
    String targetName = displayName ?? 'Znajomy';

    try {
      final PeerDialTarget parsed = PeerShareCodec.parseTarget(rawTarget);
      targetAddress = parsed.address;
      if (parsed.displayName.isNotEmpty &&
          (displayName == null || displayName.isEmpty)) {
        targetName = parsed.displayName;
      }
    } catch (_) {
      targetAddress = PeerShareCodec.normalizeAddress(rawTarget);
    }

    await _ref
        .read(socialHubControllerProvider.notifier)
        .sendFriendRequest(peerAddress: targetAddress, knownName: targetName);

    request.response.write(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'peerAddress': targetAddress,
        'displayName': targetName,
      }),
    );
    await request.response.close();
  }

  Future<void> _handleFriendAccept(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    await _ref
        .read(socialHubControllerProvider.notifier)
        .acceptFriendRequest(peerAddress: peerAddress);

    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleFriendReject(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    await _ref
        .read(socialHubControllerProvider.notifier)
        .rejectFriendRequest(peerAddress: peerAddress);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleFriendRemove(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    await _ref
        .read(socialHubControllerProvider.notifier)
        .removeFriend(peerAddress: peerAddress);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleFriendBlock(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    await _ref
        .read(socialHubControllerProvider.notifier)
        .blockFriend(peerAddress: peerAddress);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleFriendUnblock(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    await _ref
        .read(socialHubControllerProvider.notifier)
        .unblockFriend(peerAddress: peerAddress);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleFriendNickname(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    final String nickname =
        body['nickname'] as String? ?? body['displayName'] as String? ?? '';
    await _ref
        .read(socialHubControllerProvider.notifier)
        .setFriendNickname(peerAddress: peerAddress, nickname: nickname);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleGroupCreate(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String name = body['name'] as String? ?? 'Nowa Grupa';
    final String description = body['description'] as String? ?? '';
    final List<dynamic> rawMembers =
        body['memberAddresses'] as List<dynamic>? ?? <dynamic>[];
    final List<String> memberAddresses = rawMembers
        .map((dynamic e) => e.toString())
        .toList();

    final GroupProfile group = await _ref
        .read(socialHubControllerProvider.notifier)
        .createGroup(
          name: name,
          description: description,
          memberAddresses: memberAddresses,
        );

    request.response.write(
      jsonEncode(<String, dynamic>{
        'ok': true,
        'groupId': group.id,
        'name': group.name,
        'members': group.memberAddresses,
      }),
    );
    await request.response.close();
  }

  Future<void> _handleGroupSend(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String groupId = body['groupId'] as String? ?? '';
    final String text = body['text'] as String? ?? '';

    await _ref
        .read(socialHubControllerProvider.notifier)
        .sendGroupMessage(groupId: groupId, text: text);

    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleCallStart(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = body['peerAddress'] as String? ?? '';
    final String rawKind = body['kind'] as String? ?? 'audio';
    final CallInviteKind kind = rawKind == 'video'
        ? CallInviteKind.video
        : CallInviteKind.audio;

    await _ref
        .read(socialHubControllerProvider.notifier)
        .sendCallInvite(peerAddress: peerAddress, kind: kind);

    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleCallAccept(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = _peerOrActiveCall(body);
    await _ref
        .read(socialHubControllerProvider.notifier)
        .acceptIncomingCall(peerAddress: peerAddress);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleCallDecline(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = _peerOrActiveCall(body);
    await _ref
        .read(socialHubControllerProvider.notifier)
        .declineIncomingCall(peerAddress: peerAddress);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleCallEnd(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String peerAddress = _peerOrActiveCall(body);
    await _ref
        .read(socialHubControllerProvider.notifier)
        .endActiveCall(peerAddress: peerAddress);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  /// The call to act on: the one named, or else whatever call is up.
  String _peerOrActiveCall(Map<String, dynamic> body) {
    final String named = body['peerAddress'] as String? ?? '';
    if (named.isNotEmpty) {
      return named;
    }
    return _ref.read(socialHubControllerProvider).activeCall?.peerAddress ?? '';
  }

  /// The group named in [body], or else the first group the user is in.
  String? _groupOrFirst(Map<String, dynamic> body) {
    final String named = body['groupId'] as String? ?? '';
    if (named.isNotEmpty) {
      return named;
    }
    final List<GroupProfile> groups = _ref
        .read(socialHubControllerProvider)
        .groupList;
    return groups.isEmpty ? null : groups.first.id;
  }

  Future<void> _handleGroupCallStart(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String? groupId = _groupOrFirst(body);
    if (groupId == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(
        jsonEncode(<String, dynamic>{'ok': false, 'error': 'No group'}),
      );
      await request.response.close();
      return;
    }
    await _ref
        .read(socialHubControllerProvider.notifier)
        .startGroupCall(
          groupId: groupId,
          kind: body['kind'] == 'video'
              ? CallInviteKind.video
              : CallInviteKind.audio,
        );
    request.response.write(
      jsonEncode(<String, dynamic>{'ok': true, 'groupId': groupId}),
    );
    await request.response.close();
  }

  Future<void> _handleGroupCallJoin(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final SocialHubState social = _ref.read(socialHubControllerProvider);
    final String named = body['groupId'] as String? ?? '';
    final String? groupId = named.isNotEmpty
        ? named
        : (social.groupCalls.isEmpty ? null : social.groupCalls.keys.first);
    if (groupId == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write(
        jsonEncode(<String, dynamic>{
          'ok': false,
          'error': 'No running group call',
        }),
      );
      await request.response.close();
      return;
    }
    await _ref
        .read(socialHubControllerProvider.notifier)
        .joinGroupCall(groupId: groupId, video: body['kind'] == 'video');
    request.response.write(
      jsonEncode(<String, dynamic>{'ok': true, 'groupId': groupId}),
    );
    await request.response.close();
  }

  Future<void> _handleCallToggleMute(HttpRequest request) async {
    await _ref
        .read(socialHubControllerProvider.notifier)
        .toggleActiveCallMute();
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleCallToggleSpeaker(HttpRequest request) async {
    await _ref
        .read(socialHubControllerProvider.notifier)
        .toggleActiveCallSpeaker();
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleCallToggleCamera(HttpRequest request) async {
    await _ref
        .read(socialHubControllerProvider.notifier)
        .toggleActiveCallCamera();
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleCallSwitchCamera(HttpRequest request) async {
    await _ref.read(callMediaSessionControllerProvider).switchCamera();
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  Future<void> _handleThemeChange(
    HttpRequest request,
    Map<String, dynamic> body,
  ) async {
    final String mode = body['mode'] as String? ?? 'system';
    final AppThemeMode themeMode = switch (mode) {
      'light' => AppThemeMode.light,
      'dark' => AppThemeMode.dark,
      _ => AppThemeMode.system,
    };
    await _ref
        .read(appSettingsControllerProvider.notifier)
        .setThemeMode(themeMode);
    request.response.write(jsonEncode(<String, dynamic>{'ok': true}));
    await request.response.close();
  }

  void dispose() {
    _server?.close(force: true);
    _server = null;
  }
}

class TestHarnessBridge extends ConsumerStatefulWidget {
  const TestHarnessBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<TestHarnessBridge> createState() => _TestHarnessBridgeState();
}

class _TestHarnessBridgeState extends ConsumerState<TestHarnessBridge> {
  TestHarnessServer? _server;

  @override
  void initState() {
    super.initState();
    // A remote control for the app: debug builds only. Profile builds are
    // installed on real phones too (performance testing), so "not release"
    // was not enough.
    if (!kDebugMode) {
      return;
    }
    _server = TestHarnessServer(ref);
    _server?.start();
  }

  @override
  void dispose() {
    _server?.dispose();
    _server = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
