import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/atomic_file.dart';
import 'package:zen/src/core/storage/binary_store.dart';

/// The storage key the pins are sealed for.
const String kNodeKeyPinsStorageKey = 'runtime/yggdrasil.pins';

/// Keeps the device keys the node pinned per address (pq_session.go:
/// YggPqPinsJson / YggPqSetPinsJson) across restarts.
///
/// A key seen once for an address is the only one the node takes for it
/// afterwards: someone who later breaks that address's Ed25519 node key
/// (a quantum computer) can neither read what this node sends there nor
/// speak in its name. The file names everyone this node talked to, so it
/// is sealed like the node config when a protector is at hand.
final class NodeKeyPinKeeper {
  NodeKeyPinKeeper({
    required Map<String, dynamic> Function() readPins,
    required void Function(String pinsJson) writePins,
    required Future<File> Function() file,
    KeyedBinaryPayloadProtector? protector,
    this.interval = const Duration(minutes: 1),
  }) : _readPins = readPins,
       _writePins = writePins,
       _file = file,
       _protector = protector;

  final Map<String, dynamic> Function() _readPins;
  final void Function(String pinsJson) _writePins;
  final Future<File> Function() _file;
  final KeyedBinaryPayloadProtector? _protector;

  /// How often the node's pins are compared with the kept ones.
  final Duration interval;

  Timer? _timer;
  String _saved = '';
  Future<void> _saving = Future<void>.value();

  /// Hands the kept pins to the node. Nothing kept (or unreadable): the
  /// node pins from scratch.
  Future<void> restore() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return;
      }
      final Uint8List stored = await file.readAsBytes();
      final KeyedBinaryPayloadProtector? protector = _protector;
      final Uint8List plain = protector == null
          ? stored
          : await protector.unsealFor(kNodeKeyPinsStorageKey, stored);
      final Object? decoded = jsonDecode(utf8.decode(plain));
      final Map<String, String>? pins = nodeKeyPinsFrom(decoded);
      if (pins == null || pins.isEmpty) {
        return;
      }
      _writePins(jsonEncode(<String, Object?>{'pins': pins}));
      _saved = _canonical(pins);
    } on Object catch (error) {
      logZenWarning('Kept node key pins were not restored: $error');
    }
  }

  /// Saves the node's pins every [interval] while it runs.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (Timer _) => unawaited(save()));
  }

  /// Saves the node's pins now when they changed.
  Future<void> save() => _saving = _saving.then((_) => _saveNow());

  Future<void> _saveNow() async {
    try {
      final Map<String, String>? pins = nodeKeyPinsFrom(_readPins());
      if (pins == null) {
        return;
      }
      final String canonical = _canonical(pins);
      if (canonical == _saved) {
        return;
      }
      final Uint8List plain = Uint8List.fromList(
        utf8.encode(jsonEncode(<String, Object?>{'v': 1, 'pins': pins})),
      );
      final KeyedBinaryPayloadProtector? protector = _protector;
      final Uint8List bytes = protector == null
          ? plain
          : await protector.sealFor(kNodeKeyPinsStorageKey, plain);
      await writeFileAtomically(await _file(), bytes);
      _saved = canonical;
    } on Object catch (error) {
      logZenWarning('Node key pins were not saved: $error');
    }
  }

  /// Stops the timer and saves once more (the node is about to stop).
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await save();
  }

  static String _canonical(Map<String, String> pins) {
    final List<String> keys = pins.keys.toList()..sort();
    return keys.map((String key) => '$key=${pins[key]}').join(';');
  }
}

final RegExp _fingerprint = RegExp(r'^[0-9a-f]{64}$');

/// The pins in [json] (`{pins: {address: fingerprint}}`, from the bridge or
/// the kept file), malformed entries left out; null when there is no map.
@visibleForTesting
Map<String, String>? nodeKeyPinsFrom(Object? json) {
  if (json is! Map || json['pins'] is! Map) {
    return null;
  }
  final Map<String, String> pins = <String, String>{};
  (json['pins'] as Map<Object?, Object?>).forEach((Object? key, Object? value) {
    if (key is String &&
        value is String &&
        _fingerprint.hasMatch(value) &&
        InternetAddress.tryParse(key)?.type == InternetAddressType.IPv6) {
      pins[key] = value;
    }
  });
  return pins;
}

/// The file the pins are kept in, next to the node config.
Future<File> nodeKeyPinsFile(Directory runtimeDirectory) async =>
    File('${runtimeDirectory.path}${Platform.pathSeparator}yggdrasil.pins');
