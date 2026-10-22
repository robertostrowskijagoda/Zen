import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/meet_thread.dart';

/// The small chat about one thing (a circle's dinner, an accepted request
/// for food): a bottom sheet with the messages and a field to write, like
/// the chat about an invitation among neighbours.
Future<void> showMeetThreadSheet(
  BuildContext context, {
  required String title,
  required Listenable listenable,
  required List<MeetThreadMessage> Function() messages,
  required String Function(String address) nameOf,
  required Future<bool> Function(String text) send,
  String? empty,
  VoidCallback? onSeen,
}) async {
  onSeen?.call();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => _ThreadSheet(
      title: title,
      listenable: listenable,
      messages: messages,
      nameOf: nameOf,
      send: send,
      empty: empty,
      onSeen: onSeen,
    ),
  );
}

class _ThreadSheet extends StatefulWidget {
  const _ThreadSheet({
    required this.title,
    required this.listenable,
    required this.messages,
    required this.nameOf,
    required this.send,
    this.empty,
    this.onSeen,
  });

  final String title;
  final Listenable listenable;
  final List<MeetThreadMessage> Function() messages;
  final String Function(String address) nameOf;
  final Future<bool> Function(String text) send;
  final String? empty;
  final VoidCallback? onSeen;

  @override
  State<_ThreadSheet> createState() => _ThreadSheetState();
}

class _ThreadSheetState extends State<_ThreadSheet> {
  final TextEditingController _input = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String text = _input.text;
    if (text.trim().isEmpty || _sending) {
      return;
    }
    setState(() => _sending = true);
    final bool ok = await widget.send(text);
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    if (ok) {
      _input.clear();
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('Nie udało się wysłać.'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: ListenableBuilder(
        listenable: widget.listenable,
        builder: (BuildContext context, Widget? _) {
          final List<MeetThreadMessage> thread = widget.messages();
          // Whatever came while the sheet is open counts as read.
          if (thread.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => widget.onSeen?.call(),
            );
          }
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.7,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (thread.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      widget.empty ?? t('Napiszcie, jeśli trzeba coś ustalić.'),
                      style: TextStyle(color: zen.textSecondary),
                    ),
                  )
                else
                  Flexible(
                    child: SelectionArea(
                      child: ListView(
                        key: const Key('meet-thread-list'),
                        shrinkWrap: true,
                        reverse: true,
                        children: <Widget>[
                          for (final MeetThreadMessage m in thread.reversed)
                            _Bubble(
                              message: m,
                              who: m.mine ? t('Ty') : widget.nameOf(m.from),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('meet-thread-input'),
                  controller: _input,
                  maxLength: kMeetThreadMaxText,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  onSubmitted: (_) => unawaited(_send()),
                  decoration: InputDecoration(
                    hintText: t('Napisz…'),
                    suffixIcon: IconButton(
                      key: const Key('meet-thread-send'),
                      tooltip: t('Wyślij'),
                      icon: const Icon(Icons.send_rounded),
                      onPressed: _sending ? null : () => unawaited(_send()),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.who});

  final MeetThreadMessage message;
  final String who;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool mine = message.mine;
    return Align(
      alignment: mine
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: mine ? zen.accentSoft : zen.surfaceSunk,
            borderRadius: context.zenRadius(14),
            border: Border.all(color: zen.outlineSoft),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '$who · ${ZenFormat.time(DateTime.fromMillisecondsSinceEpoch(message.at))}',
                style: TextStyle(color: zen.textMuted, fontSize: 11.5),
              ),
              const SizedBox(height: 2),
              Text(
                message.text,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 14,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
