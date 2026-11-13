import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/passwords/password_entry.dart';

/// Largest file taken in (an export of thousands of passwords is far
/// smaller).
const int kMaxPasswordCsvBytes = 8 * 1024 * 1024;

/// The most rows read from one file; the rest is counted as
/// [PasswordImportSkip.tooMany].
const int kMaxPasswordCsvRows = 10000;

/// The most columns a row may have.
const int _maxColumns = 64;

/// The longest cell read (a longer one makes its row unreadable).
const int _maxCellChars = 64 * 1024;

/// Whose export a file is, by its header.
enum PasswordCsvLayout {
  /// Chrome and Edge: `name,url,username,password[,note]`.
  chrome,

  /// Firefox: `url,username,password,httpRealm,formActionOrigin,guid,…`.
  firefox,

  /// Bitwarden: `folder,favorite,type,name,notes,fields,reprompt,login_uri,
  /// login_username,login_password,login_totp`.
  bitwarden,

  /// KeePassXC: `Group,Title,Username,Password,URL,Notes,…`.
  keepassxc,

  /// KeePass: `Account,Login Name,Password,Web Site,Comments`.
  keepass,

  /// Another file whose header names a password column and a name or an
  /// address column.
  generic,
}

/// Why a whole file was not taken.
enum PasswordCsvError {
  /// Larger than [kMaxPasswordCsvBytes].
  tooLarge,

  /// Not text in UTF-8 (or UTF-16 with its mark): export it again as UTF-8.
  /// Nothing is guessed: a password read in the wrong encoding would be
  /// wrong without anyone noticing.
  encoding,

  /// No header row this build recognises (no password column, or neither a
  /// name nor an address column).
  unknownLayout,
}

/// Why a row was not taken.
enum PasswordImportSkip {
  /// A row with no password (and, in a password manager's export, a
  /// login without one).
  noPassword,

  /// Neither a name nor an address.
  noName,

  /// Not a login (a card, a note, an identity in Bitwarden).
  notLogin,

  /// In KeePassXC's recycle bin (whatever language named it).
  deleted,

  /// Archived in 1Password (its `Archived` column).
  archived,

  /// A field longer than this app keeps (a password is never cut short).
  tooLong,

  /// A broken row: more cells than the header, a quote never closed, a
  /// cell far too long ([PasswordCsvParse.damaged] says where).
  malformed,

  /// The same name or address, login and password as an entry already in
  /// the vault (or an earlier row).
  duplicate,

  /// The vault is full ([kMaxPasswordEntries], [kMaxPasswordVaultBytes]).
  full,

  /// Past [kMaxPasswordCsvRows].
  tooMany,
}

/// One row read: its line in the file and its fields. [toString] shows no
/// field.
@immutable
final class PasswordCsvRow {
  const PasswordCsvRow(this.line, this.fields);

  /// The line the row starts on (the header is line 1).
  final int line;
  final PasswordFields fields;

  @override
  String toString() => 'PasswordCsvRow(line $line)';
}

/// Lines of a file that could not be read as rows: [from] to [to], or to
/// the end of the file when [to] is null.
@immutable
final class PasswordCsvDamage {
  const PasswordCsvDamage(this.from, this.to);

  final int from;
  final int? to;

  @override
  bool operator ==(Object other) =>
      other is PasswordCsvDamage && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);

  @override
  String toString() => 'PasswordCsvDamage($from-${to ?? 'end'})';
}

/// A file read: whose it is, the rows taken, the rows left out and why.
@immutable
final class PasswordCsvParse {
  const PasswordCsvParse({
    this.layout,
    this.error,
    this.read = 0,
    this.rows = const <PasswordCsvRow>[],
    this.skipped = const <PasswordImportSkip, int>{},
    this.damaged = const <PasswordCsvDamage>[],
  });

  final PasswordCsvLayout? layout;
  final PasswordCsvError? error;

