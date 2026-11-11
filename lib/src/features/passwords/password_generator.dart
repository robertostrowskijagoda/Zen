import 'dart:math';

import 'package:flutter/foundation.dart';

/// Shortest password the generator makes.
const int kMinGeneratedPasswordLength = 8;

/// Longest password the generator makes.
const int kMaxGeneratedPasswordLength = 64;

const String _lower = 'abcdefghijklmnopqrstuvwxyz';
const String _upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const String _digits = '0123456789';

/// Symbols most sites accept (no space, quotes or backslash, which forms
/// and shells treat specially).
const String _symbols = r'!#$%&*+-=?@^_~()[]{}.,:;';

/// Characters easy to mistake for another when read or typed by hand.
const String _lookAlike = 'Il1O0o|';

/// What the generator makes.
@immutable
final class PasswordGeneratorOptions {
  const PasswordGeneratorOptions({
    this.length = 20,
    this.lower = true,
    this.upper = true,
    this.digits = true,
    this.symbols = true,
    this.avoidLookAlike = false,
  });

  /// [kMinGeneratedPasswordLength] to [kMaxGeneratedPasswordLength].
  final int length;
  final bool lower;
  final bool upper;
  final bool digits;
  final bool symbols;

  /// Leaves out `I l 1 O 0 o |`.
  final bool avoidLookAlike;

  PasswordGeneratorOptions copyWith({
    int? length,
    bool? lower,
    bool? upper,
    bool? digits,
    bool? symbols,
    bool? avoidLookAlike,
  }) => PasswordGeneratorOptions(
    length: length ?? this.length,
    lower: lower ?? this.lower,
    upper: upper ?? this.upper,
    digits: digits ?? this.digits,
    symbols: symbols ?? this.symbols,
    avoidLookAlike: avoidLookAlike ?? this.avoidLookAlike,
  );

  /// The chosen classes of characters (look-alikes left out if asked).
  List<String> get classes => <String>[
    if (lower) _lower,
    if (upper) _upper,
    if (digits) _digits,
    if (symbols) _symbols,
  ].map(_withoutLookAlike).where((String c) => c.isNotEmpty).toList();

  String _withoutLookAlike(String chars) => avoidLookAlike
      ? chars.split('').where((String c) => !_lookAlike.contains(c)).join()
      : chars;

  /// Whether a password can be made with these options.
  bool get valid =>
      length >= kMinGeneratedPasswordLength &&
      length <= kMaxGeneratedPasswordLength &&
      classes.isNotEmpty &&
      classes.length <= length;

  /// The strength of what it makes, in bits: every password of [length]
  /// characters from the chosen classes (with one of each) is as likely as
  /// any other, so this is exact up to the small share of passwords that
  /// miss a class.
  double get entropyBits {
    if (!valid) {
      return 0;
    }
    final int pool = classes.fold(0, (int sum, String c) => sum + c.length);
    return length * log(pool) / ln2;
  }

  @override
  bool operator ==(Object other) =>
      other is PasswordGeneratorOptions &&
      other.length == length &&
      other.lower == lower &&
      other.upper == upper &&
      other.digits == digits &&
      other.symbols == symbols &&
      other.avoidLookAlike == avoidLookAlike;

  @override
  int get hashCode =>
      Object.hash(length, lower, upper, digits, symbols, avoidLookAlike);
}

/// A new password made with [options] from [random] (by default the
/// system's cryptographic generator, [Random.secure]).
///
/// Each character is drawn uniformly from all the chosen characters with
/// [Random.nextInt], which is uniform over its range (no `% n` of a random
/// byte, which would favour the first characters); a draw that misses one
/// of the chosen classes is thrown away whole and drawn again, so every
/// password with at least one character of each class is equally likely.
/// Throws [ArgumentError] for options that cannot make one.
String generatePassword([
  PasswordGeneratorOptions options = const PasswordGeneratorOptions(),
  Random? random,
]) {
  if (!options.valid) {
    throw ArgumentError.value(options.length, 'options', 'cannot make one');
  }
  final Random r = random ?? Random.secure();
  final List<String> classes = options.classes;
  final String all = classes.join();
  for (int attempt = 0; attempt < 10000; attempt++) {
    final List<String> chars = List<String>.generate(
      options.length,
      (_) => all[r.nextInt(all.length)],
    );
    if (classes.every((String c) => chars.any(c.contains))) {
      return chars.join();
    }
  }
  // Practically never reached (each try fits far more often than not):
  // one of each class at random places, the rest from all, shuffled.
  final List<String> chars = <String>[
    for (final String c in classes) c[r.nextInt(c.length)],
    for (int i = classes.length; i < options.length; i++)
      all[r.nextInt(all.length)],
  ];
  for (int i = chars.length - 1; i > 0; i--) {
    final int j = r.nextInt(i + 1);
    final String t = chars[i];
    chars[i] = chars[j];
    chars[j] = t;
  }
  return chars.join();
}

/// How strong a password looks, for a bar on the screen.
enum PasswordStrengthLevel { veryWeak, weak, fair, strong, veryStrong }

/// What weakens a password.
enum PasswordWeakness {
  /// Shorter than 8 characters.
  short,

  /// One of the most common passwords.
  common,

  /// Letters or digits only of one kind.
  oneKind,

  /// Repeats (`aaaa`), runs (`abcd`, `4321`) or keyboard rows (`qwerty`).
  pattern,
}

