import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/file_picking.dart';
import 'package:zen/src/features/passwords/password_csv_import.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_widgets.dart';

/// A password export the person picked: its bytes, or that it is larger
/// than [kMaxPasswordCsvBytes] (then nothing of it was read).
@immutable
final class PickedPasswordFile {
  const PickedPasswordFile({this.bytes, this.tooLarge = false});

  final Uint8List? bytes;
  final bool tooLarge;
}

/// Lets the person pick a password export; null when they closed the
/// picker. Replaced in tests.
typedef PasswordFilePicker = Future<PickedPasswordFile?> Function();

final Provider<PasswordFilePicker> passwordFilePickerProvider =
    Provider<PasswordFilePicker>((Ref ref) => pickPasswordFile);

/// The project's file picker, then the file read whole. Where the picker
/// hands over a copy of the file in the app's cache (Android, iOS), the
/// copy is deleted at once ([_deletePickerCopy]).
Future<PickedPasswordFile?> pickPasswordFile() async {
  final String? path = await pickOnePath(
    dialogTitle: t('Importuj z pliku CSV'),
  );
  if (path == null) {
    return null;
  }
  try {
    final File file = File(path);
    if (await file.length() > kMaxPasswordCsvBytes) {
      return const PickedPasswordFile(tooLarge: true);
    }
    return PickedPasswordFile(bytes: await file.readAsBytes());
  } finally {
    await _deletePickerCopy(path);
  }
}

/// Deletes [path] when it is the picker's own copy in the app's cache:
/// an export holds the passwords in the clear, and the cache is not
/// emptied on its own. A file anywhere else is the person's and stays
/// (they are told to delete it).
Future<void> _deletePickerCopy(String path) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return;
  }
  try {
    final String cache = (await getTemporaryDirectory()).absolute.path;
    if (File(
      path,
    ).absolute.path.startsWith('$cache${Platform.pathSeparator}')) {
      await File(path).delete();
    }
  } on Object catch (error) {
    logZenWarning(
      'The picked copy of a password file was not deleted: '
      '${error.runtimeType}',
    );
  }
}

/// "Importuj z pliku CSV": a word first on what such a file is (the
/// passwords in the clear, to delete afterwards), the picker, the import
/// and what it did. The file's bytes are overwritten once read
/// ([PasswordVaultService.importCsv]); nothing of the file is kept.
Future<void> importPasswordFile(BuildContext context, WidgetRef ref) async {
  final PasswordVaultService vault = ref.read(passwordVaultServiceProvider);
  final PasswordFilePicker pick = ref.read(passwordFilePickerProvider);
  final bool? go = await showDialog<bool>(
    context: context,
    routeSettings: const RouteSettings(name: kPasswordVaultRouteName),
    builder: (BuildContext context) => AlertDialog(
      scrollable: true,
      key: const Key('password-import-warning'),
      title: Text(t('Importuj z pliku CSV')),
      content: Text(
        t(
          'Wyeksportuj hasła z przeglądarki albo menedżera haseł do pliku '
          'CSV i wybierz go tutaj. Hasła są w nim zapisane jawnie: po '
          'imporcie usuń ten plik.',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('password-import-pick'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t('Wybierz plik')),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) {
    return;
  }
  final PickedPasswordFile? picked;
  try {
    picked = await pick();
  } on Object catch (error) {
    logZenWarning('The password file was not read: ${error.runtimeType}');
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text(t('Nie udało się. Spróbuj jeszcze raz.'))),
      );
    }
    return;
  }
  if (picked == null || !context.mounted) {
    picked?.bytes?.fillRange(0, picked.bytes!.length, 0);
    return;
  }
  PasswordImportReport? report;
  final Uint8List? bytes = picked.bytes;
  if (picked.tooLarge || bytes == null) {
    report = const PasswordImportReport(error: PasswordCsvError.tooLarge);
  } else {
    final bool ok = await runPasswordAction(context, () async {
      report = await vault.importCsv(bytes);
    });
    if (!ok) {
      return;
    }
  }
  if (!context.mounted) {
    return;
  }
  await showDialog<void>(
    context: context,
    routeSettings: const RouteSettings(name: kPasswordVaultRouteName),
    builder: (BuildContext context) =>
        PasswordImportReportDialog(report: report!),
  );
}

/// What an import did, in words: rows read, passwords added, rows left out
/// and why; or why the file was not taken.
class PasswordImportReportDialog extends StatelessWidget {
  const PasswordImportReportDialog({required this.report, super.key});

  final PasswordImportReport report;