  /// Rows read after the header (blank lines are not rows).
  final int read;
  final List<PasswordCsvRow> rows;
  final Map<PasswordImportSkip, int> skipped;

  /// Where the file's damaged rows are ([PasswordImportSkip.malformed]),
  /// in the order of the file.
  final List<PasswordCsvDamage> damaged;

  @override
  String toString() =>
      'PasswordCsvParse(${layout?.name ?? error?.name}, read $read, '
      'rows ${rows.length})';
}

/// The text of a file's [bytes]: UTF-8 (a BOM dropped), or UTF-16 when it
/// starts with its byte-order mark; null for anything else.
String? passwordCsvText(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _utf16(bytes, 2, littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _utf16(bytes, 2, littleEndian: false);
  }
  final int start =
      bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF
      ? 3
      : 0;
  try {
    return utf8.decode(Uint8List.sublistView(bytes, start));
  } on FormatException {
    return null;
  }
}

String? _utf16(Uint8List bytes, int start, {required bool littleEndian}) {
  if ((bytes.length - start).isOdd) {
    return null;
  }
  final List<int> units = <int>[
    for (int i = start; i < bytes.length; i += 2)
      littleEndian
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
  ];
  // Lone surrogates mean it is not UTF-16 text.
  for (int i = 0; i < units.length; i++) {
    final int u = units[i];
    if (u >= 0xD800 && u <= 0xDBFF) {
      if (i + 1 >= units.length ||
          units[i + 1] < 0xDC00 ||
          units[i + 1] > 0xDFFF) {
        return null;
      }
      i++;
    } else if (u >= 0xDC00 && u <= 0xDFFF) {
      return null;
    }
  }
  return String.fromCharCodes(units);
}

/// One record of the file.
final class _Record {
  _Record(this.line);

  /// The line it starts on.
  final int line;
  final List<String> cells = <String>[];

  /// More columns than any export has, or a cell far too long.
  bool broken = false;

  /// A quote still open where the text ends.
  bool open = false;

  /// Text right after a closing quote (neither a separator nor a line end):
  /// the quote was not where a cell ends.
  bool stray = false;

  /// A quoted cell held a line break.
  bool spans = false;

  bool get blank => cells.every((String c) => c.isEmpty);
}

/// The separator of [text]: the one of `,`, `;` and tab found most often
/// outside quotes in its first line.
String _separatorOf(String text) {
  final Map<String, int> counts = <String, int>{',': 0, ';': 0, '\t': 0};
  bool quoted = false;
  for (int i = 0; i < text.length; i++) {
    final String c = text[i];
    if (c == '"') {
      quoted = !quoted;
    } else if (!quoted && (c == '\n' || c == '\r')) {
      break;
    } else if (!quoted && counts.containsKey(c)) {
      counts[c] = counts[c]! + 1;
    }
  }
  String best = ',';
  for (final MapEntry<String, int> e in counts.entries) {
    if (e.value > counts[best]!) {
      best = e.key;
    }
  }
  return best;
}

/// Reads the records of a text one by one (RFC 4180: cells in quotes may
/// hold the separator, line breaks and doubled quotes; CRLF, LF and CR all
/// end a line; a line break inside a cell is kept as LF).
final class _Lexer {
  _Lexer(this.text, this.sep);

  final String text;
  final String sep;

  /// Where the next record starts, and on which line.
  int pos = 0;
  int line = 1;

  bool get done => pos >= text.length;

