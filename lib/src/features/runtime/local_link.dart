import 'dart:convert';

import 'package:flutter/foundation.dart';

// Direct links with friends' and own devices nearby, without internet
// (§5.1 item 6). The Go bridge does the work (local_link*.go): it finds
// devices on local networks itself, and peers Yggdrasil over any byte
// stream a native transport gives it. This file is the Dart side of that:
// the bridge's calls ([LocalLinkNodeApi]), what it reports
// ([LocalLinksStatus]) and the shape of a native transport ([LocalLink]).

/// What carries a link.
enum LocalLinkTransport {
  /// The same Wi-Fi or cable network (beacons, then TCP).
  lan('lan'),

  /// A Wi-Fi Direct group (Android); then the same as [lan] over it.
  wifiDirect('wifi-direct'),

  /// A Bluetooth stream.
  bluetooth('bluetooth'),

  /// Apple's Multipeer Connectivity (Bluetooth and peer-to-peer Wi-Fi).
  multipeer('multipeer');

  const LocalLinkTransport(this.wireName);

  /// The name the bridge uses.
  final String wireName;

  static LocalLinkTransport? fromWire(Object? name) {
    for (final LocalLinkTransport t in values) {
      if (t.wireName == name) {
        return t;
      }
    }
    return null;
  }
}

/// One live link, as the bridge reports it.
@immutable
final class LocalLinkInfo {
  const LocalLinkInfo({
    required this.id,
    required this.transport,
    required this.address,
    required this.own,
    required this.since,
    required this.up,
  });

  final String id;

  /// `null` for a transport this app version does not name.
  final LocalLinkTransport? transport;

  /// The other device's mesh address.
  final String address;

  /// One of this account's own devices (else a friend's).
  final bool own;
  final DateTime since;

  /// Yggdrasil's peering over it is up.
  final bool up;

  static LocalLinkInfo? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? address = json['address'];
    final Object? since = json['since'];
    if (id is! String || address is! String) {
      return null;
    }
    return LocalLinkInfo(
      id: id,
      transport: LocalLinkTransport.fromWire(json['transport']),
      address: address,
      own: json['own'] == true,
      since: DateTime.fromMillisecondsSinceEpoch(since is int ? since : 0),
      up: json['up'] == true,
    );
  }
}

/// The bridge's local links (YggGetLocalLinksJson).
@immutable
final class LocalLinksStatus {
  const LocalLinksStatus({
    this.lanOn = false,
    this.lanRunning = false,
    this.interfaces = const <String>[],
    this.lanError,
    this.peerCount = 0,
    this.links = const <LocalLinkInfo>[],
  });

  /// Nothing known (no node, or before the first answer).
  static const LocalLinksStatus empty = LocalLinksStatus();

  /// The LAN setting reached the bridge.
  final bool lanOn;

  /// Beacons go out (on and with devices to find).
  final bool lanRunning;

  /// The local networks they go out on.
  final List<String> interfaces;
  final String? lanError;

  /// Devices this one may link with.
  final int peerCount;
  final List<LocalLinkInfo> links;

  /// Links whose peering is up.
  List<LocalLinkInfo> get upLinks =>
      links.where((LocalLinkInfo l) => l.up).toList(growable: false);

  static LocalLinksStatus fromJson(Map<String, dynamic> json) {
    final Object? lan = json['lan'];
    final Map<dynamic, dynamic> lanMap = lan is Map ? lan : const {};
    final Object? interfaces = lanMap['interfaces'];
    final Object? links = json['links'];
    final Object? peers = json['peers'];
    final Object? error = lanMap['error'];
    return LocalLinksStatus(
      lanOn: lanMap['on'] == true,
      lanRunning: lanMap['running'] == true,
      interfaces: interfaces is List
          ? List<String>.unmodifiable(interfaces.whereType<String>())
          : const <String>[],
      lanError: error is String && error.isNotEmpty ? error : null,
      peerCount: peers is int ? peers : 0,
      links: links is List
          ? List<LocalLinkInfo>.unmodifiable(
              links.map(LocalLinkInfo.fromJson).whereType<LocalLinkInfo>(),
            )
          : const <LocalLinkInfo>[],
    );
  }
}

/// Where a native transport hands the bridge one stream: it connects to
/// `127.0.0.1:`[port], writes the [token] bytes first, then pumps bytes both
/// ways until either side closes (that ends the link). Good for one stream,
/// for a minute.
@immutable
final class LocalLinkEndpoint {
  const LocalLinkEndpoint({
    required this.id,
    required this.port,
    required this.token,
  });

  final String id;
  final int port;
  final Uint8List token;

  static LocalLinkEndpoint? fromJson(Map<String, dynamic> json) {
    final Object? id = json['id'];
    final Object? port = json['port'];
    final Object? token = json['token'];
    if (id is! String || port is! int || token is! String) {
      return null;
    }
    final Uint8List? bytes = _unhex(token);
    return bytes == null
        ? null
        : LocalLinkEndpoint(id: id, port: port, token: bytes);
  }
}

Uint8List? _unhex(String hex) {
  if (hex.length.isOdd) {
    return null;
  }
  final Uint8List out = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    final int? byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      return null;
    }
    out[i] = byte;
  }
  return out;
}

