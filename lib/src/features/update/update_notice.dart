import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/atomic_file.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

/// How old GitHub's last answer may get while the app runs before the app
/// asks again: at start, when it comes back to the screen and while it
/// stays open. Whoever asked last (the app, the Android background
/// service) counts. A check asks the project's pages first, which have no
/// rate limit; GitHub's API (60 requests an hour per IP address, shared
/// behind a mobile operator's address) only when they do not answer.
const Duration kGithubCheckEvery = Duration(hours: 1);

/// How old the last answer may get before the Android background service
/// asks while the app is closed. The service's look rides wakes that come
/// anyway (the mailbox polls), so it adds no alarm of its own, and asks the
/// project's pages first, which have no rate limit (latest_release.dart).
const Duration kBackgroundGithubCheckEvery = Duration(hours: 2);

/// The longest error text [UpdateNoticeState.error] keeps.
const int kUpdateNoticeErrorChars = 160;

/// The notification slot of "Jest nowa wersja Zen": a newer version takes
/// the place of the one before.
const String kUpdateNoticeSlot = 'app-update';

/// The file in the app's data folder (a profile's own folder with
/// `--zen-profile`) that holds [UpdateNoticeState]. A plain file: the
/// Android background service reads and writes it too, also while the app
/// is locked, and nothing in it is private (versions, times and the last
/// error of a request to GitHub).
const String kUpdateNoticeFileName = 'update_check.json';

/// What the app and the Android background service share about the look
/// at GitHub, so that together they ask no more often than needed and tell
/// the person about a version once.
@immutable
final class UpdateNoticeState {
  const UpdateNoticeState({
    this.checkedAtMillis,
    this.newestVersion,
    this.notifiedVersion,
    this.dismissedVersion,
    this.failedAtMillis,
    this.error,
    this.retryAtMillis,
  });

  static UpdateNoticeState fromJson(Object? json) {
    if (json is! Map) {
      return const UpdateNoticeState();
    }
    int? millis(Object? value) => value is int ? value : null;
    final Object? error = json['error'];
    return UpdateNoticeState(
      checkedAtMillis: millis(json['checkedAt']),
      newestVersion: _version(json['newest']),
      notifiedVersion: _version(json['notified']),
      dismissedVersion: _version(json['dismissed']),
      failedAtMillis: millis(json['failedAt']),
      error: error is String && error.isNotEmpty
          ? updateNoticeErrorText(error)
          : null,
      retryAtMillis: millis(json['retryAt']),
    );
  }

  /// When a check last got an answer (wall time, milliseconds): the last
  /// successful check, whoever made it.
  final int? checkedAtMillis;

  /// The newest release newer than this build that a check found.
  final String? newestVersion;

  /// The version the notification was shown for.
  final String? notifiedVersion;

  /// The version whose banner the person closed.
  final String? dismissedVersion;

  /// When a check last failed (nothing answered, or only with an error),
  /// and what went wrong ([updateNoticeErrorText]); kept after a later
  /// success, for the updates screen.
  final int? failedAtMillis;
  final String? error;

  /// Not before this time (wall time, milliseconds): the wait GitHub asked
  /// for after its rate limit. Cleared by an answer.
  final int? retryAtMillis;

  UpdateNoticeState copyWith({
    int? checkedAtMillis,
    String? newestVersion,
    String? notifiedVersion,
    String? dismissedVersion,
  }) {
    return UpdateNoticeState(
      checkedAtMillis: checkedAtMillis ?? this.checkedAtMillis,
      newestVersion: newestVersion ?? this.newestVersion,
      notifiedVersion: notifiedVersion ?? this.notifiedVersion,
      dismissedVersion: dismissedVersion ?? this.dismissedVersion,
      failedAtMillis: failedAtMillis,
      error: error,
      retryAtMillis: retryAtMillis,
    );
  }

  /// A check got an answer at [at]: [newest] is the release newer than
  /// this build it named (null: none, which forgets an earlier one).
  UpdateNoticeState answered({required int at, String? newest}) {
    return UpdateNoticeState(
      checkedAtMillis: at,
      newestVersion: newest,
      notifiedVersion: notifiedVersion,
      dismissedVersion: dismissedVersion,
      failedAtMillis: failedAtMillis,
      error: error,
    );
  }

  /// A check failed at [at] with [error]; [retryAt]: not again before then
  /// (GitHub's rate limit).
  UpdateNoticeState failed({
    required int at,
    required Object error,
    int? retryAt,
  }) {
    return UpdateNoticeState(
      checkedAtMillis: checkedAtMillis,
      newestVersion: newestVersion,
      notifiedVersion: notifiedVersion,
      dismissedVersion: dismissedVersion,
      failedAtMillis: at,
      error: updateNoticeErrorText(error),
      retryAtMillis: retryAt,
    );
  }