  /// The record at [pos], which then moves past it. With [keep] false its
  /// cells are only marked as empty or not ('-'), not kept.
  _Record read({required bool keep}) {
    final _Record record = _Record(line);
    final StringBuffer cell = StringBuffer();
    bool quoted = false;
    bool wasQuoted = false;
    bool closed = false;
    bool cellStarted = false;

    void endCell() {
      if (record.cells.length >= _maxColumns) {
        record.broken = true;
      } else if (keep) {
        record.cells.add(cell.toString());
      } else {
        record.cells.add(cell.isEmpty ? '' : '-');
      }
      cell.clear();
      wasQuoted = false;
      closed = false;
      cellStarted = false;
    }

    void put(String c) {
      if (!keep) {
        // Only counted: a mark that the cell is not empty is enough.
        if (cell.isEmpty) {
          cell.write('-');
        }
        return;
      }
      if (cell.length >= _maxCellChars) {
        record.broken = true;
        return;
      }
      cell.write(c);
    }

    while (pos < text.length) {
      final String c = text[pos];
      if (quoted) {
        if (c == '"') {
          if (pos + 1 < text.length && text[pos + 1] == '"') {
            put('"');
            pos += 2;
            continue;
          }
          quoted = false;
          closed = true;
          pos++;
          continue;
        }
        if (c == '\r' || c == '\n') {
          if (c == '\r' && pos + 1 < text.length && text[pos + 1] == '\n') {
            pos++;
          }
          put('\n');
          record.spans = true;
          line++;
          pos++;
          continue;
        }
        put(c);
        pos++;
        continue;
      }
      if (c == '"' && !cellStarted && !wasQuoted) {
        quoted = true;
        wasQuoted = true;
        cellStarted = true;
        pos++;
        continue;
      }
      if (c == sep) {
        endCell();
        pos++;
        continue;
      }
      if (c == '\r' || c == '\n') {
        if (c == '\r' && pos + 1 < text.length && text[pos + 1] == '\n') {
          pos++;
        }
        pos++;
        line++;
        endCell();
        return record;
      }
      if (closed) {
        record.stray = true;
      }
      // Anything after a closing quote, or a quote inside an unquoted cell,
      // is taken as it is (exports are not always strict).
      cellStarted = true;
      put(c);
      pos++;
    }
    if (quoted) {
      record.open = true;
    }
    endCell();
    return record;
  }

  /// Moves to the first line after [from] (where a record began) that is a
  /// whole record of [width] cells on a line of its own; false when no
  /// line is, and the text has nothing more to read.
  bool resumeAfter(int from, int fromLine, int width) {
    int at = from;
    int atLine = fromLine;
    while (true) {
      final int end = _lineEnd(at);
      if (end >= text.length) {
        pos = text.length;
        return false;
      }
      at =
          end +
          (text[end] == '\r' && end + 1 < text.length && text[end + 1] == '\n'
              ? 2
              : 1);
      atLine++;
      if (at >= text.length) {
        pos = text.length;
        return false;
      }
      final _Lexer one = _Lexer(text.substring(at, _lineEnd(at)), sep);
      final _Record r = one.read(keep: false);
      if (!r.open && !r.spans && !r.broken && r.cells.length == width) {
        pos = at;
        line = atLine;
        return true;
      }
    }
  }

  /// Where the line holding [from] ends (its line break, or the end).
  int _lineEnd(int from) {
    int i = from;
    while (i < text.length && text[i] != '\n' && text[i] != '\r') {
      i++;
    }
    return i;
  }
}

/// The column of each field in a header, and whose export it is.
final class _Columns {
  _Columns(this.layout, this.index);

  final PasswordCsvLayout layout;
  final Map<String, int> index;

  int? operator [](String field) => index[field];
}

const Map<String, List<String>> _synonyms = <String, List<String>>{
  'name': <String>['name', 'title', 'account'],
  'address': <String>[
    'url',
    'login_uri',
    'web site',
    'website',
    'uri',
    'address',
    'login_url',
  ],
  'login': <String>[
    'username',
    'login_username',
    'login name',
    'user name',
    'login',
    'user',
    'email',
  ],
  'password': <String>['password', 'login_password'],
  'note': <String>['note', 'notes', 'comments', 'comment', 'extra'],
  'type': <String>['type'],
  'group': <String>['group'],
  'archived': <String>['archived'],
};

