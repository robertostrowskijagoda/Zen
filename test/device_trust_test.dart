import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/device_trust.dart';

const int _h = 3600 * 1000;
final int _wait = kNewDeviceWait.inMilliseconds;

/// A device first seen at [seen] (counts [kNewDeviceWait] later unless
/// co-signed), certified at [issued].
TrustDevice _dev(String id, {int seen = 0, int issued = 0, String? co}) =>
    TrustDevice(id: id, issued: issued, readyAt: seen + _wait, coBy: co);

/// A device that counted from the first contact.
TrustDevice _old(String id, {int issued = 0, String? co}) =>
    TrustDevice(id: id, issued: issued, readyAt: 0, coBy: co);

TrustCut _cut(
  String id,
  String target, {
  String? by,
  Set<String>? keep,
  int issued = 0,
  int received = 0,
}) => TrustCut(
  id: id,
  target: target,
  by: by,
  keep: keep,
  issued: issued,
  receivedAt: received,
);

TrustVerdict _judge(
  List<TrustDevice> devices,
  List<TrustCut> cuts, {
  required int now,
  bool strict = true,
}) => judgeDevices(
  strict: strict,
  devices: <String, TrustDevice>{for (final TrustDevice d in devices) d.id: d},
  cuts: cuts,
  now: now,
);

