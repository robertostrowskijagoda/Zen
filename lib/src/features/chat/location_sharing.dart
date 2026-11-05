import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/domain/messages/chat_location.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// Where the positions being shared are kept (this device only).
const String kLocationSharesKey = 'chat/location_shares';

/// How long a position may be shared for, as offered.
const List<Duration> kLocationShareChoices = <Duration>[
  Duration(minutes: 15),
  Duration(hours: 1),
  Duration(hours: 8),
];

/// How often a newer position is read while sharing for [length]: often
/// for a short walk, rarely for a long day (each reading wakes the GPS).
Duration locationUpdateEvery(Duration length) =>
    length <= const Duration(minutes: 15)
    ? const Duration(minutes: 1)
    : length <= const Duration(hours: 1)
    ? const Duration(minutes: 2)
    : const Duration(minutes: 5);

/// A newer position goes out only when it moved this far (metres) or this
/// long passed: standing still sends nothing new.
const double kLocationMoveMetres = 25;
const Duration kLocationRefreshAnyway = Duration(minutes: 10);

/// Whether this system can share where it is.
bool get locationSharingAvailable =>
    !kIsWeb &&
    switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      _ => false,
    };

/// What a shared position says as text (a Zen without this feature shows
/// it, and the previews).
String sharedLocationText(ChatLocation location, {required int nowMillis}) {
  final String link = mapUrl(location.lat, location.lon);
  if (!location.isLiveAt(nowMillis)) {
    return t('📍 Moje położenie: {link}', <String, Object?>{'link': link});
  }
  final DateTime until = DateTime.fromMillisecondsSinceEpoch(
    location.untilMillis,
  );
  return t('📍 Moje położenie na żywo do {time}: {link}', <String, Object?>{
    'time': '${until.hour}:${until.minute.toString().padLeft(2, '0')}',
    'link': link,
  });
}

/// Metres between two places (haversine).
double metresBetween(double lat1, double lon1, double lat2, double lon2) {
  const double r = 6371000;
  double rad(double d) => d * math.pi / 180;
  final double dLat = rad(lat2 - lat1);
  final double dLon = rad(lon2 - lon1);
  final double a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// One position being shared: the message it lives in and how it goes.
@immutable
final class LocationShare {
  const LocationShare({
    required this.conversationKey,
    required this.messageId,
    required this.untilMillis,
    required this.everyMillis,
    required this.last,
  });

  final String conversationKey;
  final String messageId;
  final int untilMillis;
  final int everyMillis;

  /// The position last sent.
  final ChatLocation last;

  Map<String, Object?> toJson() => <String, Object?>{
    'k': conversationKey,
    'm': messageId,
    'u': untilMillis,
    'e': everyMillis,
    'l': last.toJson(),
  };

  static LocationShare? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? k = json['k'];
    final Object? m = json['m'];
    final Object? u = json['u'];
    final Object? e = json['e'];
    final ChatLocation? last = ChatLocation.fromJson(json['l']);
    if (k is! String ||
        m is! String ||
        u is! int ||
        e is! int ||
        last == null) {
      return null;
    }
    return LocationShare(
      conversationKey: k,
      messageId: m,
      untilMillis: u,
      everyMillis: e.clamp(60000, 600000),
      last: last,
    );
  }
}

