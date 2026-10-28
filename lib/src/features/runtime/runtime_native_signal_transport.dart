import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/utils/copy_with_cast.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/node_key_pins.dart';
import 'package:zen/src/features/runtime/public_peers.dart';
import 'package:zen/src/features/runtime/runtime_signal_codec.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';
import 'package:zen/src/features/runtime/yggdrasil_signal_transport.dart';
import 'package:zen/src/features/runtime/yggdrasil_signal_waiter.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

typedef SignalTransportBootstrap = Future<SignalTransport> Function();
typedef RuntimeNodeSessionBootstrap = Future<RuntimeNodeSession> Function();

final Provider<RuntimeSignalBootstrapConfig>
runtimeSignalBootstrapConfigProvider = Provider<RuntimeSignalBootstrapConfig>((
  Ref ref,
) {
  return RuntimeSignalBootstrapConfig();
});

final Provider<RuntimeNodeRuntime> runtimeNodeRuntimeProvider =
    Provider<RuntimeNodeRuntime>((Ref ref) {
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
      ref.onDispose(runtime.dispose);
      return runtime;
    });

final NotifierProvider<RuntimeNodeSnapshotController, RuntimeTransportSnapshot>
runtimeNodeSnapshotProvider =
    NotifierProvider<RuntimeNodeSnapshotController, RuntimeTransportSnapshot>(
      RuntimeNodeSnapshotController.new,
    );

List buildRuntimeTransportProviderOverrides({
  required RuntimeNodeRuntime runtime,
  required RuntimeSignalBootstrapConfig runtimeConfig,
  RelayStateStore? relayStateStore,
}) {
  return [
    runtimeNodeRuntimeProvider.overrideWithValue(runtime),
    if (relayStateStore == null)
      // Friends with several devices look like one person.
      signalTransportProvider.overrideWith(
        (Ref ref) => withAccountRouting(ref, runtime),
      )
    else
      // Store-and-forward delivery (outbox, acks, friends as relays) on top
      // of the raw mesh transport.
      ...buildRelayTransportProviderOverrides(
        runtime: runtime,
        relayStateStore: relayStateStore,
      ),
    runtimeSignalBootstrapConfigProvider.overrideWithValue(runtimeConfig),
  ];
}

final class RuntimeNodeSnapshotController
    extends Notifier<RuntimeTransportSnapshot> {
  RuntimeNodeRuntime? _runtime;
  VoidCallback? _listener;

  @override
  RuntimeTransportSnapshot build() {
    final RuntimeNodeRuntime runtime = ref.watch(runtimeNodeRuntimeProvider);
    if (!identical(_runtime, runtime)) {
      final RuntimeNodeRuntime? previousRuntime = _runtime;
      final VoidCallback? previousListener = _listener;
      if (previousRuntime != null && previousListener != null) {
        previousRuntime.removeListener(previousListener);
      }
      void handleRuntimeChanged() {
        state = runtime.snapshot;
      }

      runtime.addListener(handleRuntimeChanged);
      _runtime = runtime;
      _listener = handleRuntimeChanged;
      ref.onDispose(() {
        runtime.removeListener(handleRuntimeChanged);
      });
    }
    return runtime.snapshot;
  }
}

enum RuntimeTransportHealth { active, syncing, stopped, failed }

const Object _runtimeSnapshotSentinel = Object();

@immutable
final class RuntimeTransportSnapshot {
  const RuntimeTransportSnapshot({
    required this.health,
    required this.peers,
    required this.activeTransfers,
    required this.latencyMs,
    required this.throughputMbps,
    required this.inboxLimitMb,
    this.localAddress = '',
    this.routingEntries = 0,
    this.peerPoolCount = 0,
    this.selectedPeer = '',
    this.errorMessage,
  });

  factory RuntimeTransportSnapshot.preview() {
    return const RuntimeTransportSnapshot(
      health: RuntimeTransportHealth.active,
      peers: 12,
      activeTransfers: 1,
      latencyMs: 48,
      throughputMbps: 18.4,
      inboxLimitMb: 32,
      routingEntries: 24,
      peerPoolCount: 5,
      selectedPeer: 'tcp://127.0.0.1:9001',
    );
  }

  factory RuntimeTransportSnapshot.started({
    required String localAddress,
    required int peers,
  }) {
    return RuntimeTransportSnapshot(
      health: RuntimeTransportHealth.active,
      peers: peers,
      activeTransfers: 0,
      latencyMs: 0,
      throughputMbps: 0,
      inboxLimitMb: 32,
      localAddress: localAddress,
      routingEntries: 0,
      peerPoolCount: 0,
      selectedPeer: '',
    );
  }

  factory RuntimeTransportSnapshot.stopped({
    String localAddress = '',
    String? errorMessage,
  }) {
    return RuntimeTransportSnapshot(
      health: RuntimeTransportHealth.stopped,
      peers: 0,
      activeTransfers: 0,
      latencyMs: 0,
      throughputMbps: 0,
      inboxLimitMb: 32,
      localAddress: localAddress,
      routingEntries: 0,
      peerPoolCount: 0,
      selectedPeer: '',
      errorMessage: errorMessage,
    );
  }

  factory RuntimeTransportSnapshot.syncing({
    String localAddress = '',
    String? errorMessage,
  }) {
    return RuntimeTransportSnapshot(
      health: RuntimeTransportHealth.syncing,
      peers: 0,
      activeTransfers: 0,
      latencyMs: 0,
      throughputMbps: 0,
      inboxLimitMb: 32,
      localAddress: localAddress,
      routingEntries: 0,
      peerPoolCount: 0,
      selectedPeer: '',
      errorMessage: errorMessage,
    );
  }

  factory RuntimeTransportSnapshot.failed({
    String localAddress = '',
    required String errorMessage,
  }) {
    return RuntimeTransportSnapshot(
      health: RuntimeTransportHealth.failed,
      peers: 0,
      activeTransfers: 0,
      latencyMs: 0,
      throughputMbps: 0,
      inboxLimitMb: 32,
      localAddress: localAddress,
      routingEntries: 0,
      peerPoolCount: 0,
      selectedPeer: '',
      errorMessage: errorMessage,
    );
  }

  final RuntimeTransportHealth health;
  final int peers;
  final int activeTransfers;
  final int latencyMs;
  final double throughputMbps;
  final int inboxLimitMb;
  final String localAddress;
  final int routingEntries;
  final int peerPoolCount;
  final String selectedPeer;
  final String? errorMessage;

  bool get serviceRunning =>
      health == RuntimeTransportHealth.active ||
      health == RuntimeTransportHealth.syncing;

  /// Equal snapshots tell nobody anything: the node is read every few
  /// seconds, and only a change rebuilds what shows it.
  @override
  bool operator ==(Object other) =>
      other is RuntimeTransportSnapshot &&
      other.health == health &&
      other.peers == peers &&
      other.activeTransfers == activeTransfers &&
      other.latencyMs == latencyMs &&
      other.throughputMbps == throughputMbps &&
      other.inboxLimitMb == inboxLimitMb &&
      other.localAddress == localAddress &&
      other.routingEntries == routingEntries &&
      other.peerPoolCount == peerPoolCount &&
      other.selectedPeer == selectedPeer &&
      other.errorMessage == errorMessage;

  @override
  int get hashCode => Object.hash(
    health,
    peers,
    activeTransfers,
    latencyMs,
    throughputMbps,
    inboxLimitMb,
    localAddress,
    routingEntries,
    peerPoolCount,
    selectedPeer,
    errorMessage,
  );

  RuntimeTransportSnapshot copyWith({
    RuntimeTransportHealth? health,
    int? peers,
    int? activeTransfers,
    int? latencyMs,
    double? throughputMbps,
    int? inboxLimitMb,
    String? localAddress,
    int? routingEntries,
    int? peerPoolCount,
    String? selectedPeer,
    Object? errorMessage = _runtimeSnapshotSentinel,
  }) {
    return RuntimeTransportSnapshot(
      health: health ?? this.health,
      peers: peers ?? this.peers,
      activeTransfers: activeTransfers ?? this.activeTransfers,
      latencyMs: latencyMs ?? this.latencyMs,
      throughputMbps: throughputMbps ?? this.throughputMbps,
      inboxLimitMb: inboxLimitMb ?? this.inboxLimitMb,
      localAddress: localAddress ?? this.localAddress,
      routingEntries: routingEntries ?? this.routingEntries,
      peerPoolCount: peerPoolCount ?? this.peerPoolCount,
      selectedPeer: selectedPeer ?? this.selectedPeer,
      errorMessage: identical(errorMessage, _runtimeSnapshotSentinel)
          ? this.errorMessage
          : castCopyWithValue<String>(errorMessage, fieldName: 'errorMessage'),
    );
  }
}

