import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/account/presentation/account_backup_screen.dart';
import 'package:zen/src/features/account/presentation/account_copy_screen.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/account/presentation/account_recovery_screen.dart';
import 'package:zen/src/features/account/presentation/account_restore_info.dart';
import 'package:zen/src/features/calls/call_recordings.dart';
import 'package:zen/src/features/calls/presentation/call_recordings_screen.dart';
import 'package:zen/src/features/dating/presentation/dating_screen.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/plan/plan_service.dart';
import 'package:zen/src/features/meet/presentation/alarm_screen.dart';
import 'package:zen/src/features/meet/presentation/ask_screen.dart';
import 'package:zen/src/features/meet/presentation/circle_screen.dart';
import 'package:zen/src/features/meet/presentation/events_screen.dart';
import 'package:zen/src/features/meet/presentation/food_screen.dart';
import 'package:zen/src/features/meet/presentation/plan_screen.dart';
import 'package:zen/src/features/meet/presentation/table_screen.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/neighbors/presentation/flat_door_screen.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/profile/presentation/gallery_add_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/presentation/wallet_screen.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/update/own_copy.dart';
import 'package:zen/src/features/update/presentation/install_guide_screen.dart';
import 'package:zen/src/features/update/presentation/share_app_screen.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';

/// Nobody around: the board is empty, which is enough to scroll it.
final class _Host implements EventHost {
  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => const <String>[];

  @override
  bool isFriend(String a) => false;

  @override
  String ownAddress() => '200::a1';

  @override
  String ownName() => 'Ania';

  @override
  String nameOf(String a) => '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}
}

/// Alarms: one friend, who can be asked for help.
final class _MeetHost implements MeetHost {
  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => <String>[_ania];

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) => PeerShareCodec.addressesEqual(a, _ania);

  @override
  bool isSelf(String a) => false;

  @override
  String nameOf(String a) => 'Ania';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

final String _ania = PeerShareCodec.normalizeAddress('200::a1');

/// A phone of a dinner circle: what it sends reaches the others at once.
final class _CircleHost implements EventHost {
  _CircleHost(this.net, this.name, this.friendList)
    : address = PeerShareCodec.normalizeAddress('200::$name') {
    net[address] = this;
    circles = CircleService(host: this, disk: MemoryLedgerDisk());
  }

  final Map<String, _CircleHost> net;
  final String name;
  final String address;
  final List<String> friendList;
  late final CircleService circles;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    await net[to]?.circles.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  @override
  List<String> friends() => friendList;

  @override
  bool isFriend(String a) =>
      friendList.contains(PeerShareCodec.normalizeAddress(a));

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}
}

/// A small phone (360 x 480 dp) with a system navigation bar of 52 dp at the
/// bottom.
const double _phoneHeight = 480;
const double _systemBar = 52;
const double _usableBottom = _phoneHeight - _systemBar;

/// Where a screen ends, scrolled to its very end.
typedef _Ends = ({
  /// Bottom of the lowest page-sized vertical scroll view.
  double viewport,

  /// Bottom of the lowest text or icon that is on the screen.
  double content,

  /// Whether some scroll view had anything to scroll.
  bool scrolled,
});

/// Pumps [home] on the small phone and lets what it loads settle.
Future<void> _pumpOnPhone(
  WidgetTester tester,
  Widget home, {
  List<Override> overrides = const <Override>[],
}) async {
  tester.view.physicalSize = const Size(720, 960);
  tester.view.devicePixelRatio = 2;
  tester.view.padding = const FakeViewPadding(bottom: 104);
  tester.view.viewPadding = const FakeViewPadding(bottom: 104);
  addTearDown(tester.view.reset);
  // The test font is wider than the real ones: a row that is too long here
  // is not what this is about.
  final FlutterExceptionHandler? reporter = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    if (!details.exceptionAsString().contains('overflowed by')) {
      reporter?.call(details);
    }
  };
  addTearDown(() => FlutterError.onError = reporter);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        socialHubAutoHydrateProvider.overrideWithValue(false),
        signalTransportProvider.overrideWithValue(MemorySignalTransport()),
        ...overrides,
      ],
      child: MaterialApp(theme: ZenTheme.light(), home: home),
    ),
  );
  await _settle(tester);
}

