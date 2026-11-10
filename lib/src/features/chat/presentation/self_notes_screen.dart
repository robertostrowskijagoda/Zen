import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/chat/self_notes.dart';

/// "Notatki dla siebie": a chat with oneself, the same on every device of
/// the account. A long press copies or deletes a note.
class SelfNotesScreen extends ConsumerStatefulWidget {
  const SelfNotesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const SelfNotesScreen(),
    ),
  );

  @override
  ConsumerState<SelfNotesScreen> createState() => _SelfNotesScreenState();
}

class _SelfNotesScreenState extends ConsumerState<SelfNotesScreen> {
  final TextEditingController _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(selfNotesServiceProvider).load());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String text = _text.text;
    if (text.trim().isEmpty) {
      return;
    }
    _text.clear();
    await ref.read(selfNotesServiceProvider).add(text);
  }

  Future<void> _actions(SelfNote note) async {
    final String? action = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const Key('self-note-copy'),
              leading: const Icon(Icons.copy_rounded),
              title: Text(t('Kopiuj')),
              onTap: () => Navigator.of(context).pop('copy'),
            ),
            ListTile(
              key: const Key('self-note-delete'),
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(t('Usuń')),
              onTap: () => Navigator.of(context).pop('delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'copy') {
      // Notes to oneself hold what one keeps from others (codes,
      // passwords): copied like any secret, gone after a minute and kept
      // out of the clipboard history.
      if (!await copyWithExpiry(note.text) && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Nie udało się. Spróbuj jeszcze raz.'))),
        );
      }
    } else if (action == 'delete') {
      await ref.read(selfNotesServiceProvider).delete(note.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final SelfNotesService service = ref.watch(selfNotesServiceProvider);
    return Scaffold(
      appBar: AppBar(title: Text(t('Notatki dla siebie'))),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListenableBuilder(
                listenable: service,
                builder: (BuildContext context, Widget? _) {
                  final List<SelfNote> notes = service.notes;
                  if (notes.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(24),
                      child: ZenInfo(
                        key: const Key('self-notes-empty'),
                        icon: Icons.sticky_note_2_outlined,
                        text: t(
                          'Zapisuj tu rzeczy dla siebie: listy, linki, '
                          'pomysły. Widzisz je na każdym urządzeniu tego '
                          'konta i nikt poza Tobą.',
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    key: const Key('self-notes-list'),
                    reverse: true,
                    padding: const EdgeInsets.all(12),
                    itemCount: notes.length,
                    itemBuilder: (BuildContext context, int i) {
                      final SelfNote note = notes[notes.length - 1 - i];
                      return Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: GestureDetector(
                          key: Key('self-note-${note.id}'),
                          onLongPress: () => unawaited(_actions(note)),
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            constraints: const BoxConstraints(maxWidth: 520),
                            decoration: BoxDecoration(
                              color: zen.accent.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: SelectableText(note.text),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      key: const Key('self-notes-input'),
                      controller: _text,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: kMaxSelfNoteChars,
                      decoration: InputDecoration(
                        hintText: t('Notatka…'),
                        counterText: '',
                        border: const OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => unawaited(_send()),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const Key('self-notes-send'),
                    tooltip: t('Zapisz'),
                    onPressed: () => unawaited(_send()),
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