@immutable
final class RuntimeNodeSession {
  const RuntimeNodeSession({
    required this.transport,
    required this.snapshot,
    this.refreshSnapshot,
    this.addPeer,
    this.removePeer,
    this.startDoor,
    this.stopDoor,
    this.setMailboxDoors,
    this.sendFromDoor,
    this.localLinks,
    this.sessionKey = '',
    this.pinSessionKeys,
    this.setOnScreen,
  });

  final SignalTransport transport;
  final RuntimeTransportSnapshot snapshot;
  final Future<RuntimeTransportSnapshot> Function()? refreshSnapshot;

  /// Adds a mesh peer at runtime (bridges learnt from friends).
  final void Function(String uri)? addPeer;

  /// Drops a mesh peer added with [addPeer] (a bridge no longer chosen).
  final void Function(String uri)? removePeer;

  /// Runs the flat's door with a key (hex seed) and returns its address.
  /// (door_node.go in the bridge).
  final String? Function(String seedHex)? startDoor;
  final void Function()? stopDoor;

  /// Runs exactly the mailbox doors with these keys (hex seeds) for friends
  /// (flat_door_mail.dart, door_node.go).
  final void Function(List<String> seedsHex)? setMailboxDoors;

  /// Sends a flat frame from the flat's door, not from this node
  /// (door_node.go); throws without a running door.
  final Future<void> Function(
    String remoteAddress,
    Map<String, dynamic> payload,
  )?
  sendFromDoor;

  /// Direct links with devices nearby (local_link.dart).
  final LocalLinkNodeApi? localLinks;

  /// Fingerprint (hex) of this node's post-quantum device key, which seals
  /// and authenticates its signals (pq_session.go); '' without a bridge.
  final String sessionKey;

  /// Pins device keys (address → fingerprint) in the bridge; with `keep`, a
  /// different pin already there stays. Returns the conflicts (address →
  /// the pinned fingerprint).
  final Map<String, String> Function(Map<String, String> pins, bool keep)?
  pinSessionKeys;

  /// Tells the bridge whether the app that runs the node is on screen
  /// (node_identity.go).
  final void Function(bool onScreen)? setOnScreen;
}

/// Who runs a node in this process: the app, or a background engine
/// (Android's service, an iPhone's locked receiver, a computer's tray).
enum RuntimeNodeRole { app, service }

/// The owner a node is started for, named at every start (node_identity.go
/// in the bridge). One process may hold the app's engine, a stale engine of
/// an app that opened again, and the background service at once; the
/// newest legitimate owner of an identity wins, and an owner whose node was
/// taken over goes quiet instead of starting it again ([RuntimeNodeRuntime]).
final class RuntimeNodeOwner {
  RuntimeNodeOwner(this.role);

  final RuntimeNodeRole role;

  /// The number the bridge gave this owner at its first start (0 before):
  /// higher is newer.
  int engine = 0;

  /// The next start claims the identity (takes it from an owner this one
  /// outranks): an owner's first start, and one its own logic asked for
  /// after it stopped the node. Restarts of a node lost on the way do not.
  bool claim = true;

  /// The app is on screen: the service never takes the identity from it.
  bool onScreen = false;

  Map<String, Object?> toJson() => <String, Object?>{
    'role': role.name,
    'engine': engine,
    'claim': claim,
    'onScreen': onScreen,
  };

  /// Notes the number a start's answer ([result]) gave this owner.
  void started(Map<String, dynamic> result) {
    final int given = (result['ownerEngine'] as num?)?.toInt() ?? 0;
    if (given > 0) {
      engine = given;
    }
  }
}

/// [configJson] with the [owner] the node is started for (the bridge takes
/// the key out again before it reads the config).
@visibleForTesting
String withNodeOwner(String configJson, RuntimeNodeOwner? owner) {
  if (owner == null) {
    return configJson;
  }
  final Object? decoded = jsonDecode(configJson);
  if (decoded is! Map<String, dynamic>) {
    return configJson;
  }
  return jsonEncode(<String, dynamic>{
    ...decoded,
    'ZenNodeOwner': owner.toJson(),
  });
}

/// The bridge's words for "another owner runs this identity in this
/// process, and it outranks you" (node_identity.go): the start was refused,
/// or the running node was taken over.
const List<String> _kNodeOwnerYields = <String>[
  'a newer owner runs this identity',
  'a newer app engine runs this identity',
  'taken over by a newer owner',
  'the app runs this identity on screen',
];

/// Whether [error] says another owner of this identity runs its node in
/// this process and outranks this one: no retry helps then.
@visibleForTesting
bool isNodeOwnerYield(Object? error) {
  final String text = '$error';
  return _kNodeOwnerYields.any(text.contains);
}

/// Another owner of this identity outranked this runtime's owner.
@immutable
final class RuntimeNodeYield {
  const RuntimeNodeYield({required this.reason, required this.wasRunning});

  /// The bridge's words.
  final String reason;

  /// The node ran and was taken over (otherwise a start was refused).
  final bool wasRunning;

  /// A newer app engine runs the identity: an app engine it replaced never
  /// runs it again.
  bool get byNewerApp =>
      reason.contains('a newer app engine runs this identity') ||
      reason.contains('(by the app)');
}

/// How often a background owner whose node another owner took looks again
/// whether the identity is free (a start that takes nobody's node).
const Duration kRuntimeYieldRetry = Duration(minutes: 1);

/// Platforms that ship the Go bridge (a DLL, a .so, or linked into the iOS
/// and macOS app).
bool get _hasNativeBridge =>
    Platform.isWindows ||
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isLinux ||
    Platform.isMacOS;

RuntimeNodeRuntime buildDefaultRuntimeNodeRuntime({
  RuntimeSignalBootstrapConfig? config,
  RuntimeNodeRole role = RuntimeNodeRole.app,
}) {
  if (!_hasNativeBridge) {
    return RuntimeNodeRuntime.preview();
  }
  final RuntimeSignalBootstrapConfig resolvedConfig =
      config ?? RuntimeSignalBootstrapConfig();
  final RuntimeNodeOwner owner = RuntimeNodeOwner(role);
  return RuntimeNodeRuntime.live(
    owner: owner,
    bootstrap: () =>
        _bootstrapDefaultRuntimeSession(config: resolvedConfig, owner: owner),
  );
}

SignalTransport buildDefaultSignalTransport({
  RuntimeSignalBootstrapConfig? config,
}) {
  if (!_hasNativeBridge) {
    return const NoopSignalTransport();
  }
  final RuntimeSignalBootstrapConfig resolvedConfig =
      config ?? RuntimeSignalBootstrapConfig();
  return LazySignalTransport(
    bootstrap: () => _bootstrapDefaultSignalTransport(config: resolvedConfig),
  );
}

/// [configJson] with the number of public peers a phone node should dial
/// (the bridge takes the key out again before it reads the config). Never
/// stored: only what goes to the bridge at start.
@visibleForTesting
String withNodePeerTarget(String configJson, int? peerTarget) {
  if (peerTarget == null || peerTarget <= 0) {
    return configJson;
  }
  final Object? decoded = jsonDecode(configJson);
  if (decoded is! Map<String, dynamic>) {
    return configJson;
  }
  return jsonEncode(<String, dynamic>{...decoded, 'ZenPeerTarget': peerTarget});
}

@visibleForTesting
String normalizeRuntimeNodeConfig(
  String configJson, {
  required bool isAndroid,
  required bool isWindows,
}) {
  // Platform defaults (listen addresses, multicast discovery, peer pool) are
  // owned by the native bridge; Dart only validates the JSON envelope here.
  final Object? decoded = jsonDecode(configJson);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Node config must be a JSON object.');
  }
  return jsonEncode(decoded);
}

