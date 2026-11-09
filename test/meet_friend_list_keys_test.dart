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

  SignalTransportFrame listFrom(
    String from,
    List<Map<String, Object?>> entries,
    String digest,
    int at,
  ) => SignalTransportFrame(
    from: from,
    payload: <String, dynamic>{
      'type': MeetTypes.friendList,
      'l': entries,
      'd': digest,
    },
    receivedAtMillis: at,
  );

  test('one friend\'s lists, however many, vouch for at most one list of '
      'addresses and never for another friend', () async {
    final Map<String, String> vouched = <String, String>{};
    final MeetService service = MeetService(
      host: _Host(),
      store: MeetStore(MemoryLedgerDisk()),
      now: () => 1,
    )..onVouchedKeys = vouched.addAll;
    for (int batch = 0; batch < 9; batch++) {
      await service.handle(
        listFrom(
          close,
          <Map<String, Object?>>[
            for (int i = 0; i < kMaxFriendListEntries; i++)
              <String, Object?>{
                'a': '201:${batch.toRadixString(16)}::${i.toRadixString(16)}',
                'n': 'x',
                'k': (i % 16).toRadixString(16) * 64,
              },
          ],
          'x$batch',
          2 + batch,
        ),
      );
    }
    final String bogus = 'ee' * 32;
    await service.handle(
      listFrom(
        close,
        <Map<String, Object?>>[
          <String, Object?>{'a': mid, 'n': 'Marek', 'k': bogus},
        ],
        'y',
        100,
      ),
    );
    expect(vouched.length, lessThanOrEqualTo(kMaxFriendListEntries));
    expect(vouched, isNot(contains(mid)));
  });

  test('a friend\'s new list replaces what it vouched for before; the same '
      'keys again pin nothing anew', () async {
    final List<Map<String, String>> calls = <Map<String, String>>[];
    final String own = PeerShareCodec.normalizeAddress('200::a1');
    final String far = PeerShareCodec.normalizeAddress('200::f1');
    final String other = PeerShareCodec.normalizeAddress('200::f2');
    final MeetService service =
        MeetService(
            host: _Host(),
            store: MeetStore(MemoryLedgerDisk()),
            now: () => 1,
          )
          ..ownDevices = (() => <String>[own])
          ..onVouchedKeys = ((Map<String, String> k) => calls.add(k));
    await service.handle(
      listFrom(
        close,
        <Map<String, Object?>>[
          <String, Object?>{'a': far, 'n': 'Fela', 'k': keyFar},
          <String, Object?>{'a': own, 'n': 'Ja', 'k': 'aa' * 32},
        ],
        'a',
        2,
      ),
    );
    expect(calls, <Map<String, String>>[
      <String, String>{far: keyFar},
    ]);
    await service.handle(
      listFrom(
        close,
        <Map<String, Object?>>[
          <String, Object?>{'a': far, 'n': 'Fela', 'k': keyFar},
        ],
        'b',
        3,
      ),
    );
    expect(calls, hasLength(1));
    // A new key for the same person replaces the old one.
    await service.handle(
      listFrom(
        close,
        <Map<String, Object?>>[
          <String, Object?>{'a': far, 'n': 'Fela', 'k': 'cc' * 32},
          <String, Object?>{'a': other, 'n': 'Ola', 'k': 'dd' * 32},
        ],
        'c',
        4,
      ),
    );
    expect(calls.last, <String, String>{far: 'cc' * 32, other: 'dd' * 32});
    // Someone dropped and named again with the same key costs nothing.
    await service.handle(
      listFrom(
        close,
        <Map<String, Object?>>[
          <String, Object?>{'a': other, 'n': 'Ola', 'k': 'dd' * 32},
        ],
        'd',
        5,
      ),
    );
    await service.handle(
      listFrom(
        close,
        <Map<String, Object?>>[
          <String, Object?>{'a': far, 'n': 'Fela', 'k': 'cc' * 32},
          <String, Object?>{'a': other, 'n': 'Ola', 'k': 'dd' * 32},
        ],
        'e',
        6,
      ),
    );
    expect(calls, hasLength(2));
  });

  test('a friend who named a full list once names nobody new after it, while '
      'another friend still can', () async {
    final Map<String, String> vouched = <String, String>{};
    final MeetService service = MeetService(
      host: _Host(),
      store: MeetStore(MemoryLedgerDisk()),
      now: () => 1,
    )..onVouchedKeys = vouched.addAll;
    await service.handle(
      listFrom(
        close,
        <Map<String, Object?>>[
          for (int i = 0; i < kMaxFriendListEntries; i++)
            <String, Object?>{
              'a': '201:1::${i.toRadixString(16)}',
              'n': 'x',
              'k': 'ab' * 32,
            },
        ],
        'a',
        2,
      ),
    );
    expect(vouched, hasLength(kMaxFriendListEntries));
    final String far = PeerShareCodec.normalizeAddress('200::f1');
    await service.handle(
      listFrom(
        close,
        <Map<String, Object?>>[
          <String, Object?>{'a': far, 'n': 'Fela', 'k': keyFar},
        ],
        'b',
        3,
      ),
    );
    expect(vouched, isNot(contains(far)));
    await service.handle(
      listFrom(
        mid,
        <Map<String, Object?>>[
          <String, Object?>{'a': far, 'n': 'Fela', 'k': keyFar},
        ],
        'c',
        4,
      ),
    );
    expect(vouched[far], keyFar);
  });
}
