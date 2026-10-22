import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Ways back to the account.
enum AccountRestoreMethod { device, backupFile, circle, paperKey, keyFile }

/// What comes back for one part of the account.
enum AccountRestoreCell {
  yes,

  /// Partly or under a condition (a note says which).
  partly,
  no,
}

/// One row of the table: a part of the account and how each way brings
/// it back (with the note's number for [AccountRestoreCell.partly]).
@immutable
final class AccountRestoreRow {
  const AccountRestoreRow(this.label, this.cells);

  final String label;
  final Map<AccountRestoreMethod, (AccountRestoreCell, int?)> cells;
}

String accountRestoreMethodLabel(AccountRestoreMethod m) => switch (m) {
  AccountRestoreMethod.device => t('Inne urządzenie'),
  AccountRestoreMethod.backupFile => t('Plik kopii'),
  AccountRestoreMethod.circle => t('Krąg zaufanych'),
  AccountRestoreMethod.paperKey => t('Kartka z kluczem'),
  AccountRestoreMethod.keyFile => t('Plik klucza'),
};

const (AccountRestoreCell, int?) _yes = (AccountRestoreCell.yes, null);
const (AccountRestoreCell, int?) _no = (AccountRestoreCell.no, null);
const (AccountRestoreCell, int?) _chosen = (AccountRestoreCell.yes, 1);
(AccountRestoreCell, int?) _partly(int note) =>
    (AccountRestoreCell.partly, note);

/// A part of the account: everything comes back from another device, what
/// was chosen from a backup file, [circle] from the recovery circle and
/// [key] after a key restore (paper or file).
Map<AccountRestoreMethod, (AccountRestoreCell, int?)> _row(
  (AccountRestoreCell, int?) circle,
  (AccountRestoreCell, int?) key, {
  (AccountRestoreCell, int?) device = _yes,
}) => <AccountRestoreMethod, (AccountRestoreCell, int?)>{
  AccountRestoreMethod.device: device,
  AccountRestoreMethod.backupFile: _chosen,
  AccountRestoreMethod.circle: circle,
  AccountRestoreMethod.paperKey: key,
  AccountRestoreMethod.keyFile: key,
};

/// The table "Co da się odzyskać i jak".
List<AccountRestoreRow> accountRestoreRows() => <AccountRestoreRow>[
  AccountRestoreRow(
    t('Klucz konta'),
    <AccountRestoreMethod, (AccountRestoreCell, int?)>{
      for (final AccountRestoreMethod m in AccountRestoreMethod.values) m: _yes,
    },
  ),
  AccountRestoreRow(t('Znajomi i grupy'), _row(_yes, _partly(2))),
  AccountRestoreRow(t('Rozmowy (teksty)'), _row(_partly(3), _partly(2))),
  AccountRestoreRow(t('Załączniki i media'), _row(_no, _no)),
  AccountRestoreRow(t('Profil i galeria'), _row(_partly(4), _partly(2))),
  AccountRestoreRow(
    t('Ustawienia'),
    _row(_yes, _partly(2), device: _partly(6)),
  ),
  AccountRestoreRow(t('Piramida i portfel'), _row(_partly(5), _partly(5))),
  AccountRestoreRow(t('Randki'), _row(_partly(4), _partly(2))),
  AccountRestoreRow(t('Sąsiedzi'), _row(_yes, _partly(2))),
  AccountRestoreRow(t('Spotkania i kółka'), _row(_no, _no)),
  AccountRestoreRow(t('Filmy'), _row(_no, _no)),
];

/// The notes under the table, by number.
Map<int, String> accountRestoreNotes() => <int, String>{
  1: t('Plik kopii: wraca to, co zaznaczysz przy jej tworzeniu.'),
  2: t(
    'Po kartce lub pliku klucza reszta wraca z kopii u kręgu, jeśli ją '
    'masz.',
  ),
  3: t('Teksty rozmów są w kopii u kręgu, jeśli je tam włączysz.'),
  4: t('Bez zdjęć: kopia u kręgu jest mała.'),
  5: t('Miejsce w piramidzie i portfel potwierdzają osoby z piramidy.'),
  6: t(
    'Ustawienia konta tak; ustawienia urządzenia (blokada, łączność, '
    'powiadomienia, pamięć) zostają na nim.',
  ),
};

