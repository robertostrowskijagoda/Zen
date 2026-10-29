import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_bootstrap.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_reach_service.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import '../../support/file_credentials_store.dart';
import '../../support/friends_world.dart' show RecordingNotices;

/// The port every Zen node on a computer listens on (bridge_types.go,
/// `defaultDesktopPeerListen`). The mesh's hub takes it, so the test needs
/// it free: a Zen running on the same computer holds it.
const int kZenDesktopPeerPort = 32913;

/// How long an invitation may take to show at the invited person, the
/// first contact of two devices included. On this computer it shows within
/// about a tenth of a second once the invited device can be found, a second
/// or two after it came on the mesh (ironwood's router rounds): the bridge
/// opens the way with one packet before the post-quantum session layer's key
/// frames follow, so none of them is lost while every layer below keeps only
/// one packet per destination (mesh_io.go; it took about 14 s before, R5-#9).
const Duration kInvitationWithin = Duration(seconds: 5);

/// How long the first message to or from a device that just restarted may
/// take: its sessions on every layer went with the old process, while its
/// friends still hold theirs (R5-F5). On this computer it takes from a few
/// milliseconds to about two seconds: ironwood can lose a packet then, and
/// the bridge sends it again a little over a second later (mesh_io.go).
const Duration kAfterRestartWithin = Duration(seconds: 5);

/// How long a message between friends whose devices both run may take.
const Duration kMessageWithin = Duration(seconds: 10);

/// Whether the real-node tests may run here, and why not: they need the Go
/// bridge built for this computer and the peering port free, and they run
/// only when asked for (`ZEN_E2E=1`, which the "End-to-end on Linux" CI job
/// sets), so a plain `flutter test` never starts real nodes.
Future<String?> zenMeshSkipReason() async {
  if (Platform.environment['ZEN_E2E'] != '1') {
    return 'Real-node tests run only with ZEN_E2E=1 (docs/TESTING.md).';
  }
  final String? library = zenBridgeLibraryProblem();
  if (library != null) {
    return library;
  }
  try {
    final ServerSocket probe = await ServerSocket.bind(
      InternetAddress.anyIPv6,
      kZenDesktopPeerPort,
    );
    await probe.close();
  } on SocketException {
    return 'Port $kZenDesktopPeerPort is taken (a running Zen?): the test '
        "mesh's hub needs it.";
  }
  return null;
}

/// Where `YggdrasilBridgeFfi.load()` looks for the bridge under
/// `flutter test`, or what is missing there; `null` when it is in place.
///
/// Next to the running executable, which under `flutter test` is the
/// engine's `flutter_tester` (`lib/` of that folder on Linux), where
/// `dart run tool/e2e.dart` puts it; on Windows (debug) also
/// `native\yggdrasil_bridge\bin\yggdrasil_bridge.dll` of the checkout
/// (build_windows.ps1).
String? zenBridgeLibraryProblem() {
  if (Platform.isWindows) {
    final String nextToTester =
        '${File(Platform.resolvedExecutable).parent.path}'
        r'\yggdrasil_bridge.dll';
    const String checkout = r'native\yggdrasil_bridge\bin\yggdrasil_bridge.dll';
    return File(nextToTester).existsSync() || File(checkout).existsSync()
        ? null
        : 'No yggdrasil_bridge.dll: run `dart run tool/e2e.dart`.';
  }
  if (Platform.isLinux) {
    final String library =
        '${File(Platform.resolvedExecutable).parent.path}/lib/'
        'libyggdrasil_bridge.so';
    return File(library).existsSync()
        ? null
        : 'No $library: run `dart run tool/e2e.dart` (it builds the bridge '
              'and puts it there).';
  }
  return 'Real-node tests run on Linux and Windows only.';
}

