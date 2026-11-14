import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/calls/call_media_session.dart';

/// Switching the camera off in a running call: the phone that switches it
/// off offers its camera section `recvonly`; the other phone, its camera
/// still on, used to answer `sendrecv`, which the first phone's WebRTC
/// refused ("Incompatible send direction") and the call ended.
void main() {
  // The shape of what the phones send (directions as in the technical log
  // of such a call): audio, the camera, and optionally the screen slot.
  String sdp({
    required String camera,
    String? screen,
    String screenMsid = '',
  }) =>
      'v=0\r\n'
      'o=- 1 2 IN IP4 127.0.0.1\r\n'
      's=-\r\n'
      't=0 0\r\n'
      'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
      'a=mid:0\r\n'
      'a=sendrecv\r\n'
      'm=video 9 UDP/TLS/RTP/SAVPF 96 97\r\n'
      'a=mid:1\r\n'
      'a=$camera\r\n'
      'a=rtpmap:96 VP8/90000\r\n'
      '${screen == null ? '' : 'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
                'a=mid:2\r\n'
                'a=$screen\r\n'
                '$screenMsid'}';

  /// The camera section of [value] (between the second and third `m=`).
  String cameraSection(String value) => value.split('m=')[2];

  group('the answer of a phone whose camera is on', () {
    test('to an offer whose camera was switched off sends only', () {
      final String offer = sdp(camera: 'recvonly');
      final String sent = localCallSdpToSend(
        sdp: sdp(camera: 'sendrecv'),
        type: 'answer',
        cameraWanted: true,
        remoteOffer: offer,
      );
      expect(cameraSectionDirection(sent), 'sendonly');
      expect(cameraSection(sent), isNot(contains('a=sendrecv')));
      // The same answer as WebRTC made it, recvonly where the platform
      // had no camera track bound yet, also sends only.
      expect(
        cameraSectionDirection(
          localCallSdpToSend(
            sdp: sdp(camera: 'recvonly'),
            type: 'answer',
            cameraWanted: true,
            remoteOffer: offer,
          ),
        ),
        'sendonly',
      );
      // Audio stays as it was: the call goes on with sound.
      expect(sent.split('m=')[1], contains('a=sendrecv'));
      expect(sent, contains('\r\n'));
    });

    test('to an offer with the camera on sends and receives', () {
      expect(
        cameraSectionDirection(
          localCallSdpToSend(
            sdp: sdp(camera: 'recvonly'),
            type: 'answer',
            cameraWanted: true,
            remoteOffer: sdp(camera: 'sendrecv'),
          ),
        ),
        'sendrecv',
      );
    });

    test('leaves the screen slot as WebRTC made it', () {
      final String sent = localCallSdpToSend(
        sdp: sdp(camera: 'sendrecv', screen: 'recvonly'),
        type: 'answer',
        cameraWanted: true,
        remoteOffer: sdp(camera: 'recvonly', screen: 'recvonly'),
      );
      expect(cameraSectionDirection(sent), 'sendonly');
      expect(sent.split('m=')[3], contains('a=recvonly'));
      expect(sent.split('m=')[3], isNot(contains('a=send')));
    });
  });

  test('a phone with its camera off answers as WebRTC made it', () {
    final String answer = sdp(camera: 'inactive');
    expect(
      localCallSdpToSend(
        sdp: answer,
        type: 'answer',
        cameraWanted: false,
        remoteOffer: sdp(camera: 'recvonly'),
      ),
      answer,
    );
  });

  test('an offer with the camera on always offers it both ways', () {
    // Whatever the other side did last: an offer is not cut to anything.
    expect(
      cameraSectionDirection(
        localCallSdpToSend(
          sdp: sdp(camera: 'recvonly'),
          type: 'offer',
          cameraWanted: true,
          remoteOffer: sdp(camera: 'recvonly'),
        ),
      ),
      'sendrecv',
    );
  });

  test('the camera switched off and on again many times keeps every '
      'answer acceptable', () {
    // Phone A switches its camera; phone B keeps its own on. Each of B's
    // answers must fit A's offer, or A refuses it and the call ends.
    for (int round = 0; round < 6; round++) {
      final bool aCameraOn = round.isOdd;
      final String offer = sdp(camera: aCameraOn ? 'sendrecv' : 'recvonly');
      final String answer = localCallSdpToSend(
        sdp: sdp(camera: 'sendrecv'),
        type: 'answer',
        cameraWanted: true,
        remoteOffer: offer,
      );
      expect(
        cameraSectionDirection(answer),
        aCameraOn ? 'sendrecv' : 'sendonly',
        reason: 'round $round',
      );
      // Nothing to cut: the answer already fits the offer.
      expect(fitCameraAnswerToOffer(answer, offer), answer);
    }
  });

  group('an answer that asks for more than our offer allowed', () {
    test('is cut to it (a phone before the fix answering sendrecv)', () {
      final String fitted = fitCameraAnswerToOffer(
        sdp(camera: 'sendrecv', screen: 'recvonly'),
        sdp(camera: 'recvonly', screen: 'recvonly'),
      );
      expect(cameraSectionDirection(fitted), 'sendonly');
      expect(fitted.split('m=')[3], contains('a=recvonly'));
    });

    test('is cut both ways', () {
      expect(
        cameraSectionDirection(
          fitCameraAnswerToOffer(
            sdp(camera: 'sendrecv'),
            sdp(camera: 'sendonly'),
          ),
        ),
        'recvonly',
      );
      expect(
        cameraSectionDirection(
          fitCameraAnswerToOffer(
            sdp(camera: 'sendrecv'),
            sdp(camera: 'inactive'),
          ),
        ),
        'inactive',
      );
      expect(
        cameraSectionDirection(
          fitCameraAnswerToOffer(
            sdp(camera: 'recvonly'),
            sdp(camera: 'recvonly'),
          ),
        ),
        'inactive',
      );
    });

    test('a fitting answer is left exactly as it came', () {
      for (final String answered in <String>[
        'sendrecv',
        'sendonly',
        'recvonly',
        'inactive',
      ]) {
        final String answer = sdp(camera: answered);
        expect(fitCameraAnswerToOffer(answer, sdp(camera: 'sendrecv')), answer);
      }
      final String noVideo = sdp(
        camera: 'sendrecv',
      ).split('m=video').first.trimRight();
      expect(fitCameraAnswerToOffer(noVideo, sdp(camera: 'recvonly')), noVideo);
    });
  });

  test('the camera direction of an SDP', () {
    expect(cameraSectionDirection(sdp(camera: 'recvonly')), 'recvonly');
    expect(
      cameraSectionDirection(sdp(camera: 'sendonly', screen: 'sendrecv')),
      'sendonly',
    );
    // No direction named: the SDP default.
    expect(
      cameraSectionDirection('v=0\nm=video 9 UDP/TLS/RTP/SAVPF 96\na=mid:1\n'),
      'sendrecv',
    );
    expect(
      cameraSectionDirection(
        'v=0\nm=video 9 UDP/TLS/RTP/SAVPF 96\na=mid:1\nm=audio 9 x 1\n'
        'a=recvonly\n',
      ),
      'sendrecv',
    );
    expect(
      cameraSectionDirection('v=0\nm=audio 9 x 111\na=sendrecv\n'),
      isNull,
    );
    expect(cameraSectionDirection(''), isNull);
  });
}
