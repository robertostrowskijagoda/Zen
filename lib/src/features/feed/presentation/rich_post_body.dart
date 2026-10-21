import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/feed/rich_text.dart';

/// Style of one run, shared by the post view and the editor.
TextStyle richRunStyle(
  RichRun r,
  TextStyle base,
  ZenColors zen, {
  bool revealed = true,
}) {
  TextStyle s = base.copyWith(
    fontWeight: r.bold ? FontWeight.w800 : base.fontWeight,
    fontStyle: r.italic ? FontStyle.italic : base.fontStyle,
    decoration: TextDecoration.combine(<TextDecoration>[
      if (r.underline || r.link) TextDecoration.underline,
      if (r.strike) TextDecoration.lineThrough,
    ]),
  );
  if (r.code) {
    s = s.copyWith(
      fontFamily: zen.typeface.mono,
      fontFamilyFallback: zen.typeface.monoFallback,
      fontSize: (base.fontSize ?? 15) * 0.9,
      backgroundColor: zen.surfaceSunk,
    );
  }
  if (r.link) {
    s = s.copyWith(color: zen.accent);
  }
  if (r.spoiler && !revealed) {
    s = s.copyWith(
      color: zen.textSecondary,
      backgroundColor: zen.textSecondary,
    );
  } else if (r.spoiler) {
    s = s.copyWith(backgroundColor: zen.surfaceSunk);
  }
  if (r.marker) {
    s = s.copyWith(color: zen.textMuted, fontWeight: FontWeight.w400);
  }
  return s;
}

/// A post's text with its formatting, and its photos and videos in the
/// places the author put them. Media the text does not mention are
/// left to the caller (shown after the text).
class RichPostBody extends StatefulWidget {
  const RichPostBody({
    required this.source,
    required this.mediaBuilder,
    required this.mediaCount,
    this.fontSize = 15,
    super.key,
  });

  final String source;

  /// Builds the [index]-th media of the post.
  final Widget Function(BuildContext context, int index) mediaBuilder;
  final int mediaCount;
  final double fontSize;

  @override
  State<RichPostBody> createState() => _RichPostBodyState();
}

class _RichPostBodyState extends State<RichPostBody> {
  final Set<int> _revealed = <int>{};
  final List<GestureRecognizer> _recognizers = <GestureRecognizer>[];

  @override
  void dispose() {
    for (final GestureRecognizer r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  InlineSpan _inline(String source, TextStyle base, ZenColors zen, int block) {
    final List<RichRun> runs = visibleRuns(source);
    return TextSpan(
      children: <InlineSpan>[
        for (int i = 0; i < runs.length; i++)
          _run(runs[i], base, zen, block * 1000 + i),
      ],
    );
  }

  InlineSpan _run(RichRun r, TextStyle base, ZenColors zen, int id) {
    GestureRecognizer? tap;
    if (r.spoiler && !_revealed.contains(id)) {
      tap = TapGestureRecognizer()
        ..onTap = () => setState(() => _revealed.add(id));
    } else if (r.link) {
      tap = TapGestureRecognizer()
        ..onTap = () {
          // No browser jumps from a post: the link is copied, the user
          // decides where to open it.
          unawaited(copyWithExpiry(r.text));
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(t('Skopiowano link: {link}', {'link': r.text})),
            ),
          );
        };
    }
    if (tap != null) {
      _recognizers.add(tap);
    }
    return TextSpan(
      text: r.text,
      recognizer: tap,
      style: richRunStyle(r, base, zen, revealed: _revealed.contains(id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    for (final GestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final ZenColors zen = ZenColors.of(context);
    final TextStyle base = TextStyle(
      fontSize: widget.fontSize,
      height: 1.45,
      color: zen.textPrimary,
    );
    final List<RichBlock> blocks = parseBlocks(widget.source);
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < blocks.length; i++) {
      final RichBlock b = blocks[i];
      final Widget w = switch (b.type) {
        RichBlockType.paragraph => SelectableText.rich(
          TextSpan(children: <InlineSpan>[_inline(b.text, base, zen, i)]),
        ),
        RichBlockType.heading => SelectableText.rich(
          TextSpan(
            children: <InlineSpan>[
              _inline(
                b.text,
                base.copyWith(
                  fontSize: widget.fontSize + (4 - b.level) * 3,
                  fontWeight: FontWeight.w800,
                  height: 1.25,
                ),
                zen,
                i,
              ),
            ],
          ),
        ),
        RichBlockType.quote => Container(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          decoration: BoxDecoration(
            color: zen.accent.withValues(alpha: 0.06),
            border: Border(
              left: BorderSide(
                color: zen.accent.withValues(alpha: 0.6),
                width: 3,
              ),
            ),
          ),
          child: SelectableText.rich(
            TextSpan(
              children: <InlineSpan>[
                _inline(
                  b.text,
                  base.copyWith(color: zen.textSecondary),
                  zen,
                  i,
                ),
              ],
            ),
          ),
        ),
        RichBlockType.bullet || RichBlockType.numbered => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 22,
              child: Text(
                b.type == RichBlockType.bullet ? '•' : '${b.number}.',
                style: base.copyWith(color: zen.textSecondary),
              ),
            ),
            Expanded(
              child: SelectableText.rich(
                TextSpan(children: <InlineSpan>[_inline(b.text, base, zen, i)]),
              ),
            ),
          ],
        ),
        RichBlockType.code => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: zen.surfaceSunk,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: zen.outlineSoft),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              b.text,
              style: TextStyle(
                fontFamily: zen.typeface.mono,
                fontFamilyFallback: zen.typeface.monoFallback,
                fontSize: widget.fontSize * 0.85,
                color: zen.textPrimary,
                height: 1.4,
              ),
            ),
          ),
        ),
        RichBlockType.media =>
          b.media >= 0 && b.media < widget.mediaCount
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: widget.mediaBuilder(context, b.media),
                )
              : const SizedBox.shrink(),
      };
      final bool tight =
          i > 0 &&
          (b.type == RichBlockType.bullet ||
              b.type == RichBlockType.numbered) &&
          blocks[i - 1].type == b.type;
      children.add(
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : (tight ? 2 : 8)),
          child: w,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
