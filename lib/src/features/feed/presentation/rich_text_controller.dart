import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/presentation/rich_post_body.dart';
import 'package:zen/src/features/feed/rich_text.dart';

/// A text field controller that shows Discord-style formatting live: bold
/// looks bold, markers stay visible but faint, headings are bigger.
class RichTextController extends TextEditingController {
  RichTextController({super.text});

  static final RegExp _heading = RegExp(r'^(#{1,3} )');
  static final RegExp _list = RegExp(r'^(- |\* |\d{1,3}\. |> )');
  static final RegExp _media = RegExp(r'^\{\{media:\d+\}\}$');

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final ZenColors zen = ZenColors.of(context);
    final TextStyle base = style ?? const TextStyle();
    final List<InlineSpan> out = <InlineSpan>[];
    final List<String> lines = text.split('\n');
    bool inCode = false;
    for (int li = 0; li < lines.length; li++) {
      final String line = lines[li];
      if (line.trim().startsWith('```')) {
        out.add(
          TextSpan(
            text: line,
            style: base.copyWith(color: zen.textMuted),
          ),
        );
        inCode = !inCode;
      } else if (inCode) {
        out.add(
          TextSpan(
            text: line,
            style: base.copyWith(
              fontFamily: zen.typeface.mono,
              fontFamilyFallback: zen.typeface.monoFallback,
              backgroundColor: zen.surfaceSunk,
            ),
          ),
        );
      } else if (_media.hasMatch(line.trim())) {
        out.add(
          TextSpan(
            text: line,
            style: base.copyWith(color: zen.textMuted),
          ),
        );
      } else {
        String rest = line;
        TextStyle lineStyle = base;
        final RegExpMatch? h = _heading.firstMatch(line);
        final RegExpMatch? l = _list.firstMatch(line);
        final String? prefix = h?.group(1) ?? l?.group(1);
        if (prefix != null) {
          out.add(
            TextSpan(
              text: prefix,
              style: base.copyWith(color: zen.textMuted),
            ),
          );
          rest = line.substring(prefix.length);
          if (h != null) {
            final int level = prefix.trim().length;
            lineStyle = base.copyWith(
              fontSize: (base.fontSize ?? 16) + (4 - level) * 2,
              fontWeight: FontWeight.w800,
            );
          } else if (prefix == '> ') {
            lineStyle = base.copyWith(color: zen.textSecondary);
          }
        }
        for (final RichRun r in parseInline(rest)) {
          out.add(
            TextSpan(text: r.text, style: richRunStyle(r, lineStyle, zen)),
          );
        }
      }
      if (li < lines.length - 1) {
        out.add(TextSpan(text: '\n', style: base));
      }
    }
    return TextSpan(style: base, children: out);
  }

  /// Wraps the selection in [marker] (or removes it if already wrapped);
  /// with nothing selected, inserts a pair and puts the cursor inside.
  void toggleWrap(String marker) {
    final TextSelection sel = selection.isValid
        ? selection
        : TextSelection.collapsed(offset: text.length);
    final int start = sel.start;
    final int end = sel.end;
    final int m = marker.length;
    if (start >= m &&
        end + m <= text.length &&
        text.substring(start - m, start) == marker &&
        text.substring(end, end + m) == marker) {
      value = TextEditingValue(
        text: text
            .replaceRange(end, end + m, '')
            .replaceRange(start - m, start, ''),
        selection: TextSelection(baseOffset: start - m, extentOffset: end - m),
      );
      return;
    }
    final String inner = text.substring(start, end);
    value = TextEditingValue(
      text: text.replaceRange(start, end, '$marker$inner$marker'),
      selection: inner.isEmpty
          ? TextSelection.collapsed(offset: start + m)
          : TextSelection(baseOffset: start + m, extentOffset: end + m),
    );
  }

  /// Adds (or removes) [prefix] at the start of every selected line.
  void toggleLinePrefix(String prefix) {
    final TextSelection sel = selection.isValid
        ? selection
        : TextSelection.collapsed(offset: text.length);
    final int lineStart = sel.start == 0
        ? 0
        : text.lastIndexOf('\n', sel.start - 1) + 1;
    int lineEnd = text.indexOf('\n', sel.end);
    if (lineEnd < 0) {
      lineEnd = text.length;
    }
    final List<String> lines = text.substring(lineStart, lineEnd).split('\n');
    final bool all = lines.every((String l) => l.startsWith(prefix));
    final List<String> changed = <String>[
      for (int i = 0; i < lines.length; i++)
        all
            ? lines[i].substring(prefix.length)
            : (prefix == '1. ' ? '${i + 1}. ' : prefix) +
                  lines[i].replaceFirst(_heading, '').replaceFirst(_list, ''),
    ];
    final String joined = changed.join('\n');
    value = TextEditingValue(
      text: text.replaceRange(lineStart, lineEnd, joined),
      selection: TextSelection.collapsed(offset: lineStart + joined.length),
    );
  }

  /// Wraps the selected lines in a code block.
  void toggleCodeBlock() {
    final TextSelection sel = selection.isValid
        ? selection
        : TextSelection.collapsed(offset: text.length);
    final String inner = text.substring(sel.start, sel.end);
    final String before = sel.start == 0 || text[sel.start - 1] == '\n'
        ? ''
        : '\n';
    final String block = '$before```\n$inner\n```\n';
    value = TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, block),
      selection: TextSelection.collapsed(
        offset: sel.start + before.length + 4 + inner.length,
      ),
    );
  }
}
