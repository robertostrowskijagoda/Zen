import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/call_recordings.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// Where one participant's connection stands.
enum GroupCallLegState { connecting, connected, failed }

/// What the call screen shows for one remote participant.
@immutable
final class GroupCallPeerView {
  const GroupCallPeerView({
    required this.address,
    required this.state,
    this.renderer,
    this.hasVideo = false,
    this.sharingScreen = false,
    this.screenRenderer,
  });

  final String address;
  final GroupCallLegState state;

  /// The participant's camera.
  final RTCVideoRenderer? renderer;
  final bool hasVideo;

  /// This participant shares its screen (or one app), next to its camera.
  final bool sharingScreen;

  /// The shared screen, once its picture is there.
  final RTCVideoRenderer? screenRenderer;
}

/// Sends one group-call media payload (`gc_offer` / `gc_answer`) to [peer].
typedef GroupCallSignalSender =
    Future<void> Function(String peer, Map<String, dynamic> payload);

/// Reports a participant's connection changing.
typedef GroupCallLegListener =
    void Function(String callId, String peer, GroupCallLegState state);

/// Media for one group call: a full mesh, one peer connection ("leg") per
/// remote participant, all fed from one shared microphone/camera.
///
/// Signalling decides *who* is in the call; this only builds and tears down
/// the legs it is told about. Camera on/off and screen sharing never
/// renegotiate: every leg is negotiated with two video slots from the start
/// (camera, then screen) and the tracks are swapped in and out, so two
/// people toggling at once cannot collide.
abstract class GroupCallMedia extends ChangeNotifier {
  String? get activeCallId;

  GroupCallSignalSender? sendSignal;
  GroupCallLegListener? onLegState;

  RTCVideoRenderer? get localRenderer;
  bool get hasLocalVideo;

  /// Remote participants the media knows about, by address.
  Map<String, GroupCallPeerView> get peers;

  bool hasLeg(String peer) => peers.containsKey(peer);

  GroupCallLegState? legState(String peer) => peers[peer]?.state;

  /// Opens the microphone (and the camera when [cameraOn]) for [callId].
  /// [localAddress] names this end of every leg.
  Future<void> start({
    required String callId,
    required String groupId,
    required String localAddress,
    required CallInviteKind kind,
    required bool cameraOn,
  });

  /// Starts a leg to [peer] as the offering side.
  Future<void> connectTo(String peer);

  /// Answers [peer]'s offer: a new leg, or the same answer again when the
  /// offer is a repeat.
  Future<void> handleOffer(String peer, Map<String, dynamic> description);

  Future<void> handleAnswer(String peer, Map<String, dynamic> description);

  /// Sends the pending offer to [peer] again (it travels as a datagram).
  Future<void> resendOffer(String peer);

  /// Closes the leg to [peer].
  Future<void> dropPeer(String peer);

  /// What [peer] says about its camera; drives whether its tile shows video.
  void setRemoteCamera(String peer, bool on);

  Future<void> setMuted(bool muted);
  Future<void> setSpeakerOn(bool enabled);
  Future<void> setCameraEnabled(bool enabled);
  Future<void> switchCamera();

  /// Screen sharing (§13.1): the shared screen goes out on every leg's
  /// screen slot, the camera stays on; everyone is told who shares.
  bool get isScreenSharing => false;

  Future<List<ScreenShareSource>> listScreenSources() async =>
      const <ScreenShareSource>[];

  Future<void> startScreenShare({String? sourceId}) async {
    throw UnsupportedError(t('Udostępnianie ekranu nie jest tu dostępne.'));
  }

  Future<void> stopScreenShare() async {}

  /// Recording (§13.2), always announced to everyone in the call.
  bool get canRecord => false;
  bool get isRecording => false;

  /// Participants who are recording this call right now.
  Set<String> get recordingPeers => const <String>{};

  /// File type of recordings on this device ("mp4", "wav").
  String get recordingExtension => 'mp4';

  /// Starts recording what this device hears into [path]; [label] names
  /// the recording (the group).
  Future<void> startRecording(String path, {String label = ''}) async {
    throw UnsupportedError(t('Nagrywanie nie jest tu dostępne.'));
  }

  /// Stops recording; returns the file path, or null when nothing ran.
  Future<String?> stopRecording() async => null;

  /// Gets every finished recording to be kept (encrypted) in the app.
  CallRecordingFinished? onRecordingFinished;

  Future<void> close();
}

/// The relay id of the leg between [a] and [b] in [callId]: the same string
/// on both ends (the bridge matches relay frames by it), unique per pair.
String groupCallLegId(String callId, String a, String b) {
  final List<String> pair = <String>[a.toLowerCase(), b.toLowerCase()]..sort();
  // FNV-1a, 64 bit: short, stable across platforms and isolates.
  BigInt hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final BigInt prime = BigInt.parse('100000001b3', radix: 16);
  final BigInt mask = (BigInt.one << 64) - BigInt.one;
  for (final int byte in utf8.encode(pair.join('|'))) {
    hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
  }
  return '$callId~${hash.toRadixString(16).padLeft(16, '0')}';
}

final Provider<GroupCallMedia> groupCallMediaProvider =
    Provider<GroupCallMedia>((Ref ref) {
      final GroupCallMedia media = WebRtcGroupCallMedia(
        transport: ref.read(signalTransportProvider),
      );
      media.onRecordingFinished = (String path, String mime, String label) =>
          unawaitedLogged(
            keepCallRecording(
              ref.read(ledgerDiskProvider),
              path: path,
              mime: mime,
              label: label,
            ),
            context: 'Saving the group call recording failed',
          );
      ref.onDispose(media.dispose);
      return media;
    });

