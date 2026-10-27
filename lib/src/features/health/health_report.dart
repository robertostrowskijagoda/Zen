import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/health/clock_skew_tracker.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';

/// How bad one line of the health report is.
enum HealthLevel { ok, warn, bad, unknown }

/// What the person can do about a line.
enum HealthFix { none, permissions, appSettings }

/// What the node is doing (mirrors the shell's service health).
enum HealthNetState { active, syncing, stopped, failed }

/// One line of "Dlaczego nie działa?".
@immutable
class HealthItem {
  const HealthItem({
    required this.id,
    required this.level,
    required this.title,
    required this.detail,
    this.fix = HealthFix.none,
  });

  /// Stable name: `network`, `peers`, `background`, `notifications`,
  /// `battery`, `clock`, `storage`.
  final String id;
  final HealthLevel level;
  final String title;
  final String detail;
  final HealthFix fix;
}

/// Free and total space of the volume Zen keeps its data on.
@immutable
class StorageInfo {
  const StorageInfo({required this.freeBytes, required this.totalBytes});

  final int freeBytes;
  final int totalBytes;

  double get freeFraction => totalBytes <= 0 ? 1 : freeBytes / totalBytes;
}

/// Everything the report is made of, gathered by the caller.
@immutable
class HealthInputs {
  const HealthInputs({
    required this.net,
    this.peers = 0,
    this.routingEntries = 0,
    this.localAddress = '',
    this.errorMessage,
    this.isAndroid = false,
    this.isIPhone = false,
    this.backgroundRunning,
    this.permissions,
    this.clockSkew,
    this.clockPeers = 0,
    this.storage,
  });

  final HealthNetState net;
  final int peers;
  final int routingEntries;
  final String localAddress;
  final String? errorMessage;
  final bool isAndroid;

  /// An iPhone or iPad: iOS lets Zen receive in the background only now and
  /// then (or with the keep-alive, ios_background.dart).
  final bool isIPhone;

  /// The always-on service (Android); `null` = not known.
  final bool? backgroundRunning;

  /// `null` = could not be read.
  final PermissionsSnapshot? permissions;

  /// Friends' clock minus this phone's; `null` = not enough data.
  final Duration? clockSkew;
  final int clockPeers;
  final StorageInfo? storage;
}

@immutable
class HealthReport {
  const HealthReport(this.items);

  final List<HealthItem> items;

  HealthLevel get worst {
    HealthLevel w = HealthLevel.ok;
    for (final HealthItem i in items) {
      if (i.level == HealthLevel.bad) {
        return HealthLevel.bad;
      }
      if (i.level == HealthLevel.warn) {
        w = HealthLevel.warn;
      }
    }
    return w;
  }

  int get problems => items
      .where(
        (HealthItem i) =>
            i.level == HealthLevel.bad || i.level == HealthLevel.warn,
      )
      .length;

  HealthItem? item(String id) =>
      items.where((HealthItem i) => i.id == id).firstOrNull;
}

/// A stricter limit than the free-space warning, in bytes.
const int kStorageBadBytes = 50 * 1024 * 1024;
const int kStorageWarnBytes = 300 * 1024 * 1024;
const double kStorageWarnFraction = 0.05;

/// Turns [i] into the lines of the report (pure: easy to test).
HealthReport buildHealthReport(HealthInputs i) {
  return HealthReport(<HealthItem>[
    _network(i),
    _peers(i),
    if (i.isAndroid) _background(i),
    if (i.isIPhone) _iPhoneBackground(),
    _notifications(i),
    if (i.isAndroid) _battery(i),
    _clock(i),
    _storage(i),
  ]);
}

HealthItem _network(HealthInputs i) {
  return switch (i.net) {
    HealthNetState.active => HealthItem(
      id: 'network',
      level: HealthLevel.ok,
      title: t('Sieć'),
      detail: t('Węzeł Zen działa.'),
    ),
    HealthNetState.syncing => HealthItem(
      id: 'network',
      level: HealthLevel.warn,
      title: t('Sieć'),
      detail: t('Węzeł odbudowuje trasę — to chwilę trwa.'),
    ),
    HealthNetState.stopped => HealthItem(
      id: 'network',
      level: HealthLevel.bad,
      title: t('Sieć'),
      detail: t(
        'Węzeł jest zatrzymany, więc nic nie dochodzi. Uruchom go '
        'ponownie w Ustawieniach.',
      ),
    ),
    HealthNetState.failed => HealthItem(
      id: 'network',
      level: HealthLevel.bad,
      title: t('Sieć'),
      detail: i.errorMessage == null || i.errorMessage!.isEmpty
          ? t('Węzeł zgłosił błąd. Spróbuj uruchomić go ponownie.')
          : t('Węzeł zgłosił błąd: {error}', {'error': i.errorMessage}),
    ),
  };
}

