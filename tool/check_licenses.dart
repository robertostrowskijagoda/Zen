// Checks the licence of every Dart package the app is built with, after
// `flutter pub get`:
//
//   dart run tool/check_licenses.dart
//
// Prints one line per package (licence found in its LICENSE file) and exits
// with 1 when a licence is unknown or may not fit GPL-3.0 (GPL-2.0, which
// fits only as "or later", CDDL, SSPL, BUSL, non-commercial terms). Dev
// dependencies are left out when
// .dart_tool/package_graph.json says which they are. Packages of the Flutter
// SDK are listed as such (BSD-3-Clause; Flutter reviews the engine's
// third-party code). See THIRD_PARTY_NOTICES.md.
import 'dart:convert';
import 'dart:io';

/// Licences checked by hand, for packages whose LICENSE file the patterns
/// below do not recognise: package name -> SPDX identifier.
const Map<String, String> _reviewed = <String, String>{};

const Set<String> _problems = <String>{
  'GPL-2.0',
  'CDDL',
  'SSPL',
  'BUSL',
  'non-commercial',
};

final List<(String, bool Function(String))> _detectors =
    <(String, bool Function(String))>[
      ('AGPL-3.0', (String t) => t.contains('GNU AFFERO GENERAL PUBLIC')),
      ('LGPL', (String t) => t.contains('GNU LESSER GENERAL PUBLIC LICENSE')),
      // Whether it is "only" or "or later" is in the source headers.
      (
        'GPL-2.0',
        (String t) =>
            t.contains('GNU GENERAL PUBLIC LICENSE') &&
            t.contains('Version 2, June 1991') &&
            !t.contains('CLASSPATH'),
      ),
      (
        'GPL',
        (String t) =>
            t.contains('GNU GENERAL PUBLIC LICENSE') &&
            !t.contains('GNU LESSER GENERAL PUBLIC LICENSE'),
      ),
      ('MPL-2.0', (String t) => t.contains('Mozilla Public License')),
      (
        'Apache-2.0',
        (String t) => t.contains('Apache License') && t.contains('Version 2.0'),
      ),
      (
        'MIT',
        (String t) =>
            t.contains('Permission is hereby granted, free of charge'),
      ),
      (
        'ISC',
        (String t) =>
            t.contains('Permission to use, copy, modify, and/or distribute') ||
            t.contains(
              'Permission to use, copy, modify, and distribute this '
              'software for any',
            ),
      ),
      (
        'BSD-3-Clause',
        (String t) =>
            t.contains('Redistribution and use in source and binary forms') &&
            (t.contains('Neither the name') ||
                t.contains('names of its contributors') ||
                t.contains('name of the copyright holder')),
      ),
      (
        'BSD-2-Clause',
        (String t) =>
            t.contains('Redistribution and use in source and binary forms'),
      ),
      ('Zlib', (String t) => t.contains("provided 'as-is'")),
      ('Unlicense', (String t) => t.contains('unlicense.org')),
      ('CDDL', (String t) => t.contains('COMMON DEVELOPMENT AND DISTRIBUTION')),
      ('SSPL', (String t) => t.contains('Server Side Public License')),
      ('BUSL', (String t) => t.contains('Business Source License')),
      (
        'non-commercial',
        (String t) =>
            !t.contains('GNU ') &&
            RegExp(r'non-?commercial', caseSensitive: false).hasMatch(t),
      ),
    ];

final RegExp _licenseFileName = RegExp(
  r'^(licen[cs]e|copying)',
  caseSensitive: false,
);