/// A small network of real Zen devices on one computer, cut off from the
/// internet: every device runs the app's own start-up (`ZenBootstrapper`),
/// stores in its own folder, its own real Yggdrasil node through the Go
/// bridge and the app's modules (`ZenCore`); only the screens are missing.
///
/// The nodes reach each other through one more node, the hub, which listens
/// on [kZenDesktopPeerPort] on this computer; the bridge's public peer list
/// is the hub alone, so nothing dials a public peer (nor does the hub).
///
/// ```dart
/// final ZenMesh mesh = await ZenMesh.open();
/// final ZenDevice ala = await mesh.device('Ala');
/// final ZenDevice ola = await mesh.device('Ola');
/// await mesh.befriend(ala, ola);
/// await ala.send(ola, 'cześć');
/// await ola.waitForText(ala, 'cześć', within: const Duration(seconds: 20));
/// ```
final class ZenMesh {
  ZenMesh._(this.base, this.bridge, this._hubHandle);

  /// Everything the devices write (each in its own folder inside).
  final Directory base;

  final NodeSignalBridge bridge;
  int? _hubHandle;
  final List<ZenDevice> _devices = <ZenDevice>[];

  /// What each step took (for the report at the end of a run).
  final List<String> timings = <String>[];

  /// Starts the hub and points every node of this process at it. Closed
  /// when the test ends.
  static Future<ZenMesh> open() async {
    await _Watchdog.start();
    final Directory base = await Directory.systemTemp.createTemp('zen_e2e_');
    // Anything that still asks for the instance folder lands in the mesh,
    // never in this computer's real Zen data.
    ZenInstance.debugSetBaseDirectory(base);
    _answerPathProvider(base);
    final NodeSignalBridge bridge = YggdrasilBridgeFfi.load();
    // Before any node starts: the only public peer is the hub, for the hub
    // too (it does not dial itself), so no node reaches the internet.
    bridge.setPublicPeers(
      jsonEncode(<String, Object>{
        'peers': <String>['tls://127.0.0.1:$kZenDesktopPeerPort'],
      }),
    );
    final Stopwatch keying = Stopwatch()..start();
    final String hubConfig = _hubConfig(bridge);
    keying.stop();
    final Map<String, dynamic> hub = bridge.startNode(hubConfig);
    final int handle = (hub['handle'] as num).toInt();
    final ZenMesh mesh = ZenMesh._(base, bridge, handle);
    addTearDown(mesh.close);
    mesh.timings.add("the hub's key took ${keying.elapsedMilliseconds} ms");
    // The hub's port must be ours: otherwise the devices would dial
    // whatever else listens there.
    final Socket socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      kZenDesktopPeerPort,
      timeout: const Duration(seconds: 5),
    );
    socket.destroy();
    return mesh;
  }

  /// The hub's node config: a new identity whose key is below any a device
  /// is likely to get. Ironwood roots the mesh's spanning tree at the lowest
  /// key, which on the real mesh is a long-standing node far below every
  /// Zen device's, so a device coming on (or back) never moves the root.
  /// With a random key the hub would be the lowest only now and then: a
  /// device below it would become the root when it came on and again when
  /// it restarted, moving every node's place in the tree under the test.
  static String _hubConfig(NodeSignalBridge bridge) {
    while (true) {
      final String config = bridge.generateConfigJson();
      final Object? key =
          (jsonDecode(config) as Map<String, dynamic>)['PrivateKey'];
      // The seed, then the public key, in hex: the public key's first byte
      // 0 and its second below 0x10, as the Go tests' hub (newTestMesh).
      if (key is String && key.length == 128 && key.startsWith('000', 64)) {
        return config;
      }
    }
  }

  /// A new device, started; [name] is the name its person chose.
  Future<ZenDevice> device(String name) async {
    final Directory directory = Directory(
      '${base.path}${Platform.pathSeparator}$name',
    );
    final ZenDevice device = ZenDevice._(this, name, directory);
    _devices.add(device);
    final Stopwatch watch = Stopwatch()..start();
    await device.start();
    await device.setName(name);
    timings.add('$name started in ${watch.elapsedMilliseconds} ms');
    return device;
  }

  /// [a] scans [b]'s QR code and sends an invitation; [b] accepts it. Both
  /// must then see each other as friends, by the names they chose, within
  /// [within] each.
  Future<void> befriend(
    ZenDevice a,
    ZenDevice b, {
    Duration within = const Duration(seconds: 30),
  }) async {
    final Stopwatch sending = Stopwatch()..start();
    await a.inviteByQr(b.qrCode);
    timings.add(
      'sending the invitation took ${sending.elapsedMilliseconds} ms',
    );
    final Duration request = await b.waitFor(
      'the invitation from ${a.name}',
      () => b.friendOf(a)?.status == FriendRelationshipStatus.pendingIncoming,
      within: within,
    );
    timings.add(
      'invitation ${a.name} -> ${b.name}: ${request.inMilliseconds} ms',
    );
    await b.accept(a);
    final Duration accepted = await a.waitFor(
      '${b.name} accepting',
      () => a.friendOf(b)?.status == FriendRelationshipStatus.accepted,
      within: within,
    );
    timings.add(
      'acceptance ${b.name} -> ${a.name}: ${accepted.inMilliseconds} ms',
    );
    // Never "Kontakt Zen" or an address: the names the people chose.
    await a.waitFor(
      '${b.name} shown by name',
      () => a.friendOf(b)?.displayLabel == b.name,
      within: within,
    );
    await b.waitFor(
      '${a.name} shown by name',
      () => b.friendOf(a)?.displayLabel == a.name,
      within: within,
    );
  }

  /// A step of the scenario, in every device's trace and in the timings.
  void mark(String step) {
    timings.add('-- $step');
    for (final ZenDevice device in _devices) {
      device._trace.add('${ZenDevice._clock.elapsedMilliseconds} ms: -- $step');
    }
  }

  /// Prints the timings (the CI log keeps them, to see a step getting
  /// slower before it fails).
  void report() {
    // ignore: avoid_print
    print('Mesh timings:\n  ${timings.join('\n  ')}');
  }

  /// The name of the device at [address] (for traces), or the address.
  String nameOf(String address) {
    for (final ZenDevice device in _devices) {
      if (device.running &&
          PeerShareCodec.addressesEqual(device.address, address)) {
        return device.name;
      }
    }
    return address;
  }

  /// Every device's trace, for a failure report.
  String describe() => <String>[
    for (final ZenDevice device in _devices) ...<String>[
      '${device.name}:',
      for (final String line in device.trace) '  $line',
    ],
  ].join('\n');

  /// Stops every device and the hub, and removes the files.
  Future<void> close() async {
    for (final ZenDevice device in _devices.reversed) {
      await device.stop();
    }
    _devices.clear();
    final int? hub = _hubHandle;
    _hubHandle = null;
    if (hub != null) {
      bridge.stopNode(hub);
    }
    ZenInstance.debugSetBaseDirectory(null);
    try {
      await base.delete(recursive: true);
    } on FileSystemException {
      // A file still open on Windows; the system's temp cleaning takes it.
    }
  }
}