/// How often the node's state is read: while it has no peer yet, while Zen
/// is on the screen, and otherwise (the app in the background, the
/// background service). Signals do not wait for it: they come as they
/// arrive.
const Duration kRuntimeRefreshConnecting = Duration(seconds: 2);
const Duration kRuntimeRefreshOnScreen = Duration(seconds: 10);
const Duration kRuntimeRefreshUnseen = Duration(minutes: 1);

@visibleForTesting
final class LazySignalTransport implements SignalTransport {
  LazySignalTransport({required this.bootstrap});

  final SignalTransportBootstrap bootstrap;
  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();

  SignalTransport? _delegate;
  StreamSubscription<SignalTransportFrame>? _forwardingSubscription;
  Future<void>? _starting;

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() {
    final Future<void>? inFlight = _starting;
    if (inFlight != null) {
      return inFlight;
    }
    final Future<void> operation = _startInternal();
    _starting = operation;
    return operation.whenComplete(() {
      if (identical(_starting, operation)) {
        _starting = null;
      }
    });
  }

  @override
  Future<void> stop() async {
    await _forwardingSubscription?.cancel();
    _forwardingSubscription = null;
    final SignalTransport? delegate = _delegate;
    _delegate = null;
    if (delegate != null) {
      await delegate.stop();
    }
  }

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await start();
    final SignalTransport? delegate = _delegate;
    if (delegate == null) {
      return;
    }
    await delegate.send(remoteAddress: remoteAddress, payload: payload);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async {
    await start();
    final SignalTransport? delegate = _delegate;
    if (delegate == null) {
      return 0;
    }
    return delegate.openRelay(callId: callId, remoteAddress: remoteAddress);
  }

  @override
  Future<void> closeRelay(String callId) async {
    final SignalTransport? delegate = _delegate;
    if (delegate == null) {
      return;
    }
    await delegate.closeRelay(callId);
  }

  Future<void> _startInternal() async {
    if (_delegate != null) {
      await _delegate!.start();
      return;
    }
    final SignalTransport delegate = await bootstrap();
    _forwardingSubscription = delegate.frames.listen(
      _frames.add,
      onError: _frames.addError,
    );
    _delegate = delegate;
    try {
      await delegate.start();
    } catch (error, stackTrace) {
      logZenError('Signal transport bootstrap failed', error, stackTrace);
      await _forwardingSubscription?.cancel();
      _forwardingSubscription = null;
      _delegate = null;
      rethrow;
    }
  }
}

final class ManagedSignalTransport implements SignalTransport {
  ManagedSignalTransport({required this.delegate, required this.onStop});

  final SignalTransport delegate;
  final Future<void> Function() onStop;
  bool _stopped = false;

  @override
  Stream<SignalTransportFrame> get frames => delegate.frames;

  @override
  Future<void> start() => delegate.start();

  @override
  Future<void> stop() async {
    await delegate.stop();
    if (_stopped) {
      return;
    }
    _stopped = true;
    await onStop();
  }

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) {
    return delegate.send(remoteAddress: remoteAddress, payload: payload);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) {
    return delegate.openRelay(callId: callId, remoteAddress: remoteAddress);
  }

  @override
  Future<void> closeRelay(String callId) {
    return delegate.closeRelay(callId);
  }
}

