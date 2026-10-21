import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The kinds of block the legal documents use.
enum LegalBlockKind { heading, paragraph, bullet, numbered, rule, tableRow }

/// One block of a document: a heading (with its [level]), a paragraph, a
/// list item, a rule or a table row ([cells]).
@immutable
final class LegalBlock {
  const LegalBlock(
    this.kind, {
    this.text = '',
    this.level = 0,
    this.marker = '',
    this.cells = const <String>[],
    this.header = false,
  });

  final LegalBlockKind kind;
  final String text;

  /// Heading level (1–6), or the indent of a list item (0, 1, …).
  final int level;

  /// "1." of a numbered item.
  final String marker;

  final List<String> cells;

  /// The first row of a table.
  final bool header;
}

/// Splits the small subset of Markdown the documents are written in into
/// blocks: headings, paragraphs (lines joined), bullet and numbered items
/// (with their continuation lines), rules and table rows. The plain-text
/// licence notice comes out as paragraphs.
List<LegalBlock> parseLegalMarkdown(String source) {
  final List<LegalBlock> blocks = <LegalBlock>[];
  final StringBuffer paragraph = StringBuffer();
  LegalBlock? item;
  final StringBuffer itemText = StringBuffer();
  bool firstTableRow = true;

  void flush() {
    if (paragraph.isNotEmpty) {
      blocks.add(
        LegalBlock(LegalBlockKind.paragraph, text: paragraph.toString()),
      );
      paragraph.clear();
    }
    final LegalBlock? open = item;
    if (open != null) {
      blocks.add(
        LegalBlock(
          open.kind,
          text: itemText.toString(),
          level: open.level,
          marker: open.marker,
        ),
      );
      item = null;
      itemText.clear();
    }
  }

  void append(StringBuffer to, String text) {
    if (to.isNotEmpty) {
      to.write(' ');
    }
    to.write(text);
  }

  final RegExp heading = RegExp(r'^(#{1,6})\s+(.*)$');
  final RegExp bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$');
  final RegExp numbered = RegExp(r'^(\s*)(\d+[.)])\s+(.*)$');
  final RegExp rule = RegExp(r'^\s*(-{3,}|\*{3,}|_{3,}|={3,})\s*$');
  final RegExp tableRule = RegExp(r'^\s*\|?\s*:?-{2,}');

  for (final String raw in source.replaceAll('\r\n', '\n').split('\n')) {
    final String line = raw.trimRight();
    if (line.trim().isEmpty) {
      flush();
      firstTableRow = true;
      continue;
    }
    final RegExpMatch? h = heading.firstMatch(line);
    if (h != null) {
      flush();
      blocks.add(
        LegalBlock(
          LegalBlockKind.heading,
          text: h.group(2)!.replaceAll(RegExp(r'\s*#+\s*$'), '').trim(),
          level: h.group(1)!.length,
        ),
      );
      continue;
    }
    if (rule.hasMatch(line)) {
      flush();
      blocks.add(const LegalBlock(LegalBlockKind.rule));
      continue;
    }
    if (line.trimLeft().startsWith('|')) {
      flush();
      if (tableRule.hasMatch(line) && !line.contains(RegExp(r'[A-Za-z]'))) {
        continue;
      }
      String row = line.trim();
      row = row.substring(1);
      if (row.endsWith('|')) {
        row = row.substring(0, row.length - 1);
      }
      blocks.add(
        LegalBlock(
          LegalBlockKind.tableRow,
          cells: <String>[for (final String c in row.split('|')) c.trim()],
          header: firstTableRow,
        ),
      );
      firstTableRow = false;
      continue;
    }
    final RegExpMatch? b = bullet.firstMatch(line);
    final RegExpMatch? n = b == null ? numbered.firstMatch(line) : null;
    if (b != null || n != null) {
      flush();
      final int indent = (b ?? n)!.group(1)!.length ~/ 2;
      item = n == null
          ? LegalBlock(LegalBlockKind.bullet, level: indent)
          : LegalBlock(
              LegalBlockKind.numbered,
              level: indent,
              marker: n.group(2)!,
            );
      itemText.write(b != null ? b.group(2)! : n!.group(3)!);
      continue;
    }
    if (item != null && raw.startsWith(' ')) {
      append(itemText, line.trim());
      continue;
    }
    if (item != null) {
      flush();
    }
    append(paragraph, line.trim());
  }
  flush();
  return blocks;
}

/// A run of text with its inline style: bold, italic, code, or a link.
@immutable
final class LegalSpan {
  const LegalSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.link,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  /// Where the run leads (the Markdown target or a bare web address).
  final String? link;
}

