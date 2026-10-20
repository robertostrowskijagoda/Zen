import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/calls/call_media_session.dart';

void main() {
  test('pinWebRtcSdpToLocalRelay keeps codecs and forces loopback relay', () {
    const String sdp = '''
v=0
o=- 1 2 IN IP4 192.168.1.20
s=-
t=0 0
m=audio 9 UDP/TLS/RTP/SAVPF 111
c=IN IP4 192.168.1.20
a=rtcp:9 IN IP4 192.168.1.20
a=ice-ufrag:abcd
a=ice-pwd:secretpasswordvalue
a=fingerprint:sha-256 AA:BB
a=setup:actpass
a=mid:0
a=candidate:1 1 udp 2122260223 192.168.1.20 54000 typ host
a=end-of-candidates
''';

    final String pinned = pinWebRtcSdpToLocalRelay(sdp, 41234);

    expect(pinned, contains('m=audio 41234 UDP/TLS/RTP/SAVPF 111'));
    expect(pinned, contains('c=IN IP4 127.0.0.1'));
    expect(pinned, contains('a=rtcp:41234 IN IP4 127.0.0.1'));
    expect(
      pinned,
      contains(
        'a=candidate:1 1 udp 2122260223 127.0.0.1 41234 typ host generation 0',
      ),
    );
    expect(pinned, isNot(contains('192.168.1.20')));
    expect(pinned, contains('a=ice-pwd:secretpasswordvalue'));
    expect(pinned, contains('a=fingerprint:sha-256 AA:BB'));
  });

  test(
    'pinWebRtcSdpToLocalRelay cleans video SDP and pins relay port without malformed bandwidth lines',
    () {
      const String sdp = '''
v=0
o=- 1 2 IN IP4 192.168.1.20
s=-
t=0 0
m=video 9 UDP/TLS/RTP/SAVPF 96
b=AS:500
c=IN IP4 192.168.1.20
a=rtcp:9 IN IP4 192.168.1.20
a=ice-ufrag:abcd
a=ice-pwd:secretpasswordvalue
''';

      final String pinned = pinWebRtcSdpToLocalRelay(sdp, 41234);

      expect(pinned, contains('m=video 41234 UDP/TLS/RTP/SAVPF 96'));
      expect(pinned, contains('c=IN IP4 127.0.0.1'));
      expect(pinned, isNot(contains('b=AS:')));
      expect(pinned, isNot(contains('b=TIAS:')));
    },
  );

  const String peerSdp = '''
v=0
o=- 1 2 IN IP4 192.168.1.20
s=-
t=0 0
m=audio 54000 UDP/TLS/RTP/SAVPF 111
c=IN IP4 203.0.113.7
a=rtcp:54001 IN IP4 203.0.113.7
a=rtcp-mux
a=ice-ufrag:abcd
a=ice-pwd:secretpasswordvalue
a=fingerprint:sha-256 AA:BB
a=mid:0
a=candidate:1 1 udp 2122260223 192.168.1.20 54000 typ host
a=candidate:2 1 udp 1686052607 203.0.113.7 54000 typ srflx raddr 192.168.1.20 rport 54000
a=end-of-candidates
''';

  test('stripWebRtcSdpCandidates removes every peer address', () {
    final String stripped = stripWebRtcSdpCandidates(peerSdp);

    expect(stripped, isNot(contains('a=candidate:')));
    expect(stripped, isNot(contains('a=end-of-candidates')));
    expect(stripped, isNot(contains('203.0.113.7')));
    expect(stripped, contains('c=IN IP4 0.0.0.0'));
    expect(stripped, contains('a=rtcp:54001 IN IP4 0.0.0.0'));
    expect(stripped, contains('a=rtcp-mux'));
    expect(stripped, contains('a=ice-pwd:secretpasswordvalue'));
    expect(stripped, contains('a=fingerprint:sha-256 AA:BB'));
    expect(stripped, contains('m=audio 54000 UDP/TLS/RTP/SAVPF 111'));
  });

  group('applyRemoteSdpViaLocalRelay', () {
    test('applies the pinned SDP when the platform accepts it', () async {
      final List<String> applied = <String>[];
      await applyRemoteSdpViaLocalRelay(
        sdp: peerSdp,
        type: 'offer',
        relayPort: 41234,
        apply: (String sdp, String type) async => applied.add(sdp),
      );

      expect(applied, hasLength(1));
      expect(applied.single, contains('m=audio 41234'));
      expect(applied.single, isNot(contains('192.168.1.20 54000')));
    });

    test(
      'retries without peer candidates, never with the original, when the pinned SDP is rejected',
      () async {
        final List<String> attempts = <String>[];
        await applyRemoteSdpViaLocalRelay(
          sdp: peerSdp,
          type: 'answer',
          relayPort: 41234,
          apply: (String sdp, String type) async {
            attempts.add(sdp);
            if (attempts.length == 1) {
              throw StateError('pinned SDP rejected');
            }
          },
        );

        expect(attempts, hasLength(2));
        expect(attempts.last, isNot(equals(peerSdp)));
        expect(attempts.last, isNot(contains('a=candidate:')));
        expect(attempts.last, isNot(contains('192.168.1.20 54000')));
        expect(attempts.last, isNot(contains('203.0.113.7')));
      },
    );

    test('fails the call when the stripped SDP is rejected too', () async {
      final List<String> attempts = <String>[];
      await expectLater(
        applyRemoteSdpViaLocalRelay(
          sdp: peerSdp,
          type: 'offer',
          relayPort: 41234,
          apply: (String sdp, String type) async {
            attempts.add(sdp);
            throw StateError('rejected');
          },
        ),
        throwsStateError,
      );

      expect(attempts, hasLength(2));
      expect(attempts, isNot(contains(peerSdp)));
      for (final String attempt in attempts) {
        expect(attempt, isNot(contains('192.168.1.20 54000')));
      }
    });

    test('refuses to apply anything without a relay port', () async {
      final List<String> attempts = <String>[];
      await expectLater(
        applyRemoteSdpViaLocalRelay(
          sdp: peerSdp,
          type: 'offer',
          relayPort: 0,
          apply: (String sdp, String type) async => attempts.add(sdp),
        ),
        throwsStateError,
      );

      expect(attempts, isEmpty);
    });
  });
}
