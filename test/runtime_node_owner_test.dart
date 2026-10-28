import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';

/// One identity in one process, settled the way node_identity.go in the
/// bridge settles it (its own tests hold the full table): a newer app
/// engine wins, the app's claim beats the service, the service's claim
/// beats an app off screen and never one on screen, a restart without a
/// claim takes nobody's node, and calls on a node taken over say so.
final class _Process {
  int _engines = 0;
  _Node? running;
  int starts = 0;

  RuntimeNodeSession start(RuntimeNodeOwner owner) {
    starts += 1;
    final _Node? holder = running;
    if (holder != null) {
      final String? refused = _refusal(owner, holder);
      if (refused != null) {
        throw YggdrasilBridgeException(refused);
      }
      holder.takenBy = owner.role.name;
    }
    if (owner.engine == 0) {
      owner.engine = ++_engines;
    }
    final _Node node = _Node(this, owner.role, owner.engine, owner.onScreen);
    running = node;
    return RuntimeNodeSession(
      transport: _NodeTransport(node),
      snapshot: RuntimeTransportSnapshot.started(
        localAddress: '200:1111:2222:3333:4444:5555:6666:7777',
        peers: 0,
      ),
      refreshSnapshot: () async {
        node.check();
        return RuntimeTransportSnapshot.started(
          localAddress: '200:1111:2222:3333:4444:5555:6666:7777',
          peers: 0,
        );
      },
      setOnScreen: (bool onScreen) {
        node.check();
        node.onScreen = onScreen;
      },
    );
  }

  static String? _refusal(RuntimeNodeOwner contender, _Node holder) {
    if (contender.engine != 0 && contender.engine == holder.engine) {
      return null;
    }
    if (contender.role == holder.role) {
      if (contender.engine == 0 || contender.engine > holder.engine) {
        return null;
      }
      return contender.role == RuntimeNodeRole.app
          ? 'a newer app engine runs this identity in this process'
          : 'a newer owner runs this identity in this process';
    }
    if (contender.role == RuntimeNodeRole.app) {
      return contender.claim
          ? null
          : 'a newer owner runs this identity in this process';
    }
    if (holder.onScreen) {
      return 'the app runs this identity on screen in this process';
    }
    return contender.claim
        ? null
        : 'a newer owner runs this identity in this process';
  }
}

final class _Node {
  _Node(this.process, this.role, this.engine, this.onScreen);

  final _Process process;
  final RuntimeNodeRole role;
  final int engine;
  bool onScreen;

  /// The role of the owner that took this node's identity over.
  String? takenBy;

  /// Calls on the node: since it ran, how many.
  int calls = 0;

  void check() {
    calls += 1;
    final String? by = takenBy;
    if (by != null) {
      throw YggdrasilBridgeException(
        'this node was taken over by a newer owner of its identity (by the '
        '$by)',
      );
    }
  }
}

final class _NodeTransport implements SignalTransport {
  _NodeTransport(this.node);

  final _Node node;
  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast();
  final List<String> sent = <String>[];

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    if (identical(node.process.running, node)) {
      node.process.running = null;
    }
  }

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    node.check();
    sent.add(remoteAddress);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

RuntimeNodeRuntime _runtimeIn(
  _Process process,
  RuntimeNodeRole role, {
  Duration yieldRetry = kRuntimeYieldRetry,
}) {
  final RuntimeNodeOwner owner = RuntimeNodeOwner(role);
  final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
    owner: owner,
    bootstrap: () async => process.start(owner),
    yieldRetry: yieldRetry,
  );
  addTearDown(runtime.dispose);
  return runtime;
}

