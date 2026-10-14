import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';

typedef HostLookup = Future<List<InternetAddress>> Function(String host);
typedef TcpProbe =
    Future<void> Function(InternetAddress address, int port, Duration timeout);

/// Hostname peers Dart can resolve via the OS even when Go's c-shared
/// resolver on Android cannot. Rewritten to IP literals before startNode.
const List<String> kAndroidHostnamePeerFallbacks = <String>[
  'tls://ygg.mkg20001.io:443',
  'tls://vpn.ltha.de:443',
  'tls://ygg.mnpnk.com:443',
  'tls://yggdrasil.neilalexander.dev:64648',
];

@visibleForTesting
Future<List<String>> selectReachablePeerUris(
  List<String> candidates, {
  HostLookup? lookup,
  TcpProbe? probe,
  Duration timeout = const Duration(seconds: 2),
  int limit = 8,
  int maxCandidates = 24,
}) async {
  if (candidates.isEmpty || limit <= 0) {
    return const <String>[];
  }
  final HostLookup resolve = lookup ?? InternetAddress.lookup;
  final TcpProbe connect = probe ?? _defaultTcpProbe;
  final List<String> unique = <String>[];
  final Set<String> seen = <String>{};
  for (final String uri in candidates) {
    final String trimmed = uri.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) {
      continue;
    }
    unique.add(trimmed);
    if (unique.length >= maxCandidates) {
      break;
    }
  }
  final List<String?> outcomes = await Future.wait(
    unique.map(
      (String uri) =>
          probePeerUri(uri, lookup: resolve, probe: connect, timeout: timeout),
    ),
  );
  final List<String> reachable = <String>[];
  for (final String? uri in outcomes) {
    if (uri == null || reachable.contains(uri)) {
      continue;
    }
    reachable.add(uri);
    if (reachable.length >= limit) {
      break;
    }
  }
  return reachable;
}

@visibleForTesting
Future<String?> probePeerUri(
  String peerUri, {
  required HostLookup lookup,
  required TcpProbe probe,
  required Duration timeout,
}) async {
  final Uri? parsed = Uri.tryParse(peerUri);
  if (parsed == null || parsed.host.isEmpty) {
    return null;
  }
  final int port = parsed.hasPort ? parsed.port : 443;
  if (port <= 0) {
    return null;
  }
  try {
    final List<InternetAddress> addresses =
        _literalAddress(parsed.host) ?? await lookup(parsed.host);
    addresses.sort(_preferIpv4);
    for (final InternetAddress address in addresses) {
      if (address.isLoopback || address.type == InternetAddressType.unix) {
        continue;
      }
      try {
        await probe(address, port, timeout);
        return rewritePeerUriToLiteral(parsed, address);
      } catch (_) {
        continue;
      }
    }
  } catch (_) {
    return null;
  }
  return null;
}

@visibleForTesting
String rewritePeerUriToLiteral(Uri original, InternetAddress address) {
  final Map<String, String> query = Map<String, String>.from(
    original.queryParameters,
  );
  if (InternetAddress.tryParse(original.host) == null) {
    query.putIfAbsent('sni', () => original.host);
  }
  return original
      .replace(
        host: address.address,
        port: original.hasPort ? original.port : 443,
        queryParameters: query.isEmpty ? null : query,
      )
      .toString();
}

Future<String> injectReachablePeersIntoConfig(
  String configJson, {
  required List<String> candidates,
  HostLookup? lookup,
  TcpProbe? probe,
}) async {
  final List<String> reachable = await selectReachablePeerUris(
    candidates,
    lookup: lookup,
    probe: probe,
  );
  if (reachable.isEmpty) {
    logZenWarning(
      'Android peer warmup found no reachable public peers '
      '(tried ${candidates.length}).',
    );
    return configJson;
  }
  final Object? decoded = jsonDecode(configJson);
  if (decoded is! Map<String, dynamic>) {
    return configJson;
  }
  decoded['Peers'] = reachable;
  decoded['Listen'] = <String>[];
  decoded['IfName'] = 'none';
  decoded['AdminListen'] = 'none';
  decoded['MulticastInterfaces'] = <Object>[];
  logZenMessage(
    'Android peer warmup kept ${reachable.length} reachable peers '
    '(first=${reachable.first}).',
  );
  return jsonEncode(decoded);
}

List<String> publicPeersFromGeneratedConfig(String generatedJson) {
  final Object? decoded = jsonDecode(generatedJson);
  if (decoded is! Map) {
    return const <String>[];
  }
  final Object? peers = decoded['Peers'] ?? decoded['peers'];
  if (peers is! List) {
    return const <String>[];
  }
  return peers.whereType<String>().toList(growable: false);
}

List<InternetAddress>? _literalAddress(String host) {
  final InternetAddress? parsed = InternetAddress.tryParse(host);
  if (parsed == null) {
    return null;
  }
  return <InternetAddress>[parsed];
}

int _preferIpv4(InternetAddress a, InternetAddress b) {
  if (a.type == b.type) {
    return 0;
  }
  return a.type == InternetAddressType.IPv4 ? -1 : 1;
}

Future<void> _defaultTcpProbe(
  InternetAddress address,
  int port,
  Duration timeout,
) async {
  final Socket socket = await Socket.connect(address, port, timeout: timeout);
  await socket.close();
}
