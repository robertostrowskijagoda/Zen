// Finds the Polish texts of Zen's translation calls in Dart source and checks
// translation files against them. Used by tool/i18n.dart and by
// test/i18n_test.dart; plain Dart (dart:io only), no Flutter.
//
// The texts are the string literals of
//
//   t('Polski tekst', {'name': value})
//   tn(count, one: '{n} osoba', few: '{n} osoby', many: '{n} osób')
//
// found by a small lexer that knows Dart's comments and string literals
// ('…', "…", '''…''', r'…', escapes, ${…} interpolation) and tells calls
// from declarations and method calls.
import 'dart:collection';
import 'dart:io';

/// The plural categories of CLDR, in their usual order.
const List<String> kI18nPluralCategories = <String>[
  'zero',
  'one',
  'two',
  'few',
  'many',
  'other',
];

final RegExp _placeholderPattern = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}');

/// The `{name}` placeholders of [text] (the same pattern `t()` fills).
Set<String> i18nPlaceholders(String text) => <String>{
  for (final Match match in _placeholderPattern.allMatches(text)) match[1]!,
};

/// The three Polish forms of a `tn()` call.
final class I18nPlural {
  const I18nPlural({required this.one, required this.few, required this.many});

  final String one;
  final String few;
  final String many;

  /// Every placeholder of the three forms.
  Set<String> get placeholders => <String>{
    ...i18nPlaceholders(one),
    ...i18nPlaceholders(few),
    ...i18nPlaceholders(many),
  };

  Map<String, String> toJson() => <String, String>{
    'one': one,
    'few': few,
    'many': many,
  };

  @override
  bool operator ==(Object other) =>
      other is I18nPlural &&
      other.one == one &&
      other.few == few &&
      other.many == many;

  @override
  int get hashCode => Object.hash(one, few, many);
}

/// One `t()` or `tn()` call found in a file.
final class I18nCall {
  const I18nCall({
    required this.function,
    required this.line,
    this.text,
    this.plural,
    this.error,
    this.hasArgs = false,
  });

  /// `t` or `tn`.
  final String function;

  /// 1-based line of the call.
  final int line;

  /// The key: the text of `t()`, the `many` text of `tn()`. Null when the
  /// call is broken ([error]).
  final String? text;

  /// The Polish forms of a `tn()` call.
  final I18nPlural? plural;

  /// Why the call cannot be translated (not a pure string literal…).
  final String? error;

  /// The call passes values for placeholders (`t(…, {…})`, `tn(…, args:)`).
  final bool hasArgs;
}

/// A problem found while scanning, at [file]:[line].
final class I18nIssue {
  const I18nIssue(this.file, this.line, this.message);

  final String file;
  final int line;
  final String message;

  @override
  String toString() => '$file:$line: $message';
}

/// One text to translate, with the files that use it.
final class I18nEntry {
  I18nEntry(this.key, {this.plural});

  /// The Polish text (for plurals: the `many` form).
  final String key;

  /// The Polish forms when the text comes from `tn()`.
  final I18nPlural? plural;

  /// Paths of the files that use it, sorted.
  final SplayTreeSet<String> files = SplayTreeSet<String>();

  Map<String, Object> toJson() => <String, Object>{
    'key': key,
    if (plural != null) 'plural': plural!.toJson(),
    'files': files.toList(),
  };
}

/// Everything found in a set of sources.
final class I18nScan {
  /// Texts by key, sorted by key.
  final SplayTreeMap<String, I18nEntry> entries =
      SplayTreeMap<String, I18nEntry>();

  /// Calls that cannot be translated; they make the check fail.
  final List<I18nIssue> errors = <I18nIssue>[];

  /// Suspicious calls (placeholders without values…); reported only.
  final List<I18nIssue> warnings = <I18nIssue>[];

  /// Number of files scanned.
  int fileCount = 0;

  /// Adds the calls of the file at [path] with the content [source].
  void addSource(String path, String source) {
    fileCount += 1;
    final List<I18nCall> calls;
    try {
      calls = scanI18nCalls(source);
    } on I18nSyntaxError catch (error) {
      errors.add(I18nIssue(path, error.line, error.message));
      return;
    }
    for (final I18nCall call in calls) {
      _add(path, call);
    }
  }