/// Waits (real time, at most [within]) until [condition] holds.
Future<void> _until(
  bool Function() condition, {
  Duration within = const Duration(seconds: 5),
}) async {
  final Stopwatch waited = Stopwatch()..start();
  while (!condition()) {
    if (waited.elapsed > within) {
      fail('not within $within');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> _sendFails(RuntimeNodeRuntime runtime) async {
  try {
    await runtime.send(remoteAddress: '200::9', payload: <String, dynamic>{});
  } on Object {
    return;
  }
  fail('the send went out');
}

void main() {
  test('the owner rides along in the config the bridge reads', () {
    final RuntimeNodeOwner owner = RuntimeNodeOwner(RuntimeNodeRole.service)
      ..onScreen = false;
    const String config = '{"PrivateKey":"ab"}';
    expect(withNodeOwner(config, null), config);
    final Map<String, dynamic> sent =
        jsonDecode(withNodeOwner(config, owner)) as Map<String, dynamic>;
    expect(sent['PrivateKey'], 'ab');
    expect(sent['ZenNodeOwner'], <String, Object?>{
      'role': 'service',
      'engine': 0,
      'claim': true,
      'onScreen': false,
    });
    owner.started(<String, dynamic>{'handle': 3, 'ownerEngine': 12});
    expect(owner.engine, 12);
    owner.started(<String, dynamic>{'handle': 4});
    expect(owner.engine, 12, reason: 'a start that names none keeps it');
  });

  test('the bridge words that mean another owner outranks this one', () {
    expect(
      isNodeOwnerYield(
        const YggdrasilBridgeException(
          'a newer app engine runs this identity in this process',
        ),
      ),
      isTrue,
    );
    expect(
      isNodeOwnerYield(
        'this node was taken over by a newer owner of its identity (by the '
        'service)',
      ),
      isTrue,
    );
    expect(
      isNodeOwnerYield('the app runs this identity on screen in this process'),
      isTrue,
    );
    // Still starting: a moment later the start may work.
    expect(
      isNodeOwnerYield(
        'a node with this identity already runs in this process',
      ),
      isFalse,
    );
    expect(isNodeOwnerYield(StateError('bridge exploded')), isFalse);
    const RuntimeNodeYield byApp = RuntimeNodeYield(
      reason:
          'this node was taken over by a newer owner of its identity (by the '
          'app)',
      wasRunning: true,
    );
    expect(byApp.byNewerApp, isTrue);
    const RuntimeNodeYield byService = RuntimeNodeYield(
      reason:
          'this node was taken over by a newer owner of its identity (by the '
          'service)',
      wasRunning: true,
    );
    expect(byService.byNewerApp, isFalse);
  });

  test('a start is a claim only when the owner asked for it', () async {
    final List<bool> claims = <bool>[];
    int fail = 0;
    final RuntimeNodeOwner owner = RuntimeNodeOwner(RuntimeNodeRole.app);
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
      owner: owner,
      bootstrap: () async {
        claims.add(owner.claim);
        if (fail > 0) {
          fail -= 1;
          throw StateError('the port is still held');
        }
        return RuntimeNodeSession(
          transport: MemorySignalTransport(),
          snapshot: RuntimeTransportSnapshot.started(
            localAddress: '200::1',
            peers: 1,
          ),
        );
      },
    );
    addTearDown(runtime.dispose);
    // The first start claims, also on a retry within it.
    fail = 1;
    await runtime.start();
    expect(claims, <bool>[true, true]);
    expect(owner.claim, isFalse, reason: 'running: restarts are no claims');
    // Stopped on purpose (a lock, a handoff): the next start claims again.
    await runtime.stop();
    expect(owner.claim, isTrue);
    await runtime.start();
    expect(claims.last, isTrue);
  });

  // Robert's phone after a restore: the app opened again while the old
  // engine's node still ran and its timers kept calling on it. Every start
  // of the new engine was refused for minutes: no messages, no notices.
  test('an app opened again runs its node within seconds; the old engine '
      'goes quiet and never fights back', () async {
    final _Process process = _Process();
    final RuntimeNodeRuntime old = _runtimeIn(process, RuntimeNodeRole.app);
    await old.start();
    expect(old.snapshot.health, RuntimeTransportHealth.active);
    final _Node oldNode = process.running!;
    final List<RuntimeNodeYield> oldYields = <RuntimeNodeYield>[];
    final StreamSubscription<RuntimeNodeYield> watch = old.ownerYields.listen(
      oldYields.add,
    );
    addTearDown(watch.cancel);

    final RuntimeNodeRuntime fresh = _runtimeIn(process, RuntimeNodeRole.app);
    await fresh.start();
    expect(fresh.snapshot.health, RuntimeTransportHealth.active);
    expect(process.starts, 2, reason: 'one attempt, no refusals, no retries');
    expect(oldNode.takenBy, 'app');

    // The old engine's next read of its node finds it taken, and it lets
    // go: no restart, no recovery loop.
    await _until(() => old.yieldedToOtherOwner);
    await _until(() => !old.snapshot.serviceRunning);
    expect(oldYields.single.wasRunning, isTrue);
    expect(oldYields.single.byNewerApp, isTrue);
    final int calls = oldNode.calls;
    await Future<void>.delayed(const Duration(milliseconds: 5500));
    expect(process.starts, 2, reason: 'the old engine never starts again');
    expect(oldNode.calls, calls, reason: 'its timers stopped');
    expect(process.running?.engine, fresh.owner.engine);
    expect(fresh.snapshot.health, RuntimeTransportHealth.active);

    // Even its own stop and start never bring it back: it was replaced.
    await old.stop();
    await old.start();
    expect(process.starts, 2);
    await _sendFails(old);
    expect(process.starts, 2);
  });

  test('the service whose node the app took stays quiet, and takes the '
      'identity again once it is free', () async {
    final _Process process = _Process();
    final RuntimeNodeRuntime service = _runtimeIn(
      process,
      RuntimeNodeRole.service,
      yieldRetry: const Duration(milliseconds: 100),
    );
    await service.start();
    int serviceYields = 0;
    final StreamSubscription<RuntimeNodeYield> watch = service.ownerYields
        .listen((_) => serviceYields += 1);
    addTearDown(watch.cancel);
    final RuntimeNodeRuntime app = _runtimeIn(process, RuntimeNodeRole.app);
    app.setOnScreen(true);
    await app.start();
    expect(app.snapshot.health, RuntimeTransportHealth.active);
    expect(process.running?.role, RuntimeNodeRole.app);

    // Its next call finds the node taken.
    await _sendFails(service);
    await _until(() => service.yieldedToOtherOwner);
    final int startsAfterYield = process.starts;
    // It looks now and then, with starts that take nobody's node.
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(process.starts - startsAfterYield, lessThanOrEqualTo(11));
    expect(serviceYields, 1, reason: 'each look refused says nothing new');
    expect(process.running?.role, RuntimeNodeRole.app);
    expect(app.snapshot.health, RuntimeTransportHealth.active);

    // The app lets go (a handoff, a lock): the service runs it again.
    await app.stop();
    await _until(() => process.running?.role == RuntimeNodeRole.service);
    await _until(
      () => service.snapshot.health == RuntimeTransportHealth.active,
    );
  });

  test('the service never takes the node of the app on screen, and does not '
      'retry in a loop', () async {
    final _Process process = _Process();
    final RuntimeNodeRuntime app = _runtimeIn(process, RuntimeNodeRole.app);
    app.setOnScreen(true);
    await app.start();
    final RuntimeNodeRuntime service = _runtimeIn(
      process,
      RuntimeNodeRole.service,
    );
    await service.start();
    expect(process.starts, 2, reason: 'refused once, no bootstrap retries');
    expect(service.yieldedToOtherOwner, isTrue);
    expect(service.snapshot.serviceRunning, isFalse);
    expect(service.snapshot.errorMessage, contains('on screen'));
    expect(process.running?.role, RuntimeNodeRole.app);
    // Past the first step of the recovery backoff: nothing came.
    await Future<void>.delayed(const Duration(milliseconds: 5500));
    expect(process.starts, 2);
  });

  test('an app off screen whose node the service took gets it back once on '
      'screen', () async {
    final _Process process = _Process();
    final RuntimeNodeRuntime app = _runtimeIn(process, RuntimeNodeRole.app);
    await app.start();
    // An engine without a screen (an iPhone's background check) claims it.
    final RuntimeNodeRuntime service = _runtimeIn(
      process,
      RuntimeNodeRole.service,
    );
    await service.start();
    expect(process.running?.role, RuntimeNodeRole.service);
    await _sendFails(app);
    await _until(() => app.yieldedToOtherOwner);
    // Its own restarts never take it back.
    await app.start();
    expect(process.running?.role, RuntimeNodeRole.service);

    app.setOnScreen(true);
    await _until(() => process.running?.role == RuntimeNodeRole.app);
    await _until(() => app.snapshot.health == RuntimeTransportHealth.active);
    expect(process.running!.onScreen, isTrue);
  });

  test('a disposed runtime never starts its node again', () async {
    final _Process process = _Process();
    final RuntimeNodeRuntime runtime = _runtimeIn(process, RuntimeNodeRole.app);
    runtime.dispose();
    await runtime.start();
    expect(process.starts, 0);
  });
}