/// Ends the whole test process when its main isolate stops answering: the
/// app calls the bridge on that isolate, and a call that never returns (a
/// lock or an actor in Go that nobody releases) freezes every timer, the
/// test's own timeout included. A frozen phone shows the same: the screen
/// stops. The bridge of tool/e2e.dart writes its goroutines every 10 s
/// (ZEN_STACK_DUMP); they are printed before the exit.
abstract final class _Watchdog {
  static const Duration silence = Duration(seconds: 45);
  static bool _started = false;

  static Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    final ReceivePort ready = ReceivePort();
    await Isolate.spawn(_watch, <Object?>[
      ready.sendPort,
      Platform.environment['ZEN_STACK_DUMP'],
    ]);
    final SendPort beats = await ready.first as SendPort;
    Timer.periodic(const Duration(seconds: 1), (_) => beats.send(null));
  }

  static Future<void> _watch(List<Object?> args) async {
    final ReceivePort beats = ReceivePort();
    (args[0]! as SendPort).send(beats.sendPort);
    final String? dump = args[1] as String?;
    final Stopwatch since = Stopwatch()..start();
    beats.listen((_) => since.reset());
    while (true) {
      await Future<void>.delayed(const Duration(seconds: 1));
      if (since.elapsed < silence) {
        continue;
      }
      stderr.writeln(
        'The test isolate has not run for ${silence.inSeconds} s: a call '
        'into the bridge (or other native code) never returned.',
      );
      if (dump != null && File(dump).existsSync()) {
        // Taken while it hung (every 10 s).
        await Future<void>.delayed(const Duration(seconds: 11));
        stderr.writeln('Goroutines of the Go bridge:');
        stderr.writeln(File(dump).readAsStringSync());
      }
      exit(3);
    }
  }
}