/// An estimate of a password's strength.
@immutable
final class PasswordStrength {
  const PasswordStrength(this.bits, this.level, this.weaknesses);

  /// Guesses it would take, as a power of two (an estimate).
  final double bits;
  final PasswordStrengthLevel level;
  final Set<PasswordWeakness> weaknesses;

  @override
  String toString() => 'PasswordStrength(${level.name})';
}

/// The most common passwords (worldwide and in Poland), lower case.
const Set<String> _common = <String>{
  '123456',
  '123456789',
  '12345678',
  '12345',
  '1234567',
  '1234567890',
  '111111',
  '000000',
  '123123',
  '654321',
  '666666',
  '121212',
  '112233',
  'password',
  'password1',
  'passw0rd',
  'qwerty',
  'qwerty1',
  'qwerty123',
  'qwertyuiop',
  'abc123',
  'abcd1234',
  'admin',
  'admin123',
  'letmein',
  'welcome',
  'monkey',
  'dragon',
  'iloveyou',
  'football',
  'baseball',
  'superman',
  'master',
  'sunshine',
  'princess',
  'shadow',
  'trustno1',
  '1q2w3e4r',
  '1q2w3e',
  'zaq12wsx',
  'zaq1@wsx',
  'asdfgh',
  'asdf1234',
  'polska',
  'polska1',
  'haslo',
  'haslo1',
  'haslo123',
  'kochanie',
  'misiek',
  'marcin',
  'agnieszka',
  'mateusz',
  'bartek',
  'zxcvbnm',
  'starwars',
};

const List<String> _rows = <String>[
  'qwertyuiop',
  'asdfghjkl',
  'zxcvbnm',
  '1234567890',
  'qwertzuiop',
  'azertyuiop',
];

/// Whether [b] follows [a] in a run or a keyboard row (either way).
bool _follows(String a, String b) {
  final int x = a.codeUnitAt(0);
  final int y = b.codeUnitAt(0);
  final bool alnum =
      RegExp(r'[a-z0-9]').hasMatch(a) && RegExp(r'[a-z0-9]').hasMatch(b);
  if (alnum && (y - x).abs() == 1) {
    return true;
  }
  for (final String row in _rows) {
    final int i = row.indexOf(a);
    final int j = row.indexOf(b);
    if (i >= 0 && j >= 0 && (i - j).abs() == 1) {
      return true;
    }
  }
  return false;
}

/// An estimate of how hard [password] is to guess: the characters' variety
/// times its length, where repeats, runs and keyboard rows count for a
/// quarter of a character and a common password for almost nothing. It is
/// a hint for the person, not a guarantee (a phrase from a book looks
/// strong here and is not).
PasswordStrength estimatePasswordStrength(String password) {
  final Set<PasswordWeakness> weak = <PasswordWeakness>{};
  if (password.isEmpty) {
    return PasswordStrength(
      0,
      PasswordStrengthLevel.veryWeak,
      <PasswordWeakness>{PasswordWeakness.short},
    );
  }
  final List<String> chars = password.runes.map(String.fromCharCode).toList();
  bool lower = false;
  bool upper = false;
  bool digit = false;
  bool symbol = false;
  bool other = false;
  for (final String c in chars) {
    if (_lower.contains(c)) {
      lower = true;
    } else if (_upper.contains(c)) {
      upper = true;
    } else if (_digits.contains(c)) {
      digit = true;
    } else if (c.codeUnitAt(0) < 128) {
      symbol = true;
    } else {
      other = true;
    }
  }
  final int pool =
      (lower ? 26 : 0) +
      (upper ? 26 : 0) +
      (digit ? 10 : 0) +
      (symbol ? 33 : 0) +
      (other ? 100 : 0);
  if (<bool>[lower, upper, digit, symbol, other].where((bool b) => b).length ==
      1) {
    weak.add(PasswordWeakness.oneKind);
  }
  double effective = 0;
  final String folded = password.toLowerCase();
  final List<String> low = folded.runes.map(String.fromCharCode).toList();
  for (int i = 0; i < low.length; i++) {
    final bool patterned =
        i > 0 && (low[i] == low[i - 1] || _follows(low[i - 1], low[i]));
    if (patterned) {
      weak.add(PasswordWeakness.pattern);
    }
    effective += patterned ? 0.25 : 1;
  }
  double bits = effective * log(pool) / ln2;
  if (_common.contains(folded) ||
      _common.contains(folded.replaceAll(RegExp(r'[0-9!@#$%^&*.]+$'), ''))) {
    weak.add(PasswordWeakness.common);
    bits = min(bits, 10);
  }
  if (chars.length < 8) {
    weak.add(PasswordWeakness.short);
  }
  PasswordStrengthLevel level;
  if (bits < 28) {
    level = PasswordStrengthLevel.veryWeak;
  } else if (bits < 36) {
    level = PasswordStrengthLevel.weak;
  } else if (bits < 60) {
    level = PasswordStrengthLevel.fair;
  } else if (bits < 80) {
    level = PasswordStrengthLevel.strong;
  } else {
    level = PasswordStrengthLevel.veryStrong;
  }
  if (weak.contains(PasswordWeakness.short) &&
      level.index > PasswordStrengthLevel.weak.index) {
    level = PasswordStrengthLevel.weak;
  }
  return PasswordStrength(bits, level, weak);
}
