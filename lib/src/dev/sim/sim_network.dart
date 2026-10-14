import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Something on a phone that takes incoming frames (any of the app's
/// services: `handle(frame)`).
typedef SimHandler = Future<bool> Function(SignalTransportFrame frame);

/// One message on its way.
final class SimDelivery {
  SimDelivery(this.at, this.seq, this.from, this.to, this.payload);

  final int at;
  final int seq;
  final String from;
  final String to;
  final Map<String, dynamic> payload;
}

/// Counters of what the network did.
final class SimStats {
  int sent = 0;
  int delivered = 0;
  int dropped = 0;
  int heldForOffline = 0;
  final Map<String, int> byType = <String, int>{};

  @override
  String toString() =>
      'wysłane $sent, doręczone $delivered, zgubione $dropped, czekały na odbiorcę $heldForOffline';
}

/// A simulated phone: an [EventHost] for the app's services, with a friend
/// list, notifications and an on/off switch.
final class SimPhone implements EventHost {
  SimPhone._(this.net, this.name, this.address);

  final SimNetwork net;
  final String name;
  final String address;
  final Set<String> friendSet = <String>{};
  final List<SimHandler> handlers = <SimHandler>[];
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<Map<String, dynamic>> outbox = <Map<String, dynamic>>[];
  bool online = true;

  /// Services living on this phone, by name (for scenarios).
  final Map<String, Object> services = <String, Object>{};

  T service<T extends Object>(String key) => services[key]! as T;

  void attach(SimHandler handler) => handlers.add(handler);

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    outbox.add(payload);
    net._enqueue(address, PeerShareCodec.normalizeAddress(to), payload);
  }

  @override
  List<String> friends() => friendSet.toList()..sort();

  @override
  bool isFriend(String a) =>
      friendSet.contains(PeerShareCodec.normalizeAddress(a));

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) =>
      net.byAddress[PeerShareCodec.normalizeAddress(a)]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);

  Iterable<String> get notificationTitles =>
      shown.map((RuntimeSystemNotification n) => n.title);

  @override
  String toString() => name;
}

/// A deterministic network of simulated phones (§ testing on many
/// clients): virtual time, delays, loss, phones going off and on,
/// partitions, and relays that hold messages for phones that are off (like
/// the app's reliable delivery). Every run with the same seed does the same.
final class SimNetwork {
  SimNetwork({
    int seed = 1,
    this.minLatencyMs = 20,
    this.maxLatencyMs = 400,
    this.dropRate = 0,
    this.holdForOffline = true,
    int startAt = 1700000000000,
  }) : random = Random(seed),
       now = startAt;

  final Random random;
  int minLatencyMs;
  int maxLatencyMs;

  /// Share of messages lost on the way (0–1).
  double dropRate;

  /// Messages to a phone that is off wait for it (relays), instead of
  /// being lost.
  bool holdForOffline;

  /// Virtual time, ms.
  int now;
  final Map<String, SimPhone> byAddress = <String, SimPhone>{};
  final Map<String, SimPhone> byName = <String, SimPhone>{};
  final _Heap _queue = _Heap();
  final Map<String, List<SimDelivery>> _held = <String, List<SimDelivery>>{};
  final Set<String> _cut = <String>{};
  final SimStats stats = SimStats();
  int _seq = 0;

  /// Every delivery, for those who want to look (type, from, to, time).
  final List<String> trace = <String>[];
  bool tracing = false;

  List<SimPhone> get phones => byName.values.toList();

  SimPhone phone(String name) {
    final String address = PeerShareCodec.normalizeAddress(
      '200::${(0x100 + byName.length).toRadixString(16)}',
    );
    final SimPhone p = SimPhone._(this, name, address);
    byAddress[address] = p;
    byName[name] = p;
    return p;
  }

  SimPhone operator [](String name) => byName[name]!;

  void befriend(SimPhone a, SimPhone b) {
    a.friendSet.add(b.address);
    b.friendSet.add(a.address);
  }

  void unfriend(SimPhone a, SimPhone b) {
    a.friendSet.remove(b.address);
    b.friendSet.remove(a.address);
  }

  /// Links phones in a chain a–b–c–…
  void chain(List<SimPhone> list) {
    for (int i = 0; i + 1 < list.length; i++) {
      befriend(list[i], list[i + 1]);
    }
  }

  /// Random friendships: each phone gets about [degree] friends.
  void randomGraph(List<SimPhone> list, {int degree = 3}) {
    chain(list);
    for (final SimPhone p in list) {
      for (int i = 0; i < degree - 1; i++) {
        final SimPhone q = list[random.nextInt(list.length)];
        if (q != p) {
          befriend(p, q);
        }
      }
    }
  }

