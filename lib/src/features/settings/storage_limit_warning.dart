import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// The limit for all of Zen (`AppSettings.inboxLimitMb`), told: when Zen
// takes more than it, the hourly round deletes the oldest of other people's
// photos and videos (`storage_retention.dart`), and the person hears of it
// once - on top of "Dane i pamięć" and in the list of notifications - with
// a way to raise the limit.

/// How much room a raised limit leaves above what Zen takes now.
const double kRaisedLimitHeadroom = 1.25;

/// Prefix of the notification entries about the limit for all of Zen.
const String kStorageLimitEntryPrefix = 'storage-limit:';

/// How long the list of notifications stays quiet after telling of the
/// limit.
const Duration kStorageLimitNoticeEvery = Duration(days: 1);

/// What the last round of the limits found for all of Zen against
/// [limitMb]: what it deleted of other people's photos and videos and how
/// much Zen still takes over the limit.
@immutable
final class StorageLimitWarning {
  const StorageLimitWarning({
    required this.limitMb,
    this.deletedFiles = 0,
    this.deletedBytes = 0,
    this.stillOverBytes = 0,
  });

  final int limitMb;

  /// Other people's photos and videos deleted for the limit (since the
  /// app started, at this limit).
  final int deletedFiles;
  final int deletedBytes;

  /// How much Zen takes over the limit with nothing more of that kind to
  /// delete.
  final int stillOverBytes;

  bool get stillOver => stillOverBytes > 0;

  /// Whether there is anything to tell.
  bool get matters => stillOver || deletedFiles > 0;

  /// The id of its notification entry: one per limit and per kind (photos
  /// deleted, or still over), so a change is told again.
  String get entryId =>
      '$kStorageLimitEntryPrefix$limitMb:${stillOver ? 'full' : 'trimmed'}';

  /// This round's [next] on top of what went before at the same limit.
  StorageLimitWarning then(StorageLimitWarning next) => next.limitMb == limitMb
      ? StorageLimitWarning(
          limitMb: limitMb,
          deletedFiles: deletedFiles + next.deletedFiles,
          deletedBytes: deletedBytes + next.deletedBytes,
          stillOverBytes: next.stillOverBytes,
        )
      : next;
}

/// The step of [AppSettings.storageLimitStepsMb] to raise the limit of
/// [currentMb] to when Zen takes [usedBytes]: the smallest above it that
/// leaves [kRaisedLimitHeadroom], else the largest step; `null` when no
/// step is above [currentMb].
int? raisedStorageLimitMb(int usedBytes, {required int currentMb}) {
  final double wantedMb = usedBytes * kRaisedLimitHeadroom / (1024 * 1024);
  final List<int> above = <int>[
    for (final int step in AppSettings.storageLimitStepsMb)
      if (step > currentMb) step,
  ];
  if (above.isEmpty) {
    return null;
  }
  for (final int step in above) {
    if (step >= wantedMb) {
      return step;
    }
  }
  return above.last;
}

/// What the last round found for the limit of all of Zen, or `null` when
/// Zen fits it (or there is no limit).
final NotifierProvider<StorageLimitWarningController, StorageLimitWarning?>
storageLimitWarningProvider =
    NotifierProvider<StorageLimitWarningController, StorageLimitWarning?>(
      StorageLimitWarningController.new,
    );

class StorageLimitWarningController extends Notifier<StorageLimitWarning?> {
  @override
  StorageLimitWarning? build() => null;

  /// Takes a round's [warning] (`null`: there is no limit). What was
  /// deleted at a limit stays told while the limit stays the same.
  void report(StorageLimitWarning? warning) {
    if (!ref.mounted) {
      return;
    }
    final StorageLimitWarning? before = state;
    if (warning == null) {
      state = null;
    } else if (before == null) {
      state = warning.matters ? warning : null;
    } else {
      final StorageLimitWarning next = before.then(warning);
      state = next.matters ? next : null;
    }
  }
}

/// "Zen zajmuje więcej niż 1 GB" / "Usunięto najstarsze zdjęcia i filmy
/// znajomych": the title of the warning about [warning], or about a limit
/// of [limitMb] Zen is over before any round ran (`null`).
String storageLimitWarningTitle(StorageLimitWarning? warning, int limitMb) =>
    warning == null || warning.stillOver
    ? t('Zen zajmuje więcej niż {limit}', {
        'limit': AppSettings.storageLimitLabel(limitMb),
      })
    : t('Usunięto najstarsze zdjęcia i filmy znajomych');

/// What the warning of [storageLimitWarningTitle] means.
String storageLimitWarningBody(StorageLimitWarning? warning, int limitMb) {
  if (warning == null) {
    return t(
      'Najstarsze zdjęcia i filmy znajomych zostaną usunięte same. '
      'Wiadomości, Twoje posty i kopie zostają. Możesz zwiększyć limit.',
    );
  }
  return warning.stillOver
      ? t(
          'Nie ma już zdjęć ani filmów znajomych do usunięcia, a wiadomości, '
          'Twoje posty i kopie zostają. Możesz zwiększyć limit.',
        )
      : t(
          'Zen przekroczył limit {limit}. Twoje posty i wiadomości zostają. '
          'Możesz zwiększyć limit.',
          {'limit': AppSettings.storageLimitLabel(limitMb)},
        );
}

/// The notification entry about [warning], told at [nowMillis]: a tap
/// opens "Dane i pamięć".
InboxEntry storageLimitInboxEntry(
  StorageLimitWarning warning, {
  required int nowMillis,
}) => InboxEntry(
  id: warning.entryId,
  type: InboxEntryType.storage,
  title: storageLimitWarningTitle(warning, warning.limitMb),
  body: storageLimitWarningBody(warning, warning.limitMb),
  createdAtMillis: nowMillis,
  routeKey: buildStorageRouteKey(),
);

/// Whether [warning] is to be told in the list of notifications [inbox] at
/// [nowMillis]: at most once per [kStorageLimitNoticeEvery], and only when
/// something changed since the last time (another limit or kind, or Zen
/// fit its limit in between: [fitSince]).
bool storageLimitNoticeDue(
  Iterable<InboxEntry> inbox,
  StorageLimitWarning warning, {
  required int nowMillis,
  bool fitSince = false,
}) {
  if (!warning.matters) {
    return false;
  }
  InboxEntry? last;
  for (final InboxEntry e in inbox) {
    if (e.id.startsWith(kStorageLimitEntryPrefix) &&
        (last == null || e.createdAtMillis > last.createdAtMillis)) {
      last = e;
    }
  }
  if (last == null) {
    return true;
  }
  if (nowMillis - last.createdAtMillis <
      kStorageLimitNoticeEvery.inMilliseconds) {
    return false;
  }
  return fitSince || last.id != warning.entryId;
}
