import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/account/presentation/account_copy_common.dart'
    show unlockAccountKey;
import 'package:zen/src/features/feed/presentation/feed_screen.dart'
    show readableInsets;
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_parts.dart';
import 'package:zen/src/features/pebbles/pebble_service.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_detail_screen.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

/// "Stwórz kamyczek": the editor, then a name and a note, then publishing
/// (signed with the account key; keepers are drawn) and the stone's screen
/// with its sticker.
Future<void> startPebbleCreation(BuildContext context, WidgetRef ref) async {
  if (ref.read(pebbleServiceProvider) == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          t('Kamyczki będą dostępne, gdy Zen skończy się uruchamiać.'),
        ),
      ),
    );
    return;
  }
  final PebbleEditorResult? made = await PebbleEditorScreen.open(context);
  if (made == null || !context.mounted) {
    return;
  }
  final (Uint8List design, PebbleCardLook look, Uint8List thumbnail) = made;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          PebblePublishScreen(design: design, look: look, thumbnail: thumbnail),
    ),
  );
}

/// The name and the note of a painted stone, then "Opublikuj".
class PebblePublishScreen extends ConsumerStatefulWidget {
  const PebblePublishScreen({
    required this.design,
    required this.look,
    required this.thumbnail,
    super.key,
  });

  final Uint8List design;
  final PebbleCardLook look;
  final Uint8List thumbnail;

  @override
  ConsumerState<PebblePublishScreen> createState() =>
      _PebblePublishScreenState();
}

class _PebblePublishScreenState extends ConsumerState<PebblePublishScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _note = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final PebbleService? service = ref.read(pebbleServiceProvider);
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    if (service == null || node == null) {
      return;
    }
    if (_name.text.trim().isEmpty) {
      setState(() => _error = t('Nadaj kamyczkowi nazwę.'));
      return;
    }
    if (!await unlockAccountKey(
      context,
      node,
      t('Podpisanie kamyczka'),
      wrong: () => setState(() => _error = t('Złe hasło konta.')),
    )) {
      return;
    }
    final key = node.identity.accountKey;
    if (key == null || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final PebbleEntry e = await service.create(
        key: key,
        design: widget.design,
        look: widget.look,
        thumbnail: widget.thumbnail,
        name: _name.text,
        note: _note.text,
        authorName: ref.read(userProfileControllerProvider).displayName,
      );
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              PebbleDetailScreen(card: e.card, justPublished: true),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = t('Nie udało się opublikować kamyczka: {error}', {
            'error': error,
          });
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String author = ref.watch(
      userProfileControllerProvider.select((p) => p.displayName),
    );
    final bool thumbnailFits = pebbleThumbnailFits(
      name: _name.text,
      note: _note.text,
      authorName: author,
    );
    final PebbleCardText fitted = fitPebbleCardText(
      name: _name.text,
      note: _note.text,
      authorName: author,
      thumbnail: widget.thumbnail,
    );
    final int used = pebbleCardSize(
      nameBytes: utf8.encode(fitted.name).length,
      noteBytes: utf8.encode(fitted.note).length,
      authorBytes: utf8.encode(fitted.authorName).length,
      thumbnail: fitted.thumbnail != null,
    );
    return Scaffold(
      key: const Key('pebble-publish-screen'),
      appBar: ZenSectionBar(title: t('Nowy kamyczek')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: readableInsets(context, bottom: 32),
          children: <Widget>[
            Center(
              child: PebbleView(
                design: widget.design,
                card: PebbleCard.preview(
                  look: widget.look,
                  thumbnail: widget.thumbnail,
                  name: _name.text,
                  note: _note.text,
                  authorName: author,
                ),
                size: 200,
                interactive: true,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('pebble-publish-name'),
              controller: _name,
              maxLength: kPebbleNameMaxChars,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t('Nazwa'),
                hintText: t('np. Biedronka'),
                prefixIcon: const Icon(Icons.label_outline_rounded),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('pebble-publish-note'),
              controller: _note,
              maxLength: kPebbleNoteMaxChars,
              minLines: 1,
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t('Notka (opcjonalnie)'),
                hintText: t('np. niedaleko Wisły w Warszawie'),
                prefixIcon: const Icon(Icons.sticky_note_2_outlined),
              ),
            ),
            Text(
              t('Kod QR: {used} z {max} bajtów', <String, Object?>{
                'used': used,
                'max': kPebbleCardMaxBytes,
              }),
              key: const Key('pebble-publish-size'),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
            if (fitted.note != _note.text.trim())
              Text(
                t('Notka zostanie skrócona do: „{note}”', <String, Object?>{
                  'note': fitted.note,
                }),
                key: const Key('pebble-publish-cut'),
                style: TextStyle(color: zen.danger, fontSize: 12.5),
              ),
            if (!thumbnailFits)
              ZenInfo(
                key: const Key('pebble-publish-long'),
                icon: Icons.qr_code_2_rounded,
                text: t(
                  'Przy tak długiej notce podgląd malunku nie zmieści się w '
                  'kodzie QR. Strona pokaże kamyczek w jego kolorach.',
                ),
              ),
            const SizedBox(height: 8),
            Text(
              t(
                'Kamyczka nie da się potem zmienić. Poprosimy kilku znajomych, '
                'żeby go przechowali, gdy Twój telefon będzie poza siecią.',
              ),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: zen.danger)),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('pebble-publish-button'),
              onPressed: _busy ? null : () => unawaited(_publish()),
              icon: const Icon(Icons.publish_rounded),
              label: Text(t('Opublikuj')),
            ),
          ],
        ),
      ),
    );
  }
}