  void _add(String path, I18nCall call) {
    final String? text = call.text;
    if (call.error != null || text == null) {
      errors.add(I18nIssue(path, call.line, call.error ?? 'broken call'));
      return;
    }
    if (text.trim().isEmpty) {
      errors.add(I18nIssue(path, call.line, '${call.function}(): empty text'));
      return;
    }
    final I18nPlural? plural = call.plural;
    final Set<String> placeholders = plural == null
        ? i18nPlaceholders(text)
        : (plural.placeholders..remove('n'));
    if (placeholders.isNotEmpty && !call.hasArgs) {
      warnings.add(
        I18nIssue(
          path,
          call.line,
          '${call.function}(): placeholders '
          '${placeholders.map((String p) => '{$p}').join(', ')} '
          'but no values for them: "$text"',
        ),
      );
    }
    final I18nEntry? known = entries[text];
    if (known == null) {
      entries[text] = I18nEntry(text, plural: plural)..files.add(path);
      return;
    }
    known.files.add(path);
    if ((known.plural == null) != (plural == null)) {
      errors.add(
        I18nIssue(
          path,
          call.line,
          'the text is used both by t() and as the many: form of tn(), '
          'which need different translations: "$text"',
        ),
      );
    } else if (plural != null && known.plural != plural) {
      warnings.add(
        I18nIssue(
          path,
          call.line,
          'tn(): the same many: text with other one:/few: forms elsewhere '
          '(translated once, by the first): "$text"',
        ),
      );
    }
  }
}

