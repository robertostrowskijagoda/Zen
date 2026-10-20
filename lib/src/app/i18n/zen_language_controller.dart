import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// The person's choice ([preference]: a language code, or null for
/// "automatically, like the system") and the language Zen speaks now
/// ([code]).
typedef ZenLanguageState = ({String? preference, String code});

/// Loads the strings of a language (the app: [ZenI18n.load]).
typedef ZenLanguageLoader = Future<void> Function(String code);

/// Where the choice is kept: the plain file next to the app's data. Tests
/// override it with a [MemoryZenLanguageStore], so they never touch the
/// disk.
final Provider<ZenLanguageStore> zenLanguageStoreProvider =
    Provider<ZenLanguageStore>((Ref ref) => const FileZenLanguageStore());

/// How a language gets loaded; tests can replace it.
final Provider<ZenLanguageLoader> zenLanguageLoaderProvider =
    Provider<ZenLanguageLoader>((Ref ref) => ZenI18n.load);

final NotifierProvider<ZenLanguageController, ZenLanguageState>
zenLanguageControllerProvider =
    NotifierProvider<ZenLanguageController, ZenLanguageState>(
      ZenLanguageController.new,
    );

/// The language Zen speaks and the person's choice of it.
///
/// It starts from what `loadZenLanguage()` loaded before the app started
/// (in tests, where nothing is loaded: Polish, automatic). A change is
/// remembered first and then loaded; the app rebuilds every widget when
/// [ZenLanguageState.code] changes.
final class ZenLanguageController extends Notifier<ZenLanguageState> {
  /// Changes run one after another, so a slow load can never land after a
  /// newer choice.
  Future<void> _queue = Future<void>.value();

  /// Number of the newest [choose]; older ones still waiting are skipped.
  int _latestChoice = 0;

  @override
  ZenLanguageState build() {
    return (preference: zenLanguagePreferenceAtStart, code: ZenI18n.code);
  }

  /// The language "automatically" stands for right now: the system's
  /// language when Zen speaks it, otherwise English.
  String get automaticCode => ZenI18n.resolve(null, zenSystemLocales());

  /// Speaks [code] from now on and remembers it; null follows the system.
  /// A code Zen does not speak counts as null.
  Future<void> choose(String? code) {
    final String? preference = ZenI18n.byCode(code)?.code;
    final int choice = ++_latestChoice;
    // The check mark moves at once; the texts follow when loaded.
    state = (preference: preference, code: state.code);
    return _enqueue(() async {
      if (choice != _latestChoice || !ref.mounted) {
        return;
      }
      await ref.read(zenLanguageStoreProvider).write(preference);
      // A newer choice came while saving: it saves and loads its own
      // language right after this, so loading this one is wasted work (and
      // would move the check mark back for a moment).
      if (choice != _latestChoice || !ref.mounted) {
        return;
      }
      await _load(
        ZenI18n.resolve(preference, zenSystemLocales()),
        preference: preference,
      );
    });
  }

  /// The system's languages changed ([locales], default: the current
  /// ones). With no choice of its own, Zen follows them.
  Future<void> followSystem([List<Locale>? locales]) {
    return _enqueue(() async {
      if (!ref.mounted || state.preference != null) {
        return;
      }
      final String code = ZenI18n.resolve(null, locales ?? zenSystemLocales());
      if (code == state.code && code == ZenI18n.code) {
        return;
      }
      await _load(code, preference: null);
    });
  }

  Future<void> _load(String code, {required String? preference}) async {
    await ref.read(zenLanguageLoaderProvider)(code);
    if (!ref.mounted) {
      return;
    }
    state = (preference: preference, code: code);
  }

  Future<void> _enqueue(Future<void> Function() step) {
    final Future<void> next = _queue.then((_) => step()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      logZenError('Changing the language failed', error, stackTrace);
    });
    _queue = next;
    return next;
  }
}
