import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/update/github_release.dart';

/// iPhone and iPad, next to the update steps and the install guide: Zen's
/// source added to SideStore, so that SideStore itself shows new versions
/// in "My Apps". The link is SideStore's documented one; the address can
/// always be copied for "Sources" → "+", and it is copied when the link
/// opens nothing.
class SideStoreSourceOption extends StatefulWidget {
  const SideStoreSourceOption({
    this.openLink = openSideStoreLink,
    this.copy = copyPublicText,
    super.key,
  });

  /// Opens [kSideStoreSourceLink] (false: nothing opened it).
  final Future<bool> Function(String link) openLink;

  /// Puts the source's address on the clipboard.
  final Future<void> Function(String text) copy;

  @override
  State<SideStoreSourceOption> createState() => _SideStoreSourceOptionState();
}

class _SideStoreSourceOptionState extends State<SideStoreSourceOption> {
  String? _message;

  Future<void> _add() async {
    if (await widget.openLink(kSideStoreSourceLink)) {
      _say(t('Otwarto SideStore. Jeśli zapyta, potwierdź dodanie źródła Zen.'));
      return;
    }
    await _copyAddress(
      t(
        'Nie udało się otworzyć SideStore. Skopiowano adres źródła: wklej go '
        'w SideStore w „Sources” → „+”.',
      ),
    );
  }

  Future<void> _copyAddress([String? message]) async {
    try {
      await widget.copy(kSideStoreSourceUrl);
    } on Object catch (error) {
      logZenWarning('Kopiowanie adresu źródła SideStore: $error');
    }
    _say(
      message ??
          t('Skopiowano adres źródła: {url}', {'url': kSideStoreSourceUrl}),
    );
  }

  void _say(String message) {
    if (mounted) {
      setState(() => _message = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final TextStyle style = TextStyle(
      color: zen.textSecondary,
      fontSize: 13,
      height: 1.35,
    );
    return Padding(
      key: const Key('sidestore-source'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t(
              'Dodaj źródło Zen do SideStore: nowe wersje pokażą się potem '
              'w SideStore w „My Apps”.',
            ),
            style: style,
          ),
          Wrap(
            spacing: 4,
            children: <Widget>[
              TextButton.icon(
                key: const Key('sidestore-source-add'),
                onPressed: () => unawaited(_add()),
                icon: const Icon(Icons.add_link_rounded, size: 18),
                label: Text(t('Dodaj źródło Zen do SideStore')),
              ),
              TextButton.icon(
                key: const Key('sidestore-source-copy'),
                onPressed: () => unawaited(_copyAddress()),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(t('Kopiuj adres źródła')),
              ),
            ],
          ),
          Text(
            t(
              'Jeśli przycisk nic nie robi: w SideStore otwórz „Sources”, '
              'stuknij „+” i wklej adres źródła.',
            ),
            key: const Key('sidestore-source-manual'),
            style: style,
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _message!,
                key: const Key('sidestore-source-message'),
                style: style.copyWith(color: zen.textPrimary),
              ),
            ),
        ],
      ),
    );
  }
}
