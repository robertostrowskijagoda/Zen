import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/passwords/password_generator.dart';

// The password generator: uniform characters from the chosen classes, at
// least one of each, nothing outside them; and the strength hint.

/// A generator that counts how often [nextInt] is asked and for what.
final class _CountingRandom implements Random {
  _CountingRandom(this._inner);

  final Random _inner;
  final Set<int> ranges = <int>{};

  @override
  int nextInt(int max) {
    ranges.add(max);
    return _inner.nextInt(max);
  }

  @override
  bool nextBool() => _inner.nextBool();

  @override
  double nextDouble() => _inner.nextDouble();
}

void main() {
  test('lengths and classes: one of each chosen class, nothing else', () {
    final Random random = Random(7);
    for (
      int length = kMinGeneratedPasswordLength;
      length <= kMaxGeneratedPasswordLength;
      length++
    ) {
      final String p = generatePassword(
        PasswordGeneratorOptions(length: length),
        random,
      );
      expect(p.length, length);
      expect(p, matches(RegExp('[a-z]')));
      expect(p, matches(RegExp('[A-Z]')));
      expect(p, matches(RegExp('[0-9]')));
      expect(p, matches(RegExp(r'[^a-zA-Z0-9]')));
      expect(p, isNot(matches(RegExp(r'''[\s'"\\`]'''))));
    }
    for (int i = 0; i < 200; i++) {
      final String digits = generatePassword(
        const PasswordGeneratorOptions(
          length: 8,
          lower: false,
          upper: false,
          symbols: false,
        ),
        random,
      );
      expect(digits, matches(RegExp(r'^[0-9]{8}$')));
      final String noLookAlike = generatePassword(
        const PasswordGeneratorOptions(length: 64, avoidLookAlike: true),
        random,
      );
      expect(noLookAlike, isNot(matches(RegExp('[Il1O0o|]'))));
    }
  });

  test('options that cannot make a password are refused', () {
    expect(
      () => generatePassword(const PasswordGeneratorOptions(length: 7)),
      throwsArgumentError,
    );
    expect(
      () => generatePassword(const PasswordGeneratorOptions(length: 65)),
      throwsArgumentError,
    );
    expect(
      () => generatePassword(
        const PasswordGeneratorOptions(
          lower: false,
          upper: false,
          digits: false,
          symbols: false,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('characters are drawn over the whole alphabet at once (no modulo of '
      'a byte) and come out evenly', () {
    final _CountingRandom random = _CountingRandom(Random(11));
    const PasswordGeneratorOptions options = PasswordGeneratorOptions(
      length: 64,
    );
    final int pool = options.classes.join().length;
    final Map<String, int> counts = <String, int>{};
    for (int i = 0; i < 2000; i++) {
      for (final String c in generatePassword(options, random).split('')) {
        counts[c] = (counts[c] ?? 0) + 1;
      }
    }
    expect(random.ranges, <int>{pool});
    expect(counts.length, pool);
    final double mean = 2000 * 64 / pool;
    for (final int n in counts.values) {
      // Well within chance (about ±4 standard deviations).
      expect(n, inInclusiveRange(mean * 0.85, mean * 1.15));
    }
  });

  test('the secure generator is the default', () {
    final Set<String> seen = <String>{
      for (int i = 0; i < 50; i++) generatePassword(),
    };
    expect(seen, hasLength(50));
    const PasswordGeneratorOptions options = PasswordGeneratorOptions(
      length: 20,
    );
    expect(
      options.entropyBits,
      closeTo(20 * log(options.classes.join().length) / ln2, 0.01),
    );
    expect(options.entropyBits, greaterThan(120));
  });

  test('strength: common, short and patterned passwords are weak, long '
      'random ones strong', () {
    PasswordStrengthLevel level(String p) => estimatePasswordStrength(p).level;
    expect(level(''), PasswordStrengthLevel.veryWeak);
    expect(level('123456'), PasswordStrengthLevel.veryWeak);
    expect(level('password'), PasswordStrengthLevel.veryWeak);
    expect(level('Haslo123'), PasswordStrengthLevel.veryWeak);
    expect(level('qwertyuiop'), PasswordStrengthLevel.veryWeak);
    expect(level('aaaaaaaaaaaa'), PasswordStrengthLevel.veryWeak);
    expect(level('Ab1!xY'), PasswordStrengthLevel.weak);
    expect(
      estimatePasswordStrength('Ab1!xY').weaknesses,
      contains(PasswordWeakness.short),
    );
    expect(
      estimatePasswordStrength('abcdefgh').weaknesses,
      containsAll(<PasswordWeakness>[
        PasswordWeakness.pattern,
        PasswordWeakness.oneKind,
      ]),
    );
    expect(
      level(generatePassword(const PasswordGeneratorOptions(length: 16))),
      anyOf(PasswordStrengthLevel.strong, PasswordStrengthLevel.veryStrong),
    );
    expect(
      level(generatePassword(const PasswordGeneratorOptions(length: 32))),
      PasswordStrengthLevel.veryStrong,
    );
    expect(
      estimatePasswordStrength('sekret-123').toString(),
      isNot(contains('sekret')),
    );
  });
}
