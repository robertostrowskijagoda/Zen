import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';

/// Text that can be copied from a long-press / right-click menu. Used for
/// chat bubbles and comments. With [onReport] the menu also has "Zgłoś"
/// — for what others wrote.
class CopyableText extends StatelessWidget {
  const CopyableText(
    this.text, {
    required this.style,
    this.onReport,
    super.key,
  });

  final String text;
  final TextStyle style;
  final VoidCallback? onReport;

  Future<void> _menu(BuildContext context, Offset at) async {
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final String? choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          key: const Key('bubble-copy'),
          value: 'copy',
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.copy_rounded),
            title: Text(t('Kopiuj')),
          ),
        ),
        if (onReport != null)
          PopupMenuItem<String>(
            key: const Key('bubble-report'),
            value: 'report',
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.flag_outlined),
              title: Text(t('Zgłoś')),
            ),
          ),
      ],
    );
    if (choice == 'copy') {
      // Like every other copy from the app: cleared from
      // the clipboard after a minute, unless something else was copied.
      await copyWithExpiry(text);
    } else if (choice == 'report') {
      onReport?.call();
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPressStart: (LongPressStartDetails d) =>
        unawaited(_menu(context, d.globalPosition)),
    onSecondaryTapDown: (TapDownDetails d) =>
        unawaited(_menu(context, d.globalPosition)),
    child: Text(text, style: style),
  );
}
