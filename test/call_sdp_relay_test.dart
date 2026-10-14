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
}