/// Scans every `.dart` file under [directory] (recursively, sorted by path).
/// Paths are reported relative to [root] (default: the current directory),
/// with `/` separators.
I18nScan scanI18nDirectory(Directory directory, {Directory? root}) {
  final String base = (root ?? Directory.current).absolute.path;
  final List<File> files =
      directory
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((File file) => file.path.endsWith('.dart'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  final I18nScan scan = I18nScan();
  for (final File file in files) {
    scan.addSource(
      _relativePath(file.absolute.path, base),
      file.readAsStringSync(),
    );
  }
  return scan;
}

String _relativePath(String path, String base) {
  String relative = path;
  final String prefix = base.endsWith(Platform.pathSeparator)
      ? base
      : '$base${Platform.pathSeparator}';
  if (path.startsWith(prefix)) {
    relative = path.substring(prefix.length);
  }
  return relative.replaceAll(r'\', '/');
}

/// The source cannot be read: an unterminated string or comment.
final class I18nSyntaxError implements Exception {
  const I18nSyntaxError(this.message, this.line);

  final String message;

  /// 1-based line where the broken part starts.
  final int line;

  @override
  String toString() => 'line $line: $message';
}

/// The `t()` and `tn()` calls in [source]. Throws an [I18nSyntaxError] when
/// the source cannot be read.
List<I18nCall> scanI18nCalls(String source) {
  final _Lexer lexer = _Lexer(source.replaceAll('\r\n', '\n'));
  final List<_Token> tokens = lexer.tokenize();
  final List<I18nCall> calls = <I18nCall>[];
  _findCalls(tokens, calls);
  calls.sort((I18nCall a, I18nCall b) => a.line.compareTo(b.line));
  return calls;
}

// ---------------------------------------------------------------------------
// Translation files.

/// What is wrong with one translation file.
final class I18nFileReport {
  /// Texts of the code with no (or an empty) translation.
  final List<String> missing = <String>[];

  /// Translations of texts the code no longer has.
  final List<String> stale = <String>[];

  /// Translations that do not fit their text (placeholders, plural forms).
  final List<String> mismatched = <String>[];

  bool get isClean => missing.isEmpty && stale.isEmpty && mismatched.isEmpty;

  @override
  String toString() => <String>[
    for (final String key in missing) 'missing: ${_quoted(key)}',
    for (final String key in stale) 'stale: ${_quoted(key)}',
    ...mismatched,
  ].join('\n');
}

/// Checks [translations] (a decoded `assets/i18n/<code>.json`) against the
/// texts of [scan]: a text is a JSON string with the same placeholders; a
/// `tn()` text is an object of CLDR forms (at least "other") under the
/// `many` text.
I18nFileReport checkI18nTranslations(
  I18nScan scan,
  Map<String, Object?> translations,
) {
  final I18nFileReport report = I18nFileReport();
  for (final I18nEntry entry in scan.entries.values) {
    final Object? value = translations[entry.key];
    final I18nPlural? plural = entry.plural;
    if (value == null || (value is String && value.isEmpty)) {
      report.missing.add(entry.key);
      continue;
    }
    if (plural == null) {
      _checkText(entry.key, value, report);
    } else {
      _checkPlural(entry.key, plural, value, report);
    }
  }
  for (final String key in translations.keys) {
    if (!scan.entries.containsKey(key)) {
      report.stale.add(key);
    }
  }
  report.stale.sort();
  return report;
}

void _checkText(String key, Object value, I18nFileReport report) {
  if (value is! String) {
    report.mismatched.add(
      '${_quoted(key)}: expected a text, found ${_kindOf(value)}',
    );
    return;
  }
  final String? problem = _comparePlaceholders(
    i18nPlaceholders(key),
    i18nPlaceholders(value),
  );
  if (problem != null) {
    report.mismatched.add('${_quoted(key)}: $problem');
  }
}

void _checkPlural(
  String key,
  I18nPlural plural,
  Object value,
  I18nFileReport report,
) {
  if (value is! Map) {
    report.mismatched.add(
      '${_quoted(key)}: expected plural forms ({"one": …, "other": …}), '
      'found ${_kindOf(value)}',
    );
    return;
  }
  final Object? other = value['other'];
  if (other is! String || other.isEmpty) {
    report.mismatched.add('${_quoted(key)}: the plural forms need "other"');
  }
  final Set<String> allowed = plural.placeholders..add('n');
  final Set<String> inEveryForm =
      i18nPlaceholders(plural.one)
          .intersection(i18nPlaceholders(plural.few))
          .intersection(i18nPlaceholders(plural.many))
        ..remove('n');
  for (final MapEntry<Object?, Object?> form in value.entries) {
    final Object? category = form.key;
    final Object? text = form.value;
    if (!kI18nPluralCategories.contains(category)) {
      report.mismatched.add(
        '${_quoted(key)}: "$category" is not a plural category '
        '(${kI18nPluralCategories.join(', ')})',
      );
      continue;
    }
    if (text is! String || text.isEmpty) {
      report.mismatched.add(
        '${_quoted(key)}: the "$category" form must be a non-empty text',
      );
      continue;
    }
    final Set<String> found = i18nPlaceholders(text);
    final Set<String> unknown = found.difference(allowed);
    final Set<String> lost =
        (category == 'other'
                ? (i18nPlaceholders(plural.many)..addAll(inEveryForm))
                : inEveryForm)
            .difference(found);
    if (unknown.isNotEmpty || lost.isNotEmpty) {
      report.mismatched.add(
        '${_quoted(key)} ($category): '
        '${_describePlaceholders(lost: lost, unknown: unknown)}',
      );
    }
  }
}

String? _comparePlaceholders(Set<String> source, Set<String> translation) {
  final Set<String> lost = source.difference(translation);
  final Set<String> unknown = translation.difference(source);
  if (lost.isEmpty && unknown.isEmpty) {
    return null;
  }
  return _describePlaceholders(lost: lost, unknown: unknown);
}

String _describePlaceholders({
  required Set<String> lost,
  required Set<String> unknown,
}) {
  String names(Set<String> set) =>
      (set.toList()..sort()).map((String p) => '{$p}').join(', ');
  return <String>[
    if (lost.isNotEmpty) 'missing placeholders ${names(lost)}',
    if (unknown.isNotEmpty) 'unknown placeholders ${names(unknown)}',
  ].join('; ');
}

String _kindOf(Object value) => switch (value) {
  String() => 'a text',
  Map() => 'plural forms',
  List() => 'a list',
  _ => 'a ${value.runtimeType}',
};

/// [translations] without the texts the code no longer has, sorted by key
/// (plural forms in CLDR order).
SplayTreeMap<String, Object?> pruneI18nTranslations(
  I18nScan scan,
  Map<String, Object?> translations,
) {
  final SplayTreeMap<String, Object?> pruned = SplayTreeMap<String, Object?>();
  for (final MapEntry<String, Object?> entry in translations.entries) {
    if (!scan.entries.containsKey(entry.key)) {
      continue;
    }
    final Object? value = entry.value;
    pruned[entry.key] = value is Map ? _sortedForms(value) : value;
  }
  return pruned;
}

Map<String, Object?> _sortedForms(Map<Object?, Object?> forms) {
  int rank(Object? key) {
    final int index = kI18nPluralCategories.indexOf('$key');
    return index < 0 ? kI18nPluralCategories.length : index;
  }

  final List<Object?> keys = forms.keys.toList()
    ..sort((Object? a, Object? b) {
      final int byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : '$a'.compareTo('$b');
    });
  return <String, Object?>{for (final Object? key in keys) '$key': forms[key]};
}

String _quoted(String text) {
  final String flat = text
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('\n', r'\n');
  return '"$flat"';
}

// ---------------------------------------------------------------------------
// Calls.

/// Words after which `t(` is still an expression, not a declaration.
const Set<String> _expressionKeywords = <String>{
  'return',
  'yield',
  'await',
  'throw',
  'else',
  'in',
  'case',
  'when',
  'do',
};

/// Tokens after a `)` that make `t(…)` a declaration, not a call.
const Set<String> _declarationFollowers = <String>{'{', '=>', 'async', 'sync'};

void _findCalls(List<_Token> tokens, List<I18nCall> calls) {
  for (int i = 0; i < tokens.length; i++) {
    final _Token token = tokens[i];
    for (final List<_Token> part in token.interpolations) {
      _findCalls(part, calls);
    }
    if (token.kind != _Kind.identifier ||
        (token.text != 't' && token.text != 'tn') ||
        i + 1 >= tokens.length ||
        !tokens[i + 1].isPunctuation('(')) {
      continue;
    }
    if (i > 0) {
      final _Token previous = tokens[i - 1];
      // A method of something else (`x.t(…)`, `..t(…)`).
      if (previous.isPunctuation('.') ||
          previous.isPunctuation('?.') ||
          previous.isPunctuation('..')) {
        continue;
      }
      // A declaration (`String t(String source)`).
      if (previous.kind == _Kind.identifier &&
          !_expressionKeywords.contains(previous.text)) {
        continue;
      }
    }
    final int close = _matchingParenthesis(tokens, i + 1);
    if (close < 0) {
      calls.add(
        I18nCall(
          function: token.text,
          line: token.line,
          error: '${token.text}(): no closing parenthesis',
        ),
      );
      continue;
    }
    if (close + 1 < tokens.length) {
      final _Token after = tokens[close + 1];
      if ((after.kind == _Kind.punctuation || after.kind == _Kind.identifier) &&
          _declarationFollowers.contains(after.text)) {
        continue;
      }
    }
    calls.add(_readCall(token, _splitArguments(tokens, i + 2, close)));
  }
}

int _matchingParenthesis(List<_Token> tokens, int open) {
  int depth = 0;
  for (int i = open; i < tokens.length; i++) {
    final _Token token = tokens[i];
    if (token.isPunctuation('(')) {
      depth += 1;
    } else if (token.isPunctuation(')')) {
      depth -= 1;
      if (depth == 0) {
        return i;
      }
    }
  }
  return -1;
}

/// The arguments between [start] and [end] (exclusive), split at the
/// top-level commas.
List<List<_Token>> _splitArguments(List<_Token> tokens, int start, int end) {
  final List<List<_Token>> arguments = <List<_Token>>[];
  List<_Token> current = <_Token>[];
  int depth = 0;
  int i = start;
  while (i < end) {
    final _Token token = tokens[i];
    if (token.kind == _Kind.punctuation) {
      switch (token.text) {
        case '(' || '[' || '{':
          depth += 1;
        case ')' || ']' || '}':
          depth -= 1;
        case '<' when depth == 0 && _startsValue(current):
          // Type arguments of a literal (`<String, Object?>{…}`): their
          // commas do not separate arguments.
          int angles = 0;
          while (i < end) {
            final _Token inner = tokens[i];
            current.add(inner);
            i += 1;
            if (inner.isPunctuation('<')) {
              angles += 1;
            } else if (inner.isPunctuation('>')) {
              angles -= 1;
              if (angles == 0) {
                break;
              }
            }
          }
          continue;
        case ',' when depth == 0:
          arguments.add(current);
          current = <_Token>[];
          i += 1;
          continue;
      }
    }
    current.add(token);
    i += 1;
  }
  if (current.isNotEmpty) {
    arguments.add(current);
  }
  return arguments;
}

/// [argument] so far is empty or just a name (`one:`): a value starts.
bool _startsValue(List<_Token> argument) =>
    argument.isEmpty ||
    (argument.length == 2 &&
        argument[0].kind == _Kind.identifier &&
        argument[1].isPunctuation(':'));

I18nCall _readCall(_Token name, List<List<_Token>> arguments) {
  final List<List<_Token>> positional = <List<_Token>>[];
  final Map<String, List<_Token>> named = <String, List<_Token>>{};
  for (final List<_Token> argument in arguments) {
    if (argument.length >= 2 &&
        argument[0].kind == _Kind.identifier &&
        argument[1].isPunctuation(':')) {
      named[argument[0].text] = argument.sublist(2);
    } else {
      positional.add(argument);
    }
  }
  final String function = name.text;
  final int line = name.line;
  if (function == 't') {
    if (positional.isEmpty) {
      return I18nCall(function: function, line: line, error: 't(): no text');
    }
    final _Literal literal = _Literal.of(positional.first);
    if (literal.error != null) {
      return I18nCall(
        function: function,
        line: line,
        error: 't(): ${literal.error}: ${_snippet(positional.first)}',
      );
    }
    return I18nCall(
      function: function,
      line: line,
      text: literal.value,
      hasArgs: positional.length > 1 || named.isNotEmpty,
    );
  }
  final Map<String, String> forms = <String, String>{};
  for (final String form in const <String>['one', 'few', 'many']) {
    final List<_Token>? value = named[form];
    if (value == null) {
      return I18nCall(
        function: function,
        line: line,
        error: 'tn(): no $form: text (it needs one:, few: and many:)',
      );
    }
    final _Literal literal = _Literal.of(value);
    if (literal.error != null) {
      return I18nCall(
        function: function,
        line: line,
        error: 'tn(): $form: ${literal.error}: ${_snippet(value)}',
      );
    }
    forms[form] = literal.value!;
  }
  return I18nCall(
    function: function,
    line: line,
    text: forms['many'],
    plural: I18nPlural(
      one: forms['one']!,
      few: forms['few']!,
      many: forms['many']!,
    ),
    hasArgs: named.containsKey('args'),
  );
}

/// The value of an argument that must be a string literal.
final class _Literal {
  const _Literal(this.value, this.error);

  factory _Literal.of(List<_Token> tokens) {
    if (tokens.isEmpty) {
      return const _Literal(null, 'no text');
    }
    final StringBuffer value = StringBuffer();
    for (final _Token token in tokens) {
      if (token.kind != _Kind.string) {
        return const _Literal(
          null,
          'the text must be a string literal (not a variable or expression)',
        );
      }
      if (token.interpolations.isNotEmpty) {
        return const _Literal(
          null,
          r'the text must not use $ interpolation (use {name} placeholders)',
        );
      }
      value.write(token.value);
    }
    return _Literal(value.toString(), null);
  }

  final String? value;
  final String? error;
}

String _snippet(List<_Token> tokens) {
  final String text = tokens.map((_Token token) => token.text).join(' ');
  final String flat = text.replaceAll(RegExp(r'\s+'), ' ');
  return flat.length <= 70 ? flat : '${flat.substring(0, 67)}...';
}

// ---------------------------------------------------------------------------
// Lexer.

enum _Kind { identifier, string, number, punctuation }

final class _Token {
  const _Token(
    this.kind,
    this.text,
    this.line, {
    this.value = '',
    this.interpolations = const <List<_Token>>[],
  });

  final _Kind kind;

  /// The source text (a string literal with its quotes).
  final String text;
  final int line;

  /// A string literal's value (interpolated parts left out).
  final String value;

  /// The tokens of each `$name` / `${…}` of a string literal.
  final List<List<_Token>> interpolations;

  bool isPunctuation(String punctuation) =>
      kind == _Kind.punctuation && text == punctuation;
}

/// Multi-character punctuation the scanner cares about (longest first).
const List<String> _multiPunctuation = <String>['...', '?.', '..', '=>', '??'];

final class _Lexer {
  _Lexer(this.source);

  final String source;
  int _position = 0;
  int _line = 1;

  /// Tokens up to the end of the source or, with [untilClosingBrace], up to
  /// the `}` that closes an interpolation (consumed, not returned).
  List<_Token> tokenize({bool untilClosingBrace = false}) {
    final List<_Token> tokens = <_Token>[];
    int braces = 0;
    while (_position < source.length) {
      final int c = source.codeUnitAt(_position);
      if (c == _newline) {
        _line += 1;
        _position += 1;
        continue;
      }
      if (c == _space || c == _tab || c == _carriageReturn || c == _formFeed) {
        _position += 1;
        continue;
      }
      if (c == _slash && _next(1) == _slash) {
        _skipLineComment();
        continue;
      }
      if (c == _slash && _next(1) == _star) {
        _skipBlockComment();
        continue;
      }
      if (c == _quote || c == _doubleQuote) {
        tokens.add(_readString(raw: false));
        continue;
      }
      if (c == _lowerR && (_next(1) == _quote || _next(1) == _doubleQuote)) {
        _position += 1;
        tokens.add(_readString(raw: true));
        continue;
      }
      if (_isIdentifierStart(c)) {
        tokens.add(_readIdentifier());
        continue;
      }
      if (_isDigit(c)) {
        tokens.add(_readNumber());
        continue;
      }
      if (untilClosingBrace) {
        if (c == _openBrace) {
          braces += 1;
        } else if (c == _closeBrace) {
          if (braces == 0) {
            _position += 1;
            return tokens;
          }
          braces -= 1;
        }
      }
      tokens.add(_readPunctuation());
    }
    if (untilClosingBrace) {
      throw I18nSyntaxError(r'unterminated ${…} interpolation', _line);
    }
    return tokens;
  }

  int _next(int offset) {
    final int index = _position + offset;
    return index < source.length ? source.codeUnitAt(index) : -1;
  }

  void _skipLineComment() {
    while (_position < source.length &&
        source.codeUnitAt(_position) != _newline) {
      _position += 1;
    }
  }

  void _skipBlockComment() {
    final int startLine = _line;
    int depth = 0;
    while (_position < source.length) {
      final int c = source.codeUnitAt(_position);
      if (c == _slash && _next(1) == _star) {
        depth += 1;
        _position += 2;
      } else if (c == _star && _next(1) == _slash) {
        depth -= 1;
        _position += 2;
        if (depth == 0) {
          return;
        }
      } else {
        if (c == _newline) {
          _line += 1;
        }
        _position += 1;
      }
    }
    throw I18nSyntaxError('unterminated comment', startLine);
  }

  _Token _readIdentifier() {
    final int start = _position;
    while (_position < source.length &&
        _isIdentifierPart(source.codeUnitAt(_position))) {
      _position += 1;
    }
    return _Token(_Kind.identifier, source.substring(start, _position), _line);
  }

  _Token _readNumber() {
    final int start = _position;
    while (_position < source.length) {
      final int c = source.codeUnitAt(_position);
      if (_isIdentifierPart(c) && c != _dollar) {
        _position += 1;
      } else if (c == _dot && _isDigit(_next(1))) {
        _position += 1;
      } else {
        break;
      }
    }
    return _Token(_Kind.number, source.substring(start, _position), _line);
  }

  _Token _readPunctuation() {
    for (final String punctuation in _multiPunctuation) {
      if (source.startsWith(punctuation, _position)) {
        _position += punctuation.length;
        return _Token(_Kind.punctuation, punctuation, _line);
      }
    }
    final String text = source[_position];
    _position += 1;
    return _Token(_Kind.punctuation, text, _line);
  }

  /// A string literal at [_position] (its opening quote; a raw string's
  /// `r` already consumed).
  _Token _readString({required bool raw}) {
    final int start = raw ? _position - 1 : _position;
    final int startLine = _line;
    final int quote = source.codeUnitAt(_position);
    final String quoteText = String.fromCharCode(quote);
    final bool triple = source.startsWith(quoteText * 3, _position);
    _position += triple ? 3 : 1;
    if (triple) {
      _skipFirstLineOfMultilineString();
    }
    final StringBuffer value = StringBuffer();
    final List<List<_Token>> interpolations = <List<_Token>>[];
    while (true) {
      if (_position >= source.length) {
        throw I18nSyntaxError('unterminated string', startLine);
      }
      final int c = source.codeUnitAt(_position);
      if (triple) {
        if (source.startsWith(quoteText * 3, _position)) {
          _position += 3;
          break;
        }
      } else if (c == quote) {
        _position += 1;
        break;
      } else if (c == _newline) {
        throw I18nSyntaxError('unterminated string', startLine);
      }
      if (c == _newline) {
        _line += 1;
      }
      if (!raw && c == _backslash) {
        value.write(_readEscape());
        continue;
      }
      if (!raw && c == _dollar) {
        final int next = _next(1);
        if (next == _openBrace) {
          _position += 2;
          interpolations.add(tokenize(untilClosingBrace: true));
          continue;
        }
        if (_isIdentifierStart(next) && next != _dollar) {
          _position += 1;
          final int nameStart = _position;
          while (_position < source.length) {
            final int n = source.codeUnitAt(_position);
            if (!_isIdentifierPart(n) || n == _dollar) {
              break;
            }
            _position += 1;
          }
          interpolations.add(<_Token>[
            _Token(
              _Kind.identifier,
              source.substring(nameStart, _position),
              _line,
            ),
          ]);
          continue;
        }
      }
      value.writeCharCode(c);
      _position += 1;
    }
    return _Token(
      _Kind.string,
      source.substring(start, _position),
      startLine,
      value: value.toString(),
      interpolations: interpolations,
    );
  }

  /// Dart drops the first line of a multi-line string when it holds only
  /// whitespace (possibly after a backslash).
  void _skipFirstLineOfMultilineString() {
    int index = _position;
    if (index < source.length && source.codeUnitAt(index) == _backslash) {
      index += 1;
    }
    while (index < source.length &&
        (source.codeUnitAt(index) == _space ||
            source.codeUnitAt(index) == _tab)) {
      index += 1;
    }
    if (index < source.length && source.codeUnitAt(index) == _newline) {
      _position = index + 1;
      _line += 1;
    }
  }

  /// The character of the escape at [_position] (a backslash).
  String _readEscape() {
    final int c = _next(1);
    _position += 2;
    switch (c) {
      case -1:
        throw I18nSyntaxError('unterminated string', _line);
      case _lowerN:
        return '\n';
      case _lowerR:
        return '\r';
      case _lowerT:
        return '\t';
      case _lowerB:
        return '\b';
      case _lowerF:
        return '\f';
      case _lowerV:
        return '\v';
      case _lowerX:
        return _readHex(2);
      case _lowerU:
        if (_position < source.length &&
            source.codeUnitAt(_position) == _openBrace) {
          final int close = source.indexOf('}', _position);
          if (close < 0) {
            throw I18nSyntaxError('broken \\u{…} escape', _line);
          }
          final String hex = source.substring(_position + 1, close);
          _position = close + 1;
          return String.fromCharCode(int.parse(hex, radix: 16));
        }
        return _readHex(4);
      case _newline:
        _line += 1;
        return '\n';
      default:
        return String.fromCharCode(c);
    }
  }

  String _readHex(int digits) {
    final int end = _position + digits;
    if (end > source.length) {
      throw I18nSyntaxError('broken escape', _line);
    }
    final int? code = int.tryParse(source.substring(_position, end), radix: 16);
    if (code == null) {
      throw I18nSyntaxError('broken escape', _line);
    }
    _position = end;
    return String.fromCharCode(code);
  }
}

const int _tab = 0x09;
const int _newline = 0x0A;
const int _formFeed = 0x0C;
const int _carriageReturn = 0x0D;
const int _space = 0x20;
const int _doubleQuote = 0x22;
const int _dollar = 0x24;
const int _quote = 0x27;
const int _star = 0x2A;
const int _dot = 0x2E;
const int _slash = 0x2F;
const int _backslash = 0x5C;
const int _underscore = 0x5F;
const int _lowerB = 0x62;
const int _lowerF = 0x66;
const int _lowerN = 0x6E;
const int _lowerR = 0x72;
const int _lowerT = 0x74;
const int _lowerU = 0x75;
const int _lowerV = 0x76;
const int _lowerX = 0x78;
const int _openBrace = 0x7B;
const int _closeBrace = 0x7D;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

bool _isIdentifierStart(int c) =>
    _isLetter(c) || c == _underscore || c == _dollar;

bool _isIdentifierPart(int c) => _isIdentifierStart(c) || _isDigit(c);