/// Inline Markdown: `**bold**`, `*italic*` / `_italic_`, `` `code` ``,
/// `[text](target)` and bare `https://` addresses.
List<LegalSpan> parseLegalInline(String text) {
  final List<LegalSpan> out = <LegalSpan>[];
  final RegExp token = RegExp(
    r'\[([^\]]+)\]\(([^)\s]+)\)'
    r'|\*\*(.+?)\*\*'
    r'|`([^`]+)`'
    r'|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)'
    r'|(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)'
    r'|(https?://[^\s<>)\]]+[^\s<>)\].,;:!?])',
  );
  int at = 0;
  for (final RegExpMatch m in token.allMatches(text)) {
    if (m.start > at) {
      out.add(LegalSpan(text.substring(at, m.start)));
    }
    if (m.group(1) != null) {
      out.add(LegalSpan(m.group(1)!, link: m.group(2)));
    } else if (m.group(3) != null) {
      out.add(LegalSpan(m.group(3)!, bold: true));
    } else if (m.group(4) != null) {
      out.add(LegalSpan(m.group(4)!, code: true));
    } else if (m.group(5) != null) {
      out.add(LegalSpan(m.group(5)!, italic: true));
    } else if (m.group(6) != null) {
      out.add(LegalSpan(m.group(6)!, italic: true));
    } else {
      out.add(LegalSpan(m.group(7)!, link: m.group(7)));
    }
    at = m.end;
  }
  if (at < text.length) {
    out.add(LegalSpan(text.substring(at)));
  }
  return out;
}

/// Shows a document parsed by [parseLegalMarkdown]: selectable when it sits
/// in a [SelectionArea], links tappable ([onLink]).
class LegalMarkdownView extends StatefulWidget {
  const LegalMarkdownView({
    required this.source,
    required this.onLink,
    super.key,
  });

  final String source;
  final ValueChanged<String> onLink;

  @override
  State<LegalMarkdownView> createState() => _LegalMarkdownViewState();
}

class _LegalMarkdownViewState extends State<LegalMarkdownView> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];
  late List<LegalBlock> _blocks = parseLegalMarkdown(widget.source);

  @override
  void didUpdateWidget(LegalMarkdownView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _blocks = parseLegalMarkdown(widget.source);
    }
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  TextSpan _inline(String text, TextStyle base, ZenColors zen) {
    return TextSpan(
      style: base,
      children: <InlineSpan>[
        for (final LegalSpan s in parseLegalInline(text))
          TextSpan(
            text: s.text,
            style: TextStyle(
              fontWeight: s.bold ? FontWeight.w700 : null,
              fontStyle: s.italic ? FontStyle.italic : null,
              fontFamily: s.code
                  ? zen.mono(color: zen.textPrimary).fontFamily
                  : null,
              color: s.link != null ? zen.accent : null,
              decoration: s.link != null ? TextDecoration.underline : null,
              decorationColor: s.link != null ? zen.accent : null,
            ),
            recognizer: s.link == null ? null : _recognizer(s.link!),
          ),
      ],
    );
  }

  TapGestureRecognizer _recognizer(String link) {
    final TapGestureRecognizer r = TapGestureRecognizer()
      ..onTap = () => widget.onLink(link);
    _recognizers.add(r);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final ZenColors zen = ZenColors.of(context);
    final TextStyle body = TextStyle(
      color: zen.textSecondary,
      fontSize: 14.5,
      height: 1.5,
    );
    final List<Widget> children = <Widget>[];
    for (final LegalBlock b in _blocks) {
      switch (b.kind) {
        case LegalBlockKind.heading:
          children.add(
            Padding(
              padding: EdgeInsets.only(top: b.level <= 2 ? 20 : 14, bottom: 6),
              child: Text.rich(
                _inline(
                  b.text,
                  TextStyle(
                    color: zen.textPrimary,
                    fontSize: switch (b.level) {
                      1 => 22,
                      2 => 18,
                      _ => 16,
                    },
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                  zen,
                ),
              ),
            ),
          );
        case LegalBlockKind.paragraph:
          children.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text.rich(_inline(b.text, body, zen)),
            ),
          );
        case LegalBlockKind.bullet:
        case LegalBlockKind.numbered:
          children.add(
            Padding(
              padding: EdgeInsetsDirectional.only(
                start: 4 + 18.0 * b.level,
                bottom: 6,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: b.kind == LegalBlockKind.bullet ? 16 : 26,
                    child: Text(
                      b.kind == LegalBlockKind.bullet ? '•' : b.marker,
                      style: body,
                    ),
                  ),
                  Expanded(child: Text.rich(_inline(b.text, body, zen))),
                ],
              ),
            ),
          );
        case LegalBlockKind.rule:
          children.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, color: zen.outlineSoft),
            ),
          );
        case LegalBlockKind.tableRow:
          children.add(
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: b.header ? zen.surfaceSunk : zen.surface,
                borderRadius: context.zenRadius(12),
                border: Border.all(color: zen.outlineSoft),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int i = 0; i < b.cells.length; i++)
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                      child: Text.rich(
                        _inline(
                          b.cells[i],
                          i == 0 || b.header
                              ? body.copyWith(
                                  color: zen.textPrimary,
                                  fontWeight: FontWeight.w700,
                                )
                              : body,
                          zen,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
