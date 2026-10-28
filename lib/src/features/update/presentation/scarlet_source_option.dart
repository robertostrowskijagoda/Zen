import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/update/github_release.dart';

/// iPhone and iPad, a quieter way next to the numbered update steps: Zen's
/// source added to Scarlet, so that new versions are installed in Scarlet
/// itself. Scarlet does not document the link that adds a source, so the
/// address can always be copied and the step by hand ("Add Repo") is
/// always said; when the link opens nothing, the address is copied.
class ScarletSourceOption extends StatefulWidget {
  const ScarletSourceOption({
    this.openLink = openScarletSourceLink,
    this.copy = copyPublicText,
    super.key,
  });

  /// Opens [kScarletSourceLink] (false: nothing opened it).
  final Future<bool> Function(String link) openLink;

  /// Puts the source's address on the clipboard.
  final Future<void> Function(String text) copy;

  @override
  State<ScarletSourceOption> createState() => _ScarletSourceOptionState();
}

class _ScarletSourceOptionState extends State<ScarletSourceOption> {
  String? _message;

  Future<void> _add() async {
    if (await widget.openLink(kScarletSourceLink)) {
      _say(
        t(
          'Otwarto Scarlet. Jeśli nie widać tam źródła Zen, dodaj je '
          'ręcznie.',
        ),
      );
      return;
    }
    await _copyAddress(
      t(
        'Nie udało się otworzyć Scarlet. Skopiowano adres źródła: wklej go '
        'w Scarlet w „Add Repo”.',
      ),
    );
  }

  Future<void> _copyAddress([String? message]) async {
    try {
      await widget.copy(kScarletSourceUrl);
    } on Object catch (error) {
      logZenWarning('Kopiowanie adresu źródła Scarlet: $error');
    }
    _say(
      message ??
          t('Skopiowano adres źródła: {url}', {'url': kScarletSourceUrl}),
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
      key: const Key('scarlet-source'),
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t(
              'Albo dodaj źródło Zen do Scarlet: nowe wersje zainstalujesz '
              'potem w samym Scarlet, bez pobierania pliku w Safari.',
            ),
            style: style,
          ),
          Wrap(
            spacing: 4,
            children: <Widget>[
              TextButton.icon(
                key: const Key('scarlet-source-add'),
                onPressed: () => unawaited(_add()),
                icon: const Icon(Icons.add_link_rounded, size: 18),
                label: Text(t('Dodaj źródło Zen do Scarlet')),
              ),
              TextButton.icon(
                key: const Key('scarlet-source-copy'),
                onPressed: () => unawaited(_copyAddress()),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(t('Kopiuj adres źródła')),
              ),
            ],
          ),
          Text(
            t(
              'Jeśli przycisk nic nie robi: w Scarlet przytrzymaj strzałkę '
              'pobierania, wybierz „Add Repo” i wklej adres źródła.',
            ),
            key: const Key('scarlet-source-manual'),
            style: style,
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _message!,
                key: const Key('scarlet-source-message'),
                style: style.copyWith(color: zen.textPrimary),
              ),
            ),
        ],
      ),
    );
  }
}