  static String _error(PasswordCsvError error) => switch (error) {
    PasswordCsvError.tooLarge => t('Plik jest za duży (najwyżej 8 MB).'),
    PasswordCsvError.encoding => t(
      'Plik nie jest zapisany w UTF-8. Wyeksportuj go jeszcze raz.',
    ),
    PasswordCsvError.unknownLayout => t(
      'Nie rozpoznano pliku. Potrzebna jest kolumna z hasłem i z nazwą albo '
      'adresem.',
    ),
  };

  static String _skip(PasswordImportSkip why, int n) {
    final Map<String, Object?> v = <String, Object?>{'n': n};
    return switch (why) {
      PasswordImportSkip.noPassword => t('Bez hasła: {n}', v),
      PasswordImportSkip.noName => t('Bez nazwy i adresu: {n}', v),
      PasswordImportSkip.notLogin => t('Nie loginy (karty, notatki): {n}', v),
      PasswordImportSkip.deleted => t('Z kosza: {n}', v),
      PasswordImportSkip.archived => t('Zarchiwizowane: {n}', v),
      PasswordImportSkip.tooLong => t('Za długie pola: {n}', v),
      PasswordImportSkip.malformed => t('Uszkodzone wiersze: {n}', v),
      PasswordImportSkip.duplicate => t('Już były w Zen: {n}', v),
      PasswordImportSkip.full => t('Brak miejsca: {n}', v),
      PasswordImportSkip.tooMany => t('Ponad 10 000 wierszy: {n}', v),
    };
  }

  /// Where the damaged rows are, in words: the lines of each (the first
  /// few), and from which line on the file could not be read at all.
  static String? _damage(List<PasswordCsvDamage> damaged) {
    if (damaged.isEmpty) {
      return null;
    }
    const int shown = 5;
    final List<String> lines = <String>[
      for (final PasswordCsvDamage d in damaged.take(shown))
        if (d.to != null) d.to == d.from ? '${d.from}' : '${d.from}–${d.to}',
    ];
    final List<String> parts = <String>[
      if (lines.isNotEmpty)
        t('Wiersze pliku: {lines}{more}', <String, Object?>{
          'lines': lines.join(', '),
          'more': damaged.length > shown ? ', …' : '',
        }),
      if (damaged.last.to == null)
        t(
          'Pliku nie dało się odczytać od wiersza {line} do końca.',
          <String, Object?>{'line': damaged.last.from},
        ),
    ];
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PasswordCsvError? error = report.error;
    final TextStyle line = TextStyle(color: zen.textPrimary, height: 1.4);
    final TextStyle reason = TextStyle(color: zen.textSecondary, height: 1.4);
    return AlertDialog(
      scrollable: true,
      key: const Key('password-import-report'),
      title: Text(
        error == null ? t('Import zakończony') : t('Nie zaimportowano'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (error != null)
            Text(
              _error(error),
              key: const Key('password-import-error'),
              style: line,
            )
          else ...<Widget>[
            Text(
              tn(
                report.read,
                one: 'Odczytano {n} wiersz',
                few: 'Odczytano {n} wiersze',
                many: 'Odczytano {n} wierszy',
              ),
              key: const Key('password-import-read'),
              style: line,
            ),
            Text(
              tn(
                report.imported,
                one: 'Dodano {n} hasło',
                few: 'Dodano {n} hasła',
                many: 'Dodano {n} haseł',
              ),
              key: const Key('password-import-added'),
              style: line.copyWith(fontWeight: FontWeight.w700),
            ),
            if (report.skippedCount > 0) ...<Widget>[
              Text(
                tn(
                  report.skippedCount,
                  one: 'Pominięto {n} wiersz',
                  few: 'Pominięto {n} wiersze',
                  many: 'Pominięto {n} wierszy',
                ),
                key: const Key('password-import-skipped'),
                style: line,
              ),
              for (final MapEntry<PasswordImportSkip, int> s
                  in report.skipped.entries)
                if (s.value > 0)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 12),
                    child: Text(
                      '• ${_skip(s.key, s.value)}',
                      key: Key('password-import-skip-${s.key.name}'),
                      style: reason,
                    ),
                  ),
              if (_damage(report.damaged) case final String where)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 24),
                  child: Text(
                    where,
                    key: const Key('password-import-damaged'),
                    style: reason,
                  ),
                ),
            ],
          ],
          const SizedBox(height: 4),
          ZenInfo(
            icon: Icons.delete_sweep_outlined,
            tone: zen.warning,
            text: t('Usuń teraz plik CSV: hasła są w nim jawne.'),
          ),
        ],
      ),
      actions: <Widget>[
        FilledButton(
          key: const Key('password-import-done'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Gotowe')),
        ),
      ],
    );
  }
}
