import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/net_address.dart';
import 'package:zen/src/features/ledger/port_mapper.dart';

/// The port desktops accept mesh connections on (the native bridge's
/// `tls://[::]:32913` listener).
const int kMeshListenPort = 32913;

enum BridgeHostState {
  /// Not tried yet (the mesh is still starting).
  waiting,

  /// Opening the port and asking friends to check.
  checking,

  /// Announced: other people's apps can use this computer.
  active,

  /// No router answered (or none that can open ports) and the computer
  /// has no public address.
  noRouter,

  /// The router answered but would not open the port (UPnP switched off
  /// for changes, most often).
  routerRefused,

  /// The router has no public address either (the provider shares one
  /// address between many customers: CGNAT).
  sharedAddress,

  /// The port is open, but friends could not get in (a firewall, most
  /// likely).
  unreachable,

  /// No friend was online to check from outside; tried again soon.
  noFriendsOnline,
}

@immutable
final class BridgeHostStatus {
  const BridgeHostStatus(this.state, {this.uri, this.method, this.at = 0});

  final BridgeHostState state;

  /// The announced address while [state] is active (or the one checked).
  final String? uri;

  /// `upnp`, `natpmp`, `direct` (a public address on this computer) or
  /// `manual` (a port forwarded by hand).
  final String? method;
  final int at;

  /// Short line for the settings.
  String get title => switch (state) {
    BridgeHostState.waiting => t('Most: czekam na sieć'),
    BridgeHostState.checking => t('Most: sprawdzam…'),
    BridgeHostState.active => t('Most działa'),
    BridgeHostState.noRouter => t('Most: router nie otworzył portu'),
    BridgeHostState.routerRefused => t(
      'Most: router nie pozwolił otworzyć portu',
    ),
    BridgeHostState.sharedAddress => t('Most: brak publicznego adresu'),
    BridgeHostState.unreachable => t('Most: nie da się połączyć z zewnątrz'),
    BridgeHostState.noFriendsOnline => t('Most: czekam na znajomego online'),
  };

  /// What it means, in plain words.
  String get detail => switch (state) {
    BridgeHostState.waiting => t(
      'Za chwilę komputer spróbuje zostać mostem dla innych.',
    ),
    BridgeHostState.checking => t(
      'Otwieram port w routerze i proszę znajomych o sprawdzenie z zewnątrz.',
    ),
    BridgeHostState.active => t(
      'Inni łączą się z siecią przez ten komputer ({uri}). '
      'Ogłoszenie nie mówi, czyj to komputer, ale jego adres IP jest '
      'widoczny w sieci.',
      {'uri': uri},
    ),
    BridgeHostState.noRouter => t(
      'Router nie obsługuje UPnP ani NAT-PMP (albo są wyłączone). Włącz '
      'UPnP w ustawieniach routera albo przekieruj port TCP '
      '{port} na ten komputer.',
      {'port': kMeshListenPort},
    ),
    BridgeHostState.routerRefused => t(
      'Router odpowiada, ale odmawia otwierania portów. Włącz UPnP '
      '(czasem nazywane „zezwalaj na zmiany” albo „UPnP IGD”) w '
      'ustawieniach routera albo przekieruj port TCP {port} '
      'na ten komputer.',
      {'port': kMeshListenPort},
    ),
    BridgeHostState.sharedAddress => t(
      'Dostawca internetu dzieli jeden adres między wielu klientów, więc '
      'nikt z zewnątrz nie połączy się z tym komputerem. Aplikacja '
      'działa normalnie, tylko nie jest mostem.',
    ),
    BridgeHostState.unreachable => t(
      'Port jest otwarty, ale znajomi nie mogli się połączyć. Sprawdź, czy '
      'Zapora systemu Windows pozwala aplikacji Zen na połączenia '
      'przychodzące.',
    ),
    BridgeHostState.noFriendsOnline => t(
      'Sprawdzenie z zewnątrz robi znajomy. Spróbuję, gdy ktoś będzie '
      'online.',
    ),
  };
}

/// Lists this computer's own addresses (to find a public one).
typedef LocalAddresses = Future<List<InternetAddress>> Function();

Future<List<InternetAddress>> systemAddresses() async {
  final List<InternetAddress> out = <InternetAddress>[];
  try {
    for (final NetworkInterface i in await NetworkInterface.list(
      includeLinkLocal: false,
    )) {
      out.addAll(i.addresses);
    }
  } on Object catch (error) {
    logZenWarning('Nie odczytałem adresów komputera: $error');
  }
  return out;
}

/// Makes this desktop a bridge of the mesh, without asking: opens
/// the port in the home router (UPnP / NAT-PMP), asks friends to check
/// from outside that it really answers, and only then announces it. Kept
/// up to date: the port is renewed, the address re-checked, and the
/// announcement taken back when the computer cannot be reached any more.
final class BridgeHost {
  BridgeHost({
    required this.node,
    this.port = kMeshListenPort,
    PortMapper? mapper,
    LocalAddresses? localAddresses,
    this.refresh = const Duration(minutes: 30),
    this.retrySoon = const Duration(minutes: 5),
    this.reannounceBefore = const Duration(days: 1),
    this.reachTimeout = const Duration(seconds: 20),
    this.announcePowBits = kBridgePowBits,
    int Function()? now,
  }) : _mapper = mapper ?? RouterPortMapper(),
       _localAddresses = localAddresses ?? systemAddresses,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerNode node;
  final int port;
  final Duration refresh;
  final Duration retrySoon;