_Columns? _columnsOf(List<String> header) {
  final List<String> names = <String>[
    for (final String h in header) h.trim().toLowerCase(),
  ];
  final Map<String, int> index = <String, int>{};
  for (final MapEntry<String, List<String>> e in _synonyms.entries) {
    for (final String name in e.value) {
      final int at = names.indexOf(name);
      if (at >= 0) {
        index[e.key] = at;
        break;
      }
    }
  }
  if (!index.containsKey('password') ||
      (!index.containsKey('name') && !index.containsKey('address'))) {
    return null;
  }
  final Set<String> has = names.toSet();
  final PasswordCsvLayout layout;
  if (has.contains('login_password') || has.contains('login_uri')) {
    layout = PasswordCsvLayout.bitwarden;
  } else if (has.contains('httprealm') ||
      has.contains('formactionorigin') ||
      has.contains('timepasswordchanged')) {
    layout = PasswordCsvLayout.firefox;
  } else if (has.contains('login name') && has.contains('web site')) {
    layout = PasswordCsvLayout.keepass;
  } else if (has.contains('title') &&
      has.contains('username') &&
      has.contains('url')) {
    layout = PasswordCsvLayout.keepassxc;
  } else if (has.containsAll(<String>['name', 'url', 'username', 'password'])) {
    layout = PasswordCsvLayout.chrome;
  } else {
    layout = PasswordCsvLayout.generic;
  }
  return _Columns(layout, index);
}

/// Reads a password export (the file's [bytes]) into rows: the layout is
/// told from its header; each row is checked against the limits of an
/// entry. Nothing of the file is kept or logged here; the caller drops the
/// bytes once this returns.
PasswordCsvParse parsePasswordCsv(Uint8List bytes) {
  if (bytes.length > kMaxPasswordCsvBytes) {
    return const PasswordCsvParse(error: PasswordCsvError.tooLarge);
  }
  final String? text = passwordCsvText(bytes);
  if (text == null) {
    return const PasswordCsvParse(error: PasswordCsvError.encoding);
  }
  return parsePasswordCsvText(text);
}

