import 'package:flutter/foundation.dart';

/// Formatting in posts, Discord-style (§24): plain text with markers, so a
/// post stays readable anywhere and nothing executes.
///
/// Inline: `**pogrubienie**`, `*kursywa*` / `_kursywa_`, `__podkreślenie__`,
/// `~~przekreślenie~~`, `` `kod` ``, `||spoiler||`, links (http/https).
/// Lines: `# `, `## `, `### ` headings, `> ` quote, `- ` list, `1. ` list,
/// ```` ``` ```` code blocks, and `{{media:N}}` for the N-th photo or video
/// placed at that point.

/// A piece of text with its look. [marker] pieces are the formatting
/// characters themselves (shown faint in the editor, hidden in posts).
@immutable
final class RichRun {
  const RichRun(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.code = false,
    this.spoiler = false,
    this.link = false,
    this.marker = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool code;
  final bool spoiler;
  final bool link;
  final bool marker;

  RichRun withText(String t) => RichRun(
    t,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    code: code,
    spoiler: spoiler,
    link: link,
    marker: marker,
  );

  bool sameLook(RichRun o) =>
      bold == o.bold &&
      italic == o.italic &&
      underline == o.underline &&
      strike == o.strike &&
      code == o.code &&
      spoiler == o.spoiler &&
      link == o.link &&
      marker == o.marker;

  @override
  String toString() =>
      '${<String>[if (bold) 'b', if (italic) 'i', if (underline) 'u', if (strike) 's', if (code) 'c', if (spoiler) 'sp', if (link) 'a', if (marker) 'm'].join()}:$text';
}

final class _Style {
  const _Style({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.spoiler = false,
  });

  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool spoiler;

  _Style add(String marker) => _Style(
    bold: bold || marker == '**',
    italic: italic || marker == '*' || marker == '_',
    underline: underline || marker == '__',
    strike: strike || marker == '~~',
    spoiler: spoiler || marker == '||',
  );

  RichRun run(String text, {bool code = false, bool link = false}) => RichRun(
    text,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    spoiler: spoiler,
    code: code,
    link: link,
  );

  RichRun marker(String text) => RichRun(
    text,
    bold: bold,
    italic: italic,
    underline: underline,
    strike: strike,
    spoiler: spoiler,
    marker: true,
  );
}

const List<String> _pairs = <String>['||', '**', '__', '~~', '*', '_'];
final RegExp _url = RegExp(r'https?://[^\s<>()]+[^\s<>().,!?;:]');

bool _wordChar(String c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);

/// Inline formatting of [source], markers included, covering every
/// character of [source] exactly once.
List<RichRun> parseInline(String source) {
  final List<RichRun> out = <RichRun>[];
  _inline(source, const _Style(), out);
  return _merge(out);
}

/// Only what a reader sees (markers dropped).
List<RichRun> visibleRuns(String source) => <RichRun>[
  for (final RichRun r in parseInline(source))
    if (!r.marker) r,
];

List<RichRun> _merge(List<RichRun> runs) {
  final List<RichRun> out = <RichRun>[];
  for (final RichRun r in runs) {
    if (r.text.isEmpty) {
      continue;
    }
    if (out.isNotEmpty && out.last.sameLook(r)) {
      out[out.length - 1] = out.last.withText(out.last.text + r.text);
    } else {
      out.add(r);
    }
  }
  return out;
}

void _plain(String text, _Style style, List<RichRun> out) {
  int at = 0;
  for (final RegExpMatch m in _url.allMatches(text)) {
    if (m.start > at) {
      out.add(style.run(text.substring(at, m.start)));
    }
    out.add(style.run(m.group(0)!, link: true));
    at = m.end;
  }
  if (at < text.length) {
    out.add(style.run(text.substring(at)));
  }
}

void _inline(String s, _Style style, List<RichRun> out) {
  final StringBuffer text = StringBuffer();
  void flush() {
    if (text.isNotEmpty) {
      _plain(text.toString(), style, out);
      text.clear();
    }
  }

  int i = 0;
  while (i < s.length) {
    final String c = s[i];
    // Escaped marker: \* stays a star.
    if (c == r'\' && i + 1 < s.length && r'*_~|`\'.contains(s[i + 1])) {
      flush();
      out.add(style.marker(c));
      text.write(s[i + 1]);
      i += 2;
      continue;
    }
    if (c == '`') {
      final int end = s.indexOf('`', i + 1);
      if (end > i + 1) {
        flush();
        out
          ..add(style.marker('`'))
          ..add(style.run(s.substring(i + 1, end), code: true))
          ..add(style.marker('`'));
        i = end + 1;
        continue;
      }
    }
    String? marker;
    for (final String m in _pairs) {
      if (s.startsWith(m, i)) {
        marker = m;
        break;
      }
    }
    if (marker != null) {
      final int end = _closing(s, i, marker);
      if (end > 0) {
        flush();
        out.add(style.marker(marker));
        _inline(s.substring(i + marker.length, end), style.add(marker), out);
        out.add(style.marker(marker));
        i = end + marker.length;
        continue;
      }
    }
    text.write(c);
    i++;
  }
  flush();
}

/// Index of the marker closing the one at [start], or -1.
int _closing(String s, int start, String marker) {
  final int from = start + marker.length;
  if (from >= s.length || s[from] == ' ' || s[from] == '\n') {
    return -1;
  }
  // `_` inside a word (snake_case) is not formatting.
  if (marker == '_' && start > 0 && _wordChar(s[start - 1])) {
    return -1;
  }
  int j = from;
  while (true) {
    j = s.indexOf(marker, j);
    if (j < 0) {
      return -1;
    }
    // `**` must not be read as two `*`, nor `__` as two `_`.
    final bool doubled =
        marker.length == 1 &&
        ((j + 1 < s.length && s[j + 1] == marker) ||
            (j > from && s[j - 1] == marker));
    final bool spaced = s[j - 1] == ' ' || s[j - 1] == '\n';
    final bool lineBreak = s.substring(from, j).contains('\n');
    final bool wordAfter =
        marker == '_' && j + 1 < s.length && _wordChar(s[j + 1]);
    if (j > from && !doubled && !spaced && !lineBreak && !wordAfter) {
      // "***x***": the bold pair closes on the last two stars, leaving
      // "*x*" (italic) inside.
      while (marker == '**' && j + 2 < s.length && s[j + 2] == '*') {
        j++;
      }
      return j;
    }
    if (lineBreak) {
      return -1;
    }
    j += marker.length;
  }
}

enum RichBlockType { paragraph, heading, quote, bullet, numbered, code, media }

@immutable
final class RichBlock {
  const RichBlock(
    this.type, {
    this.text = '',
    this.level = 0,
    this.number = 0,
    this.media = -1,
  });

