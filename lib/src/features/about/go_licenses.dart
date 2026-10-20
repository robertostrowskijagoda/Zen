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

bool _goLicensesRegistered = false;

/// Adds the Go bridge's licenses (and the fonts') to the "Licencje" page.
/// Flutter lists only the Dart packages by itself. The texts load only when
/// the page opens.
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

/// One license entry per module listed in the index, then the fonts.
Stream<LicenseEntry> goLicenseEntries(AssetBundle assets) async* {
  yield* _goModuleEntries(assets);
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

Future<String?> _load(AssetBundle assets, String key) async {
  try {
    return await assets.loadString(key);
  } on Object catch (error) {
    logZenWarning('Licencje: nie wczytałem $key: $error');
    return null;
  }
}
