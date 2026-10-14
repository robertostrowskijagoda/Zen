import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/ledger/net_address.dart';

/// Leading zero bits the proof of work needs (~1M hashes, a few seconds).
const int kBridgePowBits = 20;

/// Longest an announcement may stay valid.
const Duration kBridgeMaxValidity = Duration(days: 7);

const Set<String> _bridgeSchemes = <String>{'tls', 'tcp', 'quic', 'ws', 'wss'};

/// "A mesh entry point is at [uri]", signed by a throw-away bridge key that
/// is not tied to any account, with a proof of work so that flooding the
/// network with fake bridges costs real computing time.
@immutable
final class BridgeAnnouncement {
  const BridgeAnnouncement._({
    required this.uri,
    required this.key,
    required this.expires,
    required this.nonce,
    required this.signature,
  });

  final String uri;
  final String key;
  final int expires;
  final int nonce;
  final String signature;

  static Map<String, dynamic> _body(
    String uri,
    String key,
    int expires,
    int nonce,
  ) => <String, dynamic>{
    't': 'bridge',
    'uri': uri,
    'key': key,
    'exp': expires,
    'n': nonce,
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._body(uri, key, expires, nonce),
    'sig': signature,
  };

  /// The host part of [uri] (IP or name), lower case.
  String get host => Uri.tryParse(uri)?.host.toLowerCase() ?? '';

  /// Groups addresses of one network (/24 for IPv4, /48 for IPv6, the name
  /// otherwise), so one operator cannot fill the book.
  String get subnet => bridgeSubnet(host);

  static int _leadingZeroBits(List<int> hash) {
    int bits = 0;
    for (final int byte in hash) {
      if (byte == 0) {
        bits += 8;
        continue;
      }
      int b = byte;
      while ((b & 0x80) == 0) {
        bits++;
        b <<= 1;
      }
      break;
    }
    return bits;
  }

  static bool _powOk(Map<String, dynamic> body, int bits) =>
      _leadingZeroBits(crypto.sha256.convert(canonicalJsonBytes(body)).bytes) >=
      bits;

  /// Creates and signs an announcement. The proof of work runs in a
  /// background isolate so the UI does not stall.
  static Future<BridgeAnnouncement> create({
    required String uri,
    required LedgerKeyPair bridgeKey,
    required int expires,
    int powBits = kBridgePowBits,
  }) async {
    final String key = bridgeKey.id;
    final int start = Random.secure().nextInt(1 << 30);
    final int nonce = await Isolate.run(
      () => _findNonce(uri, key, expires, start, powBits),
    );
    final Uint8List sig = await bridgeKey.sign(
      canonicalJsonBytes(_body(uri, bridgeKey.id, expires, nonce)),
    );
    return BridgeAnnouncement._(
      uri: uri,
      key: bridgeKey.id,
      expires: expires,
      nonce: nonce,
      signature: b64(sig),
    );
  }

  static int _findNonce(
    String uri,
    String key,
    int expires,
    int start,
    int powBits,
  ) {
    int nonce = start;
    while (!_powOk(_body(uri, key, expires, nonce), powBits)) {
      nonce++;
    }
    return nonce;
  }

  static BridgeAnnouncement? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'bridge' ||
        json['uri'] is! String ||
        (json['uri'] as String).length > 300 ||
        unb64(json['key'], length: 32) == null ||
        json['exp'] is! int ||
        json['n'] is! int ||
        json['sig'] is! String) {
      return null;
    }
    final Uri? parsed = Uri.tryParse(json['uri'] as String);
    if (parsed == null ||
        !_bridgeSchemes.contains(parsed.scheme) ||
        parsed.host.isEmpty ||
        !parsed.hasPort) {
      return null;
    }
    return BridgeAnnouncement._(
      uri: json['uri'] as String,
      key: json['key'] as String,
      expires: json['exp'] as int,
      nonce: json['n'] as int,
      signature: json['sig'] as String,
    );
  }

  /// Signature and proof of work (cheap checks first).
  Future<bool> verify({int powBits = kBridgePowBits}) async {
    final Map<String, dynamic> body = _body(uri, key, expires, nonce);
    if (!_powOk(body, powBits)) {
      return false;
    }
    return verifyLedgerSignature(
      publicKey: key,
      message: canonicalJsonBytes(body),
      signature: signature,
    );
  }
}

/// A wider block than [bridgeSubnet] (/16 for IPv4, /32 for IPv6): roughly
/// one provider, so the bridges we use are not all with the same one.
String bridgeWiderNetwork(String host) {
  final InternetAddress? ip = ipOfHost(host);
  if (ip == null) {
    return host;
  }
  final Uint8List raw = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return 'v4:${raw[0]}.${raw[1]}';
  }
  return 'v6:${raw.sublist(0, 4).join('.')}';
}

