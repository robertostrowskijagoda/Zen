import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';

// The public Yggdrasil peers the user can edit (Ustawienia → Publiczne
// węzły): add, remove, switch off, back to the built-in list, check which
// answer. The list lives in a file next to the node config and is handed
// to the bridge before every node start (and to running nodes at once,
// public_peers_exports.go).

/// Transports a peer URI may use (Yggdrasil 0.5).
const Set<String> kPeerSchemes = <String>{'tls', 'quic', 'tcp', 'ws', 'wss'};

/// Transports whose link is encrypted (TLS 1.3): nobody on the line sees
/// which Yggdrasil keys this device talks to.
const Set<String> kEncryptedPeerSchemes = <String>{'tls', 'quic', 'wss'};

const Set<String> _peerOptions = <String>{
  'key',
  'priority',
  'password',
  'maxbackoff',
  'sni',
};

String _schemeOf(String uri) {
  final int at = uri.indexOf('://');
  return at <= 0 ? '' : uri.substring(0, at).toLowerCase();
}

/// Whether [uri]'s link is encrypted.
bool isEncryptedPeerUri(String uri) =>
    kEncryptedPeerSchemes.contains(_schemeOf(uri.trim()));

/// [raw] trimmed, with the transport in lower case (the rest as written).
String normalizePublicPeerUri(String raw) {
  final String trimmed = raw.trim();
  final int at = trimmed.indexOf('://');
  if (at <= 0) {
    return trimmed;
  }
  return '${trimmed.substring(0, at).toLowerCase()}${trimmed.substring(at)}';
}

final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _durationPart = RegExp(r'(\d+(?:\.\d+)?)(ns|us|µs|ms|s|m|h)');

/// A Go duration ("30s", "1m30s", "500ms"), or null.
Duration? _parseGoDuration(String value) {
  if (value.isEmpty) {
    return null;
  }
  int micros = 0;
  int consumed = 0;
  for (final RegExpMatch match in _durationPart.allMatches(value)) {
    if (match.start != consumed) {
      return null;
    }
    consumed = match.end;
    final double amount = double.parse(match.group(1)!);
    final double unit = switch (match.group(2)) {
      'ns' => 0.001,
      'us' || 'µs' => 1,
      'ms' => 1000,
      's' => 1000000,
      'm' => 60000000,
      _ => 3600000000,
    };
    micros += (amount * unit).round();
  }
  return consumed == value.length ? Duration(microseconds: micros) : null;
}

bool _undialableIp(InternetAddress address) {
  final Uint8List raw = address.rawAddress;
  if (raw.every((int byte) => byte == 0) || address.isMulticast) {
    return true;
  }
  // Yggdrasil's own addresses (200::/7): a peer is reached outside it.
  return address.type == InternetAddressType.IPv6 && raw[0] & 0xfe == 0x02;
}

