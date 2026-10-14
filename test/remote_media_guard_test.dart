import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/chat/remote_media_guard.dart';

void main() {
  test('allows https URLs from the allow-listed catalog hosts', () {
    expect(
      isAllowedRemoteMediaUrl('https://cdn.klipy.com/files/abc.gif'),
      isTrue,
    );
    expect(isAllowedRemoteMediaUrl('https://klipy.com/media/tiny.gif'), isTrue);
  });

  test('rejects schemes, hosts and IP literals outside the allow-list', () {
    expect(isAllowedRemoteMediaUrl(null), isFalse);
    expect(isAllowedRemoteMediaUrl(''), isFalse);
    expect(isAllowedRemoteMediaUrl('http://cdn.klipy.com/file.gif'), isFalse);
    expect(
      isAllowedRemoteMediaUrl('https://evil.com/klipy.com/file.gif'),
      isFalse,
    );
    expect(isAllowedRemoteMediaUrl('https://notklipy.com/file.gif'), isFalse);
    expect(
      isAllowedRemoteMediaUrl('https://klipy.com.evil.com/file.gif'),
      isFalse,
    );
    expect(isAllowedRemoteMediaUrl('https://192.168.0.10/track.gif'), isFalse);
    expect(isAllowedRemoteMediaUrl('https://[::1]/track.gif'), isFalse);
    expect(isAllowedRemoteMediaUrl('ftp://cdn.klipy.com/x'), isFalse);
    expect(isAllowedRemoteMediaUrl('not a url at all'), isFalse);
  });
}
