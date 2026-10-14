import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/features/calls/call_media_session.dart';

final class NoopCallMediaSessionController extends CallMediaSessionController {
  CallMediaStatusListener? _onStatusChanged;
  CallMediaErrorListener? _onError;
  String? _activeCallId;
  String? _remoteAddress;
  CallInviteKind? _activeKind;

  @override
  RTCVideoRenderer? get localRenderer => null;

  @override
  RTCVideoRenderer? get remoteRenderer => null;

  @override
  String? get activeCallId => _activeCallId;

  @override
  String? get remoteAddress => _remoteAddress;

  @override
  CallInviteKind? get activeKind => _activeKind;

  @override
  bool get hasLocalStream => false;

  @override
  bool get hasRemoteStream => false;

  @override
  bool get hasLocalVideo => false;

  @override
  bool get hasRemoteVideo => false;

  @override
  CallMediaStatusListener? get onStatusChanged => _onStatusChanged;

  @override
  set onStatusChanged(CallMediaStatusListener? value) {
    _onStatusChanged = value;
  }

  @override
  CallMediaErrorListener? get onError => _onError;

  @override
  set onError(CallMediaErrorListener? value) {
    _onError = value;
  }

  @override
  Future<void> startOutgoing({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
  }) async {
    _activeCallId = callId;
    _remoteAddress = remoteAddress;
    _activeKind = kind;
    _onStatusChanged?.call(callId, CallMediaSessionLifecycle.active);
  }

  @override
  Future<void> acceptIncoming({
    required String callId,
    required String remoteAddress,
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    _activeCallId = callId;
    _remoteAddress = remoteAddress;
    _activeKind = kind;
    _onStatusChanged?.call(callId, CallMediaSessionLifecycle.active);
  }

  @override
  Future<void> handleRemoteOffer({
    required CallInviteKind kind,
    required Map<String, dynamic> remoteDescription,
  }) async {
    _activeKind = kind;
  }

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {}

  @override
  Future<bool> resendLocalOffer(String callId) async {
    return false;
  }

  @override
  Future<bool> resendLocalAnswer(String callId) async {
    return false;
  }

  @override
  Future<void> setMuted(bool muted) async {}

  @override
  Future<void> setSpeakerOn(bool enabled) async {}

  @override
  Future<void> setCameraEnabled(bool enabled) async {}

  @override
  Future<void> close() async {
    final String? callId = _activeCallId;
    _activeCallId = null;
    _remoteAddress = null;
    _activeKind = null;
    if (callId != null) {
      _onStatusChanged?.call(callId, CallMediaSessionLifecycle.ended);
    }
  }
}
