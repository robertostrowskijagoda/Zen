import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Where tool/go_licenses.dart puts the licenses of the Go modules compiled
/// into the network bridge (native/yggdrasil_bridge).
const String kGoLicensesDir = 'assets/licenses/go';

/// One line of `assets/licenses/go/index.txt`.
@immutable
final class GoLicenseIndexEntry {
  const GoLicenseIndexEntry({
    required this.module,
    required this.version,
    required this.file,
    required this.source,
  });

  /// Module path, e.g. `github.com/yggdrasil-network/yggdrasil-go`.
  final String module;
  final String version;

  /// File name inside [kGoLicensesDir].
  final String file;

  /// Where the module's source code is published.
  final String source;
}

/// Parses the index: `module<TAB>version<TAB>file<TAB>source` per line,
/// `#` starts a comment line.
List<GoLicenseIndexEntry> parseGoLicenseIndex(String index) {
  final List<GoLicenseIndexEntry> entries = <GoLicenseIndexEntry>[];
  for (final String raw in const LineSplitter().convert(index)) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final List<String> parts = line.split('\t');
    if (parts.length < 4) {
      continue;
    }
    entries.add(
      GoLicenseIndexEntry(
        module: parts[0].trim(),
        version: parts[1].trim(),
        file: parts[2].trim(),
        source: parts[3].trim(),
      ),
    );
  }
  return entries;
}

/// Licenses of the native libraries and of the assets that neither the Dart
/// packages nor the Go bridge cover (WebRTC, Android and iOS libraries,
/// Material Icons, Zen's own sounds and images). See THIRD_PARTY_NOTICES.md.
const String kNativeLicensesDir = 'assets/licenses/native';

/// Zen's additional terms under GPL section 7.
const String kNoticePath = 'NOTICE';

/// The name Flutter gives Zen's own entry (the GPL text in LICENSE); NOTICE
/// and the statement on Zen's own assets join it.
const String kZenLicenseEntryName = 'zen';

/// One line of `assets/licenses/native/index.txt`.
@immutable
final class NativeLicenseIndexEntry {
  const NativeLicenseIndexEntry({required this.file, required this.names});

  /// File name inside [kNativeLicensesDir].
  final String file;

  /// Names the "Licencje" page lists the text under.
  final List<String> names;
}

/// Parses the native index: `file<TAB>name[<TAB>name…]` per line, `#`
/// starts a comment line.
List<NativeLicenseIndexEntry> parseNativeLicenseIndex(String index) {
  final List<NativeLicenseIndexEntry> entries = <NativeLicenseIndexEntry>[];
  for (final String raw in const LineSplitter().convert(index)) {
    final String line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) {
      continue;
    }
    final List<String> parts = line
        .split('\t')
        .map((String part) => part.trim())
        .where((String part) => part.isNotEmpty)
        .toList();
    if (parts.length < 2) {
      continue;
    }
    entries.add(
      NativeLicenseIndexEntry(file: parts.first, names: parts.sublist(1)),
    );
  }
  return entries;
}

bool _goLicensesRegistered = false;

/// Adds the licenses Flutter does not list by itself (it lists only the Dart
/// packages) to the "Licencje" page: NOTICE, the Go bridge's modules, the
/// native libraries and assets, and the fonts. The texts load only when the
/// page opens.
void registerGoLicenses({AssetBundle? bundle}) {
  if (_goLicensesRegistered) {
    return;
  }
  _goLicensesRegistered = true;
  final AssetBundle assets = bundle ?? rootBundle;
  LicenseRegistry.addLicense(() => goLicenseEntries(assets));
}

/// The bundled fonts (assets/fonts), all under the SIL Open Font License.
const String kFontLicensePath = 'assets/licenses/fonts/OFL.txt';

/// NOTICE, one license entry per Go module listed in the index, the native
/// libraries and assets, then the fonts.
Stream<LicenseEntry> goLicenseEntries(AssetBundle assets) async* {
  final String? notice = await _load(assets, kNoticePath);
  if (notice != null) {
    yield LicenseEntryWithLineBreaks(const <String>[
      kZenLicenseEntryName,
    ], notice);
  }
  yield* _goModuleEntries(assets);
  yield* _nativeEntries(assets);
  final String? fonts = await _load(assets, kFontLicensePath);
  if (fonts != null) {
    yield LicenseEntryWithLineBreaks(const <String>[
      'Fredoka',
      'Hanken Grotesk',
      'JetBrains Mono',
      'Space Mono',
      'DM Sans',
    ], fonts);
  }
}

Stream<LicenseEntry> _goModuleEntries(AssetBundle assets) async* {
  final String? index = await _load(assets, '$kGoLicensesDir/index.txt');
  if (index == null) {
    return;
  }
  for (final GoLicenseIndexEntry entry in parseGoLicenseIndex(index)) {
    final String? text = await _load(assets, '$kGoLicensesDir/${entry.file}');
    if (text == null) {
      continue;
    }
    final String sourceLine = t('Kod źródłowy: {source}', <String, Object?>{
      'source': entry.source,
    });
    yield LicenseEntryWithLineBreaks(
      <String>[entry.module],
      '${entry.module} ${entry.version}\n\n'
      '$sourceLine\n\n'
      '$text',
    );
  }
}

Stream<LicenseEntry> _nativeEntries(AssetBundle assets) async* {
  final String? index = await _load(assets, '$kNativeLicensesDir/index.txt');
  if (index == null) {
    return;
  }
  for (final NativeLicenseIndexEntry entry in parseNativeLicenseIndex(index)) {
    final String? text = await _load(
      assets,
      '$kNativeLicensesDir/${entry.file}',
    );
    if (text != null) {
      yield LicenseEntryWithLineBreaks(entry.names, text);
    }
  }
}

Future<String?> _load(AssetBundle assets, String key) async {
  try {
    return await assets.loadString(key);
  } on Object catch (error) {
    logZenWarning('Licenses: $key not loaded: $error');
    return null;
  }
}