  /// An announcement this close to expiring is made again.
  final Duration reannounceBefore;

  /// How long friends get to answer a check.
  final Duration reachTimeout;

  /// Proof of work of the announcement (lower only in tests).
  final int announcePowBits;
  final PortMapper _mapper;
  final LocalAddresses _localAddresses;
  final int Function() _now;

  final ValueNotifier<BridgeHostStatus> status = ValueNotifier(
    const BridgeHostStatus(BridgeHostState.waiting),
  );

  PortMapping? _mapping;
  Timer? _timer;
  bool _running = false;
  bool _stopped = false;

  /// Starts after [delay] (the mesh needs a moment) and repeats.
  void start({Duration delay = const Duration(minutes: 1)}) {
    _schedule(delay);
  }

  void _schedule(Duration after) {
    _timer?.cancel();
    if (_stopped) {
      return;
    }
    _timer = Timer(after, () {
      unawaitedLogged(
        runOnce(),
        context: 'Most sieci: sprawdzenie nie udało się',
      );
    });
  }

  /// One round: port, candidates, check, announce. Schedules the next.
  Future<BridgeHostStatus> runOnce() async {
    if (_running || _stopped) {
      return status.value;
    }
    _running = true;
    try {
      final BridgeHostStatus result = await _round();
      if (!_stopped) {
        status.value = result;
        _schedule(
          result.state == BridgeHostState.noFriendsOnline ? retrySoon : refresh,
        );
      }
      return result;
    } finally {
      _running = false;
    }
  }

  Future<BridgeHostStatus> _round() async {
    if (status.value.state != BridgeHostState.active) {
      status.value = BridgeHostStatus(BridgeHostState.checking, at: _now());
    }
    // The router forwarding (renewed every round: leases run out).
    PortMapping? mapping;
    try {
      mapping = await _mapper.map(port);
    } on Object catch (error) {
      logZenWarning('Most sieci: router: $error');
    }
    if (mapping == null && _mapping != null) {
      // Lost it (router restarted?): forget, it is gone anyway.
      _mapping = null;
    }
    _mapping = mapping ?? _mapping;

    final List<({String uri, String method})> candidates =
        <({String uri, String method})>[];
    final InternetAddress? external = mapping?.externalAddress;
    if (mapping != null && external != null && isPublicAddress(external)) {
      candidates.add((
        uri: meshTlsUri(external, mapping.externalPort),
        method: mapping.method,
      ));
    }
    // The router would not open the port but told its address: the port
    // may have been forwarded by hand.
    final InternetAddress? known = _mapper.knownExternalAddress;
    if (mapping == null && known != null && isPublicAddress(known)) {
      candidates.add((uri: meshTlsUri(known, port), method: 'manual'));
    }
    final List<InternetAddress> own =
        (await _localAddresses()).where(isPublicAddress).toList()
          // IPv4 first: everyone can reach it; IPv6 only some.
          ..sort(
            (InternetAddress a, InternetAddress b) =>
                (a.type == InternetAddressType.IPv4 ? 0 : 1).compareTo(
                  b.type == InternetAddressType.IPv4 ? 0 : 1,
                ),
          );
    for (final InternetAddress a in own.take(2)) {
      final String uri = meshTlsUri(a, port);
      if (!candidates.any((c) => c.uri == uri)) {
        candidates.add((uri: uri, method: 'direct'));
      }
    }
    if (candidates.isEmpty) {
      await node.withdrawBridge();
      return BridgeHostStatus(
        mapping != null
            ? BridgeHostState.sharedAddress
            : (_mapper.routerRefused
                  ? BridgeHostState.routerRefused
                  : BridgeHostState.noRouter),
        method: mapping?.method,
        at: _now(),
      );
    }

    bool anyAnswer = false;
    String? lastTried;
    for (final ({String uri, String method}) c in candidates) {
      lastTried = c.uri;
      final ReachResult reach = await node.checkReachable(
        c.uri,
        timeout: reachTimeout,
      );
      if (reach == ReachResult.noAnswer) {
        continue;
      }
      anyAnswer = true;
      if (reach == ReachResult.reachable) {
        await _announce(c.uri);
        return BridgeHostStatus(
          BridgeHostState.active,
          uri: c.uri,
          method: c.method,
          at: _now(),
        );
      }
    }
    if (!anyAnswer) {
      // Nobody to ask: keep a still valid announcement of the same address.
      final BridgeAnnouncement? current = node.ownBridge;
      if (current != null &&
          candidates.any((c) => c.uri == current.uri) &&
          current.expires > _now()) {
        return BridgeHostStatus(
          BridgeHostState.active,
          uri: current.uri,
          at: _now(),
        );
      }
      return BridgeHostStatus(
        BridgeHostState.noFriendsOnline,
        uri: lastTried,
        at: _now(),
      );
    }
    await node.withdrawBridge();
    return BridgeHostStatus(
      mapping == null && _mapper.routerRefused
          ? BridgeHostState.routerRefused
          : BridgeHostState.unreachable,
      uri: lastTried,
      at: _now(),
    );
  }

  Future<void> _announce(String uri) async {
    final BridgeAnnouncement? current = node.ownBridge;
    if (current != null &&
        current.uri == uri &&
        current.expires - _now() > reannounceBefore.inMilliseconds) {
      return;
    }
    await node.announceBridge(uri, powBits: announcePowBits);
  }

  /// Stops and takes the port forwarding off the router.
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    final PortMapping? mapping = _mapping;
    _mapping = null;
    await mapping?.remove();
    status.dispose();
  }
}