  /// Cuts the link between the two groups (both ways) until [heal].
  void partition(Iterable<SimPhone> a, Iterable<SimPhone> b) {
    for (final SimPhone x in a) {
      for (final SimPhone y in b) {
        _cut
          ..add('${x.address}>${y.address}')
          ..add('${y.address}>${x.address}');
      }
    }
  }

  void heal() => _cut.clear();

  void setOnline(SimPhone p, bool on) {
    p.online = on;
    if (on) {
      final List<SimDelivery> waiting =
          _held.remove(p.address) ?? const <SimDelivery>[];
      for (final SimDelivery d in waiting) {
        _queue.add(
          SimDelivery(now + _latency(), _seq++, d.from, d.to, d.payload),
        );
      }
    }
  }

  int _latency() =>
      minLatencyMs +
      (maxLatencyMs > minLatencyMs
          ? random.nextInt(maxLatencyMs - minLatencyMs)
          : 0);

  void _enqueue(String from, String to, Map<String, dynamic> payload) {
    stats.sent++;
    final String type = payload['type'] is String
        ? payload['type'] as String
        : '?';
    stats.byType[type] = (stats.byType[type] ?? 0) + 1;
    // Like the wire: JSON in, JSON out.
    final Map<String, dynamic> copy =
        jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    _queue.add(SimDelivery(now + _latency(), _seq++, from, to, copy));
  }

  /// Delivers everything due up to [until] (or until quiet), in time order.
  /// Handlers run one at a time, never nested, as on real phones.
  Future<void> run({Duration? forAtMost, int maxSteps = 1000000}) async {
    final int limit = forAtMost == null
        ? 1 << 62
        : now + forAtMost.inMilliseconds;
    int steps = 0;
    while (_queue.isNotEmpty && steps++ < maxSteps) {
      final SimDelivery d = _queue.first;
      if (d.at > limit) {
        break;
      }
      _queue.removeFirst();
      now = max(now, d.at);
      final SimPhone? to = byAddress[d.to];
      if (to == null || _cut.contains('${d.from}>${d.to}')) {
        stats.dropped++;
        continue;
      }
      if (!to.online) {
        if (holdForOffline) {
          stats.heldForOffline++;
          (_held[d.to] ??= <SimDelivery>[]).add(d);
        } else {
          stats.dropped++;
        }
        continue;
      }
      if (dropRate > 0 && random.nextDouble() < dropRate) {
        stats.dropped++;
        continue;
      }
      stats.delivered++;
      if (tracing) {
        trace.add(
          '${now - 1700000000000}ms ${byAddress[d.from]?.name}→${to.name} ${d.payload['type']}',
        );
      }
      final SignalTransportFrame frame = SignalTransportFrame(
        from: d.from,
        payload: d.payload,
        receivedAtMillis: now,
      );
      for (final SimHandler h in to.handlers) {
        await h(frame);
      }
    }
    if (forAtMost != null) {
      now = max(now, limit);
    }
  }

  /// Moves the clock on (delivering what falls in between).
  Future<void> advance(Duration d) => run(forAtMost: d);

  /// Runs [action] on each phone, then lets the network settle.
  Future<void> everyone(Future<void> Function(SimPhone p) action) async {
    for (final SimPhone p in phones) {
      await action(p);
    }
    await run();
  }
}

/// A min-heap of deliveries by (time, order sent).
final class _Heap {
  final List<SimDelivery> _items = <SimDelivery>[];

  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;
  SimDelivery get first => _items.first;

  static bool _less(SimDelivery a, SimDelivery b) =>
      a.at < b.at || (a.at == b.at && a.seq < b.seq);

  void add(SimDelivery d) {
    _items.add(d);
    int i = _items.length - 1;
    while (i > 0) {
      final int parent = (i - 1) >> 1;
      if (!_less(_items[i], _items[parent])) {
        break;
      }
      final SimDelivery t = _items[i];
      _items[i] = _items[parent];
      _items[parent] = t;
      i = parent;
    }
  }

  SimDelivery removeFirst() {
    final SimDelivery top = _items.first;
    final SimDelivery last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      int i = 0;
      while (true) {
        final int l = 2 * i + 1;
        final int r = l + 1;
        int smallest = i;
        if (l < _items.length && _less(_items[l], _items[smallest])) {
          smallest = l;
        }
        if (r < _items.length && _less(_items[r], _items[smallest])) {
          smallest = r;
        }
        if (smallest == i) {
          break;
        }
        final SimDelivery t = _items[i];
        _items[i] = _items[smallest];
        _items[smallest] = t;
        i = smallest;
      }
    }
    return top;
  }
}
