import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/app/zen_host.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/bluetooth_local_links.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/wifi_direct_local_link.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// "Łączność bez internetu": keeps the running node's local
// links in line with the settings, the devices the ledger knows and
// whether the app is used, and runs the native transports (local_link.dart).

/// Where the settings go: the node runtime ([RuntimeNodeRuntime]).
abstract interface class LocalLinksTarget {
  /// The bridge's settings (localLinksSettingsJson).
  void setLocalLinks(String? settingsJson);

  /// The running node's calls, `null` while it is not running.
  LocalLinkNodeApi? get localLinks;
}

final class _RuntimeTarget implements LocalLinksTarget {
  const _RuntimeTarget(this._runtime);

  final RuntimeNodeRuntime _runtime;

  @override
  void setLocalLinks(String? settingsJson) =>
      _runtime.setLocalLinks(settingsJson);

  @override
  LocalLinkNodeApi? get localLinks => _runtime.localLinks;
}

/// The native transports the settings turn on ([LocalLink]s other than the
/// LAN, which the bridge runs itself). Wi-Fi Direct makes a local network,
/// so it needs the LAN setting too; Bluetooth and Multipeer streams do not.
Set<LocalLinkTransport> enabledLocalTransports(AppSettings settings) =>
    <LocalLinkTransport>{
      if (settings.lanDiscoveryOn && settings.wifiDirect)
        LocalLinkTransport.wifiDirect,
      if (settings.bluetoothLinks) LocalLinkTransport.bluetooth,
      if (settings.multipeerLinks) LocalLinkTransport.multipeer,
    };

final class LocalLinksController {
  LocalLinksController({
    required LocalLinksTarget target,
    required Future<List<LocalLinkPeer>> Function() loadPeers,
    List<LocalLink> transports = const <LocalLink>[],
    Future<void> Function(bool held) setMulticastLock =
        AndroidMulticastLock.setHeld,
  }) : _target = target,
       _loadPeers = loadPeers,
       transports = List<LocalLink>.unmodifiable(transports),
       _setMulticastLock = setMulticastLock;

  final LocalLinksTarget _target;
  final Future<List<LocalLinkPeer>> Function() _loadPeers;
  final Future<void> Function(bool held) _setMulticastLock;

  /// The native transports this platform has.
  final List<LocalLink> transports;

  bool _running = false;

  /// Native transports may run: the app is used, or the Android background
  /// service runs.
  bool _active = false;

  /// The app is on screen (beacons more often, the multicast lock).
  bool _foreground = false;
  bool _lan = true;
  Set<LocalLinkTransport> _enabled = const <LocalLinkTransport>{};
  List<LocalLinkPeer> _peers = const <LocalLinkPeer>[];
  LocalNearbyAdverts? _nearby;
  bool? _lockHeld;
  int _generation = 0;
  Future<void> _transportWork = Future<void>.value();

  bool get isRunning => _running;

  /// The devices handed to the bridge last.
  @visibleForTesting
  List<LocalLinkPeer> get peers => _peers;

  /// Starts handing the node its local links. Returns at once: the devices
  /// come once the ledger has them (it may still be loading).
  Future<void> start({required bool active, required bool foreground}) async {
    _running = true;
    _active = active;
    _foreground = foreground;
    _push();
    unawaited(refreshPeers());
    unawaited(_applyTransports());
  }

  Future<void> stop() async {
    _running = false;
    _generation++;
    _target.setLocalLinks(
      localLinksSettingsJson(
        lan: false,
        beaconSeconds: kLocalLinkIdleBeaconSeconds,
        peers: const <LocalLinkPeer>[],
      ),
    );
    await _lock(false);
    await _applyTransports();
  }

  /// The person changed "Łączność bez internetu".
  void setSettings({
    required bool lan,
    required Set<LocalLinkTransport> transports,
  }) {
    if (lan == _lan && setEquals(transports, _enabled)) {
      return;
    }
    _lan = lan;
    _enabled = Set<LocalLinkTransport>.unmodifiable(transports);
    if (_running) {
      _push();
    }
    unawaited(_applyTransports());
  }

  /// The app went to or came back from the background.
  void setUsage({required bool active, required bool foreground}) {
    if (active == _active && foreground == _foreground) {
      return;
    }
    _active = active;
    _foreground = foreground;
    if (_running) {
      _push();
    }
    for (final LocalLink link in transports) {
      link.setForeground(foreground);
    }
    unawaited(_applyTransports());
  }

  /// "W pobliżu" on the local networks: what this device shows there and
  /// whether it looks around (`null`: neither). Goes with the LAN's
  /// beacons, so only while the LAN setting is on.
  void setNearby(LocalNearbyAdverts? nearby) {
    if (nearby == _nearby) {
      return;
    }
    _nearby = nearby;
    if (_running) {
      _push();
    }
  }