final class RuntimeNodeRuntime extends ChangeNotifier
    implements SignalTransport {
  RuntimeNodeRuntime.preview()
    : _bootstrap = null,
      _previewMode = true,
      owner = RuntimeNodeOwner(RuntimeNodeRole.app),
      _yieldRetryAfter = kRuntimeYieldRetry,
      _snapshot = RuntimeTransportSnapshot.preview();

  RuntimeNodeRuntime.live({
    required RuntimeNodeSessionBootstrap bootstrap,
    RuntimeNodeOwner? owner,
    @visibleForTesting Duration yieldRetry = kRuntimeYieldRetry,
  }) : _bootstrap = bootstrap,
       _previewMode = false,
       owner = owner ?? RuntimeNodeOwner(RuntimeNodeRole.app),
       _yieldRetryAfter = yieldRetry,
       _snapshot = RuntimeTransportSnapshot.stopped();

  final RuntimeNodeSessionBootstrap? _bootstrap;
  final bool _previewMode;
  final Duration _yieldRetryAfter;

  /// Whom the node is started for ([RuntimeNodeOwner]); the bootstrap names
  /// it to the bridge.
  final RuntimeNodeOwner owner;
  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();
  final StreamController<SignalTransportFrame> _doorFrames =
      StreamController<SignalTransportFrame>.broadcast();

  /// What came to the flat's door and the mailbox doors, for the
  /// neighbours section only. It never reaches [frames]: nothing else in the
  /// app (the ledger, the relay layer, friends, calls) may answer what came
  /// to a door, or the answer would tell the sender whose door it is.
  Stream<SignalTransportFrame> get doorFrames => _doorFrames.stream;

  void _forward(SignalTransportFrame frame) {
    final Object? type = frame.payload['type'];
    if (!frame.door) {
      _frames.add(frame);
    } else if (kFlatDoorTypes.contains(type)) {
      // The bridge lets only flat frames through the doors; anything else
      // that claims to come from one is dropped here too.
      _doorFrames.add(frame);
    }
  }

  /// Sends a flat frame from the flat's door: what goes to
  /// neighbour flats never carries this phone's own address. False while
  /// no door runs.
  Future<bool> sendFromDoor(
    String remoteAddress,
    Map<String, dynamic> payload,
  ) async {
    final Future<void> Function(String, Map<String, dynamic>)? send =
        _session?.sendFromDoor;
    if (send == null || _doorAddress == null) {
      return false;
    }
    try {
      await send(remoteAddress, payload);
      return true;
    } on Object catch (error) {
      logZenWarning('Drzwi mieszkania nie wysłały: $error');
      return false;
    }
  }

  /// Hands [frame] to [frames] as if this node had just received it: what
  /// the Android background service kept sealed while the app was locked,
  /// opened after unlock.
  void replayReceived(SignalTransportFrame frame) {
    if (!_frames.isClosed) {
      _forward(frame);
    }
  }

  /// Backoff schedule for the self-healing restart loop. The node binds a
  /// fixed peering port, so a start can fail for a while after a crash or a
  /// previous process that is still shutting down — without this the runtime
  /// stayed dead until the user restarted the app by hand.
  static const List<Duration> _recoveryBackoff = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 30),
  ];

  RuntimeNodeSession? _session;

  /// Mesh peers added at runtime; kept so they are re-added after the node
  /// restarts.
  final Set<String> _extraPeers = <String>{};

  /// Device keys others vouched for (address → fingerprint): friends'
  /// hybrid-signed device records and hellos, friends' friend lists. Kept
  /// so they are pinned again after the node restarts.
  final Map<String, String> _vouchedKeys = <String, String>{};
  static const int _maxVouchedKeys = 20000;
  final StreamController<String> _keyConflicts =
      StreamController<String>.broadcast();
  final Set<String> _reportedConflicts = <String>{};

  /// Fingerprint of this node's post-quantum device key ('' while no node
  /// runs): the ledger's hello signs it together with the address.
  String get sessionKey => _session?.sessionKey ?? '';

  /// Addresses where two sources disagree about the device key: the key
  /// the node pinned is not the one a signed record names. Each address
  /// once per run.
  Stream<String> get sessionKeyConflicts => _keyConflicts.stream;

  /// Pins [keys] (address → device key fingerprint) in the bridge before
  /// any contact, so someone holding only an address's broken node key is
  /// refused even on first contact. With [force] (a hybrid-signed hello
  /// of a known friend contradicts the session) the key replaces whatever
  /// was pinned; otherwise a different pin stays and is reported on
  /// [sessionKeyConflicts]. Safe to call before the node is up.
  void vouchSessionKeys(Map<String, String> keys, {bool force = false}) {
    final Map<String, String> pins = <String, String>{};
    keys.forEach((String address, String key) {
      final String normalized = PeerShareCodec.normalizeAddress(address);
      final String fingerprint = key.trim().toLowerCase();
      if (normalized.isEmpty || fingerprint.length != 64) {
        return;
      }
      if (!_vouchedKeys.containsKey(normalized) &&
          _vouchedKeys.length >= _maxVouchedKeys) {
        return;
      }
      _vouchedKeys[normalized] = fingerprint;
      pins[normalized] = fingerprint;
    });
    if (pins.isNotEmpty) {
      _pinNow(pins, keep: !force);
    }
  }

  void _pinNow(Map<String, String> pins, {required bool keep}) {
    final Map<String, String> Function(Map<String, String>, bool)? pin =
        _session?.pinSessionKeys;
    if (pin == null) {
      return;
    }
    try {
      for (final String address in pin(pins, keep).keys) {
        final String normalized = PeerShareCodec.normalizeAddress(address);
        if (_reportedConflicts.add(normalized) && !_keyConflicts.isClosed) {
          _keyConflicts.add(normalized);
        }
      }
    } on Object catch (error) {
      logZenWarning('Device keys were not pinned: $error');
    }
  }

  /// Connects to [uris] as additional mesh peers (bridges from friends).
  /// Already added ones are skipped. Safe to call before the node is up.
  void addMeshPeers(Iterable<String> uris) {
    for (final String uri in uris) {
      if (!_extraPeers.add(uri)) {
        continue;
      }
      _addPeerNow(uri);
    }
  }

  /// Makes [uris] the additional mesh peers (the bridges chosen now): new
  /// ones are connected, ones no longer chosen dropped (every connection
  /// costs traffic and keep-alives). Safe to call before the node is up.
  void setMeshPeers(Iterable<String> uris) {
    final Set<String> wanted = uris.toSet();
    for (final String uri in _extraPeers.toList()) {
      if (!wanted.contains(uri)) {
        _extraPeers.remove(uri);
        _removePeerNow(uri);
      }
    }
    addMeshPeers(wanted);
  }

  /// The additional mesh peers asked for now (tests).
  @visibleForTesting
  Set<String> get meshPeers => Set<String>.unmodifiable(_extraPeers);

  /// The key (hex seed) of the flat's door the neighbours section wants
  /// running; kept so the door comes back after the node restarts.
  String? _doorSeed;
  String? _doorAddress;

  /// The address of the flat's door while it runs: a node of its
  /// own next to this one, so the door sticker carries no one's address.
  String? get doorAddress => _doorAddress;

  /// Runs the flat's door with the key [seedHex] (a new key is a new
  /// door), or stops it with `null`. Safe to call before the node is up.
  void setDoorKey(String? seedHex) {
    if (seedHex == _doorSeed) {
      return;
    }
    _doorSeed = seedHex;
    _applyDoorNow();
  }

  void _applyDoorNow() {
    final RuntimeNodeSession? session = _session;
    final String? seed = _doorSeed;
    String? address;
    if (session != null) {
      try {
        if (seed == null) {
          session.stopDoor?.call();
        } else {
          address = session.startDoor?.call(seed);
        }
      } on Object catch (error) {
        logZenWarning('Drzwi mieszkania nie ruszyły: $error');
      }
    }
    _setDoorAddress(address);
  }

  /// Keys (hex seeds) of the mailbox doors this phone runs for friends;
  /// kept so they come back after the node restarts.
  List<String> _mailboxSeeds = const <String>[];

  /// Runs exactly the mailbox doors with the keys [seedsHex] (an empty list
  /// stops them). Safe to call before the node is up.
  void setMailboxDoorKeys(List<String> seedsHex) {
    if (listEquals(seedsHex, _mailboxSeeds)) {
      return;
    }
    _mailboxSeeds = List<String>.unmodifiable(seedsHex);
    _applyMailboxDoorsNow();
  }

  void _applyMailboxDoorsNow() {
    final RuntimeNodeSession? session = _session;
    if (session == null) {
      return;
    }
    try {
      session.setMailboxDoors?.call(_mailboxSeeds);
    } on Object catch (error) {
      logZenWarning('Drzwi znajomych nie ruszyły: $error');
    }
  }

  /// The local link settings (localLinksSettingsJson) the app wants;
  /// kept so they come back after the node restarts.
  String? _localLinksJson;

  /// The running node's local link calls, `null` while it is not running.
  LocalLinkNodeApi? get localLinks => _session?.localLinks;

  /// Sets the devices to link with nearby and the LAN; `null`
  /// turns local links off. Safe to call before the node is up.
  void setLocalLinks(String? settingsJson) {
    if (settingsJson == _localLinksJson) {
      return;
    }
    _localLinksJson = settingsJson;
    _applyLocalLinksNow();
  }

  void _applyLocalLinksNow() {
    final LocalLinkNodeApi? api = _session?.localLinks;
    final String? json = _localLinksJson;
    if (api == null || json == null) {
      return;
    }
    try {
      api.configure(json);
    } on Object catch (error) {
      logZenWarning('Local links not set: $error');
    }
  }

  void _setDoorAddress(String? address) {
    if (address == _doorAddress) {
      return;
    }
    _doorAddress = address;
    notifyListeners();
  }

  void _addPeerNow(String uri) {
    final void Function(String uri)? add = _session?.addPeer;
    if (add == null) {
      return;
    }
    try {
      add(uri);
    } catch (error) {
      logZenWarning('Dodanie mostu $uri nie udało się: $error');
    }
  }

  void _removePeerNow(String uri) {
    final void Function(String uri)? remove = _session?.removePeer;
    if (remove == null) {
      return;
    }
    try {
      remove(uri);
    } catch (error) {
      logZenWarning('Usunięcie mostu $uri nie udało się: $error');
    }
  }

  StreamSubscription<SignalTransportFrame>? _forwardingSubscription;
  Timer? _snapshotRefreshTimer;
  Timer? _recoveryTimer;
  int _recoveryAttempt = 0;
  bool _autoRecoveryEnabled = false;
  Future<void>? _starting;
  RuntimeTransportSnapshot _snapshot;
  int _lifecycleToken = 0;

  RuntimeTransportSnapshot get snapshot => _snapshot;

  /// Another process runs this identity's node (the Android background
  /// service): [start] does nothing until [releaseFromService]. Two nodes
  /// on one key split what friends send between them, and the one in a
  /// locked app drops its share.
  bool _heldByService = false;

  /// Whether [start] waits for the service to let go of the node.
  bool get heldByService => _heldByService;

  /// From now on [start] does nothing (a node already up stays up: the
  /// caller stops it). Before anything may start the node: the background
  /// bridge does this before it knows the service let go.
  void holdForService() {
    _heldByService = true;
  }

  /// The service confirmed it runs no node: [start] works again.
  void releaseFromService() {
    _heldByService = false;
  }

  /// Another owner of this identity runs its node in this process and
  /// outranks this one (a newer app engine, the service that took the node
  /// of a gone app, the app back on screen): [start] does nothing until the
  /// owner's own logic stops the node on purpose ([stop]) and starts it
  /// again. Restarts on their own would only fight the other owner.
  bool _yielded = false;

  /// An app engine that a newer app engine replaced (an account opened
  /// again in this process, a new Activity): it never starts the node
  /// again, [stop] or not.
  bool _retired = false;

  /// A background owner's look whether the identity is free again
  /// ([kRuntimeYieldRetry]).
  Timer? _yieldRetry;

  /// The start running now is such a look ([_yieldRetry]).
  bool _lookingAgain = false;
  final StreamController<RuntimeNodeYield> _yields =
      StreamController<RuntimeNodeYield>.broadcast();
  bool _disposed = false;

  /// Whether another owner of this identity took over ([_yielded]).
  bool get yieldedToOtherOwner => _yielded || _retired;

  /// Each time another owner of this identity took the node over or refused
  /// a start.
  Stream<RuntimeNodeYield> get ownerYields => _yields.stream;

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() {
    if (_heldByService || _yielded || _retired || _disposed) {
      return Future<void>.value();
    }
    if (_previewMode) {
      if (_snapshot.serviceRunning) {
        return Future<void>.value();
      }
      _setSnapshot(
        const RuntimeTransportSnapshot(
          health: RuntimeTransportHealth.active,
          peers: 9,
          activeTransfers: 0,
          latencyMs: 55,
          throughputMbps: 12.3,
          inboxLimitMb: 32,
          routingEntries: 16,
          peerPoolCount: 3,
          selectedPeer: 'tcp://127.0.0.1:9001',
        ),
      );
      return Future<void>.value();
    }
    _autoRecoveryEnabled = true;
    final Future<void>? inFlight = _starting;
    if (inFlight != null) {
      return inFlight;
    }
    if (_session != null) {
      return Future<void>.value();
    }
    _cancelRecoveryTimer();
    final int token = ++_lifecycleToken;
    final Future<void> operation = _startLive(token);
    _starting = operation;
    return operation.whenComplete(() {
      if (identical(_starting, operation)) {
        _starting = null;
      }
    });
  }

  Future<void> restart() async {
    if (_previewMode) {
      _setSnapshot(RuntimeTransportSnapshot.syncing());
      await Future<void>.delayed(const Duration(milliseconds: 260));
      _setSnapshot(
        const RuntimeTransportSnapshot(
          health: RuntimeTransportHealth.active,
          peers: 14,
          activeTransfers: 0,
          latencyMs: 39,
          throughputMbps: 22.7,
          inboxLimitMb: 32,
          routingEntries: 31,
          peerPoolCount: 6,
          selectedPeer: 'tcp://127.0.0.1:9001',
        ),
      );
      return;
    }
    await stop();
    await start();
  }

  /// Stops the node on purpose: the owner's own logic (a lock, a handoff, an
  /// account switch) decided it, so the next [start] claims the identity
  /// again, also after another owner had taken it.
  @override
  Future<void> stop() async {
    if (_previewMode) {
      if (!_snapshot.serviceRunning &&
          _snapshot.health != RuntimeTransportHealth.failed) {
        return;
      }
      _setSnapshot(
        RuntimeTransportSnapshot.stopped(localAddress: _snapshot.localAddress),
      );
      return;
    }
    _yielded = false;
    _lookingAgain = false;
    _yieldRetry?.cancel();
    _yieldRetry = null;
    owner.claim = true;
    await _stopNode();
  }

  /// Stops the node without a word about who may start it next.
  Future<void> _stopNode({String? errorMessage}) async {
    _autoRecoveryEnabled = false;
    _cancelRecoveryTimer();
    _lifecycleToken += 1;
    _snapshotRefreshTimer?.cancel();
    _snapshotRefreshTimer = null;
    await _forwardingSubscription?.cancel();
    _forwardingSubscription = null;
    final RuntimeNodeSession? session = _session;
    _session = null;
    // The bridge stops the door with the node.
    _doorAddress = null;
    if (session != null) {
      await session.transport.stop();
    }
    _setSnapshot(
      RuntimeTransportSnapshot.stopped(
        localAddress: _snapshot.localAddress,
        errorMessage: errorMessage,
      ),
    );
  }

  /// Another owner of this identity outranks this one ([isNodeOwnerYield]):
  /// this runtime lets go of its node (if one was left), stops every timer
  /// of its own and stays quiet. A background owner looks now and then
  /// whether the identity is free again, with a start that takes nobody's
  /// node; the app waits for its own logic to start the node again.
  Future<void> _yieldToOtherOwner(
    Object reason, {
    required bool wasRunning,
  }) async {
    final bool first = !_yielded && !_lookingAgain;
    _yielded = true;
    final RuntimeNodeYield yielded = RuntimeNodeYield(
      reason: '$reason',
      wasRunning: wasRunning,
    );
    if (owner.role == RuntimeNodeRole.app && yielded.byNewerApp) {
      _retired = true;
    }
    if (first) {
      logZenWarning(
        'Another owner of this identity runs its node in this process; '
        'this ${owner.role.name} lets go and stays quiet ($reason).',
      );
      ZenTechLog.event('node-yield', <String, Object?>{
        'role': owner.role.name,
        'running': wasRunning,
      });
      if (!_yields.isClosed) {
        _yields.add(yielded);
      }
    }
    try {
      await _stopNode(errorMessage: '$reason');
    } on Object catch (error, stackTrace) {
      logZenError('Letting go of the node failed', error, stackTrace);
    }
    _scheduleYieldRetry();
  }

  void _scheduleYieldRetry() {
    if (owner.role != RuntimeNodeRole.service || _disposed) {
      return;
    }
    _yieldRetry?.cancel();
    _yieldRetry = Timer(_yieldRetryAfter, () {
      _yieldRetry = null;
      if (!_yielded || _disposed) {
        return;
      }
      // Never a claim: it starts only on an identity nobody runs. Refused
      // again, it says nothing new.
      owner.claim = false;
      _yielded = false;
      _lookingAgain = true;
      unawaitedLogged(start(), context: 'Looking for a free identity failed');
    });
  }

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    // The session can be missing while the runtime is (re)starting — e.g.
    // right after a background/foreground handoff on Android. Wait for the
    // start instead of silently dropping the payload.
    await start();
    final RuntimeNodeSession? session = _session;
    if (session == null) {
      if (_previewMode) {
        return;
      }
      // A silent drop here used to make messages and call invites vanish
      // without a trace; callers surface thrown errors to the user.
      throw StateError(
        'Runtime node is not running (health: ${_snapshot.health.name}'
        '${_yielded ? ', another owner runs this identity' : ''}) — '
        'signal to $remoteAddress was not sent.',
      );
    }
    try {
      await session.transport.send(
        remoteAddress: remoteAddress,
        payload: payload,
      );
    } catch (error) {
      if (isNodeOwnerYield(error) && identical(_session, session)) {
        // Taken over: no need to wait for the next read of the node.
        unawaitedLogged(
          _yieldToOtherOwner(error, wasRunning: true),
          context: 'Letting go of a node taken over failed',
        );
      }
      rethrow;
    }
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async {
    if (_previewMode) {
      return 0;
    }
    await start();
    final RuntimeNodeSession? session = _session;
    if (session == null) {
      return 0;
    }
    return session.transport.openRelay(
      callId: callId,
      remoteAddress: remoteAddress,
    );
  }

  @override
  Future<void> closeRelay(String callId) async {
    if (_previewMode) {
      return;
    }
    final RuntimeNodeSession? session = _session;
    if (session == null) {
      return;
    }
    await session.transport.closeRelay(callId);
  }

  Future<void> _startLive(int token) async {
    _setSnapshot(
      RuntimeTransportSnapshot.syncing(localAddress: _snapshot.localAddress),
    );
    const int maxAttempts = 4;
    Object? lastError;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      // Held outside the try so a failure after the node came up can still
      // shut it down. Dropping the session instead leaks a live Yggdrasil
      // node - same identity, same process - that keeps answering for the
      // mesh while nothing in Dart is listening to it.
      RuntimeNodeSession? session;
      try {
        session = await _bootstrap!.call();
        if (token != _lifecycleToken) {
          await session.transport.stop();
          return;
        }
        _forwardingSubscription = session.transport.frames.listen(
          _forward,
          onError: _frames.addError,
        );
        _session = session;
        await session.transport.start();
        if (token != _lifecycleToken) {
          await _forwardingSubscription?.cancel();
          _forwardingSubscription = null;
          _session = null;
          await session.transport.stop();
          return;
        }
        _recoveryAttempt = 0;
        // Running: restarts of this node from now on are no claims, so an
        // owner that takes it over is never fought back.
        owner.claim = false;
        _lookingAgain = false;
        if (owner.onScreen) {
          _tellOnScreen(session, true);
        }
        for (final String uri in _extraPeers) {
          _addPeerNow(uri);
        }
        if (_vouchedKeys.isNotEmpty) {
          _pinNow(Map<String, String>.of(_vouchedKeys), keep: true);
        }
        _applyDoorNow();
        _applyMailboxDoorsNow();
        _applyLocalLinksNow();
        _setSnapshot(session.snapshot);
        _startSnapshotRefreshLoop(session, token);
        return;
      } catch (error, stackTrace) {
        lastError = error;
        final bool outranked = isNodeOwnerYield(error);
        if (!outranked) {
          logZenError(
            'Runtime live bootstrap attempt $attempt/$maxAttempts failed',
            error,
            stackTrace,
          );
        }
        await _forwardingSubscription?.cancel();
        _forwardingSubscription = null;
        _session = null;
        if (session != null) {
          try {
            await session.transport.stop();
          } catch (stopError, stopStackTrace) {
            logZenError(
              'Shutting down a half-started runtime node failed',
              stopError,
              stopStackTrace,
            );
          }
        }
        if (outranked) {
          // Another owner of this identity outranks this one: no retry
          // (nor a recovery loop) would start this node, each would only
          // fill the log.
          if (token == _lifecycleToken) {
            await _yieldToOtherOwner(error, wasRunning: false);
          }
          return;
        }
        if (attempt < maxAttempts && token == _lifecycleToken) {
          // The peering port can stay held for a few seconds by a process that
          // is still exiting, so the retries have to outlast that.
          await Future<void>.delayed(
            Duration(milliseconds: 500 * attempt * attempt),
          );
        }
      }
    }

    if (token != _lifecycleToken) {
      return;
    }
    _setSnapshot(
      RuntimeTransportSnapshot.failed(
        localAddress: _snapshot.localAddress,
        errorMessage: '$lastError',
      ),
    );
    _scheduleRecovery();
  }

  /// Keeps retrying a failed start in the background so the app heals itself
  /// instead of sitting offline until the next manual restart.
  void _scheduleRecovery() {
    if (_previewMode || !_autoRecoveryEnabled || _recoveryTimer != null) {
      return;
    }
    final Duration delay =
        _recoveryBackoff[_recoveryAttempt.clamp(
          0,
          _recoveryBackoff.length - 1,
        )];
    _recoveryAttempt += 1;
    logZenMessage('Runtime start failed; retrying in ${delay.inSeconds}s');
    _recoveryTimer = Timer(delay, () {
      _recoveryTimer = null;
      if (!_autoRecoveryEnabled || _session != null) {
        return;
      }
      unawaitedLogged(start(), context: 'Runtime auto-recovery restart failed');
    });
  }

  void _cancelRecoveryTimer() {
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
  }

  /// Not a claim: a node lost on the way comes back only where no other
  /// owner of the identity took over.
  Future<void> _restartAfterNodeLoss() async {
    logZenWarning('Runtime node stopped responding; restarting it');
    await _stopNode();
    await start();
  }

  void _setSnapshot(RuntimeTransportSnapshot value) {
    if (value == _snapshot || _disposed) {
      return;
    }
    _snapshot = value;
    notifyListeners();
  }

  /// Whether Zen is on the screen ([setOnScreen]); the node is read often
  /// only then.
  bool _onScreen = false;
  VoidCallback? _refreshSoon;

  /// Zen came on the screen (or left it): the node is read every
  /// [kRuntimeRefreshOnScreen] then, every [kRuntimeRefreshUnseen]
  /// otherwise (the background service's node too), and every
  /// [kRuntimeRefreshConnecting] while it has no peer yet.
  ///
  /// The bridge hears it too: the background service never takes the
  /// identity from the app on screen.
  void setOnScreen(bool onScreen) {
    if (onScreen == _onScreen) {
      return;
    }
    _onScreen = onScreen;
    owner.onScreen = onScreen;
    if (onScreen &&
        _yielded &&
        !_retired &&
        !_disposed &&
        owner.role == RuntimeNodeRole.app) {
      // Back on screen: the app outranks a background owner that took its
      // node meanwhile (an iPhone's engine without a screen). Android's
      // handoff holds the start until the service let go.
      _yielded = false;
      owner.claim = true;
      unawaitedLogged(start(), context: 'Taking the node back failed');
    }
    final RuntimeNodeSession? session = _session;
    if (session != null) {
      _tellOnScreen(session, onScreen);
    }
    if (onScreen) {
      _refreshSoon?.call();
    }
  }

  void _tellOnScreen(RuntimeNodeSession session, bool onScreen) {
    try {
      session.setOnScreen?.call(onScreen);
    } on Object catch (error) {
      logZenWarning('The bridge did not hear whether Zen is on screen: $error');
    }
  }

  Duration get _refreshInterval {
    if (!_snapshot.serviceRunning || _snapshot.peers == 0) {
      return kRuntimeRefreshConnecting;
    }
    return _onScreen ? kRuntimeRefreshOnScreen : kRuntimeRefreshUnseen;
  }

  void _startSnapshotRefreshLoop(RuntimeNodeSession session, int token) {
    _snapshotRefreshTimer?.cancel();
    final Future<RuntimeTransportSnapshot> Function()? refreshSnapshot =
        session.refreshSnapshot;
    if (refreshSnapshot == null) {
      return;
    }

    // A node whose info calls keep failing is gone for good (a dead handle
    // after a native crash). Without this the UI kept reporting "active" while
    // nothing was actually routed.
    const int maxConsecutiveRefreshFailures = 5;
    int consecutiveFailures = 0;

    Future<void> refreshOnce() async {
      try {
        final RuntimeTransportSnapshot nextSnapshot = await refreshSnapshot();
        if (token != _lifecycleToken || !identical(_session, session)) {
          return;
        }
        consecutiveFailures = 0;
        _setSnapshot(nextSnapshot);
      } catch (error, stackTrace) {
        if (token != _lifecycleToken || !identical(_session, session)) {
          return;
        }
        if (isNodeOwnerYield(error)) {
          // A newer owner of this identity took the node: let go, no
          // restart (it would take the node back and start a ping-pong).
          await _yieldToOtherOwner(error, wasRunning: true);
          return;
        }
        consecutiveFailures += 1;
        logZenError(
          'Runtime snapshot refresh failed '
          '($consecutiveFailures/$maxConsecutiveRefreshFailures)',
          error,
          stackTrace,
        );
        if (consecutiveFailures >= maxConsecutiveRefreshFailures) {
          consecutiveFailures = 0;
          unawaitedLogged(
            _restartAfterNodeLoss(),
            context: 'Restarting an unresponsive runtime node failed',
          );
        }
      }
    }

    bool live() => token == _lifecycleToken && identical(_session, session);

    void scheduleNext() {
      _snapshotRefreshTimer?.cancel();
      if (!live()) {
        _snapshotRefreshTimer = null;
        return;
      }
      _snapshotRefreshTimer = Timer(_refreshInterval, () {
        unawaitedLogged(
          refreshOnce().whenComplete(scheduleNext),
          context: 'Runtime snapshot refresh task failed',
        );
      });
    }

    // Back on the screen: read now, then at the screen's pace.
    _refreshSoon = () {
      if (!live()) {
        return;
      }
      _snapshotRefreshTimer?.cancel();
      _snapshotRefreshTimer = null;
      unawaitedLogged(
        refreshOnce().whenComplete(scheduleNext),
        context: 'Runtime snapshot refresh task failed',
      );
    };
    unawaitedLogged(
      refreshOnce().whenComplete(scheduleNext),
      context: 'Runtime snapshot refresh task failed',
    );
  }

  /// Ends this runtime for good: its node stops and nothing starts it again
  /// (an account that opened again in this process has a runtime of its
  /// own).
  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _autoRecoveryEnabled = false;
    _lifecycleToken += 1;
    _yieldRetry?.cancel();
    _yieldRetry = null;
    unawaitedLogged(
      _keyConflicts.close(),
      context: 'Closing device key conflicts failed',
    );
    unawaitedLogged(
      _yields.close(),
      context: 'Closing the owner yields failed',
    );
    _cancelRecoveryTimer();
    _snapshotRefreshTimer?.cancel();
    unawaitedLogged(
      _forwardingSubscription?.cancel(),
      context: 'Runtime frame forwarding cancellation failed',
    );
    unawaitedLogged(
      _session?.transport.stop() ?? Future<void>.value(),
      context: 'Runtime transport shutdown failed',
    );
    _frames.close();
    _doorFrames.close();
    super.dispose();
  }
}

