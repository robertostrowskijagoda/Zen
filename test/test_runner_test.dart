import 'package:flutter_test/flutter_test.dart';

import '../tool/test.dart' as runner;

void main() {
  final Map<String, int> weights = <String, int>{
    'test/a_test.dart': 100,
    'test/b_test.dart': 60,
    'test/c_test.dart': 50,
    'test/d_test.dart': 40,
    'test/e_test.dart': 30,
    'test/f_test.dart': 10,
  };
  int weight(String file) => weights[file]!;

  test('every file goes to exactly one group, the longest first', () {
    final List<String> files = weights.keys.toList();
    final List<List<String>> groups = runner.split(files, 3, weight);
    expect(groups, hasLength(3));
    expect(groups.expand((List<String> g) => g).toList()..sort(), files);
    for (final List<String> g in groups) {
      final List<int> w = g.map(weight).toList();
      expect(w, orderedEquals(List<int>.of(w)..sort((a, b) => b - a)));
    }
    // About the same work in each group.
    final List<int> loads = <int>[
      for (final List<String> g in groups)
        g.map(weight).fold(0, (a, b) => a + b),
    ];
    expect(loads.reduce((a, b) => a > b ? a : b), lessThanOrEqualTo(100));
  });

  test('the same files always give the same groups', () {
    final List<String> files = weights.keys.toList();
    expect(
      runner.split(files.reversed.toList(), 4, weight),
      runner.split(files, 4, weight),
    );
    // More groups than files: the rest stay empty.
    expect(
      runner.split(files, 8, weight).where((g) => g.isEmpty),
      hasLength(2),
    );
  });
}
