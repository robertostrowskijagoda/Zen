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
/// YggPqPinsJson / YggPqSetPinsJson) across restarts, each with its kind,
/// and the addresses the app named as known (its friends and this person's
/// own devices).
///
/// A key seen once for an address is the only one the node takes for it
/// afterwards: someone who later breaks that address's Ed25519 node key
/// (a quantum computer) can neither read what this node sends there nor
/// speak in its name. Only a pin the device proved (a session, or a hello
/// it signed) is firm; a pin nothing but a record backs comes back loose,
/// and expires unseen. Files kept before the kinds were (version 1) come
/// back loose, so a made-up key a friend's device record named once does
/// not keep the real device out for ever. The known addresses let the
/// node tell friends from strangers before the app says so again (a
/// background service never does). The file names everyone this node
/// talked to, so it is sealed like the node config when a protector is at
/// hand.
final class NodeKeyPinKeeper {
  NodeKeyPinKeeper({
    required Map<String, dynamic> Function() readPins,
    required void Function(String pinsJson) writePins,
    required Future<File> Function() file,
    KeyedBinaryPayloadProtector? protector,
    this.onConflicts,
    this.interval = const Duration(minutes: 1),
  }) : _readPins = readPins,
       _writePins = writePins,
       _file = file,
       _protector = protector;

  final Map<String, dynamic> Function() _readPins;
  final void Function(String pinsJson) _writePins;
  final Future<File> Function() _file;
  final KeyedBinaryPayloadProtector? _protector;

  /// Addresses whose record the node refused since it was read last,
  /// because they contradict a vouched device key (address → the vouched
  /// fingerprint): the app warns.
  final void Function(Map<String, String> conflicts)? onConflicts;

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
      final NodeKeyPinState? state = NodeKeyPinState.from(decoded);
      if (state == null || (state.pins.isEmpty && state.known.isEmpty)) {
        return;
      }
      _writePins(jsonEncode(state.restoreRequest()));
      _saved = state.canonical;
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
      final Map<String, dynamic> read = _readPins();
      final Map<String, String> conflicts = nodeKeyConflictsFrom(read);
      if (conflicts.isNotEmpty) {
        onConflicts?.call(conflicts);
      }
      final NodeKeyPinState? state = NodeKeyPinState.from(read);
      if (state == null) {
        return;
      }
      final String canonical = state.canonical;
      if (canonical == _saved) {
        return;
      }
      final Uint8List plain = Uint8List.fromList(
        utf8.encode(jsonEncode(state.toJson())),
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
}

final RegExp _fingerprint = RegExp(r'^[0-9a-f]{64}$');

bool _isMeshAddress(Object? address) =>
    address is String &&
    InternetAddress.tryParse(address)?.type == InternetAddressType.IPv6;

/// The pins the node keeps, with their kind ([NodeKeyPinKeeper]).
@immutable
final class NodeKeyPinState {
  const NodeKeyPinState({
    required this.pins,
    this.firm = const <String>{},
    this.vouched = const <String>{},
    this.seen,
    this.known = const <String>{},
  });

  /// Address → device key fingerprint.
  final Map<String, String> pins;

  /// Pinned addresses whose device proved its key with a session here.
  final Set<String> firm;

  /// Pinned addresses whose key a hello signed by the device vouched for.
  final Set<String> vouched;

  /// When each pin was seen last (Unix seconds, to the hour); null for a
  /// file kept before the kinds were: its pins all come back loose.
  final Map<String, int>? seen;

  /// The addresses the app named as known.
  final Set<String> known;

  /// The state in [json] (`{pins, firm, vouched, seen, known}`, from the
  /// bridge or the kept file), malformed entries left out; null when there
  /// is no pin map.
  static NodeKeyPinState? from(Object? json) {
    final Map<String, String>? pins = nodeKeyPinsFrom(json);
    if (pins == null) {
      return null;
    }
    json as Map<Object?, Object?>;
    Set<String> addresses(Object? list) => <String>{
      if (list is List)
        for (final Object? a in list)
          if (_isMeshAddress(a) && pins.containsKey(a)) a as String,
    };
    final Object? rawSeen = json['seen'];
    final Object? rawKnown = json['known'];
    return NodeKeyPinState(
      pins: pins,
      firm: addresses(json['firm']),
      vouched: addresses(json['vouched']),
      seen: rawSeen is Map
          ? <String, int>{
              for (final MapEntry<Object?, Object?> e in rawSeen.entries)
                if (pins.containsKey(e.key) && e.value is int)
                  e.key as String: (e.value as int) ~/ 3600 * 3600,
            }
          : null,
      known: <String>{
        if (rawKnown is List)
          for (final Object? a in rawKnown)
            if (_isMeshAddress(a)) a as String,
      },
    );
  }

  /// What is kept in the file.
  Map<String, Object?> toJson() => <String, Object?>{
    'v': 2,
    'pins': pins,
    'firm': firm.toList()..sort(),
    'vouched': vouched.toList()..sort(),
    if (seen != null) 'seen': seen,
    'known': known.toList()..sort(),
  };

  /// What the node is handed after a restart (YggPqSetPinsJson).
  Map<String, Object?> restoreRequest() => <String, Object?>{
    'restore': true,
    'pins': pins,
    if (seen != null) ...<String, Object?>{
      'firm': firm.toList()..sort(),
      'vouched': vouched.toList()..sort(),
      'seen': seen,
    },
    if (known.isNotEmpty) 'known': known.toList()..sort(),
  };

  /// The same text for the same state (to see whether it changed).
  String get canonical {
    final List<String> keys = pins.keys.toList()..sort();
    final List<String> knownSorted = known.toList()..sort();
    return <String>[
      for (final String key in keys)
        '$key=${pins[key]}'
            '${firm.contains(key) ? '/f' : ''}'
            '${vouched.contains(key) ? '/v' : ''}'
            '@${seen?[key] ?? ''}',
      'known:${knownSorted.join(',')}',
    ].join(';');
  }
}

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
        _isMeshAddress(key)) {
      pins[key] = value;
    }
  });
  return pins;
}

/// The refused records the bridge reports with its pins (`{conflicts:
/// {address: vouched fingerprint}}`).
@visibleForTesting
Map<String, String> nodeKeyConflictsFrom(Map<String, dynamic> json) {
  final Object? conflicts = json['conflicts'];
  if (conflicts is! Map) {
    return const <String, String>{};
  }
  return <String, String>{
    for (final MapEntry<Object?, Object?> e in conflicts.entries)
      if (_isMeshAddress(e.key) && e.value is String)
        e.key as String: e.value as String,
  };
}

/// The file the pins are kept in, next to the node config.
Future<File> nodeKeyPinsFile(Directory runtimeDirectory) async =>
    File('${runtimeDirectory.path}${Platform.pathSeparator}yggdrasil.pins');