/// What is wrong with [raw] as a public peer, or null when Yggdrasil can
/// dial it. As strict as the bridge (public_peers.go, validatePeerURI).
String? publicPeerUriProblem(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) {
    return t('Wpisz adres węzła.');
  }
  if (value.length > 512) {
    return t('Adres jest za długi.');
  }
  final Uri? uri = Uri.tryParse(value);
  if (uri == null || !value.contains('://')) {
    return t('To nie jest adres węzła.');
  }
  final String scheme = uri.scheme.toLowerCase();
  if (!kPeerSchemes.contains(scheme)) {
    return t('Obsługiwane są tls://, quic://, tcp://, ws:// i wss://.');
  }
  if (uri.userInfo.isNotEmpty || uri.hasFragment) {
    return t('To nie jest adres węzła.');
  }
  final String host = uri.host;
  if (host.isEmpty) {
    return t('Brak nazwy hosta.');
  }
  final InternetAddress? ip = InternetAddress.tryParse(host);
  if (ip != null && _undialableIp(ip)) {
    return t('Tego adresu nie da się użyć.');
  }
  final bool needsPort = scheme == 'tcp' || scheme == 'tls' || scheme == 'quic';
  if (needsPort && !uri.hasPort) {
    return t('Podaj port, np. :443.');
  }
  if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) {
    return t('Port musi być liczbą od 1 do 65535.');
  }
  if (scheme != 'ws' &&
      scheme != 'wss' &&
      uri.path.isNotEmpty &&
      uri.path != '/') {
    return t('Ścieżka jest dozwolona tylko w ws:// i wss://.');
  }
  final Map<String, List<String>> query = uri.queryParametersAll;
  for (final MapEntry<String, List<String>> option in query.entries) {
    if (!_peerOptions.contains(option.key)) {
      return t('Nieznana opcja: {name}.', <String, Object?>{
        'name': option.key,
      });
    }
    if (option.key != 'key' && option.value.length != 1) {
      return t('Opcja {name} jest podana dwa razy.', <String, Object?>{
        'name': option.key,
      });
    }
  }
  for (final String key in query['key'] ?? const <String>[]) {
    if (!_hex64.hasMatch(key)) {
      return t('Klucz (key=) musi mieć 64 znaki szesnastkowe.');
    }
  }
  final String? priority = query['priority']?.single;
  if (priority != null) {
    final int? value = int.tryParse(priority);
    if (value == null || value < 0 || value > 255) {
      return t('Priorytet musi być liczbą od 0 do 255.');
    }
  }
  final String? password = query['password']?.single;
  if (password != null && utf8.encode(password).length > 64) {
    return t('Hasło łącza może mieć najwyżej 64 bajty.');
  }
  final String? backoff = query['maxbackoff']?.single;
  if (backoff != null) {
    final Duration? duration = _parseGoDuration(backoff);
    if (duration == null || duration < const Duration(seconds: 5)) {
      return t('maxbackoff musi być czasem od 5s wzwyż.');
    }
  }
  final String? sni = query['sni']?.single;
  if (sni != null && InternetAddress.tryParse(sni) != null) {
    return t('sni musi być nazwą, nie adresem IP.');
  }
  return null;
}

/// Whether [uri] pins the peer's node key (?key=).
bool publicPeerHasPinnedKey(String uri) =>
    Uri.tryParse(uri.trim())?.queryParametersAll.containsKey('key') ?? false;

/// One public peer of the list.
@immutable
final class PublicPeer {
  const PublicPeer({required this.uri, this.enabled = true, this.country = ''});

  final String uri;
  final bool enabled;

  /// Where it stands (built-in peers only).
  final String country;

  bool get encrypted => isEncryptedPeerUri(uri);

  PublicPeer withEnabled(bool value) =>
      PublicPeer(uri: uri, enabled: value, country: country);

  Map<String, Object?> toJson() => <String, Object?>{
    'uri': uri,
    'on': enabled,
    if (country.isNotEmpty) 'country': country,
  };

  static PublicPeer? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? uri = json['uri'];
    if (uri is! String || publicPeerUriProblem(uri) != null) {
      return null;
    }
    final Object? country = json['country'];
    return PublicPeer(
      uri: normalizePublicPeerUri(uri),
      enabled: json['on'] != false,
      country: country is String ? country : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PublicPeer &&
      other.uri == uri &&
      other.enabled == enabled &&
      other.country == country;

  @override
  int get hashCode => Object.hash(uri, enabled, country);
}

/// The list as kept: the user's own ([custom]), or none (the built-in one).
///
/// Kept with the built-in list it was made from ([base]), so an update's
/// new built-in peers still come in, and built-in peers the update dropped
/// (and the user never changed) go ([mergedWith]): one change by the user
/// does not freeze the list for good while public peers come and go.
@immutable
final class PublicPeerList {
  const PublicPeerList({
    required this.custom,
    required this.peers,
    this.base = const <PublicPeer>[],
  });

  final bool custom;
  final List<PublicPeer> peers;

  /// The built-in peers when the list was saved (empty: not known).
  final List<PublicPeer> base;

  /// This list over the built-in list of this build ([builtIn]): new
  /// built-in peers are added as built in, built-in peers no longer built
  /// in are dropped unless the user changed them, and what the user
  /// removed stays removed.
  PublicPeerList mergedWith(List<PublicPeer> builtIn) {
    if (base.isEmpty || builtIn.isEmpty) {
      return this;
    }
    final Map<String, PublicPeer> before = <String, PublicPeer>{
      for (final PublicPeer p in base) p.uri: p,
    };
    final Set<String> now = <String>{for (final PublicPeer p in builtIn) p.uri};
    final List<PublicPeer> merged = <PublicPeer>[
      for (final PublicPeer p in peers)
        if (now.contains(p.uri) ||
            before[p.uri] == null ||
            before[p.uri]!.enabled != p.enabled)
          p,
    ];
    final Set<String> have = <String>{for (final PublicPeer p in merged) p.uri};
    for (final PublicPeer p in builtIn) {
      if (!before.containsKey(p.uri) && have.add(p.uri)) {
        merged.add(p);
      }
    }
    final PublicPeerList list = PublicPeerList(
      custom: custom,
      peers: merged,
      base: builtIn,
    );
    return list.active.isEmpty ? this : list;
  }

