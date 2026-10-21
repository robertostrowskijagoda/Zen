import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/update/store_build.dart';

/// "Podaj dalej" in the store build: a link instead of the APK.
Future<void> showStoreShareDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      key: const Key('store-share-dialog'),
      icon: const Icon(Icons.volunteer_activism_rounded),
      title: Text(t('Podaj Zen dalej')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t(
              'Wyślij znajomemu ten link. Znajdzie tam Zen w swoim sklepie '
              'z aplikacjami.',
            ),
          ),
          const SizedBox(height: 12),
          const SelectableText(
            kStoreShareUrl,
            key: Key('store-share-url'),
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: Text(t('Zamknij')),
        ),
        FilledButton.icon(
          key: const Key('store-share-copy'),
          onPressed: () async {
            await Clipboard.setData(const ClipboardData(text: kStoreShareUrl));
            if (!dialog.mounted) {
              return;
            }
            final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
              dialog,
            );
            Navigator.of(dialog).pop();
            messenger?.showSnackBar(
              SnackBar(
                content: Text(
                  t('Skopiowano link: {link}', {'link': kStoreShareUrl}),
                ),
              ),
            );
          },
          icon: const Icon(Icons.copy_rounded),
          label: Text(t('Kopiuj')),
        ),
      ],
    ),
  );
}
