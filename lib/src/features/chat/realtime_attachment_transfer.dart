import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/runtime/relay_candidate.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

const int kRealtimeAttachmentChunkSizeBytes = 64 * 1024;
const int kRealtimeAttachmentBufferedAmountLimitBytes = 2 * 1024 * 1024;
const Duration kRealtimeAttachmentBufferedAmountBackoff = Duration(
  milliseconds: 6,
);
const Duration kRealtimeAttachmentProgressInterval = Duration(
  milliseconds: 120,
);
const double kRealtimeAttachmentProgressDelta = 0.01;
const Duration kRealtimeAttachmentHandshakeTimeout = Duration(seconds: 12);
const Duration kRealtimeAttachmentSessionTimeout = Duration(seconds: 45);
const Duration kRealtimeAttachmentYieldDelay = Duration(milliseconds: 1);

/// Incoming realtime transfers open at once, per peer and in total. Each one
/// holds a peer connection and buffers the whole file in memory.
const int kMaxConcurrentRealtimeTransfersPerPeer = 4;
const int kMaxConcurrentRealtimeTransfers = 16;

bool shouldEmitRealtimeAttachmentProgressUpdate({
  required double previousProgress,
  required double nextProgress,
  required Duration elapsedSinceLastUpdate,
}) {
  if (nextProgress >= 1 || previousProgress < 0) {
    return true;
  }
  if (nextProgress <= previousProgress) {
    return false;
  }
  return (nextProgress - previousProgress) >=
          kRealtimeAttachmentProgressDelta ||
      elapsedSinceLastUpdate >= kRealtimeAttachmentProgressInterval;
}

abstract interface class RealtimeAttachmentTransferSession {
  ValueChanged<double>? get onProgress;
  set onProgress(ValueChanged<double>? value);

  ValueChanged<Uint8List>? get onComplete;
  set onComplete(ValueChanged<Uint8List>? value);

  ValueChanged<Object>? get onError;
  set onError(ValueChanged<Object>? value);

  Future<void> send({
    required Uint8List bytes,
    required String text,
    required ChatMessageType type,
    String? fileName,
    String? mimeType,
    int? attachmentSizeBytes,
    int? durationMs,
  });

  Future<void> acceptIncoming({
    required Map<String, dynamic> description,
    required int fileSize,
  });

  Future<void> applyRemoteAnswer(Map<String, dynamic> description);

  Future<void> close();
}

typedef CreateRealtimeAttachmentTransferSession =
    RealtimeAttachmentTransferSession Function({
      required String transferId,
      required String remoteAddress,
    });

final Provider<CreateRealtimeAttachmentTransferSession>
realtimeAttachmentTransferFactoryProvider =
    Provider<CreateRealtimeAttachmentTransferSession>((Ref ref) {
      final SignalTransport transport = ref.read(signalTransportProvider);
      return ({required String transferId, required String remoteAddress}) {
        return WebRtcRealtimeAttachmentTransferSession(
          transferId: transferId,
          remoteAddress: remoteAddress,
          transport: transport,
        );
      };
    });