  /// This build is [current]: the versions up to it that were found,
  /// announced or closed are installed, and forgotten.
  UpdateNoticeState installed(String current) {
    bool over(String? version) =>
        version != null && compareAppVersions(version, current) <= 0;
    return UpdateNoticeState(
      checkedAtMillis: checkedAtMillis,
      newestVersion: over(newestVersion) ? null : newestVersion,
      notifiedVersion: over(notifiedVersion) ? null : notifiedVersion,
      dismissedVersion: over(dismissedVersion) ? null : dismissedVersion,
      failedAtMillis: failedAtMillis,
      error: error,
      retryAtMillis: retryAtMillis,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'checkedAt': ?checkedAtMillis,
    'newest': ?newestVersion,
    'notified': ?notifiedVersion,
    'dismissed': ?dismissedVersion,
    'failedAt': ?failedAtMillis,
    'error': ?error,
    'retryAt': ?retryAtMillis,
  };

  @override
  bool operator ==(Object other) =>
      other is UpdateNoticeState &&
      other.checkedAtMillis == checkedAtMillis &&
      other.newestVersion == newestVersion &&
      other.notifiedVersion == notifiedVersion &&
      other.dismissedVersion == dismissedVersion &&
      other.failedAtMillis == failedAtMillis &&
      other.error == error &&
      other.retryAtMillis == retryAtMillis;

  @override
  int get hashCode => Object.hash(
    checkedAtMillis,
    newestVersion,
    notifiedVersion,
    dismissedVersion,
    failedAtMillis,
    error,
    retryAtMillis,
  );

  static String? _version(Object? value) =>
      value is String && isValidAppVersion(value) ? value : null;
}

/// Whether a check is due: none answered yet, or the last answer is
/// [every] old (or from the future: a clock set back).
bool updateCheckDue(
  int? checkedAtMillis, {
  required int nowMillis,
  Duration every = kGithubCheckEvery,
}) {
  if (checkedAtMillis == null) {
    return true;
  }
  final int age = nowMillis - checkedAtMillis;
  return age < 0 || age >= every.inMilliseconds;
}

/// [error] as [UpdateNoticeState.error] keeps it: one line, at most
/// [kUpdateNoticeErrorChars] characters. An error of a request to GitHub or
/// the project's pages: a status, an exception's name and the host.
String updateNoticeErrorText(Object error) {
  final String line = '$error'.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (line.length <= kUpdateNoticeErrorChars) {
    return line;
  }
  final Runes runes = line.runes;
  return '${String.fromCharCodes(runes.take(kUpdateNoticeErrorChars - 1))}…';
}

/// Whether [seen] is [version] or newer.
bool _seenAtLeast(String? seen, String version) =>
    seen != null && compareAppVersions(seen, version) >= 0;

/// Whether [version] is still to be announced: neither it nor a newer one
/// was announced, and its banner was not closed.
bool updateNoticeDue(UpdateNoticeState state, String version) =>
    !_seenAtLeast(state.notifiedVersion, version) &&
    !_seenAtLeast(state.dismissedVersion, version);

/// Where [UpdateNoticeState] is kept; in memory in tests.
abstract interface class UpdateNoticeStore {
  /// What is kept now (empty when nothing is, or it cannot be read).
  Future<UpdateNoticeState> read();

  /// Applies [change] to what is kept right now and keeps the result. Read
  /// again first: the other isolate may have written in the meantime.
  Future<UpdateNoticeState> update(
    UpdateNoticeState Function(UpdateNoticeState state) change,
  );
}

final class MemoryUpdateNoticeStore implements UpdateNoticeStore {
  MemoryUpdateNoticeStore([this.state = const UpdateNoticeState()]);

  UpdateNoticeState state;

  @override
  Future<UpdateNoticeState> read() async => state;

  @override
  Future<UpdateNoticeState> update(
    UpdateNoticeState Function(UpdateNoticeState state) change,
  ) async => state = change(state);
}

/// [UpdateNoticeState] in [kUpdateNoticeFileName]. Never throws: a file
/// that cannot be read is an empty state, a failed write is logged (the
/// worst outcome is one more check, or the notification once more).
final class FileUpdateNoticeStore implements UpdateNoticeStore {
  FileUpdateNoticeStore({Future<Directory> Function()? directory})
    : _directory = directory ?? ZenInstance.instanceDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _writing = Future<void>.value();

  Future<File> _file() async {
    final Directory dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$kUpdateNoticeFileName');
  }