/// The folders `path_provider` hands out, inside the mesh (no plugin runs
/// under `flutter test`).
void _answerPathProvider(Directory base) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (MethodCall call) async {
          final Directory folder = Directory(
            '${base.path}${Platform.pathSeparator}${call.method}',
          );
          await folder.create(recursive: true);
          return folder.path;
        },
      );
}

/// One device of a [ZenMesh]: the app without its screens, on its own data
/// folder and its own real node.
final class ZenDevice {
  ZenDevice._(this.mesh, this.name, this.directory);

  final ZenMesh mesh;
  final String name;

  /// The device's data folder; [restart] starts again on the same one.
  final Directory directory;

  /// Every notification the device posted.
  RecordingNotices notices = RecordingNotices();

  ProviderContainer? _container;
  ZenBootstrapResult? _boot;
  StreamSubscription<SignalTransportFrame>? _frameWatch;
  StreamSubscription<SignalTransportFrame>? _appFrameWatch;

  /// What reached this device and when (the mesh prints it when a test
  /// fails, and [ZenMesh.describe] on demand).
  final List<String> _trace = <String>[];
  static final Stopwatch _clock = Stopwatch()..start();

  /// When a frame of each type from each address last reached the app (wall
  /// time, ms), by the type and the address with a space between.
  final Map<String, int> _heardAt = <String, int>{};

  List<String> get trace => List<String>.unmodifiable(_trace);

  /// When a frame of [type] from [from] last reached this device's app (wall
  /// time, ms; 0: never).
  int heardAtMillis(ZenDevice from, String type) =>
      _heardAt['$type ${PeerShareCodec.normalizeAddress(from.address)}'] ?? 0;
  int _generation = 0;

  ProviderContainer get container {
    final ProviderContainer? container = _container;
    if (container == null) {
      throw StateError('$name is not running');
    }
    return container;
  }

  bool get running => _container != null;

  SocialHubController get hub =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  RuntimeNodeRuntime get runtime => _boot!.runtime;

  /// This device's mesh address (its node's): the running node's, or the
  /// last one it had while it is stopped (its identity is on its disk).
  String get address {
    final String live = _boot?.runtime.snapshot.localAddress ?? '';
    if (live.isNotEmpty) {
      _address = live;
    }
    return _address;
  }

  String _address = '';

  /// When the device last began to start (wall time, ms): whatever reached it
  /// from then on came after the start. Not when the start finished: a
  /// friend's answer to the greetings of the start can come before that.
  int startedAtMillis = 0;

  /// What the device's QR code says (the "Mój kod" screen).
  String get qrCode {
    final PeerShareProfile? profile = PeerShareCodec.buildLocalProfile(
      address: address,
      displayName: name,
    );
    if (profile == null) {
      throw StateError('$name has no address yet');
    }
    return profile.qrData;
  }

  FriendProfile? friendOf(ZenDevice other) =>
      state.friendByAddress(other.address);

