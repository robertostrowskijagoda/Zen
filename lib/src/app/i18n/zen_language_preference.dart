import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/format_version.dart';

/// The file in the app's support folder (a profile's own folder with
/// `--zen-profile`) that holds the language the person chose: one code
/// ("de"), or no file at all for "automatically, like the system".
///
/// A plain file on purpose: the language is needed before the app is
/// unlocked (the lock screen speaks it too) and in the Android background
/// service, so it cannot live in the encrypted settings.
const String kZenLanguagePreferenceFileName = 'language.txt';

/// The language the person chose (a code from [kZenLanguages]), or null for
/// automatic. Never throws: a missing or unreadable file means automatic.
///
/// [supportDirectory] replaces the app's support folder (tests).
Future<String?> readZenLanguagePreference({Directory? supportDirectory}) async {
  try {
    final File file = await _preferenceFile(supportDirectory);
    if (!await file.exists()) {
      return null;
    }
    final String code;
    try {
      code = (await file.readAsString()).trim().toLowerCase();
    } on FormatException catch (error) {
      // Not text: set aside, automatic from now on.
      await setAsideDamagedFile(file, error);
      return null;
    }
    // A language Zen no longer speaks falls back to automatic.
    return ZenI18n.byCode(code)?.code;
  } on Object catch (error) {
    logZenWarning('Reading the language preference failed: $error');
    return null;
  }
}

/// Remembers [code] as the person's language; null (or a code Zen does not
/// speak) goes back to automatic. Never throws: a failed write is logged and
/// the app simply asks again next time.
///
/// [supportDirectory] replaces the app's support folder (tests).
Future<void> writeZenLanguagePreference(
  String? code, {
  Directory? supportDirectory,
}) async {
  try {
    final File file = await _preferenceFile(supportDirectory);
    final String? known = ZenI18n.byCode(code)?.code;
    if (known == null) {
      if (await file.exists()) {
        await file.delete();
      }
      return;
    }
    await file.parent.create(recursive: true);
    // Through a temporary file and a rename: the background service may be
    // reading the file at the same moment and must never see half of it.
    final File temporary = File('${file.path}.tmp');
    await temporary.writeAsString(known, flush: true);
    await temporary.rename(file.path);
  } on Object catch (error) {
    logZenWarning('Saving the language preference failed: $error');
  }
}

/// The preference [loadZenLanguage] found (null: automatic, or not loaded).
/// The language controller starts from it, so the settings screen shows the
/// choice the app started with.
String? get zenLanguagePreferenceAtStart => _preferenceAtStart;
String? _preferenceAtStart;

/// Reads the person's choice, resolves it against the system's languages
/// and loads that language's strings ([ZenI18n.load]). Call it once per
/// isolate after `WidgetsFlutterBinding.ensureInitialized()` and before
/// anything shows text: in `main` before `runApp`, and in the Android
/// background service's entry point (its notifications speak the language
/// too). Never throws: whatever fails leaves a working language (in the
/// worst case the Polish text from the code).
///
/// Under `flutter test` it does nothing: tests speak Polish, the text in
/// the code (see [loadZenLanguageWith] to test the loading itself).
Future<void> loadZenLanguage() async {
  if (_runningUnderFlutterTest()) {
    return;
  }
  await loadZenLanguageWith();
}

/// [loadZenLanguage] with its inputs replaceable (tests): [readPreference]
/// (default: [readZenLanguagePreference]), [systemLocales] (default:
/// [zenSystemLocales]) and the asset [bundle] (default: the app's).
@visibleForTesting
Future<void> loadZenLanguageWith({
  Future<String?> Function()? readPreference,
  List<Locale>? systemLocales,
  AssetBundle? bundle,
}) async {
  try {
    final String? preference = readPreference != null
        ? await readPreference()
        : await readZenLanguagePreference();
    _preferenceAtStart = ZenI18n.byCode(preference)?.code;
    final String code = ZenI18n.resolve(
      _preferenceAtStart,
      systemLocales ?? zenSystemLocales(),
    );
    await ZenI18n.load(code, bundle: bundle);
  } on Object catch (error, stackTrace) {
    logZenError('Loading the language failed', error, stackTrace);
  }
}

/// The system's preferred languages, most preferred first. On Android 13+
/// this is the language picked for Zen in the system settings, when there
/// is one. An engine that was not told the system's languages (a headless
/// one) falls back to the process's locale.
List<Locale> zenSystemLocales() {
  List<Locale> locales = const <Locale>[];
  try {
    // The binding's dispatcher: tests can set its locales.
    locales = ServicesBinding.instance.platformDispatcher.locales;
  } on Object {
    try {
      locales = PlatformDispatcher.instance.locales;
    } on Object {
      locales = const <Locale>[];
    }
  }
  if (locales.isNotEmpty) {
    return locales;
  }
  try {
    // "pl_PL", "pl-PL", "pl_PL.UTF-8", "C".
    final String language = Platform.localeName
        .split(RegExp('[-_.@]'))
        .first
        .toLowerCase();
    if (RegExp(r'^[a-z]{2,3}$').hasMatch(language)) {
      return <Locale>[Locale(language)];
    }
  } on Object {
    // No locale at all: [ZenI18n.resolve] picks English.
  }
  return const <Locale>[];
}

/// Where the person's choice lives.
abstract interface class ZenLanguageStore {
  /// The chosen language code, or null for automatic.
  Future<String?> read();

  /// Remembers [code]; null means automatic.
  Future<void> write(String? code);
}

/// [ZenLanguageStore] in [kZenLanguagePreferenceFileName] (the app).
final class FileZenLanguageStore implements ZenLanguageStore {
  const FileZenLanguageStore({this.supportDirectory});

  /// Replaces the app's support folder (tests); null: the app's.
  final Directory? supportDirectory;

  @override
  Future<String?> read() =>
      readZenLanguagePreference(supportDirectory: supportDirectory);

  @override
  Future<void> write(String? code) =>
      writeZenLanguagePreference(code, supportDirectory: supportDirectory);
}

/// [ZenLanguageStore] in memory (tests, previews).
final class MemoryZenLanguageStore implements ZenLanguageStore {
  MemoryZenLanguageStore([this.code]);

  /// What was written last.
  String? code;

  /// How many times [write] ran.
  int writes = 0;

  @override
  Future<String?> read() async => code;

  @override
  Future<void> write(String? code) async {
    this.code = code;
    writes += 1;
  }
}

Future<File> _preferenceFile(Directory? supportDirectory) async {
  final Directory directory =
      supportDirectory ?? await ZenInstance.supportDirectory();
  return File(
    '${directory.path}${Platform.pathSeparator}'
    '$kZenLanguagePreferenceFileName',
  );
}

bool _runningUnderFlutterTest() {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } on Object {
    return false;
  }
}