HealthItem _peers(HealthInputs i) {
  final String title = t('Węzeł i sąsiedzi');
  if (i.net == HealthNetState.stopped || i.net == HealthNetState.failed) {
    return HealthItem(
      id: 'peers',
      level: HealthLevel.unknown,
      title: title,
      detail: t('Węzeł nie działa — nie ma kogo policzyć.'),
    );
  }
  if (i.localAddress.isEmpty) {
    return HealthItem(
      id: 'peers',
      level: HealthLevel.warn,
      title: title,
      detail: t('Węzeł nie ma jeszcze swojego adresu w sieci.'),
    );
  }
  if (i.peers <= 0 && i.routingEntries <= 0) {
    return HealthItem(
      id: 'peers',
      level: HealthLevel.warn,
      title: title,
      detail: t(
        'Brak połączeń z siecią. Sprawdź internet albo Wi-Fi; za chwilę '
        'Zen spróbuje ponownie.',
      ),
    );
  }
  return HealthItem(
    id: 'peers',
    level: HealthLevel.ok,
    title: title,
    detail: tn(
      i.peers,
      one: 'Połączony z {n} sąsiadem.',
      few: 'Połączony z {n} sąsiadami.',
      many: 'Połączony z {n} sąsiadami.',
    ),
  );
}

HealthItem _background(HealthInputs i) {
  final String title = t('Praca w tle');
  final bool? running = i.backgroundRunning;
  if (running == null) {
    return HealthItem(
      id: 'background',
      level: HealthLevel.unknown,
      title: title,
      detail: t('Nie udało się sprawdzić usługi w tle.'),
    );
  }
  return running
      ? HealthItem(
          id: 'background',
          level: HealthLevel.ok,
          title: title,
          detail: t('Usługa w tle działa — wiadomości i alarmy dochodzą.'),
        )
      : HealthItem(
          id: 'background',
          level: HealthLevel.warn,
          title: title,
          detail: t(
            'Usługa w tle nie działa. Wiadomości i alarmy dotrą dopiero po '
            'otwarciu aplikacji.',
          ),
          fix: HealthFix.appSettings,
        );
}

/// An iPhone cannot be fixed into receiving in the background: say so, and
/// what helps.
HealthItem _iPhoneBackground() => HealthItem(
  id: 'background',
  level: HealthLevel.warn,
  title: t('Praca w tle'),
  detail: t(
    'iPhone odbiera na bieżąco tylko przy otwartym Zen. W tle iOS czasem '
    'budzi Zen na chwilę, żeby sprawdził skrzynki u znajomych — kiedy, '
    'decyduje system. Pomaga znajomy z Zen na komputerze albo na Androidzie. '
    'Stałe odbieranie w tle włączysz w Ustawieniach → Praca w tle (zużywa '
    'więcej baterii).',
  ),
);

HealthItem _notifications(HealthInputs i) {
  final String title = t('Powiadomienia');
  final bool? granted = i.permissions?[ZenPermission.notifications];
  if (granted == null) {
    return HealthItem(
      id: 'notifications',
      level: HealthLevel.unknown,
      title: title,
      detail: t('Tego nie da się sprawdzić na tym urządzeniu.'),
    );
  }
  return granted
      ? HealthItem(
          id: 'notifications',
          level: HealthLevel.ok,
          title: title,
          detail: t('Zen może pokazywać powiadomienia.'),
        )
      : HealthItem(
          id: 'notifications',
          level: HealthLevel.bad,
          title: title,
          detail: t(
            'Powiadomienia są wyłączone — nie zobaczysz wiadomości, '
            'połączeń ani alarmu, gdy Zen jest zamknięty.',
          ),
          fix: HealthFix.permissions,
        );
}

HealthItem _battery(HealthInputs i) {
  final String title = t('Oszczędzanie baterii');
  final bool? ok = i.permissions?[ZenPermission.battery];
  if (ok == null) {
    return HealthItem(
      id: 'battery',
      level: HealthLevel.unknown,
      title: title,
      detail: t('Tego nie da się sprawdzić na tym urządzeniu.'),
    );
  }
  return ok
      ? HealthItem(
          id: 'battery',
          level: HealthLevel.ok,
          title: title,
          detail: t('Android nie usypia Zen.'),
        )
      : HealthItem(
          id: 'battery',
          level: HealthLevel.warn,
          title: title,
          detail: t(
            'Android może usypiać Zen przy zgaszonym ekranie, wtedy '
            'wiadomości i alarmy się spóźniają.',
          ),
          fix: HealthFix.permissions,
        );
}