  /// Friends or devices changed: new secrets for the bridge.
  Future<void> refreshPeers() async {
    final int generation = ++_generation;
    final List<LocalLinkPeer> peers;
    try {
      peers = await _loadPeers();
    } on Object catch (error, stackTrace) {
      logZenError('Local link devices unreadable', error, stackTrace);
      return;
    }
    if (generation != _generation || !_running) {
      return;
    }
    final bool hadPeers = _peers.isNotEmpty;
    _peers = List<LocalLinkPeer>.unmodifiable(peers);
    _push();
    if (_peers.isNotEmpty != hadPeers) {
      unawaited(_applyTransports());
    }
  }

  /// Tries the transports again: a permission may have been given
  /// meanwhile (the system dialog closed and the app came back).
  Future<void> refreshTransports() => _applyTransports();

  void _push() {
    _target.setLocalLinks(
      localLinksSettingsJson(
        lan: _lan,
        beaconSeconds: _foreground
            ? kLocalLinkActiveBeaconSeconds
            : kLocalLinkIdleBeaconSeconds,
        peers: _peers,
        nearby: _nearby,
      ),
    );
    // Looking around nearby also needs to hear the others' beacons.
    unawaited(
      _lock(
        _lan &&
            ((_foreground && _peers.isNotEmpty) || _nearby?.looking == true),
      ),
    );
  }

  Future<void> _lock(bool held) async {
    if (_lockHeld == held) {
      return;
    }
    _lockHeld = held;
    await _setMulticastLock(held);
  }

  /// Starts the transports that should run and stops the others, one change
  /// at a time. A transport runs only while it can help: switched on, the
  /// app used (or the Android background service running), and devices to
  /// link with (a friend's or the account's own); with none, nobody nearby
  /// could pass the bridge's handshake, so the radio stays quiet.
  Future<void> _applyTransports() {
    return _transportWork = _transportWork.then((_) async {
      for (final LocalLink link in transports) {
        final bool wanted =
            _running &&
            _active &&
            _peers.isNotEmpty &&
            link.isSupported &&
            _enabled.contains(link.transport);
        try {
          if (wanted) {
            await link.start(() => _target.localLinks, foreground: _foreground);
          } else {
            await link.stop();
          }
        } on Object catch (error, stackTrace) {
          logZenError(
            'Local link ${link.transport.wireName} failed',
            error,
            stackTrace,
          );
        }
      }
    });
  }

  void dispose() {
    for (final LocalLink link in transports) {
      link.dispose();
    }
  }
}

/// The native transports of [platform] (this device's by default).
List<LocalLink> platformLocalLinks([TargetPlatform? platform]) {
  final TargetPlatform on = platform ?? localLinksHost;
  final Set<LocalLinkTransport> has = localTransportsOf(on);
  return <LocalLink>[
    if (has.contains(LocalLinkTransport.wifiDirect))
      WifiDirectLocalLink(supportedPlatform: true),
    if (has.contains(LocalLinkTransport.bluetooth)) bluetoothLocalLink(on),
    if (has.contains(LocalLinkTransport.multipeer)) multipeerLocalLink(),
  ];
}

/// The devices this one links with: friends' devices and the account's own,
/// each with its pair secret — post-quantum once paired over [pairing]'s
/// signals ([LocalPairKeys]).
Future<List<LocalLinkPeer>> Function() ledgerLocalLinkPeers(
  LedgerNode? Function() ledger, {
  LocalLinkPairing? pairing,
}) {
  LocalLinkSecrets? secrets;
  return () async {
    final LedgerNode? node = ledger();
    if (node == null) {
      return const <LocalLinkPeer>[];
    }
    await node.start();
    final LocalLinkSecrets made = secrets ??= LocalLinkSecrets(
      node.identity.deviceKey,
      pairs: pairing?.keysFor(node),
    );
    return made.peersFor(node.linkableDevices, account: node.account);
  };
}

/// The pairings of the ledger's device ([LocalPairKeys]): sent and taken
/// over the signal transport.
final class LocalLinkPairing {
  LocalLinkPairing(this.transport);

  final SignalTransport transport;
  LocalPairKeys? _keys;
  LedgerNode? _node;

  /// Called when a pair's secret changed.
  void Function()? onChanged;

  /// The pairings of [node]'s device (made the first time).
  LocalPairKeys keysFor(LedgerNode node) {
    final LocalPairKeys? had = _keys;
    if (had != null && identical(_node, node)) {
      return had;
    }
    _node = node;
    return _keys = LocalPairKeys(
      disk: node.disk,
      ownDevice: node.identity.deviceKey.id,
      send: (String to, Map<String, dynamic> payload) =>
          transport.send(remoteAddress: to, payload: payload),
    )..onChanged = () => onChanged?.call();
  }