String bridgeSubnet(String host) {
  final InternetAddress? ip = ipOfHost(host);
  if (ip == null) {
    return host;
  }
  final Uint8List raw = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return 'v4:${raw[0]}.${raw[1]}.${raw[2]}';
  }
  return 'v6:${raw.sublist(0, 6).join('.')}';
}

/// Checks that a bridge really answers and says how fast: the round trip
/// in milliseconds, or `null` when it does not answer as a mesh node.
typedef BridgeProbe = Future<int?> Function(String uri);

/// The 4 bytes every Yggdrasil node sends first on a new link.
const List<int> _meshPreamble = <int>[0x6D, 0x65, 0x74, 0x61]; // "meta"

/// Connects to the bridge and waits for the mesh greeting (a Yggdrasil
/// node starts every link with "meta"). A web server, a printer or anything
/// else at that address stays silent or says something else, so an
/// announcement pointing at a stranger's machine fails right here and is
/// never passed on. Only public addresses are ever probed.
///
/// `ws`/`wss` bridges only get a TCP connection check; `quic` cannot be
/// checked at all and counts as not answering.
Future<int?> yggBridgeProbe(
  String uri, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  final Uri? parsed = Uri.tryParse(uri);
  if (parsed == null || !parsed.hasPort || parsed.scheme == 'quic') {
    return null;
  }
  final InternetAddress? ip = ipOfHost(parsed.host);
  if (ip == null || !isPublicAddress(ip)) {
    return null;
  }
  return probeMeshPort(
    ip,
    parsed.port,
    tls: parsed.scheme == 'tls',
    greeting: parsed.scheme == 'tls' || parsed.scheme == 'tcp',
    timeout: timeout,
  );
}

