import 'package:flutter/foundation.dart';

/// Search in Zen runs on this device only, over what is already decrypted
/// in memory: nothing typed in a search field leaves the phone and nothing
/// of it is written down.
///
/// Text is compared folded: lower case, without accents ("Żółw", "zolw" and
/// "ŻÓŁW" are the same word), so a query typed without Polish letters finds
/// them.

/// Letters folded to their plain form (the table covers Latin-1 and
/// Latin Extended-A: Polish, German, French, Czech, Spanish…).
const Map<String, String> _plainLetters = <String, String>{
  'a': 'ÀÁÂÃÄÅàáâãäåĀāĂăĄąǍǎ',
  'c': 'ÇçĆćĈĉĊċČč',
  'd': 'ĎďĐðÐđ',
  'e': 'ÈÉÊËèéêëĒēĔĕĖėĘęĚě',
  'g': 'ĜĝĞğĠġĢģ',
  'h': 'ĤĥĦħ',
  'i': 'ÌÍÎÏìíîïĨĩĪīĬĭĮįİıǏǐ',
  'j': 'Ĵĵ',
  'k': 'Ķķĸ',
  'l': 'ĹĺĻļĽľĿŀŁł',
  'n': 'ÑñŃńŅņŇňŉŊŋ',
  'o': 'ÒÓÔÕÖØòóôõöøŌōŎŏŐőǑǒ',
  'r': 'ŔŕŖŗŘř',
  's': 'ŚśŜŝŞşŠšſ',
  't': 'ŢţŤťŦŧ',
  'u': 'ÙÚÛÜùúûüŨũŪūŬŭŮůŰűŲųǓǔ',
  'w': 'Ŵŵ',
  'y': 'ÝýÿŶŷŸ',
  'z': 'ŹźŻżŽž',
  'ss': 'ß',
  'ae': 'Ææ',
  'oe': 'Œœ',
  'th': 'Þþ',
};

final Map<int, String> _folds = <int, String>{
  for (final MapEntry<String, String> e in _plainLetters.entries)
    for (final int unit in e.value.codeUnits) unit: e.key,
};

/// Other letters, lower-cased once and remembered.
final Map<int, String> _lowered = <int, String>{};

bool _isCombiningMark(int unit) =>
    (unit >= 0x0300 && unit <= 0x036F) || (unit >= 0x1AB0 && unit <= 0x1AFF);

/// The form of [unit] that is compared ('' for a combining accent).
String _foldUnit(int unit) {
  final String? table = _folds[unit];
  if (table != null) {
    return table;
  }
  if (_isCombiningMark(unit)) {
    return '';
  }
  return _lowered.putIfAbsent(unit, () {
    final String lower = String.fromCharCode(unit).toLowerCase();
    // A letter whose lower case is longer ("İ") stays one letter.
    return lower.length == 1 ? lower : String.fromCharCode(unit);
  });
}

/// [text] as search compares it: lower case, accents removed.
String foldForSearch(String text) {
  // Most text is plain ASCII: no buffer needed when nothing changes.
  int i = 0;
  final int length = text.length;
  while (i < length) {
    final int unit = text.codeUnitAt(i);
    if ((unit >= 0x41 && unit <= 0x5A) || unit > 0x7F) {
      break;
    }
    i++;
  }
  if (i == length) {
    return text;
  }
  final StringBuffer out = StringBuffer(text.substring(0, i));
  for (; i < length; i++) {
    final int unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      out.writeCharCode(unit >= 0x41 && unit <= 0x5A ? unit + 32 : unit);
    } else {
      out.write(_foldUnit(unit));
    }
  }
  return out.toString();
}

/// [text] folded, and for each folded letter where it came from in [text].
({String folded, List<int> origin}) _foldWithOrigin(String text) {
  final StringBuffer out = StringBuffer();
  final List<int> origin = <int>[];
  for (int i = 0; i < text.length; i++) {
    final int unit = text.codeUnitAt(i);
    final String folded = unit < 0x80
        ? String.fromCharCode(unit >= 0x41 && unit <= 0x5A ? unit + 32 : unit)
        : _foldUnit(unit);
    out.write(folded);
    for (int k = 0; k < folded.length; k++) {
      origin.add(i);
    }
  }
  return (folded: out.toString(), origin: origin);
}

/// A part of a text a search found, from [start] up to [end].
typedef SearchRange = ({int start, int end});

/// What was typed in a search field: its words, folded. A text matches when
/// it has every word, in any order, anywhere (also inside a longer word).
@immutable
final class SearchQuery {
  const SearchQuery._(this.raw, this.terms);

