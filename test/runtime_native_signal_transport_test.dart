import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';

void main() {
  test('lazy signal transport bootstraps once and forwards frames', () async {
    final MemorySignalTransport inner = MemorySignalTransport();
    int bootstrapCalls = 0;
    final LazySignalTransport transport = LazySignalTransport(
      bootstrap: () async {
        bootstrapCalls += 1;
        return inner;
      },
    );
    final List<SignalTransportFrame> frames = <SignalTransportFrame>[];
    final subscription = transport.frames.listen(frames.add);

    await transport.send(
      remoteAddress: '200:1111:2222:3333:4444:5555:6666:7777',
      payload: const <String, dynamic>{'type': 'ping'},
    );
    await inner.injectIncoming(
      from: '200:aaaa:bbbb:cccc:dddd:eeee:ffff:1111',
      payload: const <String, dynamic>{'type': 'message', 'text': 'hej'},
      receivedAtMillis: 42,
    );
    await Future<void>.delayed(Duration.zero);

    expect(bootstrapCalls, 1);
    expect(inner.sentSignals.single.payload['type'], 'ping');
    expect(frames.single.from, '200:aaaa:bbbb:cccc:dddd:eeee:ffff:1111');
    expect(frames.single.receivedAtMillis, 42);

    await subscription.cancel();
    await transport.stop();
  });

  test('lazy signal transport forwards relay operations', () async {
    final MemorySignalTransport inner = MemorySignalTransport()
      ..relayPortResult = 54322;
    final LazySignalTransport transport = LazySignalTransport(
      bootstrap: () async => inner,
    );

    final int port = await transport.openRelay(
      callId: 'call-1',
      remoteAddress: 'ada.ygg',
    );
    await transport.closeRelay('call-1');

    expect(port, 54322);
    expect(inner.openedRelays.single.callId, 'call-1');
    expect(inner.closedRelays, <String>['call-1']);
    await transport.stop();
  });

  test('normalizeRuntimeNodeConfig keeps the bridge-owned node policy', () {
    // Platform defaults (listen/multicast/peer pool) are owned by the Go
    // bridge; Dart only validates the JSON envelope.
    final String normalized = normalizeRuntimeNodeConfig(
      '{"Listen":["tls://0.0.0.0:32913"],"MulticastInterfaces":[".*"]}',
      isAndroid: true,
      isWindows: false,
    );

    expect(
      normalized,
      '{"Listen":["tls://0.0.0.0:32913"],"MulticastInterfaces":[".*"]}',
    );
  });

  test('normalizeRuntimeNodeConfig rejects non-object configs', () {
    expect(
      () => normalizeRuntimeNodeConfig(
        '[1,2,3]',
        isAndroid: false,
        isWindows: true,
      ),
      throwsFormatException,
    );
  });

  test(
    'runtime node preview can stop and restart without a native bridge',
    () async {
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();

      await runtime.stop();
      expect(runtime.snapshot.health, RuntimeTransportHealth.stopped);

      await runtime.restart();
      expect(runtime.snapshot.health, RuntimeTransportHealth.active);
      expect(runtime.snapshot.throughputMbps, 22.7);
    },
  );

  test(
    'runtime node captures bootstrap failures without crashing transport start',
    () async {
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
        bootstrap: () async => throw StateError('bridge exploded'),
      );

      await runtime.start();

      expect(runtime.snapshot.health, RuntimeTransportHealth.failed);
      expect(runtime.snapshot.errorMessage, contains('bridge exploded'));
    },
  );

  test('runtime node ignores late startup completion after stop', () async {
    final Completer<RuntimeNodeSession> completer =
        Completer<RuntimeNodeSession>();
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
      bootstrap: () => completer.future,
    );

    final Future<void> startFuture = runtime.start();
    await Future<void>.delayed(Duration.zero);
    await runtime.stop();
    completer.complete(
      RuntimeNodeSession(
        transport: MemorySignalTransport(),
        snapshot: RuntimeTransportSnapshot.started(
          localAddress: '200:1111:2222:3333:4444:5555:6666:7777',
          peers: 0,
        ),
      ),
    );
    await startFuture;

    expect(runtime.snapshot.health, RuntimeTransportHealth.stopped);
  });

  test('the flat door runs with the node and comes back after a restart '
      '(§18.2)', () async {
    final List<String> doorCalls = <String>[];
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.live(
      bootstrap: () async => RuntimeNodeSession(
        transport: MemorySignalTransport(),
        snapshot: RuntimeTransportSnapshot.started(
          localAddress: '200:1111:2222:3333:4444:5555:6666:7777',
          peers: 1,
        ),
        startDoor: (String seed) {
          doorCalls.add('start $seed');
          return '200:dddd::${seed.substring(0, 2)}';
        },
        stopDoor: () => doorCalls.add('stop'),
      ),
    );
    addTearDown(runtime.dispose);

    // Asked for before the node is up: it starts with the node.
    runtime.setDoorKey('aa');
    expect(runtime.doorAddress, isNull);
    await runtime.start();
    expect(runtime.doorAddress, '200:dddd::aa');
    expect(doorCalls, <String>['start aa']);

    runtime.setDoorKey('aa');
    expect(doorCalls, hasLength(1), reason: 'the same key keeps the door');
    runtime.setDoorKey('bb');
    expect(runtime.doorAddress, '200:dddd::bb');

    await runtime.stop();
    expect(runtime.doorAddress, isNull);
    await runtime.start();
    expect(runtime.doorAddress, '200:dddd::bb');

    runtime.setDoorKey(null);
    expect(runtime.doorAddress, isNull);
    expect(doorCalls.last, 'stop');
    await runtime.stop();
  });

  test('loadOrCreateNodeConfigJson returns a readable stored config', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'zen_node_config',
    );
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/yggdrasil.config.json');
    await file.writeAsBytes(utf8.encode('{"PrivateKey":"abc"}'));

    final String loaded = await loadOrCreateNodeConfigJson(
      file: file,
      generateConfig: () => '{"PrivateKey":"fresh"}',
    );

    expect(loaded, '{"PrivateKey":"abc"}');
  });

  test(
    'loadOrCreateNodeConfigJson mints a new identity after a MAC failure',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'zen_node_config',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/yggdrasil.config.json');
      await file.writeAsBytes(Uint8List.fromList(<int>[1, 2, 3, 4]));

      final String loaded = await loadOrCreateNodeConfigJson(
        file: file,
        generateConfig: () => '{"PrivateKey":"fresh"}',
        protector: _MacFailingProtector(),
      );

      expect(loaded, '{"PrivateKey":"fresh"}');
      expect(await file.readAsBytes(), isNotEmpty);
    },
  );

  test(
    'a damaged node config comes back from its backup: the address stays',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'zen_node_config',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/yggdrasil.config.json');
      // First start: the config and its backup are written.
      final String first = await loadOrCreateNodeConfigJson(
        file: file,
        generateConfig: () => '{"PrivateKey":"mine"}',
      );
      expect(first, '{"PrivateKey":"mine"}');
      expect(await File('${file.path}.bak').exists(), isTrue);
      // A crash halfway through a write leaves garbage behind.
      await file.writeAsBytes(utf8.encode('{"PrivateKe'));
      final String again = await loadOrCreateNodeConfigJson(
        file: file,
        generateConfig: () => '{"PrivateKey":"fresh"}',
      );
      expect(
        again,
        '{"PrivateKey":"mine"}',
        reason: 'never a new identity while a good copy exists',
      );
      expect(utf8.decode(await file.readAsBytes()), '{"PrivateKey":"mine"}');
    },
  );

  test(
    'loadOrCreateNodeConfigJson does not wipe identity while locked',
    () async {
      final Directory directory = await Directory.systemTemp.createTemp(
        'zen_node_config',
      );
      addTearDown(() => directory.delete(recursive: true));
      final File file = File('${directory.path}/yggdrasil.config.json');
      final Uint8List original = Uint8List.fromList(<int>[9, 8, 7]);
      await file.writeAsBytes(original);

      await expectLater(
        () => loadOrCreateNodeConfigJson(
          file: file,
          generateConfig: () => '{"PrivateKey":"fresh"}',
          protector: _LockedProtector(),
        ),
        throwsStateError,
      );
      expect(await file.readAsBytes(), original);
    },
  );

  test('a plain node config is not taken: nobody plants a node key', () async {
    final Directory directory = await Directory.systemTemp.createTemp(
      'zen_node_config',
    );
    addTearDown(() => directory.delete(recursive: true));
    final File file = File('${directory.path}/yggdrasil.config.json');
    await file.writeAsBytes(utf8.encode('{"PrivateKey":"planted"}'));
    final EncryptedBinaryPayloadProtector protector =
        EncryptedBinaryPayloadProtector(
          MemoryAppSecurityService(passwordIterations: 10),
        );

    final String loaded = await loadOrCreateNodeConfigJson(
      file: file,
      generateConfig: () => '{"PrivateKey":"fresh"}',
      protector: protector,
    );

    expect(loaded, '{"PrivateKey":"fresh"}');
    final Uint8List onDisk = await file.readAsBytes();
    expect(protector.isSealed(onDisk), isTrue);
    expect(
      utf8.decode(await protector.unsealFor(kNodeConfigStorageKey, onDisk)),
      '{"PrivateKey":"fresh"}',
    );
    // Sealed for its own place only.
    await expectLater(
      protector.unsealFor('social/hub', onDisk),
      throwsA(anything),
    );
  });
}

final class _MacFailingProtector implements KeyedBinaryPayloadProtector {
  @override
  Future<Uint8List> seal(Uint8List payload) async => payload;

  @override
  Future<Uint8List> unseal(Uint8List payload) async => payload;

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) async =>
      payload;

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async {
    throw Exception(
      'SecretBoxAuthenticationError: SecretBox has wrong message authentication code (MAC)',
    );
  }

  @override
  bool isSealed(Uint8List payload) => true;
}

final class _LockedProtector implements KeyedBinaryPayloadProtector {
  @override
  Future<Uint8List> seal(Uint8List payload) async => payload;

  @override
  Future<Uint8List> unseal(Uint8List payload) async => payload;

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) async =>
      payload;

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async {
    throw StateError(
      'Encrypted storage is enabled but no decryption key is available.',
    );
  }

  @override
  bool isSealed(Uint8List payload) => true;
}