  /// Starts the device as the app does: settings, security, stores, node,
  /// then the core with all its modules; returns once the node reached the
  /// hub. The device is on the screen afterwards.
  Future<void> start({Duration within = const Duration(seconds: 60)}) async {
    final int beganAt = DateTime.now().millisecondsSinceEpoch;
    await directory.create(recursive: true);
    final Stopwatch watch = Stopwatch()..start();
    final FileCredentialsStore secrets = FileCredentialsStore(
      File('${directory.path}.secrets.json'),
    );
    final AppSettingsStore settings = buildZenAppSettingsStoreForDirectory(
      directory,
      secrets: secrets,
    );
    if (await settings.load() == null) {
      // The radios for friends nearby off, as their person may switch
      // them off: the Wi-Fi beacons would go out on this computer's real
      // network, and Bluetooth has no plugin here.
      await settings.save(
        const AppSettings(
          lanDiscovery: false,
          wifiDirect: false,
          bluetoothLinks: false,
        ),
      );
    }
    final ZenBootstrapper bootstrapper = ZenBootstrapper(
      supportDirectoryLoader: () async => directory,
      appSecurityServiceBuilder: () =>
          LocalAppSecurityService(credentialsStore: secrets),
      appSettingsStoreBuilder: (Directory folder) =>
          buildZenAppSettingsStoreForDirectory(folder, secrets: secrets),
      prepareAccounts: () async {},
      receivesInBackground: () async => false,
      // The app's own runtime, with the node's files in this device's
      // folder: the app finds them through the instance folder, which is
      // one per process and here shared by every device.
      runtimeBuilder: ({required RuntimeSignalBootstrapConfig config}) =>
          buildDefaultRuntimeNodeRuntime(
            config: RuntimeSignalBootstrapConfig(
              waitTimeout: config.waitTimeout,
              nodeConfigProtector: config.nodeConfigProtector,
              fallbackPollInterval: config.fallbackPollInterval,
              peerTarget: config.peerTarget,
              supportDirectory: () async => directory,
            ),
          ),
    );
    // The bug of the logo that never goes away: the start must finish.
    final ZenBootstrapResult boot = await bootstrapper.bootstrap().timeout(
      within,
      onTimeout: () => throw TimeoutException('$name: start-up hung', within),
    );
    _boot = boot;
    final ProviderContainer container = ProviderContainer(
      overrides: [
        ...boot.buildProviderOverrides(
          systemNotificationServiceFactory: () => notices,
        ),
        supportDirectoryResolverProvider.overrideWithValue(
          () async => directory,
        ),
      ],
    );
    _container = container;
    _trace.add('${_clock.elapsedMilliseconds} ms: started');
    _frameWatch?.cancel();
    _frameWatch = boot.runtime.frames.listen((SignalTransportFrame frame) {
      _trace.add(
        '${_clock.elapsedMilliseconds} ms: node frame '
        '${frame.payload['type'] ?? frame.payload.keys.take(3).join(',')}'
        '${_detail(frame.payload)} from ${mesh.nameOf(frame.from)}',
      );
    });
    _appFrameWatch?.cancel();
    _appFrameWatch = container.read(signalTransportProvider).frames.listen((
      SignalTransportFrame frame,
    ) {
      _trace.add(
        '${_clock.elapsedMilliseconds} ms: app frame '
        '${frame.payload['type']}${_detail(frame.payload)} '
        'from ${mesh.nameOf(frame.from)}',
      );
      _heardAt['${frame.payload['type']} '
              '${PeerShareCodec.normalizeAddress(frame.from)}'] =
          DateTime.now().millisecondsSinceEpoch;
    });
    await hub.whenHydrated.timeout(within);
    final ZenCore core = container.read(zenCoreProvider);
    await core.start().timeout(within);
    await setOnScreen(true);
    await waitFor(
      'its node to reach the hub',
      () => address.isNotEmpty && runtime.snapshot.peers > 0,
      within: within - watch.elapsed,
    );
    startedAtMillis = beganAt;
  }

  /// What the trace tells of a frame besides its type: a message's text and
  /// which message it is, or which message an acknowledgement is for.
  static String _detail(Map<String, dynamic> payload) {
    final Object? id = payload['msgId'];
    // 'outgoing-<time>-<address>': the time tells the messages apart.
    final String which = id is String
        ? ' ${id.split('-').elementAtOrNull(1) ?? id}'
        : '';
    final Object? text = payload['text'];
    if (payload['type'] == 'message' && text is String) {
      return ' "$text"$which';
    }
    return which;
  }

  /// Stops the core and the node as closing the app does; the files stay.
  Future<void> stop() async {
    final ProviderContainer? container = _container;
    final ZenBootstrapResult? boot = _boot;
    _container = null;
    _boot = null;
    if (container == null) {
      return;
    }
    _trace.add('${_clock.elapsedMilliseconds} ms: stopping');
    await _appFrameWatch?.cancel();
    await _frameWatch?.cancel();
    _appFrameWatch = null;
    _frameWatch = null;
    await container.read(zenCoreProvider).stop();
    // The node down first (its handle and its identity free for the next
    // start), then what still runs on the providers.
    await boot?.runtime.stop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    container.dispose();
    if (boot != null) {
      retireBootstrapResult(boot);
    }
  }

  /// Closes the app and starts it again on the same folder (a restart of
  /// the phone, an update).
  Future<void> restart() async {
    await stop();
    notices = RecordingNotices();
    await start();
  }

