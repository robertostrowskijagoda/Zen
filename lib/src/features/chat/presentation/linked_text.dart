import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/feed/rich_text.dart';

/// Opens a link someone wrote (a message, a post, a comment) in the
/// browser; where that is not possible it is copied, and said so.
Future<void> openTextLink(BuildContext context, String link) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (await openWebLink(link, allowHttp: true)) {
    return;
  }
  await copyWithExpiry(link);
  messenger?.showSnackBar(
    SnackBar(content: Text(t('Skopiowano link: {link}', {'link': link}))),
  );
}

/// [text] with its web links ([kTextLinkPattern]) underlined in the accent
/// colour; a tap opens one ([openTextLink]). Plain [Text] when it has none.
class LinkedText extends StatefulWidget {
  const LinkedText(this.text, {required this.style, super.key});

  final String text;
  final TextStyle style;

  @override
  State<LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends State<LinkedText> {
  final List<TapGestureRecognizer> _recognizers = <TapGestureRecognizer>[];

  void _clear() {
    for (final TapGestureRecognizer r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String text = widget.text;
    final List<RegExpMatch> links = kTextLinkPattern.allMatches(text).toList();
    _clear();
    if (links.isEmpty) {
      return Text(text, style: widget.style);
    }
    final ZenColors zen = ZenColors.of(context);
    final TextStyle linkStyle = widget.style.copyWith(
      color: zen.accent,
      decoration: TextDecoration.underline,
      decorationColor: zen.accent,
    );
    final List<InlineSpan> spans = <InlineSpan>[];
    int at = 0;
    for (final RegExpMatch m in links) {
      if (m.start > at) {
        spans.add(TextSpan(text: text.substring(at, m.start)));
      }
      final String link = m.group(0)!;
      final TapGestureRecognizer tap = TapGestureRecognizer()
        ..onTap = () => unawaited(openTextLink(context, link));
      _recognizers.add(tap);
      spans.add(TextSpan(text: link, style: linkStyle, recognizer: tap));
      at = m.end;
    }
    if (at < text.length) {
      spans.add(TextSpan(text: text.substring(at)));
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