/// "Udostępnij położenie": one position, or newer ones for a while. While
/// sharing, Zen reads where the device is every [locationUpdateEvery] and
/// sends it when it moved; the sharing ends by itself at its time, or
/// earlier with [stop]. It goes on after a restart (kept on this device)
/// and only while Zen runs.
final class LocationSharingService extends ChangeNotifier {
  LocationSharingService({
    required this.disk,
    required this.readFix,
    required this.send,
    required this.update,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerDisk disk;

  /// Where the device is now; `null` when that cannot be known. [ask]:
  /// the person is looking (the permission question may show).
  final Future<GeoFix?> Function({required bool ask}) readFix;

  /// Sends a new shared position; its message's id.
  final Future<String> Function(
    String conversationKey,
    String text,
    ChatLocation location,
  )
  send;

  /// Puts a newer position on a shared one; `false` when that message is
  /// gone.
  final Future<bool> Function(
    String conversationKey,
    String messageId,
    String text,
    ChatLocation location,
  )
  update;

  final int Function() _now;

  Map<String, LocationShare> _shares = <String, LocationShare>{};
  bool _loaded = false;
  Timer? _timer;
  Future<void>? _ticking;

  /// The live shares in [conversationKey], or everywhere.
  List<LocationShare> active([String? conversationKey]) => _shares.values
      .where(
        (LocationShare s) =>
            conversationKey == null || s.conversationKey == conversationKey,
      )
      .toList();

  bool isSharing(String messageId) => _shares.containsKey(messageId);

  Future<void> load() async {
    final Map<String, LocationShare> read = <String, LocationShare>{};
    try {
      final Uint8List? raw = await disk.read(kLocationSharesKey);
      if (raw != null) {
        final Object? json = jsonDecode(utf8.decode(raw));
        if (json is List) {
          for (final Object? item in json) {
            final LocationShare? share = LocationShare.fromJson(item);
            if (share != null) {
              read[share.messageId] = share;
            }
          }
        }
      }
    } on Object catch (error) {
      logZenWarning('Reading the shared positions failed: $error');
    }
    _shares = read;
    _loaded = true;
    notifyListeners();
  }

  /// Shares where the device is in [conversationKey]: once ([length]
  /// null), or live for [length]. Throws a [StateError] with a message for
  /// the person when the position cannot be known.
  Future<void> share(String conversationKey, {Duration? length}) async {
    await _ensureLoaded();
    final GeoFix? fix = await readFix(ask: true);
    if (fix == null) {
      throw StateError(
        t(
          'Nie udało się ustalić położenia. Sprawdź, czy lokalizacja jest '
          'włączona i czy Zen ma do niej dostęp.',
        ),
      );
    }
    final int now = _now();
    final Duration? capped = length == null
        ? null
        : (length > kMaxLocationShare ? kMaxLocationShare : length);
    final ChatLocation location = ChatLocation(
      lat: fix.lat,
      lon: fix.lon,
      accuracy: fix.accuracy,
      atMillis: now,
      untilMillis: capped == null ? now : now + capped.inMilliseconds,
    );
    final String id = await send(
      conversationKey,
      sharedLocationText(location, nowMillis: now),
      location,
    );
    if (capped != null) {
      _shares[id] = LocationShare(
        conversationKey: conversationKey,
        messageId: id,
        untilMillis: location.untilMillis,
        everyMillis: locationUpdateEvery(capped).inMilliseconds,
        last: location,
      );
      await _save();
      start();
    }
  }

  /// Ends the live sharing [messageId] now (the last position stays).
  Future<void> stop(String messageId) async {
    await _ensureLoaded();
    final LocationShare? share = _shares.remove(messageId);
    if (share == null) {
      return;
    }
    await _save();
    final ChatLocation ended = share.last.copyWith(untilMillis: _now());
    try {
      await update(
        share.conversationKey,
        messageId,
        sharedLocationText(ended, nowMillis: _now()),
        ended,
      );
    } on Object catch (error) {
      logZenWarning('Ending a shared position failed: $error');
    }
  }

  /// Checks the shares every minute while some are live.
  void start() {
    if (_shares.isEmpty && _loaded) {
      return;
    }
    _timer ??= Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(tick()),
    );
    unawaited(tick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  /// One round: ends the shares whose time is up, sends a newer position
  /// for those due (one reading of the position for all).
  Future<void> tick() => _ticking ??= _tick().whenComplete(() {
    _ticking = null;
  });

  Future<void> _tick() async {
    await _ensureLoaded();
    final int now = _now();
    bool changed = false;
    for (final LocationShare share in _shares.values.toList()) {
      if (now >= share.untilMillis) {
        _shares.remove(share.messageId);
        changed = true;
      }
    }
    final List<LocationShare> due = _shares.values
        .where(
          (LocationShare s) => now - s.last.atMillis >= s.everyMillis - 5000,
        )
        .toList();
    if (due.isNotEmpty) {
      GeoFix? fix;
      try {
        fix = await readFix(ask: false);
      } on Object catch (error) {
        logZenWarning('Reading the position failed: $error');
      }
      if (fix != null) {
        for (final LocationShare share in due) {
          final bool moved =
              metresBetween(share.last.lat, share.last.lon, fix.lat, fix.lon) >=
              math.max(kLocationMoveMetres, fix.accuracy / 2);
          if (!moved &&
              now - share.last.atMillis <
                  kLocationRefreshAnyway.inMilliseconds) {
            continue;
          }
          final ChatLocation next = ChatLocation(
            lat: fix.lat,
            lon: fix.lon,
            accuracy: fix.accuracy,
            atMillis: now,
            untilMillis: share.untilMillis,
          );
          try {
            final bool there = await update(
              share.conversationKey,
              share.messageId,
              sharedLocationText(next, nowMillis: now),
              next,
            );
            if (there) {
              _shares[share.messageId] = LocationShare(
                conversationKey: share.conversationKey,
                messageId: share.messageId,
                untilMillis: share.untilMillis,
                everyMillis: share.everyMillis,
                last: next,
              );
            } else {
              _shares.remove(share.messageId);
            }
            changed = true;
          } on Object catch (error) {
            logZenWarning('Sending a newer position failed: $error');
          }
        }
      }
    }
    if (changed) {
      await _save();
    }
    if (_shares.isEmpty) {
      _stopTimer();
    }
  }

  Future<void> _ensureLoaded() async {
    if (!_loaded) {
      await load();
    }
  }

  Future<void> _save() async {
    await disk.write(
      kLocationSharesKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<Object?>[
            for (final LocationShare s in _shares.values) s.toJson(),
          ]),
        ),
      ),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }
}

/// The position now: with the question for the permission when the person
/// is looking, under the background reading otherwise.
Future<GeoFix?> _platformFix({required bool ask}) {
  final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
  if (ask || state == null || state == AppLifecycleState.resumed) {
    return currentFix(ask: ask);
  }
  return currentFixInBackground();
}

/// This device's shared positions, sent through the chat.
final Provider<LocationSharingService> locationSharingProvider =
    Provider<LocationSharingService>((Ref ref) {
      SocialHubController hub() =>
          ref.read(socialHubControllerProvider.notifier);
      final LocationSharingService service = LocationSharingService(
        disk: ref.read(ledgerDiskProvider),
        readFix: _platformFix,
        send: (String key, String text, ChatLocation location) =>
            hub().sendLocationMessage(
              conversationKey: key,
              text: text,
              location: location,
            ),
        update: (String key, String id, String text, ChatLocation location) =>
            hub().updateSharedLocation(
              conversationKey: key,
              messageId: id,
              text: text,
              location: location,
            ),
      );
      ref.onDispose(service.dispose);
      return service;
    });