  /// On the screen (and unlocked), or in the background.
  Future<void> setOnScreen(bool onScreen) async {
    _generation += 1;
    await hub.setLifecycle(
      LifecycleSnapshot(
        visibility: onScreen
            ? AppVisibilityState.foregroundFocused
            : AppVisibilityState.background,
        generation: _generation,
        capturedAtMillis: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    container.read(zenCoreProvider).setInteractive(onScreen);
  }

  Future<void> setName(String displayName) => container
      .read(userProfileControllerProvider.notifier)
      .updateProfile(displayName: displayName);

  /// Scans [qr] and sends the invitation, as the "Dodaj znajomego" dialog
  /// does.
  Future<void> inviteByQr(String qr) async {
    final PeerDialTarget target = PeerShareCodec.parseTarget(qr);
    await hub.sendFriendRequest(
      peerAddress: target.address,
      senderDisplayName: name,
    );
  }

  Future<void> accept(ZenDevice from) => hub.acceptFriendRequest(
    peerAddress: from.address,
    senderDisplayName: name,
  );

  Future<void> remove(ZenDevice friend) =>
      hub.removeFriend(peerAddress: friend.address);

  /// The friends that hold this device's mail while it is away (its relay
  /// set), as addresses.
  Future<List<String>> mailboxes() async =>
      (await _boot!.stores.relayStateStore.load()).currentRelays;

  /// Publishes a post as the wall's editor does (publishDraft in feed_screen.dart).
  Future<void> post(String text, {Audience audience = Audience.public}) async {
    final LedgerNode node = container.read(ledgerNodeProvider)!;
    await node.publish(
      kPostKind,
      await node.seal(audience, newPostBody(text, audience: audience)),
    );
  }

  /// The texts of the posts on this device's wall (friends' posts and the
  /// ones that reach it from further away), as the wall builds them.
  List<String> wall() {
    final LedgerNode? node = container.read(ledgerNodeProvider);
    if (node == null) {
      return const <String>[];
    }
    return <String>[
      for (final FeedPost p in buildFeed(
        node,
        nameOf: mesh.nameOf,
        held: container.read(postReachProvider),
      ))
        p.text,
    ];
  }

  Future<void> send(ZenDevice to, String text) =>
      hub.sendLocalMessage(peerAddress: to.address, text: text);

  /// The conversation with [peer] as stored on this device, oldest first.
  Future<List<ChatMessage>> thread(ZenDevice peer) =>
      container.read(messageTimelineStoreProvider).load(peer.address);

  Future<List<String>> textsFrom(ZenDevice peer) async => <String>[
    for (final ChatMessage m in await thread(peer))
      if (m.direction == ChatMessageDirection.incoming) m.text,
  ];

  /// Waits until [text] from [from] is in this device's chat; returns how
  /// long it took.
  Future<Duration> waitForText(
    ZenDevice from,
    String text, {
    Duration within = const Duration(seconds: 30),
  }) async {
    bool seen = false;
    return waitForAsync(
      '"$text" from ${from.name}',
      () async => seen = seen || (await textsFrom(from)).contains(text),
      within: within,
    );
  }

  /// Waits (in real time) until [condition] holds; fails with what was
  /// awaited after [within]. Returns how long it took.
  Future<Duration> waitFor(
    String what,
    bool Function() condition, {
    Duration within = const Duration(seconds: 30),
  }) => waitForAsync(what, () async => condition(), within: within);

  Future<Duration> waitForAsync(
    String what,
    Future<bool> Function() condition, {
    Duration within = const Duration(seconds: 30),
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    while (true) {
      if (await condition()) {
        return watch.elapsed;
      }
      if (watch.elapsed > within) {
        fail(
          '$name: no $what within ${within.inSeconds} s\n${mesh.describe()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Checks for [period] that [condition] keeps holding (something that
  /// must not happen does not).
  Future<void> holdsFor(
    String what,
    Future<bool> Function() condition, {
    Duration period = const Duration(seconds: 10),
  }) async {
    final Stopwatch watch = Stopwatch()..start();
    while (watch.elapsed < period) {
      if (!await condition()) {
        fail('$name: $what stopped holding after ${watch.elapsed.inSeconds} s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}