/// "Co da się odzyskać i jak": every way back to the account and what
/// each brings back.
class AccountRestoreInfoScreen extends StatelessWidget {
  const AccountRestoreInfoScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const AccountRestoreInfoScreen(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<AccountRestoreRow> rows = accountRestoreRows();
    final Map<int, String> notes = accountRestoreNotes();
    Widget cell((AccountRestoreCell, int?) c) {
      final (AccountRestoreCell kind, int? note) = c;
      final (String mark, Color tone) = switch (kind) {
        AccountRestoreCell.yes => ('✓', zen.success),
        AccountRestoreCell.partly => ('~', zen.warning),
        AccountRestoreCell.no => ('–', zen.textMuted),
      };
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Text(
          note == null ? mark : '$mark$note',
          textAlign: TextAlign.center,
          style: TextStyle(color: tone, fontWeight: FontWeight.w700),
        ),
      );
    }

    Widget head(String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: zen.textPrimary,
          fontWeight: FontWeight.w700,
          fontSize: 12.5,
        ),
      ),
    );

    return Scaffold(
      key: const Key('account-restore-info'),
      appBar: AppBar(title: Text(t('Co da się odzyskać i jak'))),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            Text(
              t(
                'Konto wraca na kilka sposobów. Najwięcej daje drugie '
                'urządzenie albo plik kopii zapasowej; krąg zaufanych i '
                'klucz pomogą, gdy nie masz żadnego z nich.',
              ),
              style: TextStyle(color: zen.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 12),
            ZenCard(
              padding: const EdgeInsets.all(8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  key: const Key('account-restore-table'),
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  border: TableBorder(
                    horizontalInside: BorderSide(color: zen.outlineSoft),
                  ),
                  children: <TableRow>[
                    TableRow(
                      children: <Widget>[
                        head(''),
                        for (final AccountRestoreMethod m
                            in AccountRestoreMethod.values)
                          head(accountRestoreMethodLabel(m)),
                      ],
                    ),
                    for (final AccountRestoreRow r in rows)
                      TableRow(
                        children: <Widget>[
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 8,
                            ),
                            child: Text(
                              r.label,
                              style: TextStyle(color: zen.textPrimary),
                            ),
                          ),
                          for (final AccountRestoreMethod m
                              in AccountRestoreMethod.values)
                            cell(r.cells[m] ?? _no),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t('✓ wraca · ~ częściowo (patrz uwaga) · – nie wraca'),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
            for (final MapEntry<int, String> n in notes.entries)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${n.key}. ${n.value}',
                  style: TextStyle(color: zen.textSecondary, height: 1.35),
                ),
              ),
            ZenSection(t('Jak')),
            _Way(
              icon: Icons.devices_rounded,
              title: t('Inne urządzenie'),
              text: t(
                'Urządzenia jednego konta mają na bieżąco to samo: rozmowy z '
                'plikami i nagraniami, znajomych, profil i zdjęcia, posty, '
                'galerię, filmy, ustawienia konta, randki, spotkania i '
                'kółka, piramidę, a także kopię mieszkania. Pliki idą przez '
                'Wi-Fi (przez dane komórkowe, gdy „Media tylko przez Wi-Fi” '
                'jest wyłączone). Na starym urządzeniu: Konto i '
                'odzyskiwanie → Przenieś na inne urządzenie; na nowym: '
                'Odzyskaj z innego urządzenia i zeskanuj kod. Przerwane '
                'przenoszenie wznowisz od miejsca, w którym stanęło.',
              ),
            ),
            _Way(
              icon: Icons.save_alt_rounded,
              title: t('Plik kopii'),
              text: t(
                'Konto i odzyskiwanie → Utwórz kopię zapasową. Wybierasz, co '
                'ma się w niej znaleźć; plik jest zaszyfrowany hasłem, '
                'którego nikt poza Tobą nie zna — bez hasła nie otworzy go '
                'nikt, także Ty. Przywracasz przez „Mam backup”.',
              ),
            ),
            _Way(
              icon: Icons.groups_2_outlined,
              title: t('Krąg zaufanych'),
              text: t(
                'Osoby z kręgu oddają kawałki klucza: z hasłem konta po '
                '24 h, bez hasła po 7 dniach. Potem z ich kopii wracają '
                'znajomi, grupy, profil, ustawienia i reszta z tabeli.',
              ),
            ),
            _Way(
              icon: Icons.history_edu_rounded,
              title: t('Kartka z kluczem i plik klucza'),
              text: t(
                'Przywracają samo konto, od razu i bez niczyjej pomocy. '
                'Kto ma kartkę albo plik z hasłem, ma konto — trzymaj je '
                'bezpiecznie.',
              ),
            ),
            const SizedBox(height: 8),
            ZenInfo(
              icon: Icons.timer_off_outlined,
              text: t('Znikające wiadomości nie wracają nigdy.'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Way extends StatelessWidget {
  const _Way({required this.icon, required this.title, required this.text});

  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: zen.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  text,
                  style: TextStyle(color: zen.textSecondary, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
