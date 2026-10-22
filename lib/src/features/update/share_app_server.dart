import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/update/android_abi.dart';

/// "Podaj dalej": this device hands the app's installer to someone
/// nearby over the local network — the same Wi-Fi, or this phone's own
/// hotspot — with no internet and no store. The other person scans a QR
/// code and their browser downloads the file.
///
/// Only one file is served, under a random path, only while the screen is
/// open (and at most [lifetime]), and only on the one address of the
/// network the person shares on (the hotspot or the Wi-Fi, see
/// [chooseShareNetwork]) — not on mobile data, a VPN or any other
/// interface. Nothing else on this device is reachable.
final class ShareAppServer {
  ShareAppServer({
    required this.file,
    required this.fileName,
    this.apkAbis,
    this.lifetime = const Duration(minutes: 20),
    Random? random,
  }) : _token = _makeToken(random ?? Random.secure());

  final File file;
  final String fileName;

  /// The ABIs of the APK's native code (one per release APK), when known:
  /// the page says which phones it is for and warns a phone that looks
  /// like another kind.
  final Set<String>? apkAbis;
  final Duration lifetime;
  final String _token;

  final List<HttpServer> _servers = <HttpServer>[];
  List<InternetAddress> _served = const <InternetAddress>[];
  int? _port;
  Timer? _expiry;
  int _downloads = 0;
  final StreamController<int> _downloadsChanged =
      StreamController<int>.broadcast();

  /// Completed downloads so far.
  int get downloads => _downloads;
  Stream<int> get downloadsChanged => _downloadsChanged.stream;

  int? get port => _port;
  bool get isRunning => _servers.isNotEmpty;

  /// The addresses actually listened on (all with the same [port]).
  List<InternetAddress> get servedAddresses =>
      List<InternetAddress>.unmodifiable(_served);