Future<SignalTransport> _bootstrapDefaultSignalTransport({
  required RuntimeSignalBootstrapConfig config,
}) async {
  final RuntimeNodeSession session = await _bootstrapDefaultRuntimeSession(
    config: config,
  );
  return session.transport;
}

Future<RuntimeNodeSession> _bootstrapDefaultRuntimeSession({
  required RuntimeSignalBootstrapConfig config,
  RuntimeNodeOwner? owner,
}) async {
  final NodeSignalBridge bridge = YggdrasilBridgeFfi.load();
  final String configJson = await _loadOrCreateNodeConfig(
    bridge,
    config.nodeConfigProtector,
    config.supportDirectory,
  );
  // The user's public peers (public_peers.dart) before the node dials any.
  await applyStoredPublicPeers(bridge);
  // Whom the node is for: the bridge settles which owner of the identity
  // runs it (node_identity.go).
  final Map<String, dynamic> startResult = bridge.startNode(
    withNodeOwner(withNodePeerTarget(configJson, config.peerTarget), owner),
  );
  owner?.started(startResult);
  final int handle = _readNodeHandle(startResult);
  // The device keys pinned in earlier runs, before any signal comes in.
  final Directory runtimeDirectory = (await _runtimeConfigFile(
    config.supportDirectory,
  )).parent;
  final NodeKeyPinKeeper pins = NodeKeyPinKeeper(
    readPins: () => bridge.pqPins(handle),
    writePins: (String pinsJson) => bridge.setPqPins(handle, pinsJson),
    file: () => nodeKeyPinsFile(runtimeDirectory),
    protector: config.nodeConfigProtector,
  );
  await pins.restore();
  pins.start();
  final RuntimeTransportSnapshot initialSnapshot = _snapshotFromNodeInfo(
    _sampled(startResult),
  );
  final SignalPayloadCompressor doorCompressor = ZstdSignalPayloadCompressor();
  return RuntimeNodeSession(
    transport: ManagedSignalTransport(
      delegate: YggdrasilSignalTransport(
        bridge: bridge,
        nodeHandle: handle,
        compressor: ZstdSignalPayloadCompressor(),
        openWaiter: () => IsolateSignalWaiter.spawn(
          nodeHandle: handle,
          openBridge: YggdrasilBridgeFfi.load,
        ),
        waitTimeout: config.waitTimeout,
        fallbackPollInterval: config.fallbackPollInterval,
      ),
      onStop: () async {
        await pins.stop();
        bridge.stopNode(handle);
        ZenTechLog.nodeStopped(handle);
      },
    ),
    snapshot: initialSnapshot,
    // The technical log samples the node from these reads (no wake of its
    // own).
    refreshSnapshot: () async =>
        _snapshotFromNodeInfo(_sampled(bridge.getNodeInfo(handle))),
    addPeer: (String uri) => bridge.addPeer(handle, uri),
    removePeer: (String uri) => bridge.removePeer(handle, uri),
    startDoor: (String seedHex) =>
        bridge.startDoorNode(handle, seedHex)['address'] as String?,
    stopDoor: () => bridge.stopDoorNode(handle),
    setMailboxDoors: (List<String> seedsHex) =>
        bridge.setMailboxDoors(handle, jsonEncode(seedsHex)),
    sendFromDoor: (String remoteAddress, Map<String, dynamic> payload) async =>
        bridge.doorSendSignal(
          handle,
          remoteAddress,
          await encodeRuntimeSignalPayload(payload, doorCompressor),
        ),
    localLinks: BridgeLocalLinkApi(bridge, handle),
    sessionKey: startResult['pqKey'] as String? ?? '',
    pinSessionKeys: (Map<String, String> pins, bool keep) =>
        sessionKeyConflictsFrom(
          bridge.setPqPins(
            handle,
            jsonEncode(<String, Object?>{'pins': pins, 'keep': keep}),
          ),
        ),
    setOnScreen: (bool onScreen) => bridge.setNodeOnScreen(handle, onScreen),
  );
}

