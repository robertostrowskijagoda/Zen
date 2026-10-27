import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

/// How often Zen asks GitHub for its newest release, wherever it asks from
/// (the app, the Android background service): one request in this time at
/// most, whoever made it.
const Duration kGithubCheckEvery = Duration(hours: 12);

/// The notification slot of "Jest nowa wersja Zen": a newer version takes
/// the place of the one before.
const String kUpdateNoticeSlot = 'app-update';

/// The file in the app's data folder (a profile's own folder with
/// `--zen-profile`) that holds [UpdateNoticeState]. A plain file: the
/// Android background service reads and writes it too, also while the app
/// is locked, and nothing in it is private (versions and a time).
const String kUpdateNoticeFileName = 'update_check.json';

/// What the app and the Android background service share about the look
/// at GitHub, so that together they ask at most every [kGithubCheckEvery]
/// and tell the person about a version once.
@immutable
final class UpdateNoticeState {
  const UpdateNoticeState({
    this.checkedAtMillis,
    this.newestVersion,
    this.notifiedVersion,
    this.dismissedVersion,
  });

  static UpdateNoticeState fromJson(Object? json) {
    if (json is! Map) {
      return const UpdateNoticeState();
    }
    final Object? at = json['checkedAt'];
    return UpdateNoticeState(
      checkedAtMillis: at is int ? at : null,
      newestVersion: _version(json['newest']),
      notifiedVersion: _version(json['notified']),
      dismissedVersion: _version(json['dismissed']),
    );
  }

  /// When GitHub last answered a check (wall time, milliseconds).
  final int? checkedAtMillis;

  /// The newest release newer than this build that a check found.
  final String? newestVersion;

  /// The version the notification was shown for.
  final String? notifiedVersion;

  /// The version whose banner the person closed.
  final String? dismissedVersion;

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
    );
  }

  /// GitHub answered at [at]: [newest] is the release newer than this
  /// build it named (null: none, which forgets an earlier one).
  UpdateNoticeState answered({required int at, String? newest}) {
    return UpdateNoticeState(
      checkedAtMillis: at,
      newestVersion: newest,
      notifiedVersion: notifiedVersion,
      dismissedVersion: dismissedVersion,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'checkedAt': ?checkedAtMillis,
    'newest': ?newestVersion,
    'notified': ?notifiedVersion,
    'dismissed': ?dismissedVersion,
  };

  @override
  bool operator ==(Object other) =>
      other is UpdateNoticeState &&
      other.checkedAtMillis == checkedAtMillis &&
      other.newestVersion == newestVersion &&
      other.notifiedVersion == notifiedVersion &&
      other.dismissedVersion == dismissedVersion;

  @override
  int get hashCode => Object.hash(
    checkedAtMillis,
    newestVersion,
    notifiedVersion,
    dismissedVersion,
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

/// Whether [seen] is [version] or newer.
bool _seenAtLeast(String? seen, String version) =>
    seen != null && compareAppVersions(seen, version) >= 0;

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

  @override
  Future<UpdateNoticeState> read() async {
    try {
      final File file = await _file();
      if (!await file.exists()) {
        return const UpdateNoticeState();
      }
      return UpdateNoticeState.fromJson(jsonDecode(await file.readAsString()));
    } on Object catch (error) {
      logZenWarning('Reading the update check state failed: $error');
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
      final File file = await _file();
      await file.parent.create(recursive: true);
      // Through a temporary file and a rename: the other isolate may be
      // reading the file at the same moment and must never see half of it.
      final File temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
      await temporary.rename(file.path);
    } on Object catch (error) {
      logZenWarning('Saving the update check state failed: $error');
    }
  }
}

/// "Jest nowa wersja Zen": tapping it opens "Aktualizacje i Podaj dalej".
/// Quiet (no sound), and with nothing private in it, so the "no content"
/// setting leaves it as it is.
RuntimeSystemNotification updateAvailableNotification(
  String version, {
  required int createdAtMillis,
}) {
  return RuntimeSystemNotification(
    id: '$kUpdateNoticeSlot-$version',
    slotKey: kUpdateNoticeSlot,
    title: t('Jest nowa wersja Zen'),
    body: t('Wersja {version} — warto zaktualizować', {'version': version}),
    createdAtMillis: createdAtMillis,
    category: RuntimeSystemNotificationCategory.update,
    routeKey: buildUpdatesRouteKey(),
    contentRedacted: true,
  );
}

/// Shows [updateAvailableNotification] for [version] once: never again for
/// it or an older one, whichever isolate asks, and not at all when its
/// banner was already closed. Returns whether it was shown now.
Future<bool> announceUpdateOnce({
  required UpdateNoticeStore store,
  required RuntimeSystemNotificationService notices,
  required String version,
  required int nowMillis,
}) async {
  bool due = false;
  await store.update((UpdateNoticeState state) {
    due =
        !_seenAtLeast(state.notifiedVersion, version) &&
        !_seenAtLeast(state.dismissedVersion, version);
    // Noted before it is shown: two isolates finding the version at the
    // same moment show it once (and the slot keeps one anyway).
    return due ? state.copyWith(notifiedVersion: version) : state;
  });
  if (!due) {
    return false;
  }
  try {
    return await notices.show(
      updateAvailableNotification(version, createdAtMillis: nowMillis),
    );
  } on Object catch (error, stackTrace) {
    logZenError('Showing the update notification failed', error, stackTrace);
    return false;
  }
}