  /// The URIs the node dials, in order.
  List<String> get active => <String>[
    for (final PublicPeer peer in peers)
      if (peer.enabled) peer.uri,
  ];

  Map<String, Object?> toJson() => <String, Object?>{
    'v': 1,
    'peers': <Object?>[for (final PublicPeer peer in peers) peer.toJson()],
    if (base.isNotEmpty)
      'base': <Object?>[for (final PublicPeer peer in base) peer.toJson()],
  };

  /// A kept list, or null when [json] is not one (or has no peer on).
  static PublicPeerList? fromJson(Object? json) {
    if (json is! Map ||
        !isReadableFormat(json, current: 1) ||
        json['peers'] is! List) {
      return null;
    }
    final Object? rawBase = json['base'];
    final List<PublicPeer> base = <PublicPeer>[
      if (rawBase is List)
        for (final Object? entry in rawBase) ?PublicPeer.fromJson(entry),
    ];
    final List<PublicPeer> peers = <PublicPeer>[];
    final Set<String> seen = <String>{};
    for (final Object? entry in json['peers'] as List<Object?>) {
      final PublicPeer? peer = PublicPeer.fromJson(entry);
      if (peer != null && seen.add(peer.uri)) {
        peers.add(peer);
      }
    }
    final PublicPeerList list = PublicPeerList(
      custom: true,
      peers: peers,
      base: base,
    );
    return list.active.isEmpty ? null : list;
  }
}

/// What this device does with a peer of its pool now (the bridge's
/// public_peers_exports.go, publicPeerStates).
enum PublicPeerState {
  /// Dialled, and the link is up.
  up('up'),

  /// Dialled, not up yet.
  connecting('connecting'),

  /// Dialled, and the last try failed: a phone swaps it for one in reserve
  /// soon, a computer keeps trying.
  failing('failing'),

  /// Set aside for a while by the transit guard (too much of others' mesh
  /// traffic went through this phone).
  aside('aside'),

  /// Not dialled now: waits in reserve. A device dials only a few peers of
  /// its list at once.
  standby('standby');

  const PublicPeerState(this.wire);

  final String wire;

  static PublicPeerState? fromWire(Object? value) {
    for (final PublicPeerState state in values) {
      if (state.wire == value) {
        return state;
      }
    }
    return null;
  }
}

/// The states from the bridge's `{states: {uri: state}}`.
Map<String, PublicPeerState> publicPeerStatesFrom(
  Map<String, dynamic> payload,
) {
  final Object? states = payload['states'];
  if (states is! Map) {
    return const <String, PublicPeerState>{};
  }
  return <String, PublicPeerState>{
    for (final MapEntry<Object?, Object?> entry in states.entries)
      if (entry.key is String && PublicPeerState.fromWire(entry.value) != null)
        entry.key! as String: PublicPeerState.fromWire(entry.value)!,
  };
}

/// What checking a peer found.
@immutable
final class PublicPeerProbe {
  const PublicPeerProbe({
    required this.reachable,
    this.latencyMs,
    this.key,
    this.keyMatches,
    this.error,
  });

  final bool reachable;
  final double? latencyMs;

  /// The node key the peer showed (tls://, quic://), hex.
  final String? key;

  /// Whether that key is the one the URI pins (null: no pin).
  final bool? keyMatches;
  final String? error;

  static PublicPeerProbe fromJson(Map<String, dynamic> json) {
    final Object? latency = json['latencyMs'];
    final Object? key = json['key'];
    final Object? matches = json['keyMatches'];
    final Object? error = json['error'];
    return PublicPeerProbe(
      reachable: json['reachable'] == true,
      latencyMs: latency is num ? latency.toDouble() : null,
      key: key is String && key.isNotEmpty ? key : null,
      keyMatches: matches is bool ? matches : null,
      error: error is String && error.isNotEmpty ? error : null,
    );
  }
}

/// The file the list is kept in (next to the node config).
Future<File> publicPeersFile() async {
  final Directory support = await ZenInstance.supportDirectory();
  final String separator = Platform.pathSeparator;
  return File(
    '${support.path}${separator}runtime${separator}public_peers.json',
  );
}

/// Reads and writes the list. No file: the built-in list.
class PublicPeersStore {
  PublicPeersStore({Future<File> Function()? file})
    : _file = file ?? publicPeersFile;

