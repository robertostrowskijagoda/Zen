import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final String mid = PeerShareCodec.normalizeAddress('200::b2');
final String close = PeerShareCodec.normalizeAddress('200::c3');

final class _Host implements MeetHost {
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];

  Map<String, dynamic>? last(String to, String type) {
    for (final (String, Map<String, dynamic>) s in sent.reversed) {
      if (s.$1 == to && s.$2['type'] == type) {
        return s.$2;
      }
    }
    return null;
  }

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async =>
      sent.add((to, payload));

  @override
  List<String> friends() => <String>[mid, close];

  @override
  List<String> closeFriends() => <String>[close];

  @override
  bool isFriend(String a) => a == mid || a == close;

  @override
  bool isSelf(String a) => false;

  @override
  String nameOf(String a) => a;

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

void main() {
  test('"Tylko przyjaciele": close friends see the friend list, others get '
      'an empty one until let in, and the choice is remembered', () async {
    final _Host host = _Host();
    final MeetService service = MeetService(
      host: host,
      store: MeetStore(MemoryLedgerDisk()),
      now: () => 1000,
    )..friendNames = () => <String, String>{mid: 'Marek', close: 'Celina'};

    await service.setFriendListAudience(FriendListAudience.close);
    await service.shareFriendList(service.friendNames!(), force: true);
    expect(service.friendListVisibleTo(close), isTrue);
    expect(service.friendListVisibleTo(mid), isFalse);
    expect(host.last(close, MeetTypes.friendList)!['l'], isNotEmpty);
    expect(host.last(mid, MeetTypes.friendList)!['l'], isEmpty);

    // A friend who asked and was let in sees it too.
    await service.allowFriendList(mid, allow: true);
    expect(service.friendListVisibleTo(mid), isTrue);

    final MeetBook back = MeetBook.fromJson(
      jsonDecode(jsonEncode(service.book.toJson())),
    );
    expect(back.friendListAudience, FriendListAudience.close);
    expect(back.showsFriendListTo(close, close: true), isTrue);
    expect(back.showsFriendListTo('200::d4'), isFalse);
    expect(FriendListAudience.byName('close'), FriendListAudience.close);
  });

  test('a friend the gate is open to sees the friend list unasked, '
      'whatever the audience', () async {
    final _Host host = _Host();
    final MeetService service = MeetService(
      host: host,
      store: MeetStore(MemoryLedgerDisk()),
      now: () => 1000,
    )..friendNames = () => <String, String>{mid: 'Marek', close: 'Celina'};
    await service.setFriendListAudience(FriendListAudience.close);
    expect(service.friendListVisibleTo(mid), isFalse);

    service.gateOpenTo = (String friend) => friend == mid;
    expect(service.friendListVisibleTo(mid), isTrue);
    await service.shareFriendList(service.friendNames!(), force: true);
    expect(host.last(mid, MeetTypes.friendList)!['l'], isNotEmpty);
  });
}
