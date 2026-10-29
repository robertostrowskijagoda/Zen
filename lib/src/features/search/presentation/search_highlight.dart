import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/search/search_text.dart';

/// Marks the words of [query] in the texts below it that know how to
/// (chat bubbles, [CopyableText]): a search found this message.
class SearchHighlight extends InheritedWidget {
  const SearchHighlight({required this.query, required super.child, super.key});

  final SearchQuery query;

  static SearchQuery? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SearchHighlight>()?.query;

  @override
  bool updateShouldNotify(SearchHighlight oldWidget) =>
      oldWidget.query != query;
}

/// How a found word looks: a tinted background and heavier letters (not
/// by colour alone).
TextStyle searchMarkStyle(BuildContext context) {
  final ZenColors zen = ZenColors.of(context);
  return TextStyle(
    backgroundColor: zen.warning.withValues(alpha: 0.40),
    fontWeight: FontWeight.w800,
  );
}

/// [text] in pieces, the [ranges] in [mark].
List<InlineSpan> searchMarkedSpans(
  String text,
  List<SearchRange> ranges,
  TextStyle mark,
) {
  if (ranges.isEmpty) {
    return <InlineSpan>[TextSpan(text: text)];
  }
  final List<InlineSpan> spans = <InlineSpan>[];
  int at = 0;
  for (final SearchRange r in ranges) {
    final int start = r.start.clamp(at, text.length);
    final int end = r.end.clamp(start, text.length);
    if (start > at) {
      spans.add(TextSpan(text: text.substring(at, start)));
    }
    if (end > start) {
      spans.add(TextSpan(text: text.substring(start, end), style: mark));
    }
    at = end;
  }
  if (at < text.length) {
    spans.add(TextSpan(text: text.substring(at)));
  }
  return spans;
}

/// [text] with the words of [query] marked.
List<InlineSpan> searchMarked(
  BuildContext context,
  String text,
  SearchQuery query,
) => searchMarkedSpans(text, query.rangesIn(text), searchMarkStyle(context));