  static String _makeToken(Random random) {
    const String alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
    return List<String>.generate(
      10,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
  }

  /// The page to open on [address].
  Uri pageUri(InternetAddress address) =>
      Uri(scheme: 'http', host: address.address, port: port, path: '/$_token/');

  Uri fileUri(InternetAddress address) => Uri(
    scheme: 'http',
    host: address.address,
    port: port,
    path: '/$_token/$fileName',
  );

  /// Listens on [addresses] only (by default just this device's loopback).
  /// Addresses that cannot be used are skipped; throws when none can.
  Future<void> start({int port = 0, List<InternetAddress>? addresses}) async {
    if (_servers.isNotEmpty) {
      return;
    }
    final List<InternetAddress> wanted =
        addresses ?? <InternetAddress>[InternetAddress.loopbackIPv4];
    final List<InternetAddress> served = <InternetAddress>[];
    int bindPort = port;
    Object? failure;
    for (final InternetAddress address in wanted) {
      try {
        final HttpServer server = await HttpServer.bind(address, bindPort);
        // One port everywhere, so every link has the same shape.
        bindPort = server.port;
        _servers.add(server);
        served.add(address);
        server.listen(
          (HttpRequest request) => unawaitedLogged(
            _handle(request),
            context: 'Podaj dalej: zapytanie',
          ),
        );
      } on SocketException catch (error) {
        failure = error;
        logZenWarning(
          'Podaj dalej: nie można nasłuchiwać na ${address.address}: $error',
        );
      }
    }
    if (_servers.isEmpty) {
      throw failure ?? StateError('Podaj dalej: brak adresu do nasłuchu.');
    }
    _port = bindPort;
    _served = served;
    _expiry = Timer(lifetime, () => unawaited(stop()));
  }

  Future<void> stop() async {
    _expiry?.cancel();
    _expiry = null;
    final List<HttpServer> servers = List<HttpServer>.of(_servers);
    _servers.clear();
    _served = const <InternetAddress>[];
    _port = null;
    for (final HttpServer server in servers) {
      await server.close(force: true);
    }
  }

  Future<void> dispose() async {
    await stop();
    await _downloadsChanged.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final HttpResponse response = request.response;
    response.headers
      ..set('Cache-Control', 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    final List<String> parts = request.uri.pathSegments;
    if (request.method != 'GET' ||
        parts.isEmpty ||
        parts.first != _token ||
        parts.length > 2) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (parts.length == 1 || parts[1].isEmpty) {
      response.headers.contentType = ContentType.html;
      response.write(_page());
      await response.close();
      return;
    }
    if (parts[1] != fileName) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    final int length = await file.length();
    response.headers
      ..contentType = ContentType.parse(
        fileName.toLowerCase().endsWith('.apk')
            ? 'application/vnd.android.package-archive'
            : 'application/octet-stream',
      )
      ..contentLength = length
      ..set('Content-Disposition', 'attachment; filename="$fileName"');
    try {
      await response.addStream(file.openRead());
      await response.close();
      _downloads++;
      if (!_downloadsChanged.isClosed) {
        _downloadsChanged.add(_downloads);
      }
    } on Object catch (error) {
      logZenWarning('Podaj dalej: przerwane pobieranie: $error');
    }
  }

  String _page() {
    final String name = const HtmlEscape().convert(fileName);
    // Translated texts go into the page as text, never as markup.
    String text(String value) =>
        const HtmlEscape(HtmlEscapeMode.element).convert(value);
    final String lang = ZenI18n.code;
    final String dir = ZenI18n.language.rtl ? ' dir="rtl"' : '';
    return '''<!doctype html>
<html lang="$lang"$dir><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Zen</title>
<style>body{font-family:sans-serif;max-width:32rem;margin:2rem auto;padding:0 1rem;line-height:1.5}
a.b{display:block;text-align:center;background:#2f6f5e;color:#fff;padding:1rem;border-radius:.6rem;text-decoration:none;font-size:1.2rem}</style>
</head><body>
<h1>Zen</h1>
<p>${text(t('Znajomy podaje Ci aplikację Zen bezpośrednio ze swojego telefonu.'))}</p>
<p><a class="b" href="$name">${text(t('Pobierz {file}', {'file': fileName}))}</a></p>
<ol>
<li>${text(t('Pobierz plik i otwórz go.'))}</li>
<li>${text(t('Jeśli telefon zapyta, zezwól przeglądarce na instalowanie aplikacji.'))}</li>
<li>${text(t('Po instalacji otwórz Zen i dodaj znajomego jego kodem.'))}</li>
</ol>
${_abiPart(text)}</body></html>''';
  }

  /// Which phones the APK is for, and a warning when the browser's phone
  /// clearly is another kind (best effort: many browsers do not say).
  String _abiPart(String Function(String) text) {
    final Set<String>? abis = apkAbis;
    if (abis == null || abis.isEmpty) {
      return '';
    }
    final String forPhones = t('Ten plik jest dla telefonów typu {type}.', {
      'type': androidAbisLabel(abis),
    });
    final String warning = t(
      'Ten telefon wygląda na inny typ: Zen może się na nim nie '
      'zainstalować. Wtedy pobierz Zen dla swojego telefonu ze strony '
      'instalacji Zen, gdy będziesz mieć internet.',
    );
    // Data for the script as JSON, never as markup.
    final String data = jsonEncode(<String, Object>{
      'abis': abis.toList(),
    }).replaceAll('<', r'\u003c');
    return '''<p>${text(forPhones)}</p>
<p id="abi" style="color:#a33;font-weight:bold" hidden>${text(warning)}</p>
<script>
(function () {
  var apk = $data.abis;
  // What a phone of this kind can run; null when unsure (a 32-bit
  // browser on a 64-bit phone, x86 Chromebooks that also run ARM apps).
  function kinds(arch, bits) {
    return arch === "arm" && bits === "64" ? ["arm64-v8a", "armeabi-v7a"] : null;
  }
  function check(list) {
    if (!list) { return; }
    for (var i = 0; i < apk.length; i++) {
      if (list.indexOf(apk[i]) >= 0) { return; }
    }
    document.getElementById("abi").hidden = false;
  }
  // armv7l: a 32-bit system (a 32-bit browser on a 64-bit one says
  // armv8l); Chrome's frozen "Linux armv81" says nothing.
  var p = String(navigator.platform || "").toLowerCase();
  if (/armv7l|armv6l/.test(p)) { check(["armeabi-v7a"]); }
  else if (/aarch64|arm64|armv8l/.test(p)) { check(["arm64-v8a", "armeabi-v7a"]); }
  var ua = navigator.userAgentData;
  if (ua && ua.getHighEntropyValues) {
    ua.getHighEntropyValues(["architecture", "bitness"]).then(function (v) {
      check(kinds(v.architecture, v.bitness));
    }, function () {});
  }
})();
</script>
''';
  }
}

/// A local network this device can share on: one interface and its
/// private IPv4 address.
@immutable
final class ShareNetwork {
  const ShareNetwork({required this.interfaceName, required this.address});

  final String interfaceName;
  final InternetAddress address;

  /// Short text for a chooser: `wlan0 · 192.168.1.20`.
  String get label => '$interfaceName · ${address.address}';

  @override
  bool operator ==(Object other) =>
      other is ShareNetwork &&
      other.interfaceName == interfaceName &&
      other.address == address;

  @override
  int get hashCode => Object.hash(interfaceName, address);
}

/// Interfaces that never lead to a person nearby: mobile data (whose
/// carrier addresses are often private too), VPNs and tunnels, virtual
/// machines and containers.
final RegExp _notNearbyInterface = RegExp(
  r'^(rmnet|ccmni|pdp_ip|clat|v4-|dummy|lo|tun|tap|utun|ipsec|ppp|wg|'
  r'tailscale|zt|docker|br-|veth|virbr|vmnet|vboxnet|awdl|llw|anpi)|'
  r'virtualbox|vmware|vethernet|hyper-v|wsl|loopback|npcap|vpn',
  caseSensitive: false,
);

final RegExp _hotspotInterface = RegExp(
  r'^(ap|swlan|softap)',
  caseSensitive: false,
);

final RegExp _wifiInterface = RegExp(
  r'^(wlan|wl|wifi|wi-fi|wlp|bridge1)|wi-?fi|wireless|wlan',
  caseSensitive: false,
);

/// Ranks [networks] for sharing: this phone's hotspot first, then
/// Wi-Fi, then the rest (wired), leaving out interfaces that never reach
/// anyone nearby. The first one is the network the default route most
/// likely uses on the local network.
List<ShareNetwork> rankShareNetworks(Iterable<ShareNetwork> networks) {
  int rank(ShareNetwork n) {
    final List<int> b = n.address.rawAddress;
    // Android hotspots: 192.168.43.1 (older), 192.168.49.1 (local-only),
    // 10.x.x.1 on some phones: the hotspot's own address ends in .1.
    if (_hotspotInterface.hasMatch(n.interfaceName)) {
      return 0;
    }
    if (_wifiInterface.hasMatch(n.interfaceName)) {
      return b[3] == 1 ? 0 : 1;
    }
    return b[3] == 1 ? 2 : 3;
  }

  final List<ShareNetwork> out = <ShareNetwork>[
    for (final ShareNetwork n in networks)
      if (!n.address.isLoopback &&
          isPrivateIPv4(n.address) &&
          !_notNearbyInterface.hasMatch(n.interfaceName))
        n,
  ];
  // A stable sort: equal ranks keep the system's interface order.
  final List<int> order = <int>[for (int i = 0; i < out.length; i++) i];
  order.sort((int a, int b) {
    final int byRank = rank(out[a]) - rank(out[b]);
    return byRank != 0 ? byRank : a - b;
  });
  return <ShareNetwork>[for (final int i in order) out[i]];
}

/// The networks other devices nearby can reach this one on, best first
/// (see [rankShareNetworks]).
Future<List<ShareNetwork>> localShareNetworks() async {
  final List<NetworkInterface> interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  return rankShareNetworks(<ShareNetwork>[
    for (final NetworkInterface i in interfaces)
      for (final InternetAddress a in i.addresses)
        ShareNetwork(interfaceName: i.name, address: a),
  ]);
}

/// The one network to share on: the one the person chose ([chosen], when
/// it is still there), otherwise the best ranked. The server listens on
/// that address only, never on every private address.
ShareNetwork? chooseShareNetwork(
  List<ShareNetwork> networks, {
  ShareNetwork? chosen,
}) {
  if (chosen != null) {
    for (final ShareNetwork n in networks) {
      if (n == chosen) {
        return n;
      }
    }
  }
  return networks.firstOrNull;
}

/// Addresses other devices nearby can reach this one at, best first.
Future<List<InternetAddress>> localShareAddresses() async => <InternetAddress>[
  for (final ShareNetwork n in await localShareNetworks()) n.address,
];

bool isPrivateIPv4(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) {
    return false;
  }
  final List<int> b = a.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168);
}

/// SHA-256 of [file] in hex, shown next to the QR code: whoever receives
/// the app can check that the downloaded file is exactly the one offered
/// (the link is plain HTTP on the local network).
Future<String> fileSha256Hex(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

/// [hex] in groups of four characters, easier to compare by eye.
String groupedHex(String hex) => <String>[
  for (int i = 0; i < hex.length; i += 4)
    hex.substring(i, min(i + 4, hex.length)),
].join(' ');

/// A QR text that joins a Wi-Fi network (understood by phone cameras).
String wifiQrText({required String ssid, required String password}) {
  String esc(String v) =>
      v.replaceAllMapped(RegExp(r'([\\;,:"])'), (Match m) => '\\${m[1]}');
  return 'WIFI:T:WPA;S:${esc(ssid)};P:${esc(password)};;';
}