  final Future<File> Function() _file;

  Future<PublicPeerList?> load() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return null;
      }
      return PublicPeerList.fromJson(jsonDecode(await file.readAsString()));
    } on Object catch (error) {
      logZenWarning('The public peer list is unreadable: $error');
      return null;
    }
  }

  /// Keeps [list]; the built-in list removes the file.
  Future<void> save(PublicPeerList list) async {
    final File file = await _file();
    if (!list.custom) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(list.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}

/// The bridge's side of the list.
abstract interface class PublicPeersBridge {
  /// The built-in peers, those this device dials by default enabled.
  List<PublicPeer> builtIn();

  /// Makes [uris] the public peers of every node (null: the built-in ones).
  /// Throws when the bridge refuses the list.
  void apply(List<String>? uris);

  /// Checks [uris]; off the UI isolate, a few seconds at most.
  Future<Map<String, PublicPeerProbe>> probe(List<String> uris);

  /// What the running nodes do with each peer of the pool now (empty while
  /// none runs). From memory, at once.
  Map<String, PublicPeerState> states();
}

/// No bridge (tests, previews): nothing built in, nothing checked.
final class NoPublicPeersBridge implements PublicPeersBridge {
  const NoPublicPeersBridge();

  @override
  List<PublicPeer> builtIn() => const <PublicPeer>[];

  @override
  void apply(List<String>? uris) {}

  @override
  Future<Map<String, PublicPeerProbe>> probe(List<String> uris) async =>
      const <String, PublicPeerProbe>{};

  @override
  Map<String, PublicPeerState> states() => const <String, PublicPeerState>{};
}

/// The Go bridge (public_peers_exports.go).
final class FfiPublicPeersBridge implements PublicPeersBridge {
  FfiPublicPeersBridge(this._bridge);

  final NodeSignalBridge _bridge;

  @override
  List<PublicPeer> builtIn() =>
      builtInPublicPeersFrom(_bridge.defaultPublicPeers());

  @override
  void apply(List<String>? uris) {
    _bridge.setPublicPeers(jsonEncode(<String, Object?>{'peers': uris}));
  }

  @override
  Future<Map<String, PublicPeerProbe>> probe(List<String> uris) async {
    final String request = jsonEncode(<String, Object?>{'peers': uris});
    // The probe blocks for seconds: never on the UI isolate.
    final Map<String, dynamic> result = await Isolate.run(
      () => YggdrasilBridgeFfi.load().probePeers(request),
    );
    return publicPeerProbesFrom(result);
  }

  @override
  Map<String, PublicPeerState> states() =>
      publicPeerStatesFrom(_bridge.publicPeerStates());
}

/// The built-in list from the bridge's `{peers: [...]}`, in the order this
/// device tries them. Every one is on: the device dials a few at once and
/// keeps the others in reserve (`chosen` only names its first picks), so a
/// switch is off only where the person switched it off.
List<PublicPeer> builtInPublicPeersFrom(Map<String, dynamic> payload) {
  final Object? peers = payload['peers'];
  if (peers is! List) {
    return const <PublicPeer>[];
  }
  return <PublicPeer>[
    for (final Object? entry in peers)
      if (entry is Map && entry['uri'] is String)
        PublicPeer(
          uri: entry['uri'] as String,
          country: entry['country'] is String ? entry['country'] as String : '',
        ),
  ];
}

/// The results of a check from the bridge's `{results: [...]}`, by URI.
Map<String, PublicPeerProbe> publicPeerProbesFrom(
  Map<String, dynamic> payload,
) {
  final Object? results = payload['results'];
  if (results is! List) {
    return const <String, PublicPeerProbe>{};
  }
  return <String, PublicPeerProbe>{
    for (final Object? entry in results)
      if (entry is Map<String, dynamic> && entry['uri'] is String)
        entry['uri'] as String: PublicPeerProbe.fromJson(entry),
  };
}

bool get _hasPeerBridge =>
    Platform.isWindows ||
    Platform.isAndroid ||
    Platform.isIOS ||
    Platform.isLinux ||
    Platform.isMacOS;

/// Hands the kept list to the bridge before a node starts (in every
/// process that runs one: the app and Android's background service).
Future<void> applyStoredPublicPeers(
  NodeSignalBridge bridge, {
  PublicPeersStore? store,
}) async {
  final PublicPeerList? list = await (store ?? PublicPeersStore()).load();
  if (list == null) {
    return;
  }
  try {
    final FfiPublicPeersBridge peers = FfiPublicPeersBridge(bridge);
    peers.apply(list.mergedWith(peers.builtIn()).active);
  } on Object catch (error) {
    logZenWarning('The public peer list was not applied: $error');
  }
}

final Provider<PublicPeersBridge> publicPeersBridgeProvider =
    Provider<PublicPeersBridge>((Ref ref) {
      if (!_hasPeerBridge) {
        return const NoPublicPeersBridge();
      }
      try {
        return FfiPublicPeersBridge(YggdrasilBridgeFfi.load());
      } on Object catch (error) {
        logZenWarning('Public peers unavailable: $error');
        return const NoPublicPeersBridge();
      }
    });

final Provider<PublicPeersStore> publicPeersStoreProvider =
    Provider<PublicPeersStore>((Ref ref) => PublicPeersStore());

/// What the settings show.
@immutable
final class PublicPeersState {
  const PublicPeersState({
    this.loaded = false,
    this.custom = false,
    this.peers = const <PublicPeer>[],
    this.probes = const <String, PublicPeerProbe>{},
    this.live = const <String, PublicPeerState>{},
    this.checking = false,
    this.error,
  });

  final bool loaded;
  final bool custom;
  final List<PublicPeer> peers;
  final Map<String, PublicPeerProbe> probes;

  /// What the running nodes do with each peer now ([PublicPeerState]);
  /// empty while none runs.
  final Map<String, PublicPeerState> live;
  final bool checking;

  /// Why the last change did not take, or null.
  final String? error;

  int get activeCount => peers.where((PublicPeer peer) => peer.enabled).length;

  /// Switched-on peers in [state] now.
  int countLive(PublicPeerState state) => peers
      .where((PublicPeer peer) => peer.enabled && live[peer.uri] == state)
      .length;

  PublicPeersState copyWith({
    bool? loaded,
    bool? custom,
    List<PublicPeer>? peers,
    Map<String, PublicPeerProbe>? probes,
    Map<String, PublicPeerState>? live,
    bool? checking,
    String? error,
    bool clearError = false,
  }) => PublicPeersState(
    loaded: loaded ?? this.loaded,
    custom: custom ?? this.custom,
    peers: peers ?? this.peers,
    probes: probes ?? this.probes,
    live: live ?? this.live,
    checking: checking ?? this.checking,
    error: clearError ? null : error ?? this.error,
  );
}

final NotifierProvider<PublicPeersController, PublicPeersState>
publicPeersProvider = NotifierProvider<PublicPeersController, PublicPeersState>(
  PublicPeersController.new,
);

final class PublicPeersController extends Notifier<PublicPeersState> {
  List<PublicPeer> _builtIn = const <PublicPeer>[];
  Future<void>? _loading;

  /// Completes once the kept list was read.
  Future<void> get loaded => _loading ?? Future<void>.value();

  @override
  PublicPeersState build() {
    _loading = Future<void>.microtask(_load);
    return const PublicPeersState();
  }

  Future<void> _load() async {
    try {
      _builtIn = ref.read(publicPeersBridgeProvider).builtIn();
    } on Object catch (error) {
      logZenWarning('Built-in public peers unavailable: $error');
    }
    final PublicPeerList? kept = await ref
        .read(publicPeersStoreProvider)
        .load();
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(
      loaded: true,
      custom: kept != null,
      peers: kept?.mergedWith(_builtIn).peers ?? _builtIn,
    );
    refreshStates();
  }

  /// Reads again what the running nodes do with each peer (cheap: from
  /// the bridge's memory). The settings call it every few seconds while
  /// they are on the screen.
  void refreshStates() {
    if (!ref.mounted) {
      return;
    }
    Map<String, PublicPeerState> live = const <String, PublicPeerState>{};
    try {
      live = ref.read(publicPeersBridgeProvider).states();
    } on Object catch (error) {
      logZenWarning('Public peer states unavailable: $error');
    }
    if (!mapEquals(live, state.live)) {
      state = state.copyWith(live: live);
    }
  }

  /// Adds [raw]; returns why it was not added, or null.
  Future<String?> add(String raw) async {
    final String? problem = publicPeerUriProblem(raw);
    if (problem != null) {
      return problem;
    }
    final String uri = normalizePublicPeerUri(raw);
    if (state.peers.any((PublicPeer peer) => peer.uri == uri)) {
      return t('Ten węzeł już jest na liście.');
    }
    return _commit(<PublicPeer>[...state.peers, PublicPeer(uri: uri)]);
  }

  /// Removes [uri]; returns why not, or null.
  Future<String?> remove(String uri) {
    final List<PublicPeer> next = <PublicPeer>[
      for (final PublicPeer peer in state.peers)
        if (peer.uri != uri) peer,
    ];
    return _commit(next);
  }

  /// Switches [uri] on or off; returns why not, or null.
  Future<String?> setEnabled(String uri, bool enabled) {
    final List<PublicPeer> next = <PublicPeer>[
      for (final PublicPeer peer in state.peers)
        peer.uri == uri ? peer.withEnabled(enabled) : peer,
    ];
    return _commit(next);
  }

  /// Pins [uri] to the node key a check saw ([PublicPeerProbe.key]): from
  /// then on Yggdrasil only takes that node at that address (?key=).
  Future<String?> pinKey(String uri) {
    final String? key = state.probes[uri]?.key;
    if (key == null || publicPeerHasPinnedKey(uri)) {
      return Future<String?>.value();
    }
    final String pinned = '$uri${uri.contains('?') ? '&' : '?'}key=$key';
    if (publicPeerUriProblem(pinned) != null) {
      return Future<String?>.value(t('Tego adresu nie da się użyć.'));
    }
    final List<PublicPeer> next = <PublicPeer>[
      for (final PublicPeer peer in state.peers)
        peer.uri == uri
            ? PublicPeer(
                uri: pinned,
                enabled: peer.enabled,
                country: peer.country,
              )
            : peer,
    ];
    final Map<String, PublicPeerProbe> probes =
        Map<String, PublicPeerProbe>.of(state.probes)
          ..[pinned] = PublicPeerProbe(
            reachable: true,
            latencyMs: state.probes[uri]?.latencyMs,
            key: key,
            keyMatches: true,
          );
    state = state.copyWith(probes: probes);
    return _commit(next);
  }

  /// Back to the built-in list.
  Future<void> restoreDefaults() async {
    state = state.copyWith(custom: false, peers: _builtIn, clearError: true);
    await ref
        .read(publicPeersStoreProvider)
        .save(const PublicPeerList(custom: false, peers: <PublicPeer>[]));
    if (ref.mounted) {
      _apply(null);
    }
  }

  Future<String?> _commit(List<PublicPeer> peers) async {
    final PublicPeerList list = PublicPeerList(
      custom: true,
      peers: peers,
      base: _builtIn,
    );
    if (list.active.isEmpty) {
      return t('Zostaw włączony co najmniej jeden węzeł.');
    }
    state = state.copyWith(custom: true, peers: peers, clearError: true);
    await ref.read(publicPeersStoreProvider).save(list);
    if (ref.mounted) {
      _apply(list.active);
    }
    return null;
  }

  void _apply(List<String>? uris) {
    try {
      ref.read(publicPeersBridgeProvider).apply(uris);
      refreshStates();
    } on Object catch (error) {
      logZenWarning('The public peer list was not applied: $error');
      if (ref.mounted) {
        state = state.copyWith(
          error: t('Nie udało się zastosować listy. Spróbuj ponownie.'),
        );
      }
    }
  }

  /// Checks every peer on the list (reachability, latency, pinned key).
  Future<void> check() async {
    if (state.checking || state.peers.isEmpty) {
      return;
    }
    state = state.copyWith(checking: true);
    Map<String, PublicPeerProbe> probes = const <String, PublicPeerProbe>{};
    try {
      probes = await ref.read(publicPeersBridgeProvider).probe(<String>[
        for (final PublicPeer peer in state.peers) peer.uri,
      ]);
    } on Object catch (error) {
      logZenWarning('Checking public peers failed: $error');
    }
    if (!ref.mounted) {
      return;
    }
    state = state.copyWith(checking: false, probes: probes);
    refreshStates();
  }
}