void main() {
  final File configFile = File('.dart_tool/package_config.json');
  if (!configFile.existsSync()) {
    stderr.writeln('Brak .dart_tool/package_config.json: flutter pub get.');
    exitCode = 1;
    return;
  }
  final Map<String, dynamic> config =
      jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final Map<String, Directory> roots = <String, Directory>{};
  for (final Object? raw in config['packages'] as List<Object?>) {
    final Map<String, dynamic> package = raw! as Map<String, dynamic>;
    final Uri root = configFile.absolute.uri.resolve(
      package['rootUri'] as String,
    );
    roots[package['name'] as String] = Directory.fromUri(root);
  }
  final String? appName = _appName();
  final Set<String>? shipped = _shippedPackages(appName);
  final String? flutterRoot = _flutterRoot(roots['flutter']);

  int bad = 0;
  final List<String> names = roots.keys.toList()..sort();
  for (final String name in names) {
    if (name == appName || (shipped != null && !shipped.contains(name))) {
      continue;
    }
    final Directory directory = roots[name]!;
    if (flutterRoot != null &&
        directory.absolute.path.startsWith(
          '$flutterRoot${Platform.pathSeparator}',
        )) {
      stdout.writeln('$name\tFlutter SDK (BSD-3-Clause)');
      continue;
    }
    final String? reviewed = _reviewed[name];
    if (reviewed != null) {
      stdout.writeln('$name\t$reviewed (reviewed)');
      continue;
    }
    final String? text = _licenseText(directory);
    final List<String> found = text == null
        ? const <String>[]
        : _identify(text);
    String status = 'ok';
    if (found.isEmpty) {
      status = 'UNKNOWN - check by hand, then add it to _reviewed';
      bad++;
    } else if (found.any(_problems.contains)) {
      status = 'PROBLEM - may not fit GPL-3.0, check by hand';
      bad++;
    }
    final String licences = found.isEmpty ? '?' : found.join(' + ');
    stdout.writeln('$name\t$licences\t$status');
  }
  if (bad > 0) {
    stderr.writeln('$bad pakiet(y) do sprawdzenia.');
    exitCode = 1;
  }
}

/// Licence identifiers found in [text]; the more general GPL and BSD-2
/// matches are dropped when a more specific one is there.
List<String> _identify(String text) {
  final String t = text.replaceAll('\r\n', '\n');
  final List<String> found = <String>[
    for (final (String, bool Function(String)) detector in _detectors)
      if (detector.$2(t)) detector.$1,
  ];
  if (found.contains('GPL-2.0') || found.contains('AGPL-3.0')) {
    found.remove('GPL');
  }
  if (found.contains('BSD-3-Clause')) {
    found.remove('BSD-2-Clause');
  }
  return found;
}

String? _licenseText(Directory directory) {
  if (!directory.existsSync()) {
    return null;
  }
  final List<File> files =
      directory
          .listSync()
          .whereType<File>()
          .where((File f) => _licenseFileName.hasMatch(f.uri.pathSegments.last))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    return null;
  }
  return files.map((File f) => f.readAsStringSync()).join('\n\n');
}

String? _appName() {
  final RegExpMatch? match = RegExp(
    r'^name:\s*(\S+)',
    multiLine: true,
  ).firstMatch(File('pubspec.yaml').readAsStringSync());
  return match?.group(1);
}

/// The packages the app depends on, without dev dependencies, from
/// .dart_tool/package_graph.json; `null` when there is no such file.
Set<String>? _shippedPackages(String? appName) {
  final File graphFile = File('.dart_tool/package_graph.json');
  if (appName == null || !graphFile.existsSync()) {
    return null;
  }
  final Map<String, dynamic> graph =
      jsonDecode(graphFile.readAsStringSync()) as Map<String, dynamic>;
  final Map<String, List<String>> dependencies = <String, List<String>>{};
  for (final Object? raw in graph['packages'] as List<Object?>) {
    final Map<String, dynamic> package = raw! as Map<String, dynamic>;
    final List<Object?> direct =
        package['dependencies'] as List<Object?>? ?? const <Object?>[];
    dependencies[package['name'] as String] = <String>[
      for (final Object? name in direct) name! as String,
    ];
  }
  final Set<String> seen = <String>{};
  final List<String> queue = <String>[...?dependencies[appName]];
  while (queue.isNotEmpty) {
    final String name = queue.removeLast();
    if (seen.add(name)) {
      queue.addAll(dependencies[name] ?? const <String>[]);
    }
  }
  return seen;
}

/// The Flutter SDK's root (two levels above packages/flutter).
String? _flutterRoot(Directory? flutterPackage) {
  if (flutterPackage == null) {
    return null;
  }
  return flutterPackage.absolute.parent.parent.path;
}
