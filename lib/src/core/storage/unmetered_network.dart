import 'dart:async';
import 'dart:io';

/// A network interface and the addresses it holds.
final class NetInterfaceInfo {
  const NetInterfaceInfo(this.name, this.addresses);

  final String name;
  final List<InternetAddress> addresses;
}

typedef NetInterfaceLister = Future<List<NetInterfaceInfo>> Function();

Future<List<NetInterfaceInfo>> _systemInterfaces() async {
  final List<NetworkInterface> all = await NetworkInterface.list(
    includeLinkLocal: false,
  );
  return <NetInterfaceInfo>[
    for (final NetworkInterface i in all) NetInterfaceInfo(i.name, i.addresses),
  ];
}

/// Whether the phone is on Wi-Fi (or a cable) rather than mobile data, for
/// the "media only on Wi-Fi" setting. There is no plugin for this in the
/// app, so it is read from the interfaces the system lists: a mobile-data
/// interface (`rmnet*`, `ccmni*`, `pdp_ip*`...) with an address and no
/// Wi-Fi or Ethernet one means a metered network. If nothing identifies
/// mobile data (a desktop, or a system that hides the list), the network
/// counts as unmetered, so media never stay blocked for good. A phone
/// sharing its own hotspot looks like Wi-Fi.
///
/// [onUnmetered] is a synchronous answer from the last look, refreshed
/// in the background when it is older than [maxAge].
final class UnmeteredNetwork {
  UnmeteredNetwork({
    NetInterfaceLister? lister,
    bool? isMobile,
    this.maxAge = const Duration(seconds: 20),
  }) : _lister = lister ?? _systemInterfaces,
       _isMobile = isMobile ?? (Platform.isAndroid || Platform.isIOS);

  static final UnmeteredNetwork instance = UnmeteredNetwork();

  final NetInterfaceLister _lister;
  final bool _isMobile;
  final Duration maxAge;

  bool? _unmetered;
  DateTime? _looked;
  Future<void>? _refreshing;

  /// The last answer. Before the first look on a phone it is `false`
  /// (media wait rather than use mobile data by mistake).
  bool get onUnmetered {
    if (!_isMobile) {
      return true;
    }
    final DateTime? looked = _looked;
    if (looked == null || DateTime.now().difference(looked) > maxAge) {
      unawaited(refresh());
    }
    return _unmetered ?? false;
  }

  /// Looks at the interfaces now (calls overlap into one look).
  Future<void> refresh() {
    if (!_isMobile) {
      _unmetered = true;
      return Future<void>.value();
    }
    return _refreshing ??= _look().whenComplete(() => _refreshing = null);
  }

  Future<void> _look() async {
    try {
      _unmetered = classify(await _lister());
    } on Object {
      _unmetered = true;
    }
    _looked = DateTime.now();
  }

  /// `true` unless [interfaces] show mobile data and nothing better.
  static bool classify(List<NetInterfaceInfo> interfaces) {
    bool cellular = false;
    bool unmetered = false;
    for (final NetInterfaceInfo i in interfaces) {
      final bool hasAddress = i.addresses.any(
        (InternetAddress a) => !a.isLoopback && !a.isLinkLocal,
      );
      if (!hasAddress) {
        continue;
      }
      final String name = i.name.toLowerCase();
      if (_cellularName.hasMatch(name)) {
        cellular = true;
      } else if (_unmeteredName.hasMatch(name)) {
        unmetered = true;
      }
    }
    return unmetered || !cellular;
  }

  static final RegExp _cellularName = RegExp(
    r'^(v4-)?(rmnet|ccmni|pdp_ip|wwan|ppp|usb_rmnet)',
  );

  // Android Wi-Fi/Ethernet, iOS Wi-Fi (`en0`) and wired (`en1`+) adapters.
  static final RegExp _unmeteredName = RegExp(r'^(wlan|swlan|eth|en\d)');
}