/// In-memory stand-in: legs "connect" once offer and answer have crossed,
/// which is enough to exercise all of the signalling end to end.
final class FakeGroupCallMedia extends GroupCallMedia {
  FakeGroupCallMedia({this.failStart = false});

  final bool failStart;
  String? _callId;
  String? _groupId;
  CallInviteKind _kind = CallInviteKind.audio;
  bool muted = false;
  bool cameraOn = false;
  bool speakerOn = false;
  final Map<String, GroupCallLegState> _legs = <String, GroupCallLegState>{};
  final Map<String, bool> _remoteCamera = <String, bool>{};
  final Map<String, String> _lastOfferSdp = <String, String>{};
  final Map<String, bool> _offering = <String, bool>{};

  /// Every offer that went out, by peer (repeats included).
  final Map<String, int> offersSent = <String, int>{};
  int answersSent = 0;
  int startCount = 0;
  int closeCount = 0;

  @override
  String? get activeCallId => _callId;

  @override
  RTCVideoRenderer? get localRenderer => null;

  @override
  bool get hasLocalVideo => cameraOn;

  @override
  Map<String, GroupCallPeerView> get peers => <String, GroupCallPeerView>{
    for (final MapEntry<String, GroupCallLegState> e in _legs.entries)
      e.key: GroupCallPeerView(
        address: e.key,
        state: e.value,
        hasVideo: _remoteCamera[e.key] ?? false,
      ),
  };

  List<String> get connectedPeers =>
      _legs.entries
          .where(
            (MapEntry<String, GroupCallLegState> e) =>
                e.value == GroupCallLegState.connected,
          )
          .map((MapEntry<String, GroupCallLegState> e) => e.key)
          .toList()
        ..sort();

  /// Marks a leg as failed, the way a dead network path would.
  void failLeg(String peer) {
    if (_legs.containsKey(peer)) {
      _setLeg(peer, GroupCallLegState.failed);
    }
  }

  @override
  Future<void> start({
    required String callId,
    required String groupId,
    required String localAddress,
    required CallInviteKind kind,
    required bool cameraOn,
  }) async {
    if (failStart) {
      throw StateError('Brak dostępu do mikrofonu.');
    }
    _reset();
    startCount += 1;
    _callId = callId;
    _groupId = groupId;
    _kind = kind;
    this.cameraOn = cameraOn;
    notifyListeners();
  }

  void _setLeg(String peer, GroupCallLegState state) {
    if (_legs[peer] == state) {
      return;
    }
    _legs[peer] = state;
    notifyListeners();
    final String? callId = _callId;
    if (callId != null) {
      onLegState?.call(callId, peer, state);
    }
  }

  Map<String, dynamic> _payload(String type, String sdp) => <String, dynamic>{
    'type': type,
    'callId': _callId,
    'groupId': _groupId,
    'kind': _kind.name,
    'description': <String, dynamic>{
      'type': type == 'gc_offer' ? 'offer' : 'answer',
      'sdp': sdp,
    },
  };

  @override
  Future<void> connectTo(String peer) async {
    if (_callId == null) {
      return;
    }
    _offering[peer] = true;
    _setLeg(peer, GroupCallLegState.connecting);
    final String sdp = 'offer:$_callId:$peer:${offersSent[peer] ?? 0}';
    _lastOfferSdp[peer] = sdp;
    offersSent[peer] = (offersSent[peer] ?? 0) + 1;
    await sendSignal?.call(peer, _payload('gc_offer', sdp));
  }

  @override
  Future<void> resendOffer(String peer) async {
    final String? sdp = _lastOfferSdp[peer];
    if (_callId == null || sdp == null || _offering[peer] != true) {
      return;
    }
    offersSent[peer] = (offersSent[peer] ?? 0) + 1;
    await sendSignal?.call(peer, _payload('gc_offer', sdp));
  }

  @override
  Future<void> handleOffer(
    String peer,
    Map<String, dynamic> description,
  ) async {
    if (_callId == null) {
      return;
    }
    _offering[peer] = false;
    answersSent += 1;
    _setLeg(peer, GroupCallLegState.connected);
    await sendSignal?.call(
      peer,
      _payload('gc_answer', 'answer:${description['sdp']}'),
    );
  }

  @override
  Future<void> handleAnswer(
    String peer,
    Map<String, dynamic> description,
  ) async {
    if (_callId == null || _offering[peer] != true) {
      return;
    }
    _offering[peer] = false;
    _setLeg(peer, GroupCallLegState.connected);
  }

  @override
  Future<void> dropPeer(String peer) async {
    _offering.remove(peer);
    _lastOfferSdp.remove(peer);
    if (_legs.remove(peer) != null) {
      notifyListeners();
    }
  }

  @override
  void setRemoteCamera(String peer, bool on) {
    _remoteCamera[peer] = on;
    notifyListeners();
  }

  @override
  Future<void> setMuted(bool muted) async {
    this.muted = muted;
  }

  @override
  Future<void> setSpeakerOn(bool enabled) async {
    speakerOn = enabled;
  }

  @override
  Future<void> setCameraEnabled(bool enabled) async {
    cameraOn = enabled;
    notifyListeners();
  }

  @override
  Future<void> switchCamera() async {}

  @override
  Future<void> close() async {
    closeCount += 1;
    _reset();
  }

  void _reset() {
    _callId = null;
    _legs.clear();
    _offering.clear();
    _lastOfferSdp.clear();
    _remoteCamera.clear();
    cameraOn = false;
    muted = false;
    notifyListeners();
  }
}