void main() {
  test('an account that never co-signed keeps the old rule: every device '
      'counts until the account key cuts it off', () {
    final TrustVerdict v = _judge(
      <TrustDevice>[_dev('A', seen: 10 * _h), _dev('B', seen: 10 * _h)],
      <TrustCut>[_cut('c', 'B')],
      now: 10 * _h,
      strict: false,
    );
    expect(v.counting, <String>{'A'});
    expect(v.isOut('B'), isTrue);
  });

  test('a co-signed device counts at once; one without a co-signature '
      'waits 24 hours from when it was first seen', () {
    final List<TrustDevice> devices = <TrustDevice>[
      _old('A'),
      _dev('B', seen: 50 * _h, co: 'A'),
      _dev('P', seen: 50 * _h),
      // Co-signed by a device that waits itself: waits as well.
      _dev('Q', seen: 51 * _h, co: 'P'),
    ];
    TrustVerdict v = _judge(devices, const <TrustCut>[], now: 52 * _h);
    expect(v.counting, <String>{'A', 'B'});
    expect(v.pendingUntil, <String, int>{
      'P': 50 * _h + _wait,
      'Q': 51 * _h + _wait,
    });
    v = _judge(devices, const <TrustCut>[], now: 50 * _h + _wait);
    expect(v.counting, <String>{'A', 'B', 'P', 'Q'});
  });

  test('a cut-off by the account key alone counts in a co-signing account '
      'only when it was taken before (it is not handed in otherwise), and '
      'a cut-off by a device that does not count yet does nothing', () {
    final List<TrustDevice> devices = <TrustDevice>[
      _old('A'),
      _dev('T', seen: 100 * _h),
    ];
    final TrustVerdict v = _judge(devices, <TrustCut>[
      _cut('t', 'A', by: 'T', keep: <String>{'T'}, issued: 101 * _h),
    ], now: 101 * _h);
    expect(v.counting, <String>{'A'});
    expect(v.pendingUntil.keys, <String>['T']);

    final TrustVerdict old = _judge(devices, <TrustCut>[
      _cut('u', 'A'),
    ], now: 101 * _h);
    expect(old.isOut('A'), isTrue);
  });

  test('a thief\'s cut-off of the owner\'s device is undone by the owner\'s '
      'cut-off of the stolen device', () {
    final List<TrustDevice> devices = <TrustDevice>[
      _old('A'),
      _old('B', co: 'A'),
      _old('S', co: 'A'),
    ];
    final TrustCut thief = _cut(
      's',
      'B',
      by: 'S',
      keep: <String>{'S'},
      issued: 10 * _h,
      received: 10 * _h,
    );
    TrustVerdict v = _judge(devices, <TrustCut>[thief], now: 10 * _h);
    expect(v.counting, <String>{'S'});
    v = _judge(devices, <TrustCut>[
      thief,
      _cut(
        'a',
        'S',
        by: 'A',
        keep: <String>{'A', 'B'},
        issued: 11 * _h,
        received: 11 * _h,
      ),
    ], now: 11 * _h);
    expect(v.counting, <String>{'A', 'B'});
    expect(v.isOut('S'), isTrue);
  });

  test('two devices that cut each other off within a day are both cut off, '
      'with what only they vouched for; a device certified after both '
      'stays', () {
    final TrustVerdict v = _judge(
      <TrustDevice>[
        _old('A', issued: 1),
        _old('B', issued: 2, co: 'A'),
        _old('S', issued: 3, co: 'A'),
        _dev('P', seen: 20 * _h, issued: 20 * _h),
      ],
      <TrustCut>[
        _cut(
          'a',
          'S',
          by: 'A',
          keep: <String>{'A', 'B'},
          issued: 5 * _h,
          received: 5 * _h,
        ),
        _cut(
          's',
          'A',
          by: 'S',
          keep: <String>{'S'},
          issued: 4 * _h,
          received: 28 * _h,
        ),
      ],
      now: 20 * _h + _wait,
    );
    expect(v.counting, <String>{'P'});
    for (final String out in <String>['A', 'B', 'S']) {
      expect(v.isOut(out), isTrue, reason: out);
    }
  });

  test('a cut-off that stood a day unanswered is settled: the owner\'s, '
      'and also the thief\'s when the owner did not answer in time', () {
    final List<TrustDevice> devices = <TrustDevice>[
      _old('A', issued: 1),
      _old('B', issued: 2, co: 'A'),
      _old('S', issued: 3, co: 'A'),
    ];
    TrustCut cut(String id, String target, String by, int at) =>
        _cut(id, target, by: by, keep: <String>{by}, issued: at, received: at);
    TrustVerdict v = _judge(devices, <TrustCut>[
      cut('a', 'S', 'A', 10 * _h),
      cut('s', 'A', 'S', 34 * _h),
    ], now: 40 * _h);
    expect(v.counting, <String>{'A', 'B'});
    v = _judge(devices, <TrustCut>[
      cut('s', 'A', 'S', 10 * _h),
      cut('b', 'S', 'B', 40 * _h),
    ], now: 40 * _h);
    expect(v.counting, <String>{'S'});
  });

  test('a veto: a device without a co-signature cut off while it waited '
      'never counts, and its cut-off of the vetoing device does nothing', () {
    final List<TrustDevice> devices = <TrustDevice>[
      _old('A'),
      _dev('T', seen: 100 * _h, issued: 100 * _h),
    ];
    final TrustCut veto = _cut(
      'a',
      'T',
      by: 'A',
      keep: <String>{'A'},
      issued: 101 * _h,
      received: 101 * _h,
    );
    final TrustCut answer = _cut(
      't',
      'A',
      by: 'T',
      keep: <String>{'T'},
      issued: 130 * _h,
      received: 130 * _h,
    );
    final TrustVerdict v = _judge(devices, <TrustCut>[
      veto,
      answer,
    ], now: 130 * _h);
    expect(v.counting, <String>{'A'});
    expect(v.isOut('T'), isTrue);

    // Cut off only after it counted here: that is no veto, the two cut
    // each other off.
    final TrustVerdict late = _judge(devices, <TrustCut>[
      _cut(
        'a',
        'T',
        by: 'A',
        keep: <String>{'A'},
        issued: 125 * _h,
        received: 125 * _h,
      ),
      answer,
    ], now: 130 * _h);
    expect(late.counting, isEmpty);
  });

  test('without a veto a device that waited its 24 hours counts: the thief '
      'with the account key and password is the owner to everyone', () {
    final TrustVerdict v = _judge(
      <TrustDevice>[_old('A'), _dev('T', seen: 100 * _h, issued: 100 * _h)],
      const <TrustCut>[],
      now: 100 * _h + _wait,
    );
    expect(v.counting, <String>{'A', 'T'});
  });

  test('a cut-off leaves out what its signer does not keep: devices the '
      'cut-off device co-signed, and older devices without a co-signature; '
      'devices co-signed by a kept one stay', () {
    final List<TrustDevice> devices = <TrustDevice>[
      _old('A', issued: 1),
      _old('B', issued: 2, co: 'A'),
      _old('S', issued: 3, co: 'A'),
      // The thief's, co-signed by the stolen device before the cut-off,
      // even certified as if later.
      _old('T', issued: 50 * _h, co: 'S'),
      // The thief's own made before the cut-off and hidden until it counted.
      _old('H', issued: 4),
      // Co-signed by B, which the cutting device did not know of yet.
      _old('B2', issued: 5, co: 'B'),
    ];
    final TrustVerdict v = _judge(devices, <TrustCut>[
      _cut('a', 'S', by: 'A', keep: <String>{'A', 'B'}, issued: 10 * _h),
    ], now: 60 * _h);
    expect(v.counting, <String>{'A', 'B', 'B2'});
    for (final String out in <String>['S', 'T', 'H']) {
      expect(v.isOut(out), isTrue, reason: out);
    }
  });

  test('an old cut-off replayed later does not touch devices certified '
      'after it, and a cut-off device cuts nothing any more', () {
    final List<TrustDevice> devices = <TrustDevice>[
      _old('A', issued: 1),
      _old('S', issued: 2, co: 'A'),
      // Restored from paper months later.
      _dev('P', seen: 2000 * _h, issued: 2000 * _h),
      _dev('P2', seen: 2001 * _h, issued: 2001 * _h, co: 'A'),
    ];
    final List<TrustCut> cuts = <TrustCut>[
      _cut('a', 'S', by: 'A', keep: <String>{'A'}, issued: 10 * _h),
      // The cut-off device, its key still working, cuts newer devices.
      _cut(
        's',
        'P2',
        by: 'S',
        keep: <String>{'S'},
        issued: 2002 * _h,
        received: 2002 * _h,
      ),
    ];
    TrustVerdict v = _judge(devices, cuts, now: 2002 * _h);
    expect(v.counting, <String>{'A', 'P2'});
    expect(v.pendingUntil.keys, <String>['P']);
    v = _judge(devices, cuts, now: 2000 * _h + _wait);
    expect(v.counting, <String>{'A', 'P', 'P2'});
  });

  test('a device the cut-off device co-signed cannot undo a settled '
      'cut-off', () {
    final TrustVerdict v = _judge(
      <TrustDevice>[
        _old('A', issued: 1),
        _old('S', issued: 2, co: 'A'),
        _old('S2', issued: 3, co: 'S'),
      ],
      <TrustCut>[
        _cut(
          'a',
          'S',
          by: 'A',
          keep: <String>{'A'},
          issued: 10 * _h,
          received: 10 * _h,
        ),
        _cut(
          's2',
          'A',
          by: 'S2',
          keep: <String>{'S2'},
          issued: 11 * _h,
          received: 40 * _h,
        ),
      ],
      now: 40 * _h,
    );
    expect(v.counting, <String>{'A'});
  });

  test('cut-offs in a ring all count', () {
    final TrustVerdict v = _judge(
      <TrustDevice>[_old('A'), _old('B'), _old('C'), _old('D')],
      <TrustCut>[
        _cut('ab', 'B', by: 'A'),
        _cut('bc', 'C', by: 'B'),
        _cut('ca', 'A', by: 'C'),
      ],
      now: 1,
    );
    expect(v.counting, <String>{'D'});
  });

  test('a cut-off taken before co-signatures still counts and stops what '
      'its target signs', () {
    final TrustVerdict v = _judge(
      <TrustDevice>[_old('A'), _old('S', co: 'A'), _old('B', co: 'A')],
      <TrustCut>[
        _cut('old', 'S'),
        _cut('s', 'B', by: 'S', keep: <String>{'S'}),
      ],
      now: 1,
    );
    expect(v.counting, <String>{'A', 'B'});
  });

  test('a made-up loop of co-signatures counts for nothing on its own', () {
    final TrustVerdict v = _judge(
      <TrustDevice>[
        _old('A'),
        _dev('X', seen: 10 * _h, co: 'Y'),
        _dev('Y', seen: 10 * _h, co: 'X'),
      ],
      const <TrustCut>[],
      now: 11 * _h,
    );
    expect(v.counting, <String>{'A'});
    expect(v.pendingUntil.keys.toSet(), <String>{'X', 'Y'});
  });
}
