import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The fuzzing of frames from the network (test/signal_fuzz_test.dart) keeps
// up with the parser (lib/src/features/runtime/runtime_signal_parser.dart)
// by itself: every frame type the parser knows and every field it reads
// from a frame must be among what the fuzzer sends. A new kind of frame, a
// new field or a new chat extra (a poll, a location, ...) fails here until
// it is fuzzed too, so nobody has to remember it.

const String _parser = 'lib/src/features/runtime/runtime_signal_parser.dart';
const String _fuzz = 'test/signal_fuzz_test.dart';

/// The entries of the `const List<String> [name] = <String>[...]` in
/// [source]: quoted names, and constants (`kPollKey`) by their name.
Set<String> _listIn(String source, String name) {
  final RegExpMatch? list = RegExp(
    'const List<String> $name = <String>\\[([^\\]]*)\\]',
  ).firstMatch(source);
  expect(list, isNotNull, reason: '$name in $_fuzz');
  return <String>{
    for (final RegExpMatch m in RegExp(
      r"'([^']*)'|\b(k[A-Z]\w*)\b",
    ).allMatches(list!.group(1)!))
      m.group(1) ?? m.group(2)!,
  };
}

void main() {
  final String parser = File(_parser).readAsStringSync();
  final String fuzz = File(_fuzz).readAsStringSync();

  test('every frame type the parser knows is fuzzed', () {
    final Set<String> types = <String>{
      for (final RegExpMatch m in RegExp(
        r"^\s*case '([a-z_]+)':",
        multiLine: true,
      ).allMatches(parser))
        m.group(1)!,
    };
    expect(types, isNotEmpty);
    expect(
      types.difference(_listIn(fuzz, '_types')),
      isEmpty,
      reason: 'add them to _types in $_fuzz',
    );
  });

  test('every field the parser reads from a frame is fuzzed', () {
    final Set<String> fields = <String>{
      for (final RegExpMatch m in RegExp(
        r"payload\[(?:'([^']+)'|(k[A-Z]\w*))\]",
      ).allMatches(parser))
        m.group(1) ?? m.group(2)!,
    };
    expect(fields, containsAll(<String>['msgId', 'kPollKey', 'kLocationKey']));
    expect(
      fields.difference(_listIn(fuzz, '_keys')),
      isEmpty,
      reason: 'add them to _keys in $_fuzz',
    );
  });
}