/// Real async work (disks, keys) and the frames that follow it.
Future<void> _settle(WidgetTester tester, [int rounds = 8]) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Waits (for real) until [what] is on the screen.
Future<void> _waitFor(WidgetTester tester, Finder what) async {
  for (int i = 0; i < 200 && what.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(what, findsOneWidget);
}

bool _isPage(Element e) {
  final Widget w = e.widget;
  if (w is! Scrollable ||
      axisDirectionToAxis(w.axisDirection) != Axis.vertical) {
    return false;
  }
  final Size size = (e.renderObject! as RenderBox).size;
  // Not the scroll view inside a text field.
  return size.height > 100 && size.width > 200;
}

Rect _rectOf(WidgetTester tester, Element e) =>
    tester.getRect(find.byElementPredicate((Element x) => x == e));

/// Scrolls every page-sized vertical scroll view to its very end and tells
/// where the page ends then.
Future<_Ends> _scrollToEnd(WidgetTester tester) async {
  final List<Element> pages = find
      .byWidgetPredicate((Widget w) => w is Scrollable)
      .evaluate()
      .where(_isPage)
      .toList();
  bool scrolled = false;
  double viewport = 0;
  for (final Element page in pages) {
    final ScrollableState state =
        (page as StatefulElement).state as ScrollableState;
    // Lazy lists learn their length as they scroll.
    for (int i = 0; i < 20; i++) {
      final double end = state.position.maxScrollExtent;
      if (state.position.pixels >= end) {
        break;
      }
      state.position.jumpTo(end);
      scrolled = true;
      await tester.pump(const Duration(milliseconds: 50));
    }
    final double bottom = _rectOf(tester, page).bottom;
    viewport = viewport > bottom ? viewport : bottom;
  }
  await _settle(tester, 2);
  double content = 0;
  for (final Element e in find.byType(RichText).evaluate()) {
    final Rect r = _rectOf(tester, e);
    if (r.top < _phoneHeight && r.bottom > 0) {
      content = content > r.bottom ? content : r.bottom;
    }
  }
  return (viewport: viewport, content: content, scrolled: scrolled);
}

/// Scrolled to the end, nothing of the screen is under the system bar: its
/// scroll views stop above the bar, and so does the last text or icon.
Future<void> _expectAboveSystemBar(
  WidgetTester tester, {
  bool mustScroll = true,
}) async {
  final _Ends ends = await _scrollToEnd(tester);
  expect(ends.viewport, greaterThan(0), reason: 'no scroll view');
  expect(ends.viewport, lessThanOrEqualTo(_usableBottom));
  expect(ends.content, lessThanOrEqualTo(_usableBottom));
  expect(ends.scrolled, mustScroll, reason: 'scrolling the page');
}

/// The account's screens: the ledger runs on memory.
List<Override> _accountOverrides() => <Override>[
  ledgerNodeEnabledProvider.overrideWithValue(true),
  ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
];

MeetService _meet(LedgerDisk disk) =>
    MeetService(host: _MeetHost(), store: MeetStore(disk));

List<Override> _meetOverrides(MeetService meet) => <Override>[
  meetServiceProvider.overrideWithValue(meet),
  eventServiceProvider.overrideWithValue(
    EventService(
      host: MeetEventHost(_MeetHost(), address: () => '', name: () => 'Ja'),
      disk: MemoryLedgerDisk(),
    ),
  ),
];

/// A dinner circle of four, as its founder (the others have answered when
/// [answered]) or as the first of the others (who has not answered yet).
Future<_CircleHost> _circleOf(
  WidgetTester tester, {
  required bool answered,
}) async {
  final Map<String, _CircleHost> net = <String, _CircleHost>{};
  final List<String> names = <String>['a1', 'b2', 'c3', 'd4'];
  final List<_CircleHost> phones = <_CircleHost>[
    for (final String n in names)
      _CircleHost(net, n, <String>[
        for (final String o in names)
          if (o != n) PeerShareCodec.normalizeAddress('200::$o'),
      ]),
  ];
  await tester.runAsync(() async {
    final DinnerCircle c = await phones.first.circles.create(
      name: 'Czwartki',
      friends: <String>[for (final _CircleHost h in phones.skip(1)) h.address],
      weekday: DateTime.thursday,
      hour: 19,
      firstDinner: DateTime.now().add(const Duration(days: 3)),
    );
    if (answered) {
      for (final _CircleHost h in phones.skip(1)) {
        await h.circles.answerInvite(c.id, true);
      }
    }
  });
  return answered ? phones.first : phones[1];
}

List<Override> _circleOverrides(_CircleHost host) => <Override>[
  circleServiceProvider.overrideWithValue(host.circles),
  eventServiceProvider.overrideWithValue(
    EventService(host: host, disk: MemoryLedgerDisk()),
  ),
];

/// A household with its door open.
Future<NeighborsService> _flat(WidgetTester tester) async {
  final String door = PeerShareCodec.normalizeAddress('200::d0:1234');
  final NeighborsService flat = NeighborsService(
    host: _Host(),
    disk: MemoryLedgerDisk(),
    doorInbox: () => door,
    doorSend: (String to, Map<String, dynamic> payload) async => false,
    deviceName: () => 'Telefon testowy',
  );
  await tester.runAsync(() => flat.createFlat('Nowakowie', place: 'm. 12'));
  expect(flat.hasFlat, isTrue);
  return flat;
}

/// One screen under test: how it is put on the small phone.
typedef _Case = Future<void> Function(WidgetTester tester);

void main() {
  testWidgets('the check sees a long page that runs under the system bar', (
    WidgetTester tester,
  ) async {
    Widget page({required bool safe}) {
      // Lists with their own padding, like the screens: they do not make
      // room for the system bar by themselves.
      final Widget list = ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          for (int i = 0; i < 40; i++) ListTile(title: Text('Wiersz $i')),
        ],
      );
      return Scaffold(
        appBar: AppBar(title: const Text('Dlugo')),
        body: safe ? SafeArea(top: false, child: list) : list,
      );
    }

    await _pumpOnPhone(tester, page(safe: false));
    final _Ends under = await _scrollToEnd(tester);
    expect(under.viewport, _phoneHeight);
    expect(under.content, greaterThan(_usableBottom));

    await _pumpOnPhone(tester, page(safe: true));
    await _expectAboveSystemBar(tester);
  });

  final Map<String, _Case> screens = <String, _Case>{
    '"O Zen"': (WidgetTester tester) async {
      await _pumpOnPhone(
        tester,
        const AboutScreen(),
        overrides: <Override>[
          ownCopyCheckProvider.overrideWith(
            (Ref ref) async => const OwnCopyCheck(OwnCopyState.unknown),
          ),
        ],
      );
      await _expectAboveSystemBar(tester);
    },
    '"Jak zainstalować Zen"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const InstallGuideScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Aktualizacje"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const UpdatesScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Podaj dalej"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const ShareAppScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Kopia konta" (making)': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const AccountBackupScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Mam kopie"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const AccountBackupRestoreScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Przenies konto" (sending)': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const AccountCopySendScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Odzyskaj z innego urzadzenia"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const AccountCopyReceiveScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Zapytaj siec"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const AskScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Plan na weekend"': (WidgetTester tester) async {
      final PlanService plans = PlanService(
        host: _Host(),
        disk: MemoryLedgerDisk(),
        now: () => DateTime(2026, 10, 14, 12).millisecondsSinceEpoch,
      );
      await _pumpOnPhone(tester, PlanBoard(plans: plans));
      await _expectAboveSystemBar(tester);
    },
    '"Plan na weekend" (in the app)': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const PlanScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Portfel"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const WalletScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Stol na szesc"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const TableScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Jedzenie do wziecia"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const FoodScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Podziel sie jedzeniem"': (WidgetTester tester) async {
      await _pumpOnPhone(
        tester,
        const FoodShareScreen(circleId: '', seats: true),
      );
      await _expectAboveSystemBar(tester);
    },
    '"Kolka obiadowe"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const CirclesScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Urzadzenia konta"': (WidgetTester tester) async {
      await _pumpOnPhone(
        tester,
        const AccountDevicesScreen(),
        overrides: _accountOverrides(),
      );
      await _waitFor(tester, find.byType(ListView));
      await _expectAboveSystemBar(tester);
    },
    '"Podlacz nowe urzadzenie"': (WidgetTester tester) async {
      await _pumpOnPhone(
        tester,
        const AccountDevicesScreen(),
        overrides: _accountOverrides(),
      );
      await _waitFor(tester, find.byType(ListView));
      await tester.scrollUntilVisible(
        find.byKey(const Key('devices-link-new')),
        300,
      );
      await tester.tap(find.byKey(const Key('devices-link-new')));
      await _settle(tester);
      expect(find.byType(AccountDevicesScreen), findsNothing);
      await _expectAboveSystemBar(tester);
    },
    '"To nowe urzadzenie: dolacz do konta"': (WidgetTester tester) async {
      await _pumpOnPhone(
        tester,
        const AccountDevicesScreen(),
        overrides: _accountOverrides(),
      );
      await _waitFor(tester, find.byType(ListView));
      await tester.scrollUntilVisible(
        find.byKey(const Key('devices-join-account')),
        300,
      );
      await tester.tap(find.byKey(const Key('devices-join-account')));
      await _settle(tester);
      expect(find.byType(AccountDevicesScreen), findsNothing);
      await _expectAboveSystemBar(tester);
    },
    '"Konto i odzyskiwanie"': (WidgetTester tester) async {
      await _pumpOnPhone(
        tester,
        const AccountRecoveryScreen(),
        overrides: _accountOverrides(),
      );
      await _waitFor(tester, find.byKey(const Key('recovery-set-password')));
      await _expectAboveSystemBar(tester);
    },
    '"Alarm" (setting the PIN)': (WidgetTester tester) async {
      final MeetService meet = _meet(MemoryLedgerDisk());
      await _pumpOnPhone(
        tester,
        const AlarmScreen(),
        overrides: _meetOverrides(meet),
      );
      await _expectAboveSystemBar(tester);
    },
    '"Alarm" (ready)': (WidgetTester tester) async {
      final MeetService meet = _meet(MemoryLedgerDisk());
      await tester.runAsync(() => meet.setAlarmPin('1234', '4321'));
      await _pumpOnPhone(
        tester,
        const AlarmScreen(),
        overrides: _meetOverrides(meet),
      );
      await _expectAboveSystemBar(tester);
    },
    '"Alarm" (going on)': (WidgetTester tester) async {
      final MeetService meet = _meet(MemoryLedgerDisk());
      await tester.runAsync(() async {
        await meet.setAlarmPin('1234', '4321');
        await meet.raiseAlarm(note: 'pomocy');
      });
      await _pumpOnPhone(
        tester,
        const AlarmScreen(),
        overrides: _meetOverrides(meet),
      );
      await _expectAboveSystemBar(tester);
    },
    "A friend's alarm": (WidgetTester tester) async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final int now = DateTime.now().millisecondsSinceEpoch;
      final MeetBook book = MeetBook()
        ..alarms.add(
          AlarmRecord(
            id: 'alarm1',
            from: _ania,
            at: now,
            lat: 54.35,
            lon: 18.65,
            accuracy: 12,
            locatedAt: now,
            note: 'Ktos za mna idzie, prosze o telefon',
          ),
        );
      await disk.write(
        MeetStore.key,
        Uint8List.fromList(utf8.encode(jsonEncode(book.toJson()))),
      );
      final MeetService meet = _meet(disk);
      await tester.runAsync(meet.reload);
      await _pumpOnPhone(
        tester,
        const FriendAlarmScreen(alarmId: 'alarm1'),
        overrides: _meetOverrides(meet),
      );
      await _expectAboveSystemBar(tester);
    },
    '"Kolko obiadowe" (a member)': (WidgetTester tester) async {
      final _CircleHost host = await _circleOf(tester, answered: true);
      await _pumpOnPhone(
        tester,
        CircleScreen(circleId: host.circles.circles.single.id),
        overrides: _circleOverrides(host),
      );
      await _expectAboveSystemBar(tester);
    },
    '"Kolko obiadowe" (an invitation)': (WidgetTester tester) async {
      final _CircleHost host = await _circleOf(tester, answered: false);
      await _pumpOnPhone(
        tester,
        CircleScreen(circleId: host.circles.invitations.single.id),
        overrides: _circleOverrides(host),
      );
      await _expectAboveSystemBar(tester, mustScroll: false);
    },
    '"Kod na drzwi"': (WidgetTester tester) async {
      final NeighborsService flat = await _flat(tester);
      await _pumpOnPhone(
        tester,
        const FlatDoorScreen(),
        overrides: <Override>[neighborsServiceProvider.overrideWithValue(flat)],
      );
      await _expectAboveSystemBar(tester);
    },
    '"Domownicy"': (WidgetTester tester) async {
      final NeighborsService flat = await _flat(tester);
      await _pumpOnPhone(
        tester,
        const FlatHomeScreen(),
        overrides: <Override>[neighborsServiceProvider.overrideWithValue(flat)],
      );
      await _expectAboveSystemBar(tester);
    },
    '"Dodaj do galerii"': (WidgetTester tester) async {
      final LedgerNode node = LedgerNode(
        transport: MemorySignalTransport(),
        disk: MemoryLedgerDisk(),
        friendAddresses: () => const <String>[],
      );
      await _pumpOnPhone(tester, GalleryAddScreen(node: node));
      await _expectAboveSystemBar(tester);
    },
    '"Co da sie odzyskac"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const AccountRestoreInfoScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Wydarzenia"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const EventsScreen());
      await _expectAboveSystemBar(tester, mustScroll: false);
    },
    '"Nowe wydarzenie"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const CreateEventScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Randki"': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const DatingScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Piramida" (not joined)': (WidgetTester tester) async {
      await _pumpOnPhone(tester, const PyramidScreen());
      await _expectAboveSystemBar(tester);
    },
    '"Sasiedzi" (with a flat)': (WidgetTester tester) async {
      final NeighborsService flat = await _flat(tester);
      await _pumpOnPhone(
        tester,
        const NeighborsScreen(),
        overrides: <Override>[neighborsServiceProvider.overrideWithValue(flat)],
      );
      await _expectAboveSystemBar(tester);
    },
    '"Nagrania rozmow"': (WidgetTester tester) async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await disk.write(
        'recordings/index',
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<Map<String, dynamic>>[
              for (int i = 0; i < 12; i++)
                CallRecording(
                  id: 'r$i',
                  file: 'f$i',
                  peer: 'Znajomy $i',
                  millis: 1760000000000 + i * 3600000,
                  bytes: 3000000 + i,
                ).toJson(),
            ]),
          ),
        ),
      );
      await _pumpOnPhone(
        tester,
        const CallRecordingsScreen(),
        overrides: <Override>[ledgerDiskProvider.overrideWithValue(disk)],
      );
      await _expectAboveSystemBar(tester);
    },
  };

  for (final MapEntry<String, _Case> screen in screens.entries) {
    testWidgets('${screen.key}: the end of the page is above the system bar', (
      WidgetTester tester,
    ) async {
      await screen.value(tester);
    });
  }

  /// The very last row of a list, which is built by a plain list of rows.
  Future<void> expectLastRowAbove(WidgetTester tester) async {
    await _expectAboveSystemBar(tester);
    final Finder list = find.byType(ListView);
    expect(list, findsOneWidget);
    final ListView view = tester.widget<ListView>(list);
    final SliverChildListDelegate rows =
        view.childrenDelegate as SliverChildListDelegate;
    final Finder last = find.byWidget(rows.children.last);
    expect(last, findsOneWidget);
    expect(tester.getBottomLeft(last).dy, lessThanOrEqualTo(_usableBottom));
  }

  testWidgets('"Mam kopie": the last row is above the system bar', (
    WidgetTester tester,
  ) async {
    await _pumpOnPhone(tester, const AccountBackupRestoreScreen());
    await expectLastRowAbove(tester);
  });

  testWidgets('"Odzyskaj z innego urzadzenia": the last row is above the '
      'system bar', (WidgetTester tester) async {
    await _pumpOnPhone(tester, const AccountCopyReceiveScreen());
    await expectLastRowAbove(tester);
  });

  testWidgets('"Plan na weekend": the last row is above the system bar', (
    WidgetTester tester,
  ) async {
    final PlanService plans = PlanService(
      host: _Host(),
      disk: MemoryLedgerDisk(),
      now: () => DateTime(2026, 10, 14, 12).millisecondsSinceEpoch,
    );
    await _pumpOnPhone(tester, PlanBoard(plans: plans));
    await expectLastRowAbove(tester);
  });
}