/// [parsePasswordCsv] of the file's text.
///
/// A record that runs over several lines because of a quote that was not
/// meant as one (a password starting with `"`, cut short by an export)
/// would swallow the rest of the file: one that ends with the quote still
/// open, has text right after a closing quote, or has another number of
/// cells than the header is taken as damaged, and reading goes on from
/// the next line that is a whole record by itself. The lines between are
/// reported ([PasswordCsvParse.damaged]); when no such line comes, the
/// file could not be read from that record on, and the report says so.
PasswordCsvParse parsePasswordCsvText(String text) {
  final String body = text.startsWith('﻿') ? text.substring(1) : text;
  final _Lexer lexer = _Lexer(body, _separatorOf(body));
  _Record? header;
  while (!lexer.done && header == null) {
    final _Record r = lexer.read(keep: true);
    if (!r.blank || r.broken || r.open) {
      header = r;
    }
  }
  final _Columns? columns = header == null || header.broken || header.open
      ? null
      : _columnsOf(header.cells);
  if (columns == null) {
    return const PasswordCsvParse(error: PasswordCsvError.unknownLayout);
  }
  final int width = header!.cells.length;
  final List<PasswordCsvRow> rows = <PasswordCsvRow>[];
  final Map<PasswordImportSkip, int> skipped = <PasswordImportSkip, int>{};
  final List<PasswordCsvDamage> damaged = <PasswordCsvDamage>[];
  void skip(PasswordImportSkip why, [int n = 1]) =>
      skipped[why] = (skipped[why] ?? 0) + n;
  int read = 0;
  int more = 0;
  while (!lexer.done) {
    final int start = lexer.pos;
    final bool keep = read < kMaxPasswordCsvRows;
    final _Record r = lexer.read(keep: keep);
    if (r.blank && !r.broken && !r.open) {
      continue;
    }
    if (!keep) {
      // Past the limit: only counted.
      more++;
      continue;
    }
    read++;
    if (r.spans && (r.open || r.stray || r.cells.length != width)) {
      skip(PasswordImportSkip.malformed);
      final bool resumed = lexer.resumeAfter(start, r.line, width);
      damaged.add(PasswordCsvDamage(r.line, resumed ? lexer.line - 1 : null));
      continue;
    }
    if (r.broken || r.open || r.cells.length > width) {
      skip(PasswordImportSkip.malformed);
      damaged.add(PasswordCsvDamage(r.line, r.line));
      continue;
    }
    String cell(String field) {
      final int? at = columns[field];
      return at == null || at >= r.cells.length ? '' : r.cells[at];
    }

    if (columns.layout == PasswordCsvLayout.bitwarden) {
      final String type = cell('type').trim().toLowerCase();
      if (type.isNotEmpty && type != 'login') {
        skip(PasswordImportSkip.notLogin);
        continue;
      }
    }
    if (_inRecycleBin(cell('group'))) {
      skip(PasswordImportSkip.deleted);
      continue;
    }
    if (_truthy.contains(cell('archived').trim().toLowerCase())) {
      skip(PasswordImportSkip.archived);
      continue;
    }
    String address = cell('address').trim();
    if (columns.layout == PasswordCsvLayout.bitwarden &&
        address.contains(',')) {
      // Several addresses of one login: the first is the entry's.
      address = address.split(',').first.trim();
    }
    final PasswordFields fields = PasswordFields(
      name: cell('name'),
      login: cell('login'),
      password: cell('password'),
      address: address,
      note: cell('note'),
    ).trimmed();
    if (fields.password.isEmpty) {
      skip(PasswordImportSkip.noPassword);
      continue;
    }
    switch (fields.problem) {
      case PasswordFieldsProblem.tooLong:
        skip(PasswordImportSkip.tooLong);
        continue;
      case PasswordFieldsProblem.noName:
        skip(PasswordImportSkip.noName);
        continue;
      case PasswordFieldsProblem.noPassword:
        skip(PasswordImportSkip.noPassword);
        continue;
      case null:
        break;
    }
    rows.add(PasswordCsvRow(r.line, fields));
  }
  if (more > 0) {
    read += more;
    skip(PasswordImportSkip.tooMany, more);
  }
  return PasswordCsvParse(
    layout: columns.layout,
    read: read,
    rows: rows,
    skipped: skipped,
    damaged: damaged,
  );
}

/// The values of a column such as 1Password's `Archived` that mean yes.
const Set<String> _truthy = <String>{'true', 'yes', '1'};

/// Names KeePassXC gives its recycle bin, which it names in the language it
/// runs in when it makes it (a group right under the root).
const Set<String> _recycleBins = <String>{
  'recycle bin',
  'kosz',
  'papierkorb',
  'corbeille',
  'papelera',
  'papelera de reciclaje',
  'cestino',
  'prullenbak',
  'lixeira',
  'reciclagem',
  'koš',
  'kôš',
  'papírkosár',
  'papperskorg',
  'papirkurv',
  'roskakori',
  'çöp kutusu',
  'корзина',
  'кошик',
  'кош',
  'κάδος ανακύκλωσης',
  'סל המחזור',
  'سلة المحذوفات',
  'ごみ箱',
  '回收站',
  '資源回收筒',
  '휴지통',
};

/// Whether [group] (KeePassXC's `Group` column: `Root/Kosz/…`) is in the
/// recycle bin: its first group under the root, or a group named
/// "Recycle Bin" anywhere, as KeePassXC names it in English.
bool _inRecycleBin(String group) {
  final List<String> path = <String>[
    for (final String g in group.split('/')) g.trim().toLowerCase(),
  ];
  return path.contains('recycle bin') ||
      (path.length >= 2 && _recycleBins.contains(path[1]));
}
