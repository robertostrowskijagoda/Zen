import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final String mid = PeerShareCodec.normalizeAddress('200::b2');
final String close = PeerShareCodec.normalizeAddress('200::c3');
final String keyMid = 'b2' * 32;
final String keyFar = 'f1' * 32;

final class _Host implements MeetHost {
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];

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
  test(
    'friend lists carry friends\' device keys; received ones are pinned',
    () async {
      final _Host host = _Host();
      final Map<String, String> vouched = <String, String>{};
      final MeetService service =
          MeetService(
              host: host,
              store: MeetStore(MemoryLedgerDisk()),
              now: () => 1,
            )
            ..friendNames = (() => <String, String>{
              mid: 'Marek',
              close: 'Celina',
            })
            ..sessionKeyOf = ((String a) => a == mid ? keyMid : null)
            ..onVouchedKeys = vouched.addAll;

      await service.shareFriendList(service.friendNames!(), force: true);
      final Map<String, dynamic> toClose = host.sent
          .lastWhere(((String, Map<String, dynamic>) s) => s.$1 == close)
          .$2;
      final List<Object?> list = toClose['l'] as List<Object?>;
      expect(
        list,
        contains(equals(<String, String>{'a': mid, 'n': 'Marek', 'k': keyMid})),
      );

      final String far = PeerShareCodec.normalizeAddress('200::f1');
      await service.handle(
        SignalTransportFrame(
          from: close,
          payload: <String, dynamic>{
            'type': MeetTypes.friendList,
            'l': <Object?>[
              <String, Object?>{'a': far, 'n': 'Fela', 'k': keyFar},
              <String, Object?>{'a': '200::f2', 'n': 'X', 'k': 'nonsense'},
              <String, Object?>{'a': '200::f3', 'n': 'Y'},
            ],
            'd': 'x',
          },
          receivedAtMillis: 2,
        ),
      );
      expect(vouched, <String, String>{far: keyFar});
    },
  );
}
