import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _FakeClipboard implements ClipboardAccess {
  String? text;

  @override
  Future<void> write(String value) async => text = value;

  @override
  Future<String?> read() async => text;
}

void main() {
  const String address = '200:1111:2222:3333:4444:5555:6666:7777';

  PeerShareProfile profile() =>
      PeerShareCodec.buildLocalProfile(address: address, displayName: 'Ada')!;

  test('the invitation copied is a message with the full link', () {
    final PeerShareProfile me = profile();
    expect(me.inviteLink, me.qrData);
    expect(me.inviteMessage, contains(me.inviteLink));
    expect(me.inviteMessage, startsWith('Dodaj mnie w Zen: https://'));
  });

  test('the whole pasted message still adds the person', () {
    final PeerShareProfile me = profile();
    expect(PeerShareCodec.parseTarget(me.inviteMessage).address, address);
    expect(PeerShareCodec.parseTarget(me.inviteLink).address, address);
    expect(
      PeerShareCodec.inviteCodeInText('Hej! ${me.inviteLink}.'),
      isNotNull,
    );
    expect(PeerShareCodec.inviteCodeInText('nic tu nie ma'), isNull);
    expect(
      () => PeerShareCodec.parseTarget('Hej, to jest zwykły tekst'),
      throwsFormatException,
    );
  });

  test('a public invitation stays on the clipboard', () async {
    final _FakeClipboard board = _FakeClipboard();
    final ExpiringClipboard clip = ExpiringClipboard(
      access: board,
      isInForeground: () => true,
    );
    await clip.copy('secret', ttl: const Duration(milliseconds: 30));
    await clip.copyPublic(profile().inviteMessage);
    expect(clip.pendingText, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(board.text, profile().inviteMessage);
  });
}