/// The bridge's local link calls for one running node.
abstract interface class LocalLinkNodeApi {
  /// Sets the devices to link with and the LAN (localLinksSettingsJson);
  /// returns the status.
  LocalLinksStatus configure(String settingsJson);

  LocalLinksStatus status();

  /// An endpoint for one native stream over [transport].
  LocalLinkEndpoint? openStream(LocalLinkTransport transport);

  /// Ends a link (or an endpoint still waiting).
  void close(String id);

  /// A fresh advert (hex) for a native transport to show: a Bloom filter of
  /// [bytes] bytes (0: sized to the devices) only they can test. Make a new
  /// one every few minutes.
  String? advert({int bytes = 0});

  /// Whether a nearby advert (hex) may be a device to link with (and not
  /// one linked already).
  bool matches(String advertHex);
}

/// What a running node answers to its local link calls, as the FFI layer
/// gives it (JSON maps).
abstract interface class LocalLinkBridgeCalls {
  Map<String, dynamic> setLocalLinks(int handle, String settingsJson);
  Map<String, dynamic> getLocalLinks(int handle);
  Map<String, dynamic> openLocalLink(int handle, String requestJson);
  Map<String, dynamic> closeLocalLink(int handle, String id);
  Map<String, dynamic> localLinkAdvert(int handle, String requestJson);
  Map<String, dynamic> matchLocalLinkAdvert(int handle, String requestJson);
}

/// [LocalLinkNodeApi] over the FFI calls of node [handle].
final class BridgeLocalLinkApi implements LocalLinkNodeApi {
  const BridgeLocalLinkApi(this._bridge, this._handle);

  final LocalLinkBridgeCalls _bridge;
  final int _handle;

  @override
  LocalLinksStatus configure(String settingsJson) =>
      LocalLinksStatus.fromJson(_bridge.setLocalLinks(_handle, settingsJson));

  @override
  LocalLinksStatus status() =>
      LocalLinksStatus.fromJson(_bridge.getLocalLinks(_handle));

  @override
  LocalLinkEndpoint? openStream(LocalLinkTransport transport) =>
      LocalLinkEndpoint.fromJson(
        _bridge.openLocalLink(
          _handle,
          jsonEncode(<String, String>{'transport': transport.wireName}),
        ),
      );

  @override
  void close(String id) => _bridge.closeLocalLink(_handle, id);

  @override
  String? advert({int bytes = 0}) {
    final Object? advert = _bridge.localLinkAdvert(
      _handle,
      jsonEncode(<String, int>{'bytes': bytes}),
    )['advert'];
    return advert is String ? advert : null;
  }

  @override
  bool matches(String advertHex) =>
      _bridge.matchLocalLinkAdvert(
        _handle,
        jsonEncode(<String, String>{'advert': advertHex}),
      )['match'] ==
      true;
}

/// How far a native transport got.
enum LocalLinkPhase {
  /// Switched off.
  off,

  /// Not on this device (no hardware, or not this platform).
  unavailable,

  /// It needs a permission the person has not given.
  needsPermission,

  /// Its radio is switched off (Bluetooth off).
  radioOff,

  /// On, but not needed now (e.g. Wi-Fi Direct while on a Wi-Fi network).
  idle,

  /// Looking for devices nearby.
  searching,

  /// Connected to at least one device nearby.
  connected,
}

@immutable
final class LocalLinkState {
  const LocalLinkState(this.phase, {this.peers = 0});

  static const LocalLinkState off = LocalLinkState(LocalLinkPhase.off);

  final LocalLinkPhase phase;

  /// Devices it is connected to.
  final int peers;

  @override
  bool operator ==(Object other) =>
      other is LocalLinkState && other.phase == phase && other.peers == peers;

  @override
  int get hashCode => Object.hash(phase, peers);
}

/// A native transport that finds Zen devices nearby and gives the bridge a
/// way to them. Wi-Fi Direct (wifi_direct_local_link.dart) forms a group,
/// and the bridge's LAN discovery runs over it; a Bluetooth or Multipeer
/// transport would instead advertise [LocalLinkNodeApi.advert], connect only
/// to devices whose advert [LocalLinkNodeApi.matches], and hand each
/// stream to the bridge through [LocalLinkNodeApi.openStream]. The bridge
/// then proves the pair in its handshake and refuses everyone else.
///
/// The controller (local_links_controller.dart) starts a transport while
/// its setting is on and the app is used (on screen, or the Android
/// background service runs), and stops it otherwise.
abstract class LocalLink {
  LocalLinkTransport get transport;

  /// Whether this platform has it at all.
  bool get isSupported;

  /// What it does now, for the status line in Settings.
  ValueListenable<LocalLinkState> get state;

  /// Starts it for the running node [node] ([node] is read again on every
  /// use: the node may restart). [foreground]: the app is on screen.
  Future<void> start(
    LocalLinkNodeApi? Function() node, {
    required bool foreground,
  });

  /// The app went to or came back from the background while running.
  void setForeground(bool foreground) {}

  /// Asks for what it needs (permissions); `true` once it has them.
  Future<bool> requestPermissions() async => true;

  Future<void> stop();

  /// Gives up its resources for good.
  void dispose() {}
}