final class WebRtcRealtimeAttachmentTransferSession
    implements RealtimeAttachmentTransferSession {
  WebRtcRealtimeAttachmentTransferSession({
    required this.transferId,
    required this.remoteAddress,
    required this.transport,
  });

  final String transferId;
  final String remoteAddress;
  final SignalTransport transport;

  @override
  ValueChanged<double>? onProgress;

  @override
  ValueChanged<Uint8List>? onComplete;

  @override
  ValueChanged<Object>? onError;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  Completer<void>? _remoteAnswerCompleter;
  Completer<void>? _sendCompleter;
  Map<int, Uint8List> _incomingChunks = <int, Uint8List>{};
  int _incomingExpectedBytes = 0;
  int _incomingReceivedBytes = 0;
  int? _relayPort;
  String? _relaySdpMid;
  int _relaySdpMLineIndex = 0;
  bool _relayCandidateAdded = false;
  bool _outgoingStarted = false;
  double _lastProgress = -1;
  DateTime? _lastProgressAt;
  Timer? _sessionTimeout;

  @override
  Future<void> send({
    required Uint8List bytes,
    required String text,
    required ChatMessageType type,
    String? fileName,
    String? mimeType,
    int? attachmentSizeBytes,
    int? durationMs,
  }) async {
    final Completer<void> sendCompleter = Completer<void>();
    _sendCompleter = sendCompleter;
    _remoteAnswerCompleter = Completer<void>();
    try {
      await _prepareConnection();
      final RTCDataChannel channel = await _peerConnection!.createDataChannel(
        'zen-attachment',
        RTCDataChannelInit()
          ..ordered = true
          ..maxRetransmits = -1,
      );
      _bindOutgoingChannel(channel, bytes);
      final RTCSessionDescription offer = await _peerConnection!.createOffer(
        <String, dynamic>{},
      );
      _captureRelayMetadata(offer.sdp);
      await _peerConnection!.setLocalDescription(offer);
      await transport.send(
        remoteAddress: remoteAddress,
        payload: <String, dynamic>{
          'type': 'transfer_offer',
          'transferId': transferId,
          'description': <String, dynamic>{
            'sdp': offer.sdp,
            'type': offer.type,
          },
          'text': text,
          'messageType': type.name,
          'fileName': fileName,
          'mimeType': mimeType,
          'attachmentSizeBytes': attachmentSizeBytes,
          'durationMs': durationMs,
          'fileSize': bytes.length,
        },
      );
      await _remoteAnswerCompleter!.future.timeout(
        kRealtimeAttachmentHandshakeTimeout,
      );
      await sendCompleter.future.timeout(kRealtimeAttachmentSessionTimeout);
    } catch (error) {
      onError?.call(error);
      await close();
      rethrow;
    }
  }

  @override
  Future<void> acceptIncoming({
    required Map<String, dynamic> description,
    required int fileSize,
  }) async {
    try {
      if (fileSize <= 0 || fileSize > kMaxIncomingAttachmentBytes) {
        // The whole file is buffered in memory: refuse what no real
        // attachment can be before opening anything.
        throw FormatException('Unacceptable realtime transfer size: $fileSize');
      }
      await _prepareConnection();
      _incomingExpectedBytes = fileSize;
      _incomingReceivedBytes = 0;
      _incomingChunks = <int, Uint8List>{};
      _peerConnection!.onDataChannel = (RTCDataChannel channel) {
        _bindIncomingChannel(channel);
      };
      await _peerConnection!.setRemoteDescription(
        RTCSessionDescription(
          _readDescriptionValue(description, 'sdp'),
          _readDescriptionValue(description, 'type'),
        ),
      );
      final RTCSessionDescription answer = await _peerConnection!.createAnswer(
        <String, dynamic>{},
      );
      _captureRelayMetadata(answer.sdp);
      await _peerConnection!.setLocalDescription(answer);
      await _ensureRelayCandidate();
      await transport.send(
        remoteAddress: remoteAddress,
        payload: <String, dynamic>{
          'type': 'transfer_answer',
          'transferId': transferId,
          'description': <String, dynamic>{
            'sdp': answer.sdp,
            'type': answer.type,
          },
        },
      );
    } catch (error) {
      onError?.call(error);
      await close();
      rethrow;
    }
  }

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {
    final RTCPeerConnection? connection = _peerConnection;
    if (connection == null) {
      return;
    }
    await connection.setRemoteDescription(
      RTCSessionDescription(
        _readDescriptionValue(description, 'sdp'),
        _readDescriptionValue(description, 'type'),
      ),
    );
    await _ensureRelayCandidate();
    final Completer<void>? answerCompleter = _remoteAnswerCompleter;
    if (answerCompleter != null && !answerCompleter.isCompleted) {
      answerCompleter.complete();
    }
  }

  Future<void> _prepareConnection() async {
    await close();
    _resetProgress();
    _relayCandidateAdded = false;
    _relaySdpMid = null;
    _relaySdpMLineIndex = 0;
    _outgoingStarted = false;
    _relayPort = await transport.openRelay(
      callId: transferId,
      remoteAddress: remoteAddress,
    );
    if ((_relayPort ?? 0) <= 0) {
      throw StateError('WebRTC relay is unavailable for attachment transfer.');
    }
    _peerConnection = await createPeerConnection(<String, dynamic>{
      'iceServers': const <Object>[],
      'sdpSemantics': 'unified-plan',
    });
    _sessionTimeout = Timer(kRealtimeAttachmentSessionTimeout, () {
      onError?.call(
        TimeoutException('Attachment transfer did not complete in time.'),
      );
      unawaited(close());
    });
  }

  void _bindOutgoingChannel(RTCDataChannel channel, Uint8List bytes) {
    _dataChannel = channel;
    channel.bufferedAmountLowThreshold = kRealtimeAttachmentChunkSizeBytes;
    channel.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen &&
          !_outgoingStarted) {
        _outgoingStarted = true;
        unawaited(_streamOutgoingBytes(channel, bytes));
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        final Completer<void>? completer = _sendCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.completeError(
            StateError('Attachment transfer channel closed unexpectedly.'),
          );
        }
      }
    };
  }

  void _bindIncomingChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onMessage = (RTCDataChannelMessage message) {
      if (!message.isBinary || message.binary.length < 4) {
        return;
      }
      final ByteData header = ByteData.sublistView(message.binary, 0, 4);
      final int chunkIndex = header.getUint32(0);
      if (_incomingChunks.containsKey(chunkIndex)) {
        return;
      }
      final Uint8List chunk = Uint8List.sublistView(message.binary, 4);
      final int expectedChunks =
          (_incomingExpectedBytes + kRealtimeAttachmentChunkSizeBytes - 1) ~/
          kRealtimeAttachmentChunkSizeBytes;
      if (chunkIndex >= expectedChunks ||
          chunk.isEmpty ||
          chunk.length > kRealtimeAttachmentChunkSizeBytes ||
          _incomingReceivedBytes + chunk.length > _incomingExpectedBytes) {
        // Not a chunk of the file that was announced: stop buffering
        // whatever else the other side keeps pushing.
        onError?.call(
          StateError('Attachment receive channel sent an invalid chunk.'),
        );
        unawaited(close());
        return;
      }
      _incomingChunks[chunkIndex] = Uint8List.fromList(chunk);
      _incomingReceivedBytes += chunk.length;
      _emitProgress(_incomingReceivedBytes / _incomingExpectedBytes);
      if (_incomingReceivedBytes < _incomingExpectedBytes) {
        return;
      }
      final Uint8List bytes = _assembleIncomingBytes();
      _emitProgress(1, force: true);
      onComplete?.call(bytes);
      unawaited(close());
    };
    channel.onDataChannelState = (RTCDataChannelState state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed &&
          _incomingReceivedBytes < _incomingExpectedBytes) {
        onError?.call(
          StateError('Attachment receive channel closed before completion.'),
        );
        unawaited(close());
      }
    };
  }

  Future<void> _streamOutgoingBytes(
    RTCDataChannel channel,
    Uint8List bytes,
  ) async {
    int offset = 0;
    int chunkIndex = 0;
    try {
      while (offset < bytes.length) {
        if (!identical(channel, _dataChannel) ||
            channel.state != RTCDataChannelState.RTCDataChannelOpen) {
          throw StateError('Attachment transfer channel is no longer open.');
        }
        if (await _currentBufferedAmount(channel) >
            kRealtimeAttachmentBufferedAmountLimitBytes) {
          await Future<void>.delayed(kRealtimeAttachmentBufferedAmountBackoff);
          continue;
        }
        final int end =
            offset + kRealtimeAttachmentChunkSizeBytes < bytes.length
            ? offset + kRealtimeAttachmentChunkSizeBytes
            : bytes.length;
        final Uint8List frame = Uint8List(4 + end - offset);
        frame.buffer.asByteData().setUint32(0, chunkIndex);
        frame.setRange(4, frame.length, bytes, offset);
        await channel.send(RTCDataChannelMessage.fromBinary(frame));
        offset = end;
        chunkIndex += 1;
        _emitProgress(offset / bytes.length);
        if (offset < bytes.length) {
          await Future<void>.delayed(kRealtimeAttachmentYieldDelay);
        }
      }
      await _waitForBufferedDrain(channel);
      _emitProgress(1, force: true);
      final Completer<void>? completer = _sendCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      await close();
    } catch (error, stackTrace) {
      final Completer<void>? completer = _sendCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
      onError?.call(error);
      await close();
    }
  }

  void _captureRelayMetadata(String? sdp) {
    if (sdp == null || sdp.isEmpty) {
      return;
    }
    final List<String> lines = sdp.split('\n');
    for (int index = 0; index < lines.length; index += 1) {
      final String line = lines[index].trim();
      if (!line.startsWith('a=mid:')) {
        continue;
      }
      _relaySdpMid = line.substring(6);
      _relaySdpMLineIndex = 0;
      return;
    }
  }

  Future<void> _ensureRelayCandidate() async {
    if (_relayCandidateAdded ||
        _peerConnection == null ||
        _relayPort == null ||
        _relaySdpMid == null ||
        _relaySdpMid!.isEmpty) {
      return;
    }
    await _peerConnection!.addCandidate(
      RTCIceCandidate(
        buildUdpRelayCandidateSdp(host: kRelayLoopbackHost, port: _relayPort!),
        _relaySdpMid,
        _relaySdpMLineIndex,
      ),
    );
    _relayCandidateAdded = true;
  }

  Future<int> _currentBufferedAmount(RTCDataChannel channel) async {
    final int? bufferedAmount = channel.bufferedAmount;
    if (bufferedAmount != null) {
      return bufferedAmount;
    }
    return channel.getBufferedAmount();
  }

  Future<void> _waitForBufferedDrain(RTCDataChannel channel) async {
    while (identical(channel, _dataChannel) &&
        channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      if (await _currentBufferedAmount(channel) <= 0) {
        return;
      }
      await Future<void>.delayed(kRealtimeAttachmentBufferedAmountBackoff);
    }
  }

  Uint8List _assembleIncomingBytes() {
    final BytesBuilder builder = BytesBuilder(copy: false);
    for (int index = 0; builder.length < _incomingExpectedBytes; index += 1) {
      final Uint8List? chunk = _incomingChunks[index];
      if (chunk == null) {
        throw StateError('Incoming attachment chunk $index is missing.');
      }
      builder.add(chunk);
    }
    final Uint8List bytes = builder.takeBytes();
    return bytes.length == _incomingExpectedBytes
        ? bytes
        : Uint8List.sublistView(bytes, 0, _incomingExpectedBytes);
  }

  void _emitProgress(double progress, {bool force = false}) {
    final double normalized = progress.clamp(0, 1).toDouble();
    final DateTime now = DateTime.now();
    final Duration elapsedSinceLastUpdate = _lastProgressAt == null
        ? Duration.zero
        : now.difference(_lastProgressAt!);
    if (!force &&
        !shouldEmitRealtimeAttachmentProgressUpdate(
          previousProgress: _lastProgress,
          nextProgress: normalized,
          elapsedSinceLastUpdate: elapsedSinceLastUpdate,
        )) {
      return;
    }
    _lastProgress = normalized;
    _lastProgressAt = now;
    onProgress?.call(normalized);
  }

  void _resetProgress() {
    _lastProgress = -1;
    _lastProgressAt = null;
  }

  String _readDescriptionValue(Map<String, dynamic> description, String key) {
    final String value = description[key] as String? ?? '';
    if (value.isEmpty) {
      throw FormatException('Missing "$key" in realtime transfer description.');
    }
    return value;
  }

  @override
  Future<void> close() async {
    _sessionTimeout?.cancel();
    _sessionTimeout = null;
    try {
      await _dataChannel?.close();
    } catch (error, stackTrace) {
      logZenError(
        'Closing realtime transfer data channel failed',
        error,
        stackTrace,
      );
    }
    try {
      await _peerConnection?.close();
      await _peerConnection?.dispose();
    } catch (error, stackTrace) {
      logZenError(
        'Closing realtime transfer peer connection failed',
        error,
        stackTrace,
      );
    }
    if (_relayPort != null) {
      try {
        await transport.closeRelay(transferId);
      } catch (error, stackTrace) {
        logZenError(
          'Closing realtime transfer relay failed',
          error,
          stackTrace,
        );
      }
    }
    _dataChannel = null;
    _peerConnection = null;
    _relayPort = null;
    _relaySdpMid = null;
    _relaySdpMLineIndex = 0;
    _relayCandidateAdded = false;
    _outgoingStarted = false;
    _remoteAnswerCompleter = null;
    _sendCompleter = null;
  }
}