/// The conflicts in the bridge's answer to a pin request (`{taken,
/// conflicts: {address: pinned}}`).
@visibleForTesting
Map<String, String> sessionKeyConflictsFrom(Map<String, dynamic> result) {
  final Object? conflicts = result['conflicts'];
  if (conflicts is! Map) {
    return const <String, String>{};
  }
  return <String, String>{
    for (final MapEntry<Object?, Object?> entry in conflicts.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  };
}

/// Which Yggdrasil and Go the bridge was built with, for the
/// technical info; `null` without a bridge (tests, previews).
final Provider<RuntimeBridgeBuildInfo?> runtimeBridgeBuildInfoProvider =
    Provider<RuntimeBridgeBuildInfo?>((Ref ref) {
      if (!_hasNativeBridge) {
        return null;
      }
      try {
        return RuntimeBridgeBuildInfo.fromJson(
          YggdrasilBridgeFfi.load().getBuildInfo(),
        );
      } on Object catch (error) {
        logZenWarning('Bridge build info unavailable: $error');
        return null;
      }
    });

@immutable
final class RuntimeBridgeBuildInfo {
  const RuntimeBridgeBuildInfo({required this.yggdrasil, required this.go});

  factory RuntimeBridgeBuildInfo.fromJson(Map<String, dynamic> json) =>
      RuntimeBridgeBuildInfo(
        yggdrasil: json['yggdrasil'] as String? ?? '',
        go: json['go'] as String? ?? '',
      );

  /// Yggdrasil's version, e.g. `0.5.12`.
  final String yggdrasil;

  /// Go's version, e.g. `go1.26.1`.
  final String go;
}

/// The storage key the node config is sealed for (also used when the
/// config is sealed again under another key, e.g. the background key).
const String kNodeConfigStorageKey = 'runtime/yggdrasil.config';

Future<String> _loadOrCreateNodeConfig(
  NodeSignalBridge bridge,
  KeyedBinaryPayloadProtector? protector, [
  Future<Directory> Function()? supportDirectory,
]) async {
  return loadOrCreateNodeConfigJson(
    file: await _runtimeConfigFile(supportDirectory),
    generateConfig: () => normalizeRuntimeNodeConfig(
      bridge.generateConfigJson(),
      isAndroid: Platform.isAndroid,
      isWindows: Platform.isWindows,
    ),
    protector: protector,
  );
}

/// Loads the persisted Yggdrasil identity, or mints a new one.
///
/// With a [protector] the config is sealed for [kNodeConfigStorageKey];
/// plaintext or a payload sealed for another place does not open, so
/// nobody with access to the files alone can plant a node key or peers.
///
/// A sealed config that no longer matches the device master key (Android
/// Keystore rotation, an in-app reset that missed this file, a restored
/// backup) used to throw on every start. The runtime then sat in
/// `syncing` forever and the status bar read "Łączę...".
@visibleForTesting
Future<String> loadOrCreateNodeConfigJson({
  required File file,
  required String Function() generateConfig,
  KeyedBinaryPayloadProtector? protector,
}) async {
  // The node's key IS this person's address: a new one means every friend
  // loses them. So a damaged file is never the end — the last good copy
  // (`.bak`) is tried first, and an unreadable file is kept aside, not
  // overwritten.
  final File backup = File('${file.path}.bak');
  for (final File candidate in <File>[file, backup]) {
    final String? stored = await _readNodeConfig(candidate, protector);
    if (stored == null) {
      continue;
    }
    if (!identical(candidate, file)) {
      logZenWarning('Node config restored from its backup copy.');
    }
    final bool rewriteFile = !identical(candidate, file);
    if (rewriteFile || !await _holdsCurrentSeal(backup, protector)) {
      final Uint8List sealed = await _sealNodeConfig(stored, protector);
      if (rewriteFile) {
        await _writeAtomically(file, sealed);
      }
      await _writeAtomically(backup, sealed);
    }
    return stored;
  }
  if (await file.exists()) {
    // Neither copy opens (another device's key, a wiped key, damage): keep
    // the bytes for a manual rescue instead of writing over them.
    try {
      await file.rename(
        '${file.path}.unreadable-${DateTime.now().millisecondsSinceEpoch}',
      );
    } on Object catch (error) {
      logZenWarning('Could not set the unreadable node config aside: $error');
    }
  }
  final String configJson = generateConfig();
  final Uint8List sealed = await _sealNodeConfig(configJson, protector);
  await file.parent.create(recursive: true);
  await _writeAtomically(file, sealed);
  await _writeAtomically(backup, sealed);
  return configJson;
}

Future<Uint8List> _sealNodeConfig(
  String config,
  KeyedBinaryPayloadProtector? protector,
) async {
  final Uint8List plain = Uint8List.fromList(utf8.encode(config));
  return protector == null
      ? plain
      : protector.sealFor(kNodeConfigStorageKey, plain);
}

/// Whether [file] exists and holds what [protector] writes now.
Future<bool> _holdsCurrentSeal(
  File file,
  KeyedBinaryPayloadProtector? protector,
) async {
  if (!await file.exists()) {
    return false;
  }
  if (protector == null) {
    return true;
  }
  try {
    return protector.isSealed(await file.readAsBytes());
  } on FileSystemException {
    return false;
  }
}

/// The stored config in [file]; null when it is missing, empty, unreadable
/// or not sealed for its place (plaintext included). A locked app (no key yet)
/// throws instead: nothing may be replaced then.
Future<String?> _readNodeConfig(
  File file,
  KeyedBinaryPayloadProtector? protector,
) async {
  if (!await file.exists()) {
    return null;
  }
  try {
    final Uint8List stored = await file.readAsBytes();
    if (stored.isEmpty) {
      return null;
    }
    final Uint8List unsealed = protector == null
        ? stored
        : await protector.unsealFor(kNodeConfigStorageKey, stored);
    final String savedConfig = utf8.decode(unsealed);
    if (savedConfig.trim().isEmpty) {
      return null;
    }
    jsonDecode(savedConfig);
    return savedConfig;
  } on StateError {
    // No key while the app is locked — wait for unlock instead of
    // burning the node identity.
    rethrow;
  } catch (error, stackTrace) {
    logZenError(
      'Stored node config ${file.path} is unreadable',
      error,
      stackTrace,
    );
    return null;
  }
}

/// Writes [bytes] so that [file] is always either the old or the new
/// content, never half of it (a crash or a dead battery mid-write).
Future<void> _writeAtomically(File file, Uint8List bytes) async {
  await file.parent.create(recursive: true);
  final File tmp = File('${file.path}.tmp');
  await tmp.writeAsBytes(bytes, flush: true);
  await tmp.rename(file.path);
}

Future<File> _runtimeConfigFile([
  Future<Directory> Function()? supportDirectoryOf,
]) async {
  final Directory supportDirectory =
      await (supportDirectoryOf ?? ZenInstance.supportDirectory)();
  final Directory runtimeDirectory = Directory(
    '${supportDirectory.path}${Platform.pathSeparator}runtime',
  );
  await runtimeDirectory.create(recursive: true);
  return File(
    '${runtimeDirectory.path}${Platform.pathSeparator}yggdrasil.config.json',
  );
}

int _readNodeHandle(Map<String, dynamic> payload) {
  final int? handle = (payload['handle'] as num?)?.toInt();
  if (handle == null || handle < 0) {
    throw const FormatException('Native bridge did not return a valid handle.');
  }
  return handle;
}

String _readNodeAddress(Map<String, dynamic> payload) {
  final String? address = payload['address'] as String?;
  final String trimmed = address?.trim() ?? '';
  if (trimmed.isEmpty) {
    return trimmed;
  }
  return PeerShareCodec.normalizeAddress(trimmed);
}

Map<String, dynamic> _sampled(Map<String, dynamic> info) {
  ZenTechLog.node(info);
  return info;
}

RuntimeTransportSnapshot _snapshotFromNodeInfo(Map<String, dynamic> payload) {
  return RuntimeTransportSnapshot.started(
    localAddress: _readNodeAddress(payload),
    peers: _readPeerCount(payload),
  ).copyWith(
    latencyMs: _readSelectedPeerLatencyMs(payload),
    routingEntries: _readRoutingEntries(payload),
    peerPoolCount: _readPeerPoolCount(payload),
    selectedPeer: _readSelectedPeer(payload),
  );
}

int _readPeerCount(Map<String, dynamic> payload) {
  final int availablePeers =
      (payload['availablePeerCount'] as num?)?.toInt() ?? 0;
  final Object? rawPeers = payload['peers'];
  int connectedPeers = 0;
  int listedPeers = 0;
  bool sawHealthFlag = false;
  if (rawPeers is List) {
    listedPeers = rawPeers.length;
    for (final Object? peer in rawPeers) {
      if (peer is! Map) {
        continue;
      }
      if (!peer.containsKey('up')) {
        continue;
      }
      sawHealthFlag = true;
      if (_isPeerMarkedUp(peer['up'])) {
        connectedPeers += 1;
      }
    }
  }
  if (connectedPeers > 0) {
    return connectedPeers;
  }
  if (availablePeers > 0) {
    return availablePeers;
  }
  return sawHealthFlag ? 0 : listedPeers;
}

bool _isPeerMarkedUp(Object? value) {
  return value == true || value == 1 || value == 'true' || value == '1';
}

int _readRoutingEntries(Map<String, dynamic> payload) {
  return (payload['routingEntries'] as num?)?.toInt() ?? 0;
}

int _readPeerPoolCount(Map<String, dynamic> payload) {
  return (payload['peerPoolCount'] as num?)?.toInt() ?? 0;
}

String _readSelectedPeer(Map<String, dynamic> payload) {
  final String? selectedPeer = payload['selectedPeer'] as String?;
  return selectedPeer?.trim() ?? '';
}

int _readSelectedPeerLatencyMs(Map<String, dynamic> payload) {
  final String rawValue =
      (payload['selectedPeerLatency'] as String?)?.trim() ?? '';
  if (rawValue.isEmpty || rawValue == '0' || rawValue == '0s') {
    return 0;
  }
  final RegExpMatch? match = RegExp(
    r'^([0-9]+(?:\.[0-9]+)?)(ms|s|m)$',
  ).firstMatch(rawValue);
  if (match == null) {
    return 0;
  }
  final double magnitude = double.tryParse(match.group(1) ?? '') ?? 0;
  final String unit = match.group(2) ?? 'ms';
  switch (unit) {
    case 'm':
      return (magnitude * Duration.millisecondsPerMinute).round();
    case 's':
      return (magnitude * Duration.millisecondsPerSecond).round();
    default:
      return magnitude.round();
  }
}

/// How many public peers a phone node dials while it only receives: the
/// locked receiver of the default account and the extra accounts' nodes in
/// the background service. Every peer passes on the tree's signed updates
/// (each node renews its own every few minutes) and each of them is
/// answered, so on a locked phone the peers are what wakes the radio most
/// (about a thousand small packets an hour each way with four); two halve
/// that and are what Yggdrasil advises for end nodes. A peer that stays
/// down is swapped for the next of the pool (phone_peers.go). The app on
/// screen dials the bridge's own number (four).
const int kReceiveOnlyPeerTarget = 2;

final class RuntimeSignalBootstrapConfig {
  RuntimeSignalBootstrapConfig({
    this.waitTimeout = const Duration(seconds: 30),
    this.nodeConfigProtector,
    this.fallbackPollInterval = const Duration(seconds: 1),
    this.supportDirectory,
    this.peerTarget,
  });

  /// How many public peers a phone node dials at once; `null`: the
  /// bridge's own number (4). Nodes that only receive ask for fewer
  /// ([kReceiveOnlyPeerTarget]; phone_peers.go in the bridge).
  final int? peerTarget;

  /// The folder of the account whose node this is; `null`: the account
  /// open in this isolate. Set for the other accounts the background
  /// service (or a computer's tray) receives for.
  final Future<Directory> Function()? supportDirectory;

  /// How long one blocking signal wait lasts before it is renewed (signals
  /// arrive as they come; this only bounds one wait).
  Duration waitTimeout;

  /// Polling interval used only when the blocking signal wait fails.
  Duration fallbackPollInterval;

  /// Seals the persisted Yggdrasil node config (which contains the node
  /// identity key), bound to its storage key: with the master key, or on
  /// Android with the background key, since the background service runs
  /// the node while the app is locked.
  KeyedBinaryPayloadProtector? nodeConfigProtector;
}
