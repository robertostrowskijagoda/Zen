import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/media/media_transfer.dart';

/// The largest picture taken from the keyboard or the clipboard.
const int kMaxKeyboardPictureBytes = 20 * 1024 * 1024;

/// A GIF (or a sticker, a picture) from the keyboard: a field to open the
/// keyboard's GIFs on and tap one (Android's rich content), or to paste one
/// into ("Wklej obrazek": iPhone keyboards copy GIFs to the clipboard).
/// The picture's bytes, or `null` when the person closed it.
Future<Uint8List?> showKeyboardPictureDialog(BuildContext context) =>
    showDialog<Uint8List>(
      context: context,
      builder: (BuildContext context) => const _KeyboardPictureDialog(),
    );

class _KeyboardPictureDialog extends StatefulWidget {
  const _KeyboardPictureDialog();

  @override
  State<_KeyboardPictureDialog> createState() => _KeyboardPictureDialogState();
}

class _KeyboardPictureDialogState extends State<_KeyboardPictureDialog> {
  final TextEditingController _field = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _take(Uint8List? data) {
    if (data == null || data.isEmpty) {
      setState(() => _error = t('Klawiatura nie przekazała obrazka.'));
      return;
    }
    if (data.length > kMaxKeyboardPictureBytes) {
      setState(
        () => _error = t(
          'To zdjęcie jest za duże albo nie da się go otworzyć (najwyżej 20 MB).',
        ),
      );
      return;
    }
    Navigator.of(context).pop(data);
  }

  Future<void> _pasted(List<TransferItem> items) async {
    for (final TransferItem item in items) {
      Uint8List? bytes = item.bytes;
      final String? path = item.path;
      if (bytes == null && path != null) {
        try {
          final File file = File(path);
          bytes = await file.length() > kMaxKeyboardPictureBytes
              ? null
              : await file.readAsBytes();
        } on FileSystemException {
          bytes = null;
        }
      }
      if (!mounted) {
        return;
      }
      _take(bytes);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      key: const Key('keyboard-picture-dialog'),
      title: Text(t('GIF z klawiatury')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t(
                'Otwórz w klawiaturze GIF-y i stuknij jeden. Na iPhonie '
                'skopiuj go w klawiaturze, przytrzymaj pole i wybierz '
                '„Wklej obrazek”.',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('keyboard-picture-field'),
              controller: _field,
              autofocus: true,
              contentInsertionConfiguration: ContentInsertionConfiguration(
                onContentInserted: (KeyboardInsertedContent content) =>
                    _take(content.data),
              ),
              contextMenuBuilder: picturePasteMenu(_pasted),
              decoration: InputDecoration(
                hintText: t('Tutaj wstaw GIF'),
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
      ],
    );
  }
}