  factory SearchQuery.parse(String raw) {
    final List<String> terms = <String>[];
    for (final String word in foldForSearch(raw).split(_spaces)) {
      if (word.isNotEmpty && !terms.contains(word)) {
        terms.add(word);
      }
    }
    // The longest word first: it rules out most texts soonest.
    terms.sort((String a, String b) => b.length.compareTo(a.length));
    return SearchQuery._(raw, List<String>.unmodifiable(terms));
  }

  static const SearchQuery empty = SearchQuery._('', <String>[]);

  static final RegExp _spaces = RegExp(r'\s+');

  /// Letters a query needs before messages are searched (one letter would
  /// match nearly every message). Names are searched from the first one.
  static const int minMessageQueryLength = 2;

  /// As typed.
  final String raw;

  /// The words, folded ([foldForSearch]), longest first, each once.
  final List<String> terms;

  bool get isEmpty => terms.isEmpty;

  /// Long enough to search messages with: two letters, or one letter of a
  /// script that writes whole words with one (Chinese, Japanese…).
  bool get searchesMessages {
    if (terms.isEmpty) {
      return false;
    }
    int letters = 0;
    for (final String term in terms) {
      letters += term.length;
      if (term.codeUnits.any((int u) => u >= 0x2E80)) {
        return true;
      }
    }
    return letters >= minMessageQueryLength;
  }

  /// Whether [folded] (a text already through [foldForSearch]) has every
  /// word. An empty query matches nothing.
  bool matchesFolded(String folded) {
    if (terms.isEmpty) {
      return false;
    }
    for (final String term in terms) {
      if (!folded.contains(term)) {
        return false;
      }
    }
    return true;
  }

  bool matches(String text) => matchesFolded(foldForSearch(text));

  /// Where the words are in [text] (every place each one is), in order,
  /// overlapping places joined: what a result shows marked.
  List<SearchRange> rangesIn(String text) {
    if (terms.isEmpty || text.isEmpty) {
      return const <SearchRange>[];
    }
    final ({String folded, List<int> origin}) f = _foldWithOrigin(text);
    final List<SearchRange> found = <SearchRange>[];
    for (final String term in terms) {
      int from = 0;
      while (true) {
        final int at = f.folded.indexOf(term, from);
        if (at < 0) {
          break;
        }
        final int last = at + term.length;
        final int start = f.origin[at];
        // Accents dropped right after the match belong to it.
        final int next = last < f.origin.length ? f.origin[last] : text.length;
        final int end = next > f.origin[last - 1]
            ? next
            : f.origin[last - 1] + 1;
        found.add((start: start, end: end));
        from = at + 1;
      }
    }
    if (found.length < 2) {
      return found;
    }
    found.sort((SearchRange a, SearchRange b) => a.start.compareTo(b.start));
    final List<SearchRange> joined = <SearchRange>[found.first];
    for (final SearchRange r in found.skip(1)) {
      final SearchRange last = joined.last;
      if (r.start <= last.end) {
        if (r.end > last.end) {
          joined[joined.length - 1] = (start: last.start, end: r.end);
        }
      } else {
        joined.add(r);
      }
    }
    return joined;
  }

  @override
  bool operator ==(Object other) =>
      other is SearchQuery && listEquals(other.terms, terms);

  @override
  int get hashCode => Object.hashAll(terms);
}

/// A short part of [text] around the first place [query] found, on one
/// line: about [before] characters before it and up to [length] in all,
/// with "…" where it was cut. The ranges are in the snippet.
({String text, List<SearchRange> ranges}) searchSnippet(
  String text,
  SearchQuery query, {
  int before = 24,
  int length = 120,
}) {
  final String line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final List<SearchRange> ranges = query.rangesIn(line);
  if (line.length <= length) {
    return (text: line, ranges: ranges);
  }
  int start = ranges.isEmpty ? 0 : ranges.first.start - before;
  if (start < 0) {
    start = 0;
  }
  // Start at a word.
  if (start > 0) {
    final int space = line.lastIndexOf(' ', start);
    if (space >= 0 && start - space < 12) {
      start = space + 1;
    }
  }
  int end = start + length;
  if (end > line.length) {
    end = line.length;
    start = (end - length).clamp(0, line.length);
  }
  final String lead = start > 0 ? '…' : '';
  final String tail = end < line.length ? '…' : '';
  final int shift = lead.length - start;
  return (
    text: '$lead${line.substring(start, end)}$tail',
    ranges: <SearchRange>[
      for (final SearchRange r in ranges)
        if (r.end > start && r.start < end)
          (
            start: (r.start < start ? start : r.start) + shift,
            end: (r.end > end ? end : r.end) + shift,
          ),
    ],
  );
}
