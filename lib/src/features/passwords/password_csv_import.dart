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

  /// In KeePassXC's recycle bin.
  deleted,

  /// A field longer than this app keeps (a password is never cut short).
  tooLong,

  /// A broken row: more cells than the header, a quote never closed, a
  /// cell far too long.
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

/// A file read: whose it is, the rows taken, the rows left out and why.
@immutable
final class PasswordCsvParse {
  const PasswordCsvParse({
    this.layout,
    this.error,
    this.read = 0,
    this.rows = const <PasswordCsvRow>[],
    this.skipped = const <PasswordImportSkip, int>{},
  });

  final PasswordCsvLayout? layout;
  final PasswordCsvError? error;

  /// Rows read after the header (blank lines are not rows).
  final int read;
  final List<PasswordCsvRow> rows;
  final Map<PasswordImportSkip, int> skipped;

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

  final int line;
  final List<String> cells = <String>[];
  bool broken = false;

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

/// The records of [text] (RFC 4180: cells in quotes may hold the
/// separator, line breaks and doubled quotes; CRLF, LF and CR all end a
/// line; a line break inside a cell is kept as LF). Past [keep] records
/// that are not blank, records are only counted ([_Records.more]), not
/// kept. A quote left open at the end makes the last record broken.
_Records _records(String text, String sep, int keep) {
  final _Records out = _Records();
  int kept = 0;
  int line = 1;
  _Record record = _Record(line);
  final StringBuffer cell = StringBuffer();
  bool quoted = false;
  bool wasQuoted = false;
  bool cellStarted = false;

  void endCell() {
    if (record.cells.length >= _maxColumns) {
      record.broken = true;
    } else if (kept < keep) {
      record.cells.add(cell.toString());
    } else {
      record.cells.add(cell.isEmpty ? '' : '-');
    }
    cell.clear();
    wasQuoted = false;
    cellStarted = false;
  }

  void endRecord() {
    endCell();
    if (!record.blank || record.broken) {
      if (kept < keep) {
        kept++;
        out.records.add(record);
      } else {
        out.more++;
      }
    }
    record = _Record(line);
  }

  void put(String c) {
    if (kept >= keep) {
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

  int i = 0;
  while (i < text.length) {
    final String c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          put('"');
          i += 2;
          continue;
        }
        quoted = false;
        i++;
        continue;
      }
      if (c == '\r' || c == '\n') {
        if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
          i++;
        }
        put('\n');
        line++;
        i++;
        continue;
      }
      put(c);
      i++;
      continue;
    }
    if (c == '"' && !cellStarted && !wasQuoted) {
      quoted = true;
      wasQuoted = true;
      cellStarted = true;
      i++;
      continue;
    }
    if (c == sep) {
      endCell();
      i++;
      continue;
    }
    if (c == '\r' || c == '\n') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') {
        i++;
      }
      i++;
      line++;
      endRecord();
      continue;
    }
    // Anything after a closing quote, or a quote inside an unquoted cell,
    // is taken as it is (exports are not always strict).
    cellStarted = true;
    put(c);
    i++;
  }
  if (cellStarted || cell.isNotEmpty || record.cells.isNotEmpty || quoted) {
    if (quoted) {
      record.broken = true;
    }
    endRecord();
  }
  return out;
}

/// The records kept, and how many more there were.
final class _Records {
  final List<_Record> records = <_Record>[];
  int more = 0;
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
PasswordCsvParse parsePasswordCsvText(String text) {
  final String body = text.startsWith('﻿') ? text.substring(1) : text;
  // The header and at most [kMaxPasswordCsvRows] rows; blank lines are
  // not rows.
  final _Records all = _records(
    body,
    _separatorOf(body),
    kMaxPasswordCsvRows + 1,
  );
  if (all.records.isEmpty) {
    return const PasswordCsvParse(error: PasswordCsvError.unknownLayout);
  }
  final _Record header = all.records.first;
  final _Columns? columns = header.broken ? null : _columnsOf(header.cells);
  if (columns == null) {
    return const PasswordCsvParse(error: PasswordCsvError.unknownLayout);
  }
  final int width = header.cells.length;
  final List<PasswordCsvRow> rows = <PasswordCsvRow>[];
  final Map<PasswordImportSkip, int> skipped = <PasswordImportSkip, int>{};
  void skip(PasswordImportSkip why, [int n = 1]) =>
      skipped[why] = (skipped[why] ?? 0) + n;
  int read = 0;
  for (final _Record r in all.records.skip(1)) {
    read++;
    if (r.broken || r.cells.length > width) {
      skip(PasswordImportSkip.malformed);
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
    if (columns.layout == PasswordCsvLayout.keepassxc &&
        cell('group').split('/').any((String g) => g.trim() == 'Recycle Bin')) {
      skip(PasswordImportSkip.deleted);
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
  if (all.more > 0) {
    read += all.more;
    skip(PasswordImportSkip.tooMany, all.more);
  }
  return PasswordCsvParse(
    layout: columns.layout,
    read: read,
    rows: rows,
    skipped: skipped,
  );
}