  final RichBlockType type;

  /// Inline source (markers included) or code.
  final String text;

  /// Heading level 1..3.
  final int level;
  final int number;

  /// Index into the post's media for [RichBlockType.media].
  final int media;
}

final RegExp _mediaLine = RegExp(r'^\{\{media:(\d+)\}\}$');
final RegExp _heading = RegExp(r'^(#{1,3}) (.*)$');
final RegExp _numbered = RegExp(r'^(\d{1,3})\. (.*)$');

/// The placeholder line for the [index]-th media.
String mediaToken(int index) => '{{media:$index}}';

/// Media indices referenced in [source], in order.
List<int> referencedMedia(String source) => <int>[
  for (final String line in source.split('\n'))
    if (_mediaLine.firstMatch(line.trim()) case final RegExpMatch m)
      int.parse(m.group(1)!),
];

/// Splits a post into blocks.
List<RichBlock> parseBlocks(String source) {
  final List<RichBlock> out = <RichBlock>[];
  final List<String> lines = source.replaceAll('\r\n', '\n').split('\n');
  final List<String> para = <String>[];
  void flush() {
    if (para.isNotEmpty) {
      out.add(RichBlock(RichBlockType.paragraph, text: para.join('\n')));
      para.clear();
    }
  }

  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i];
    final String t = line.trim();
    if (t.startsWith('```')) {
      flush();
      final List<String> code = <String>[];
      int j = i + 1;
      while (j < lines.length && !lines[j].trim().startsWith('```')) {
        code.add(lines[j]);
        j++;
      }
      out.add(RichBlock(RichBlockType.code, text: code.join('\n')));
      i = j;
      continue;
    }
    final RegExpMatch? media = _mediaLine.firstMatch(t);
    if (media != null) {
      flush();
      out.add(
        RichBlock(RichBlockType.media, media: int.parse(media.group(1)!)),
      );
      continue;
    }
    final RegExpMatch? h = _heading.firstMatch(line);
    if (h != null) {
      flush();
      out.add(
        RichBlock(
          RichBlockType.heading,
          text: h.group(2)!,
          level: h.group(1)!.length,
        ),
      );
      continue;
    }
    if (line.startsWith('> ') || line == '>') {
      flush();
      out.add(
        RichBlock(
          RichBlockType.quote,
          text: line.length > 2 ? line.substring(2) : '',
        ),
      );
      continue;
    }
    if (line.startsWith('- ') || line.startsWith('* ')) {
      flush();
      out.add(RichBlock(RichBlockType.bullet, text: line.substring(2)));
      continue;
    }
    final RegExpMatch? n = _numbered.firstMatch(line);
    if (n != null) {
      flush();
      out.add(
        RichBlock(
          RichBlockType.numbered,
          text: n.group(2)!,
          number: int.parse(n.group(1)!),
        ),
      );
      continue;
    }
    if (t.isEmpty) {
      flush();
      continue;
    }
    para.add(line);
  }
  flush();
  return out;
}

/// Text without any formatting (previews, notifications).
String plainText(String source) {
  final List<String> parts = <String>[];
  for (final RichBlock b in parseBlocks(source)) {
    switch (b.type) {
      case RichBlockType.media:
        parts.add('[zdjęcie]');
      case RichBlockType.code:
        parts.add(b.text);
      case _:
        parts.add(visibleRuns(b.text).map((RichRun r) => r.text).join());
    }
  }
  return parts.join('\n');
}