  /// A signal that came: a pairing is taken from a device the ledger has
  /// at the sender's address.
  Future<void> onFrame(SignalTransportFrame frame) async {
    final LedgerNode? node = _node;
    final LocalPairKeys? keys = _keys;
    if (node == null || keys == null) {
      return;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    await keys.onFrame(
      frame,
      deviceAt: (String address) {
        for (final AccountDevice d in node.linkableDevices) {
          final String? at = d.address;
          if (at != null && PeerShareCodec.normalizeAddress(at) == from) {
            return d.device;
          }
        }
        return null;
      },
    );
  }
}

/// What "W pobliżu" shows and looks for on the local networks (set by the
/// nearby service, `meet_providers.dart`); kept apart from the controller,
/// which is made again when the ledger changes.
final Provider<ValueNotifier<LocalNearbyAdverts?>> localNearbyProvider =
    Provider<ValueNotifier<LocalNearbyAdverts?>>((Ref ref) {
      final ValueNotifier<LocalNearbyAdverts?> nearby =
          ValueNotifier<LocalNearbyAdverts?>(null);
      ref.onDispose(nearby.dispose);
      return nearby;
    });

final Provider<LocalLinksController> localLinksControllerProvider =
    Provider<LocalLinksController>((Ref ref) {
      final LedgerNode? ledger = ref.watch(ledgerNodeProvider);
      final SignalTransport transport = ref.read(signalTransportProvider);
      final LocalLinkPairing pairing = LocalLinkPairing(transport);
      final LocalLinksController controller = LocalLinksController(
        target: _RuntimeTarget(ref.watch(runtimeNodeRuntimeProvider)),
        loadPeers: ledgerLocalLinkPeers(() => ledger, pairing: pairing),
        transports: platformLocalLinks(),
      );
      pairing.onChanged = () => unawaited(controller.refreshPeers());
      final ValueNotifier<LocalNearbyAdverts?> nearby = ref.read(
        localNearbyProvider,
      );
      void onNearby() => controller.setNearby(nearby.value);
      onNearby();
      nearby.addListener(onNearby);
      ref.listen<AppSettings>(appSettingsControllerProvider, (
        AppSettings? previous,
        AppSettings next,
      ) {
        controller.setSettings(
          lan: next.lanDiscoveryOn,
          transports: enabledLocalTransports(next),
        );
      }, fireImmediately: true);
      final List<StreamSubscription<void>> subscriptions =
          <StreamSubscription<void>>[
            transport.frames
                .where(
                  (SignalTransportFrame f) =>
                      f.payload['type'] == kLocalPairType,
                )
                .listen(
                  (SignalTransportFrame f) => unawaitedLogged(
                    pairing.onFrame(f),
                    context: 'Local link pairing',
                  ),
                ),
            if (ledger != null) ...<StreamSubscription<void>>[
              ledger.devicesChanged.listen(
                (_) => unawaited(controller.refreshPeers()),
              ),
              ledger.contactsChanged.listen(
                (_) => unawaited(controller.refreshPeers()),
              ),
            ],
          ];
      ref.onDispose(() {
        nearby.removeListener(onNearby);
        for (final StreamSubscription<void> s in subscriptions) {
          unawaited(s.cancel());
        }
        unawaitedLogged(controller.stop(), context: 'Stopping local links');
        controller.dispose();
      });
      return controller;
    });

/// What the settings page shows of the bridge's local links; read every few
/// seconds while it is open.
final Provider<LocalLinksStatus Function()> localLinksStatusReaderProvider =
    Provider<LocalLinksStatus Function()>((Ref ref) {
      final RuntimeNodeRuntime runtime = ref.watch(runtimeNodeRuntimeProvider);
      return () {
        try {
          return runtime.localLinks?.status() ?? LocalLinksStatus.empty;
        } on Object catch (error) {
          logZenWarning('Local links status unreadable: $error');
          return LocalLinksStatus.empty;
        }
      };
    });

/// The local links module of [ZenCore]: on while the core runs. In the app
/// the native transports run while it is used, on Android while its core
/// runs at all (on screen or unlocked in the background).
final class LocalLinksModule extends ZenModule {
  LocalLinksModule(this._ref);

  final Ref _ref;
  bool _interactive = false;
  bool _started = false;

  /// Devices are read again this often anyway (friends removed).
  static const int refreshMinutes = 5;

  @override
  String get id => 'local-links';

  /// Links keep going with nobody looking: in the background service, and
  /// on Android in the app too — its core runs there only while it owns
  /// the node, on screen or unlocked in the background.
  bool get _background =>
      _ref.read(zenHostProvider) == ZenHost.backgroundService ||
      Platform.isAndroid;

  @override
  Future<void> start() async {
    _started = true;
    await _ref
        .read(localLinksControllerProvider)
        .start(active: _background || _interactive, foreground: _interactive);
  }

  @override
  Future<void> stop() async {
    _started = false;
    await _ref.read(localLinksControllerProvider).stop();
  }

  @override
  void onInteractiveChanged(bool interactive) {
    _interactive = interactive;
    if (!_started) {
      return;
    }
    _ref
        .read(localLinksControllerProvider)
        .setUsage(active: _background || interactive, foreground: interactive);
  }

  @override
  void onResume() {
    if (_started) {
      unawaited(_ref.read(localLinksControllerProvider).refreshTransports());
    }
  }

  @override
  void onMinute(int minute) {
    if (minute % refreshMinutes == 0) {
      unawaited(_ref.read(localLinksControllerProvider).refreshPeers());
    }
  }
}