HealthItem _clock(HealthInputs i) {
  final String title = t('Zegar telefonu');
  final Duration? skew = i.clockSkew;
  if (skew == null) {
    return HealthItem(
      id: 'clock',
      level: HealthLevel.unknown,
      title: title,
      detail: t(
        'Za mało danych — zegar porównujemy z czasem wiadomości od '
        'znajomych.',
      ),
    );
  }
  final int minutes = skew.abs().inMinutes;
  if (skew.abs() <= ClockSkewTracker.warnThreshold) {
    return HealthItem(
      id: 'clock',
      level: HealthLevel.ok,
      title: title,
      detail: t('Zegar zgadza się z zegarami znajomych.'),
    );
  }
  final String how = skew.isNegative
      ? t('Twój zegar spieszy się o {min} min.', {'min': minutes})
      : t('Twój zegar się spóźnia o {min} min.', {'min': minutes});
  return HealthItem(
    id: 'clock',
    level: minutes >= 10 ? HealthLevel.bad : HealthLevel.warn,
    title: title,
    detail: t(
      '{how} Wiadomości, spotkania i bilety mogą być po cichu odrzucane. '
      'Włącz w systemie automatyczną datę i godzinę.',
      {'how': how},
    ),
  );
}

HealthItem _storage(HealthInputs i) {
  final String title = t('Miejsce na dane');
  final StorageInfo? s = i.storage;
  if (s == null) {
    return HealthItem(
      id: 'storage',
      level: HealthLevel.unknown,
      title: title,
      detail: t('Nie udało się sprawdzić wolnego miejsca.'),
    );
  }
  final String free = formatBytes(s.freeBytes);
  if (s.freeBytes < kStorageBadBytes) {
    return HealthItem(
      id: 'storage',
      level: HealthLevel.bad,
      title: title,
      detail: t(
        'Zostało tylko {free}. Zapis wiadomości może się nie udać — '
        'zwolnij miejsce.',
        {'free': free},
      ),
    );
  }
  if (s.freeBytes < kStorageWarnBytes ||
      s.freeFraction < kStorageWarnFraction) {
    return HealthItem(
      id: 'storage',
      level: HealthLevel.warn,
      title: title,
      detail: t('Zostało {free} wolnego miejsca — warto je zwolnić.', {
        'free': free,
      }),
    );
  }
  return HealthItem(
    id: 'storage',
    level: HealthLevel.ok,
    title: title,
    detail: t('Wolne miejsce: {free}.', {'free': free}),
  );
}

/// "1,4 GB", "230 MB".
String formatBytes(int bytes) {
  const int mb = 1024 * 1024;
  if (bytes >= 1024 * mb) {
    return '${(bytes / (1024 * mb)).toStringAsFixed(1)} GB';
  }
  return '${(bytes / mb).round()} MB';
}

/// Reads `df -k` output for one path: the last line with the numbers.
StorageInfo? parseDfOutput(String output) {
  final List<String> lines = output
      .split('\n')
      .map((String l) => l.trim())
      .where((String l) => l.isNotEmpty)
      .toList();
  for (final String line in lines.reversed) {
    final List<String> cols = line.split(RegExp(r'\s+'));
    if (cols.length < 4) {
      continue;
    }
    final int? total = int.tryParse(cols[1]);
    final int? free = int.tryParse(cols[3]);
    if (total != null && free != null) {
      return StorageInfo(freeBytes: free * 1024, totalBytes: total * 1024);
    }
  }
  return null;
}

/// The system side of the report (a fake in tests).
abstract interface class HealthProbe {
  Future<StorageInfo?> storage();

  /// Android: the always-on service is running; `null` = unknown.
  Future<bool?> backgroundServiceRunning();
}

final class SystemHealthProbe implements HealthProbe {
  const SystemHealthProbe();

  @override
  Future<StorageInfo?> storage() async {
    if (kIsWeb || Platform.isWindows) {
      return null;
    }
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      final ProcessResult r = await Process.run('df', <String>[
        '-k',
        dir.path,
      ]).timeout(const Duration(seconds: 3));
      if (r.exitCode != 0) {
        return null;
      }
      return parseDfOutput(r.stdout.toString());
    } on Object catch (error) {
      logZenWarning('Wolne miejsce: $error');
      return null;
    }
  }

  @override
  Future<bool?> backgroundServiceRunning() async {
    if (kIsWeb || !Platform.isAndroid) {
      return null;
    }
    try {
      return await FlutterForegroundTask.isRunningService;
    } on Object {
      return null;
    }
  }
}

final Provider<HealthProbe> healthProbeProvider = Provider<HealthProbe>(
  (Ref ref) => const SystemHealthProbe(),
);

final Provider<ClockSkewTracker> clockSkewTrackerProvider =
    Provider<ClockSkewTracker>((Ref ref) => ClockSkewTracker.instance);
