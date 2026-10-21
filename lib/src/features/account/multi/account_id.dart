import 'dart:math';

/// Crockford's base32 alphabet: no I, L, O or U, nothing to confuse when
/// an ID is read off a screen and typed again.
const String kAccountIdAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// Characters of an account ID: 16 × 5 bits = 80 random bits, far too
/// many to guess an account into existence.
const int kAccountIdLength = 16;

/// A new random account ID (normalized: [kAccountIdLength] characters of
/// [kAccountIdAlphabet]).
String newAccountId([Random? random]) {
  final Random r = random ?? Random.secure();
  return List<String>.generate(
    kAccountIdLength,
    (_) => kAccountIdAlphabet[r.nextInt(kAccountIdAlphabet.length)],
  ).join();
}

/// [typed] as an account ID: upper case, without spaces and dashes, with
/// O read as 0, I and L as 1 and U as V; `null` when it is not an ID.
String? normalizeAccountId(String typed) {
  final StringBuffer out = StringBuffer();
  for (final int rune in typed.toUpperCase().runes) {
    String c = String.fromCharCode(rune);
    if (c == ' ' || c == '-' || c == ' ' || c == '\t') {
      continue;
    }
    c = switch (c) {
      'O' => '0',
      'I' || 'L' => '1',
      'U' => 'V',
      _ => c,
    };
    if (!kAccountIdAlphabet.contains(c)) {
      return null;
    }
    out.write(c);
  }
  final String id = out.toString();
  return id.length == kAccountIdLength ? id : null;
}

/// The ID in groups of four: `ABCD-EFGH-JKMN-PQRS`.
String formatAccountId(String id) {
  final List<String> groups = <String>[
    for (int i = 0; i < id.length; i += 4)
      id.substring(i, min(i + 4, id.length)),
  ];
  return groups.join('-');
}

/// Only the last group (`••••-PQRS`), for a listed account.
String maskAccountId(String id) =>
    id.length <= 4 ? id : '••••-${id.substring(id.length - 4)}';