  /// The state kept; nothing kept when the file is missing or cannot be
  /// read. A damaged file is set aside ([setAsideDamagedFile]): read as
  /// nothing kept again and again, it would never be written over while
  /// nothing changed.
  @override
  Future<UpdateNoticeState> read() async {
    final File file;
    final String text;
    try {
      file = await _file();
      if (!await file.exists()) {
        return const UpdateNoticeState();
      }
      text = await file.readAsString();
    } on FormatException catch (error) {
      await setAsideDamagedFile(await _file(), error);
      return const UpdateNoticeState();
    } on Object catch (error) {
      logZenWarning('Reading the update check state failed: $error');
      return const UpdateNoticeState();
    }
    try {
      return UpdateNoticeState.fromJson(jsonDecode(text));
    } on Object catch (error) {
      await setAsideDamagedFile(file, error);
      return const UpdateNoticeState();
    }
  }

  @override
  Future<UpdateNoticeState> update(
    UpdateNoticeState Function(UpdateNoticeState state) change,
  ) {
    final Future<UpdateNoticeState> result = _writing.then((_) async {
      final UpdateNoticeState before = await read();
      final UpdateNoticeState after = change(before);
      if (after != before) {
        await _write(after);
      }
      return after;
    });
    _writing = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _write(UpdateNoticeState state) async {
    try {
      // The other isolate may be reading the file at the same moment and
      // must never see half of it.
      await writeFileAtomically(
        await _file(),
        utf8.encode(jsonEncode(state.toJson())),
      );
    } on Object catch (error) {
      logZenWarning('Saving the update check state failed: $error');
    }
  }
}

/// "Jest nowa wersja Zen": tapping it opens "Aktualizacje i Podaj dalej".
/// Quiet (no sound), and with nothing private in it, so the "no content"
/// setting leaves it as it is. [whatsNew]: the release's note in the app's
/// language (whats_new.dart), a line each under the first one, shown when
/// the notification is expanded.
RuntimeSystemNotification updateAvailableNotification(
  String version, {
  required int createdAtMillis,
  List<String> whatsNew = const <String>[],
}) {
  return RuntimeSystemNotification(
    id: '$kUpdateNoticeSlot-$version',
    slotKey: kUpdateNoticeSlot,
    title: t('Jest nowa wersja Zen'),
    body: <String>[
      t('Wersja {version} — warto zaktualizować', {'version': version}),
      for (final String line in whatsNew) '• $line',
    ].join('\n'),
    createdAtMillis: createdAtMillis,
    category: RuntimeSystemNotificationCategory.update,
    routeKey: buildUpdatesRouteKey(),
    contentRedacted: true,
  );
}

/// Shows [updateAvailableNotification] for [version] (with [whatsNew])
/// once: never again for it or an older one, whichever isolate asks, and
/// not at all when its banner was already closed. A newer version is
/// shown again, in the place of the one before ([kUpdateNoticeSlot]): a
/// notice or a closed banner of 1.13.1 never holds back 1.14.0. Returns
/// whether it was shown now.
Future<bool> announceUpdateOnce({
  required UpdateNoticeStore store,
  required RuntimeSystemNotificationService notices,
  required String version,
  required int nowMillis,
  List<String> whatsNew = const <String>[],
}) async {
  bool due = false;
  await store.update((UpdateNoticeState state) {
    due = updateNoticeDue(state, version);
    // Noted before it is shown: two isolates finding the version at the
    // same moment show it once (and the slot keeps one anyway).
    return due ? state.copyWith(notifiedVersion: version) : state;
  });
  if (!due) {
    return false;
  }
  try {
    return await notices.show(
      updateAvailableNotification(
        version,
        createdAtMillis: nowMillis,
        whatsNew: whatsNew,
      ),
    );
  } on Object catch (error, stackTrace) {
    logZenError('Showing the update notification failed', error, stackTrace);
    return false;
  }
}

/// Takes "Jest nowa wersja Zen" away once its version is installed: the
/// version it named is [currentVersion] or older, so it would offer what
/// the person already has (a phone keeps the notification across an app
/// update). A notice of a version newer than this build stays. Returns
/// whether one was taken away.
Future<bool> withdrawInstalledUpdateNotice({
  required UpdateNoticeStore store,
  required RuntimeSystemNotificationService notices,
  required String currentVersion,
}) async {
  String? announced;
  await store.update((UpdateNoticeState state) {
    announced = state.notifiedVersion;
    return state.installed(currentVersion);
  });
  final String? version = announced;
  if (version == null || compareAppVersions(version, currentVersion) > 0) {
    return false;
  }
  try {
    await notices.dismissSlot(kUpdateNoticeSlot);
    return true;
  } on Object catch (error, stackTrace) {
    logZenError(
      'Taking the update notification away failed',
      error,
      stackTrace,
    );
    return false;
  }
}