/// The probe itself, without the address checks (tests use loopback).
Future<int?> probeMeshPort(
  InternetAddress ip,
  int port, {
  required bool tls,
  bool greeting = true,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final Stopwatch watch = Stopwatch()..start();
  Socket? socket;
  try {
    socket = tls
        ? await SecureSocket.connect(
            ip,
            port,
            timeout: timeout,
            // Mesh nodes use throw-away self-signed certificates; the
            // greeting below is what proves it is one.
            onBadCertificate: (_) => true,
          )
        : await Socket.connect(ip, port, timeout: timeout);
    final int connected = watch.elapsedMilliseconds;
    if (!greeting) {
      return connected;
    }
    final List<int> got = <int>[];
    await for (final Uint8List chunk in socket.timeout(timeout)) {
      got.addAll(chunk);
      if (got.length >= _meshPreamble.length) {
        break;
      }
    }
    if (got.length < _meshPreamble.length) {
      return null;
    }
    for (int i = 0; i < _meshPreamble.length; i++) {
      if (got[i] != _meshPreamble[i]) {
        return null;
      }
    }
    return connected;
  } on Object {
    return null;
  } finally {
    socket?.destroy();
  }
}

enum BridgeStatus { unchecked, working, failed }

final class BridgeRecord {
  BridgeRecord(this.announcement, {this.own = false});

  /// This device's own bridge (never probed, always passed on).
  final bool own;

  BridgeAnnouncement announcement;
  BridgeStatus status = BridgeStatus.unchecked;
  int checkedAt = 0;

  /// Round trip of the last successful probe, in milliseconds.
  int? latencyMs;

  /// Failed probes in a row; the bridge is forgotten after a few.
  int failures = 0;
}

/// Known mesh entry points, learnt from other users.
///
/// Guards against spam and abuse:
/// * signature + proof of work before anything is stored;
/// * validity capped at 7 days, expired entries dropped;
/// * at most [maxPerSubnet] bridges per network and [capacity] overall;
/// * a bridge is passed on only after it was probed and answered, so fake
///   or victim addresses die at the first hop (no amplification);
/// * at most [probesPerMinute] probes, so nobody can use us to scan.
final class BridgeBook {
  BridgeBook({
    BridgeProbe? probe,
    int Function()? now,
    this.capacity = 2000,
    this.maxPerSubnet = 4,
    this.probesPerMinute = 6,
    this.powBits = kBridgePowBits,
    this.recheckWorkingAfter = const Duration(hours: 6),
    this.retryFailedAfter = const Duration(hours: 24),
    this.forgetAfterFailures = 3,
    this.allowPrivateAddresses = false,
    Random? random,
  }) : _probe = probe ?? yggBridgeProbe,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random();

  final BridgeProbe _probe;
  final int Function() _now;
  final int capacity;
  final int maxPerSubnet;
  final int probesPerMinute;
  final int powBits;
  final Random _random;

  /// A working bridge is checked again after this long (it may be gone, or
  /// slower now).
  final Duration recheckWorkingAfter;

  /// A failed bridge gets another chance after this long…
  final Duration retryFailedAfter;

  /// …and is forgotten after this many failures in a row.
  final int forgetAfterFailures;

  /// Tests only: accept bridges on home/loopback addresses. In the app an
  /// announcement must name a public IP (no names: a name could point
  /// anywhere, including into our own home network).
  final bool allowPrivateAddresses;

  /// By bridge key.
  final Map<String, BridgeRecord> _records = <String, BridgeRecord>{};
  final List<int> _probeTimes = <int>[];

  Iterable<BridgeRecord> get records => _records.values;

  /// This device's own bridge, if it announced one.
  BridgeRecord? get own =>
      _records.values.where((BridgeRecord r) => r.own).firstOrNull;

  /// Forgets this device's own bridge. Returns whether there was one.
  bool removeOwn() {
    final int before = _records.length;
    _records.removeWhere((_, BridgeRecord r) => r.own);
    return _records.length != before;
  }

  /// Adds this device's own announcement (it knows it works).
  void addOwn(BridgeAnnouncement announcement) {
    removeOwn();
    _records[announcement.key] = BridgeRecord(announcement, own: true)
      ..status = BridgeStatus.working;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'items': <Map<String, dynamic>>[
      for (final BridgeRecord r in _records.values)
        <String, dynamic>{
          'a': r.announcement.toJson(),
          's': r.status.name,
          'o': r.own,
          'c': r.checkedAt,
          if (r.latencyMs != null) 'l': r.latencyMs,
          if (r.failures > 0) 'x': r.failures,
        },
    ],
  };

  /// Restores a saved book (our own data: no proof of work re-check).
  void restore(Object? json) {
    if (json is! Map || json['v'] != 1 || json['items'] is! List) {
      return;
    }
    final int now = _now();
    for (final Object? item in json['items'] as List) {
      if (item is! Map) {
        continue;
      }
      final BridgeAnnouncement? a = BridgeAnnouncement.fromJson(item['a']);
      if (a == null || a.expires <= now) {
        continue;
      }
      final BridgeStatus status = BridgeStatus.values.firstWhere(
        (BridgeStatus s) => s.name == item['s'],
        orElse: () => BridgeStatus.unchecked,
      );
      _records[a.key] = BridgeRecord(a, own: item['o'] == true)
        ..status = status
        ..checkedAt = item['c'] is int ? item['c'] as int : 0
        ..latencyMs = item['l'] is int ? item['l'] as int : null
        ..failures = item['x'] is int ? item['x'] as int : 0;
    }
  }

  List<BridgeRecord> get working => _records.values
      .where((BridgeRecord r) => r.status == BridgeStatus.working)
      .toList();

  /// Takes announcements from a peer. Returns how many were new or newer.
  Future<int> addAll(Iterable<Object?> items) async {
    int added = 0;
    for (final Object? json in items.take(100)) {
      if (await add(json)) {
        added++;
      }
    }
    return added;
  }

  Future<bool> add(Object? json) async {
    final BridgeAnnouncement? a = BridgeAnnouncement.fromJson(json);
    if (a == null || !_addressAllowed(a)) {
      return false;
    }
    final int now = _now();
    if (a.expires <= now ||
        a.expires > now + kBridgeMaxValidity.inMilliseconds) {
      return false;
    }
    final BridgeRecord? existing = _records[a.key];
    if (existing != null && existing.announcement.expires >= a.expires) {
      return false;
    }
    final int sameSubnet = _records.values
        .where(
          (BridgeRecord r) =>
              r.announcement.subnet == a.subnet && r.announcement.key != a.key,
        )
        .length;
    if (sameSubnet >= maxPerSubnet) {
      return false;
    }
    if (!await a.verify(powBits: powBits)) {
      return false;
    }
    if (existing != null) {
      final bool moved = existing.announcement.uri != a.uri;
      existing.announcement = a;
      if (moved) {
        existing.status = BridgeStatus.unchecked;
      }
      return true;
    }
    _prune(now);
    if (_records.length >= capacity) {
      return false;
    }
    _records[a.key] = BridgeRecord(a);
    return true;
  }

  void _prune(int now) {
    _records.removeWhere((_, BridgeRecord r) => r.announcement.expires <= now);
    if (_records.length < capacity) {
      return;
    }
    // Drop failed ones first, then the ones expiring soonest.
    final List<BridgeRecord> order = _records.values.toList()
      ..sort((BridgeRecord a, BridgeRecord b) {
        final int byStatus = (a.status == BridgeStatus.failed ? 0 : 1)
            .compareTo(b.status == BridgeStatus.failed ? 0 : 1);
        return byStatus != 0
            ? byStatus
            : a.announcement.expires.compareTo(b.announcement.expires);
      });
    for (final BridgeRecord r in order.take(_records.length - capacity + 1)) {
      _records.remove(r.announcement.key);
    }
  }

  bool _mayProbe() {
    final int now = _now();
    _probeTimes.removeWhere((int t) => now - t > 60000);
    if (_probeTimes.length >= probesPerMinute) {
      return false;
    }
    _probeTimes.add(now);
    return true;
  }

  bool _addressAllowed(BridgeAnnouncement a) {
    final InternetAddress? ip = ipOfHost(a.host);
    if (ip == null) {
      return false;
    }
    return allowPrivateAddresses || isPublicAddress(ip);
  }

  /// Probes bridges (within the rate limit): new ones first, then working
  /// ones not checked for a while, then failed ones that get another
  /// chance. Returns how many were checked.
  Future<int> probeSome() async {
    final int now = _now();
    bool due(BridgeRecord r) {
      if (r.own) {
        return false;
      }
      return switch (r.status) {
        BridgeStatus.unchecked => true,
        BridgeStatus.working =>
          now - r.checkedAt >= recheckWorkingAfter.inMilliseconds,
        BridgeStatus.failed =>
          now - r.checkedAt >= retryFailedAfter.inMilliseconds,
      };
    }

    final List<BridgeRecord> queue = _records.values.where(due).toList()
      ..sort(
        (BridgeRecord a, BridgeRecord b) =>
            _probeRank(a).compareTo(_probeRank(b)),
      );
    int checked = 0;
    for (final BridgeRecord r in queue) {
      if (!_mayProbe()) {
        break;
      }
      final int? latency = await _probe(r.announcement.uri);
      r.checkedAt = _now();
      if (latency != null) {
        r
          ..status = BridgeStatus.working
          ..latencyMs = latency
          ..failures = 0;
      } else {
        r
          ..status = BridgeStatus.failed
          ..failures += 1;
        if (r.failures >= forgetAfterFailures) {
          _records.remove(r.announcement.key);
        }
      }
      checked++;
    }
    return checked;
  }

  static int _probeRank(BridgeRecord r) => switch (r.status) {
    BridgeStatus.unchecked => 0,
    BridgeStatus.working => 1,
    BridgeStatus.failed => 2,
  };

  /// What to pass on to a friend: only bridges that answered, freshest
  /// first plus a random part, at most [count].
  List<Map<String, dynamic>> sample(int count) {
    final List<BridgeRecord> good = working
      ..sort(
        (BridgeRecord a, BridgeRecord b) =>
            b.announcement.expires.compareTo(a.announcement.expires),
      );
    if (good.length <= count) {
      return <Map<String, dynamic>>[
        for (final BridgeRecord r in good) r.announcement.toJson(),
      ];
    }
    final int fresh = count ~/ 2;
    final List<BridgeRecord> rest = good.sublist(fresh)..shuffle(_random);
    return <Map<String, dynamic>>[
      for (final BridgeRecord r in <BridgeRecord>[
        ...good.take(fresh),
        ...rest.take(count - fresh),
      ])
        r.announcement.toJson(),
    ];
  }

  /// Bridges to connect to: the fastest working ones, spread over as many
  /// different networks as possible (first different providers' address
  /// blocks, then different local networks).
  ///
  /// Countries are not known without a location database (which would
  /// have to be downloaded and would tell where people are); spreading over
  /// address blocks keeps the choice away from any single operator anyway.
  List<String> choose(int count) {
    final List<BridgeRecord> good =
        working.where((BridgeRecord r) => !r.own).toList()
          ..shuffle(_random)
          ..sort(
            (BridgeRecord a, BridgeRecord b) =>
                (a.latencyMs ?? 1 << 20).compareTo(b.latencyMs ?? 1 << 20),
          );
    final List<BridgeRecord> chosen = <BridgeRecord>[];
    void pass(String Function(BridgeRecord r) group) {
      final Set<String> used = <String>{
        for (final BridgeRecord r in chosen) group(r),
      };
      for (final BridgeRecord r in good) {
        if (chosen.length >= count) {
          return;
        }
        if (!chosen.contains(r) && used.add(group(r))) {
          chosen.add(r);
        }
      }
    }

    pass((BridgeRecord r) => bridgeWiderNetwork(r.announcement.host));
    pass((BridgeRecord r) => r.announcement.subnet);
    pass((BridgeRecord r) => r.announcement.key);
    return <String>[for (final BridgeRecord r in chosen) r.announcement.uri];
  }
}
