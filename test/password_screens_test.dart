import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_import.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_screen.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

import 'support/text_fit.dart';

// "Hasła" on the screen: it opens only after the app password, shows the
// entries as a list to search with a copy button each, hides a password
// until it is shown, adds, edits, deletes and takes back earlier passwords,
// imports a browser's export and says what it did, and closes with
// everything in it when Zen locks.

const PasswordFields _bank = PasswordFields(
  name: 'Bank',
  login: 'ania',
  password: 'tajne-haslo-1',
  address: 'https://bank.example.com/login',
  note: 'PIN w sejfie',
);

const PasswordFields _mail = PasswordFields(
  name: 'poczta',
  login: 'ania@example.com',
  password: 'inne-haslo',
  address: 'mail.example.org',
);

/// What the vault put on the clipboard (its copy is replaced here).
final class _Clipboard {
  final List<String> copied = <String>[];
  bool works = true;

  Future<bool> copy(String text) async {
    if (!works) {
      return false;
    }
    copied.add(text);
    return true;
  }
}

PasswordVaultService _vault(
  LedgerDisk disk, {
  _Clipboard? clipboard,
  AppSecurityService? security,
  int seed = 1,
}) {
  int t = 1760000000000;
  return PasswordVaultService(
    disk: disk,
    now: () => t += 60000,
    random: Random(seed),
    isLocked: security == null ? null : () => security.isLocked,
    copy: (clipboard ?? _Clipboard()).copy,
  );
}

/// The frames of a route or a sheet coming in (an endless animation, such
/// as a spinner, would keep pumpAndSettle waiting).
Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// A page with one button that opens "Hasła" (as the settings row does).
Future<void> _pump(
  WidgetTester tester, {
  required PasswordVaultService vault,
  AppSecurityService? security,
  PasswordFilePicker? picker,
  String search = '',
  Size size = const Size(420, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        passwordVaultServiceProvider.overrideWithValue(vault),
        appSecurityServiceProvider.overrideWithValue(
          security ?? MemoryAppSecurityService(),
        ),
        if (picker != null)
          passwordFilePickerProvider.overrideWithValue(picker),
      ],
      child: MaterialApp(
        theme: ZenTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () => unawaited(
                  PasswordVaultScreen.open(context, search: search),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('open')));
  await _frames(tester);
}

Future<void> _tap(WidgetTester tester, String key) async {
  final Finder f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await _frames(tester);
}

Future<MemoryAppSecurityService> _withPassword() async {
  final MemoryAppSecurityService security = MemoryAppSecurityService(
    passwordIterations: 10,
  );
  await security.setPassword('sekret12');
  return security;
}

Future<void> _confirm(WidgetTester tester, String password) async {
  await tester.enterText(
    find.byKey(const Key('sensitive-access-password')),
    password,
  );
  await tester.tap(find.byKey(const Key('sensitive-access-confirm')));
  await _frames(tester);
}

final Finder _screen = find.byKey(const Key('passwords-screen'));

Map<String, Object?> _versions(MemoryLedgerDisk d) => Map<String, Object?>.from(
  (jsonDecode(utf8.decode(d.files[kPasswordVaultKey]!)) as Map)['e'] as Map,
);

void main() {
  testWidgets('it opens only after the app password: cancelled or wrong, '
      'nothing opens; every opening asks again', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    await vault.add(_bank);
    vault.forget();
    await _pump(tester, vault: vault, security: security);

    await _open(tester);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsOneWidget);
    expect(_screen, findsNothing);
    await tester.tap(find.text('Anuluj'));
    await _frames(tester);
    expect(_screen, findsNothing);
    // Nothing was even read.
    expect(vault.loaded, isFalse);

    await _open(tester);
    await _confirm(tester, 'zle-haslo');
    expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);
    await tester.tap(find.text('Anuluj'));
    await _frames(tester);
    expect(_screen, findsNothing);

    await _open(tester);
    await _confirm(tester, 'sekret12');
    expect(_screen, findsOneWidget);
    expect(find.text('Bank'), findsOneWidget);

    // Closed and opened again at once: asked again.
    await tester.pageBack();
    await _frames(tester);
    await _open(tester);
    expect(find.byKey(const Key('sensitive-access-dialog')), findsOneWidget);
  });

  testWidgets('without an app password it opens at once; empty, it says what '
      'it is and offers to add or import', (WidgetTester tester) async {
    await _pump(tester, vault: _vault(MemoryLedgerDisk()));
    await _open(tester);
    expect(_screen, findsOneWidget);
    expect(find.byKey(const Key('passwords-empty')), findsOneWidget);
    expect(find.text('Tu zapiszesz swoje hasła'), findsOneWidget);
    expect(find.byKey(const Key('passwords-empty-add')), findsOneWidget);
    expect(find.byKey(const Key('passwords-empty-import')), findsOneWidget);
    // The "+" comes with the first entry.
    expect(find.byKey(const Key('passwords-add')), findsNothing);
    expect(tester.takeException(), isNull);

    // "Jak to działa" in the menu.
    await _tap(tester, 'passwords-menu');
    await _tap(tester, 'passwords-menu-help');
    expect(
      find.textContaining('Skopiowane hasło znika ze schowka po 30 sekundach'),
      findsOneWidget,
    );
  });

  testWidgets('the list: a row per entry with its letter, name and login, a '
      'copy button, a mark on a conflict; the search finds by name, login '
      'and address, never by the password', (WidgetTester tester) async {
    final _Clipboard clipboard = _Clipboard();
    final PasswordVaultService vault = _vault(
      MemoryLedgerDisk(),
      clipboard: clipboard,
    );
    final PasswordEntry bank = await vault.add(_bank);
    final PasswordEntry mail = await vault.add(_mail);
    await _pump(tester, vault: vault);
    await _open(tester);

    expect(find.byKey(Key('password-row-${bank.id}')), findsOneWidget);
    expect(find.byKey(Key('password-row-${mail.id}')), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('P'), findsOneWidget);
    expect(find.text('ania@example.com'), findsOneWidget);
    expect(find.byKey(Key('password-conflict-${bank.id}')), findsNothing);
    // No password is on the list.
    expect(find.textContaining('tajne'), findsNothing);
    expect(find.byKey(const Key('passwords-add')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('passwords-search')), 'POCZ');
    await tester.pump();
    expect(find.byKey(Key('password-row-${bank.id}')), findsNothing);
    expect(find.byKey(Key('password-row-${mail.id}')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('passwords-search')),
      'bank.example',
    );
    await tester.pump();
    expect(find.byKey(Key('password-row-${bank.id}')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('passwords-search')), 'tajne');
    await tester.pump();
    expect(find.byKey(const Key('passwords-search-empty')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('passwords-search')), '');
    await tester.pump();
    // One tap copies the password, through the vault (cleared later).
    await _tap(tester, 'password-row-copy-${mail.id}');
    expect(clipboard.copied, <String>['inne-haslo']);
    expect(
      find.text('Skopiowano — zniknie ze schowka za 30 s'),
      findsOneWidget,
    );
  });

  testWidgets('opened with a search typed (for the autofill later)', (
    WidgetTester tester,
  ) async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    await vault.add(_bank);
    await vault.add(_mail);
    await _pump(tester, vault: vault, search: 'mail.example');
    await _open(tester);
    expect(find.text('poczta'), findsOneWidget);
    expect(find.text('Bank'), findsNothing);
  });

  testWidgets('an entry: the password hidden until shown, copies of the '
      'login and the password, a refused copy said so', (
    WidgetTester tester,
  ) async {
    final _Clipboard clipboard = _Clipboard();
    final PasswordVaultService vault = _vault(
      MemoryLedgerDisk(),
      clipboard: clipboard,
    );
    final PasswordEntry bank = await vault.add(_bank);
    await _pump(tester, vault: vault);
    await _open(tester);
    await _tap(tester, 'password-row-${bank.id}');

    expect(find.byKey(const Key('password-entry-screen')), findsOneWidget);
    expect(find.text('ania'), findsOneWidget);
    expect(find.text('PIN w sejfie'), findsOneWidget);
    expect(find.text('tajne-haslo-1'), findsNothing);
    await _tap(tester, 'password-reveal');
    expect(find.text('tajne-haslo-1'), findsOneWidget);
    await _tap(tester, 'password-reveal');
    expect(find.text('tajne-haslo-1'), findsNothing);

    await _tap(tester, 'password-copy-login');
    await _tap(tester, 'password-copy');
    expect(clipboard.copied, <String>['ania', 'tajne-haslo-1']);

    clipboard.works = false;
    await _tap(tester, 'password-copy');
    expect(find.text('Nie udało się. Spróbuj jeszcze raz.'), findsOneWidget);
    expect(clipboard.copied, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding with the generator: the password made is the one '
      'saved; the entry opens after', (WidgetTester tester) async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    await _pump(tester, vault: vault);
    await _open(tester);
    await _tap(tester, 'passwords-empty-add');
    expect(find.byKey(const Key('password-form-screen')), findsOneWidget);

    // Nothing to save yet: it says what is missing.
    await _tap(tester, 'password-save');
    expect(find.text('Wpisz nazwę albo adres.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('password-field-name')),
      'Sklep',
    );
    await tester.enterText(
      find.byKey(const Key('password-field-login')),
      'ania@sklep.pl',
    );
    await tester.pump();
    await _tap(tester, 'password-save');
    expect(find.text('Wpisz hasło albo notatkę.'), findsOneWidget);

    await _tap(tester, 'password-generate');
    expect(find.byKey(const Key('password-generator')), findsOneWidget);
    String shown() =>
        tester.widget<Text>(find.byKey(const Key('generator-password'))).data!;
    expect(shown(), hasLength(20));
    expect(find.byKey(const Key('password-strength')), findsWidgets);
    // Without symbols and look-alikes; a new one each time.
    await _tap(tester, 'generator-symbols');
    await _tap(tester, 'generator-look-alike');
    final String first = shown();
    expect(first, matches(RegExp(r'^[A-Za-z0-9]{20}$')));
    expect(first, isNot(matches(RegExp('[Il1O0o]'))));
    await _tap(tester, 'generator-refresh');
    final String made = shown();
    expect(made, isNot(first));
    await _tap(tester, 'generator-use');
    expect(find.byKey(const Key('password-generator')), findsNothing);

    await _tap(tester, 'password-save');
    expect(vault.entries, hasLength(1));
    expect(vault.entries.single.password, made);
    expect(vault.entries.single.login, 'ania@sklep.pl');
    expect(find.byKey(const Key('password-entry-screen')), findsOneWidget);
  });

  testWidgets('a field over its limit says so and is not cut; nothing is '
      'saved then', (WidgetTester tester) async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    await _pump(tester, vault: vault);
    await _open(tester);
    await _tap(tester, 'passwords-empty-add');
    final String long = 'x' * (kMaxPasswordNameChars + 1);
    await tester.enterText(find.byKey(const Key('password-field-name')), long);
    await tester.pump();
    expect(
      find.text('Za długie: najwyżej $kMaxPasswordNameChars znaków.'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('password-field-name')))
          .controller!
          .text,
      long,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('password-save')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('back with something typed asks first; "Pisz dalej" keeps it', (
    WidgetTester tester,
  ) async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    await _pump(tester, vault: vault);
    await _open(tester);
    await _tap(tester, 'passwords-empty-add');
    await tester.enterText(
      find.byKey(const Key('password-field-name')),
      'Bank',
    );
    await tester.pump();

    await tester.pageBack();
    await _frames(tester);
    expect(find.byKey(const Key('password-discard-dialog')), findsOneWidget);
    await tester.tap(find.text('Pisz dalej'));
    await _frames(tester);
    expect(find.byKey(const Key('password-form-screen')), findsOneWidget);
    expect(find.text('Bank'), findsOneWidget);

    await tester.pageBack();
    await _frames(tester);
    await _tap(tester, 'password-discard');
    expect(find.byKey(const Key('password-form-screen')), findsNothing);
    expect(vault.entries, isEmpty);
  });

  testWidgets('editing keeps the earlier password, which can be shown, '
      'copied and taken back', (WidgetTester tester) async {
    final _Clipboard clipboard = _Clipboard();
    final PasswordVaultService vault = _vault(
      MemoryLedgerDisk(),
      clipboard: clipboard,
    );
    final PasswordEntry bank = await vault.add(_bank);
    await _pump(tester, vault: vault);
    await _open(tester);
    await _tap(tester, 'password-row-${bank.id}');
    await _tap(tester, 'password-edit');
    expect(find.byKey(const Key('password-form-screen')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('password-field-password')),
      'nowe-haslo-2',
    );
    await tester.pump();
    await _tap(tester, 'password-save');

    expect(vault.entry(bank.id)!.password, 'nowe-haslo-2');
    expect(find.byKey(const Key('password-history')), findsOneWidget);
    final PasswordHistoryItem old = vault.entry(bank.id)!.history.single;
    expect(old.password, 'tajne-haslo-1');
    expect(find.textContaining('Zastąpione'), findsOneWidget);
    expect(find.text('tajne-haslo-1'), findsNothing);
    await _tap(tester, 'password-history-reveal-${old.versionKey}');
    expect(find.text('tajne-haslo-1'), findsOneWidget);
    await _tap(tester, 'password-history-copy-${old.versionKey}');
    expect(clipboard.copied, <String>['tajne-haslo-1']);

    await _tap(tester, 'password-history-restore-${old.versionKey}');
    expect(vault.entry(bank.id)!.password, 'tajne-haslo-1');
    // What it replaced is in the history now.
    expect(
      vault.entry(bank.id)!.history.map((PasswordHistoryItem h) => h.password),
      contains('nowe-haslo-2'),
    );

    // The old passwords go, after a question.
    await _tap(tester, 'password-history-clear');
    await _tap(tester, 'password-history-clear-confirm');
    expect(vault.entry(bank.id)!.history, isEmpty);
    expect(find.byKey(const Key('password-history')), findsNothing);
  });

  testWidgets('deleting asks first; "Anuluj" keeps the entry', (
    WidgetTester tester,
  ) async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    final PasswordEntry bank = await vault.add(_bank);
    await _pump(tester, vault: vault);
    await _open(tester);
    await _tap(tester, 'password-row-${bank.id}');
    await _tap(tester, 'password-delete');
    expect(find.text('Usunąć „Bank”?'), findsOneWidget);
    await tester.tap(find.text('Anuluj'));
    await _frames(tester);
    expect(vault.entries, hasLength(1));

    await _tap(tester, 'password-delete');
    await _tap(tester, 'password-delete-confirm');
    expect(vault.entries, isEmpty);
    expect(find.byKey(const Key('password-entry-screen')), findsNothing);
    expect(find.byKey(const Key('passwords-empty')), findsOneWidget);
  });

  testWidgets('changed on two devices at once: marked on the list, said in '
      'one sentence, settled by keeping one', (WidgetTester tester) async {
    // Two devices of the account, each with the same entry, each editing
    // it; the account's sync then takes the versions of both.
    final MemoryLedgerDisk phone = MemoryLedgerDisk();
    final PasswordVaultService a = _vault(phone);
    final PasswordEntry bank = await a.add(_bank);
    final MemoryLedgerDisk laptop = MemoryLedgerDisk()
      ..files[kPasswordVaultKey] = phone.files[kPasswordVaultKey]!;
    final PasswordVaultService b = _vault(laptop, seed: 2);
    await b.load();
    await a.edit(
      bank.id,
      const PasswordFields(name: 'Bank', password: 'z-telefonu'),
    );
    await b.edit(
      bank.id,
      const PasswordFields(name: 'Bank', password: 'z-laptopa'),
    );
    await phone.write(
      kPasswordVaultKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'v': 1,
            'e': <String, Object?>{..._versions(phone), ..._versions(laptop)},
          }),
        ),
      ),
    );
    final PasswordVaultService vault = _vault(phone, seed: 3);
    await vault.load();
    expect(vault.entry(bank.id)!.conflict, isTrue);

    await _pump(tester, vault: vault);
    await _open(tester);
    expect(find.byKey(Key('password-conflict-${bank.id}')), findsOneWidget);
    await _tap(tester, 'password-row-${bank.id}');
    expect(find.byKey(const Key('password-conflict-info')), findsOneWidget);
    expect(find.textContaining('Z innego urządzenia'), findsOneWidget);

    await _tap(tester, 'password-keep-current');
    expect(vault.entry(bank.id)!.conflict, isFalse);
    expect(find.byKey(const Key('password-conflict-info')), findsNothing);
  });

  testWidgets('kept over a deletion on another device: said, settled by '
      '"Zostaw" without changing a field', (WidgetTester tester) async {
    final MemoryLedgerDisk phone = MemoryLedgerDisk();
    final PasswordVaultService a = _vault(phone);
    final PasswordEntry bank = await a.add(_bank);
    final MemoryLedgerDisk laptop = MemoryLedgerDisk()
      ..files[kPasswordVaultKey] = phone.files[kPasswordVaultKey]!;
    final PasswordVaultService b = _vault(laptop, seed: 2);
    await b.load();
    await a.delete(bank.id);
    await b.edit(
      bank.id,
      const PasswordFields(name: 'Bank', password: 'z-laptopa'),
    );
    await phone.write(
      kPasswordVaultKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'v': 1,
            'e': <String, Object?>{..._versions(phone), ..._versions(laptop)},
          }),
        ),
      ),
    );
    final PasswordVaultService vault = _vault(phone, seed: 3);
    await vault.load();
    expect(vault.entry(bank.id)!.keptOverDeletion, isTrue);

    await _pump(tester, vault: vault);
    await _open(tester);
    await _tap(tester, 'password-row-${bank.id}');
    expect(find.byKey(const Key('password-kept-info')), findsOneWidget);
    await _tap(tester, 'password-keep-over-deletion');
    expect(vault.entry(bank.id)!.keptOverDeletion, isFalse);
    expect(vault.entry(bank.id)!.password, 'z-laptopa');
    expect(find.byKey(const Key('password-kept-info')), findsNothing);
  });

  testWidgets('exact copies are removed at once after a question; one of '
      'each stays', (WidgetTester tester) async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    await vault.add(_bank);
    await vault.add(_bank);
    await vault.add(_bank);
    await vault.add(_mail);
    expect(vault.duplicateCount, 2);

    await _pump(tester, vault: vault);
    await _open(tester);
    await _tap(tester, 'passwords-menu');
    await _tap(tester, 'passwords-menu-duplicates');
    expect(
      find.byKey(const Key('passwords-duplicates-dialog')),
      findsOneWidget,
    );
    await _tap(tester, 'passwords-duplicates-confirm');
    expect(vault.entries.map((PasswordEntry e) => e.name), <String>[
      'Bank',
      'poczta',
    ]);
    expect(vault.duplicateCount, 0);
  });

  testWidgets('import: a warning first, then the report in words; the '
      "file's bytes are overwritten", (WidgetTester tester) async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    await vault.add(_bank);
    final Uint8List csv = Uint8List.fromList(
      utf8.encode(
        'name,url,username,password\n'
        'Bank,https://bank.example.com/login,ania,tajne-haslo-1\n'
        'Sklep,https://sklep.example.com,ania,haslo-sklep\n'
        'Pusty,https://pusty.example.com,ania,\n',
      ),
    );
    int picks = 0;
    await _pump(
      tester,
      vault: vault,
      picker: () async {
        picks++;
        return PickedPasswordFile(bytes: csv);
      },
    );
    await _open(tester);
    await _tap(tester, 'passwords-menu');
    await _tap(tester, 'passwords-menu-import');
    expect(find.byKey(const Key('password-import-warning')), findsOneWidget);
    expect(picks, 0);
    await _tap(tester, 'password-import-pick');
    expect(picks, 1);

    expect(find.byKey(const Key('password-import-report')), findsOneWidget);
    expect(find.text('Odczytano 3 wiersze'), findsOneWidget);
    expect(find.text('Dodano 1 hasło'), findsOneWidget);
    expect(find.text('Pominięto 2 wiersze'), findsOneWidget);
    expect(find.text('• Już były w Zen: 1'), findsOneWidget);
    expect(find.text('• Bez hasła: 1'), findsOneWidget);
    expect(find.textContaining('Usuń teraz plik CSV'), findsOneWidget);
    expect(csv.every((int b) => b == 0), isTrue);
    expect(vault.entries.map((PasswordEntry e) => e.name), <String>[
      'Bank',
      'Sklep',
    ]);
    await _tap(tester, 'password-import-done');
    expect(find.text('Sklep'), findsOneWidget);
  });

  testWidgets('import: a file that is not an export, or too large, is said '
      'so', (WidgetTester tester) async {
    final PasswordVaultService vault = _vault(MemoryLedgerDisk());
    PickedPasswordFile next = PickedPasswordFile(
      bytes: Uint8List.fromList(utf8.encode('a,b,c\n1,2,3\n')),
    );
    await _pump(tester, vault: vault, picker: () async => next);
    await _open(tester);
    await _tap(tester, 'passwords-empty-import');
    await _tap(tester, 'password-import-pick');
    expect(find.text('Nie zaimportowano'), findsOneWidget);
    expect(find.byKey(const Key('password-import-error')), findsOneWidget);
    expect(find.textContaining('Nie rozpoznano pliku'), findsOneWidget);
    await _tap(tester, 'password-import-done');

    next = const PickedPasswordFile(tooLarge: true);
    await _tap(tester, 'passwords-empty-import');
    await _tap(tester, 'password-import-pick');
    expect(find.text('Plik jest za duży (najwyżej 8 MB).'), findsOneWidget);
    expect(vault.entries, isEmpty);
  });

  testWidgets('locking Zen closes it all, a half-typed form too, and the '
      'vault holds nothing', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await _withPassword();
    final PasswordVaultService vault = _vault(
      MemoryLedgerDisk(),
      security: security,
    );
    final PasswordEntry bank = await vault.add(_bank);
    await _pump(tester, vault: vault, security: security);
    await _open(tester);
    await _confirm(tester, 'sekret12');
    await _tap(tester, 'password-row-${bank.id}');
    await _tap(tester, 'password-edit');
    await tester.enterText(
      find.byKey(const Key('password-field-password')),
      'w-polowie',
    );
    await tester.pump();

    security.lock();
    // The vault forgets on the lock (as its provider does).
    vault.forget();
    await _frames(tester);
    expect(find.byKey(const Key('password-form-screen')), findsNothing);
    expect(find.byKey(const Key('password-entry-screen')), findsNothing);
    expect(_screen, findsNothing);
    expect(find.byKey(const Key('password-discard-dialog')), findsNothing);
    expect(find.byKey(const Key('open')), findsOneWidget);
    expect(vault.entries, isEmpty);
    expect(vault.loaded, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a damaged store and one of a newer Zen are shown read-only and '
      'explained', (WidgetTester tester) async {
    final MemoryLedgerDisk damaged = MemoryLedgerDisk()
      ..files[kPasswordVaultKey] = Uint8List.fromList(utf8.encode('{nie json'));
    await _pump(tester, vault: _vault(damaged));
    await _open(tester);
    expect(find.byKey(const Key('passwords-damaged')), findsOneWidget);
    expect(find.byKey(const Key('passwords-add')), findsNothing);
    expect(find.byKey(const Key('passwords-empty-add')), findsNothing);
    await tester.pageBack();
    await _frames(tester);

    final MemoryLedgerDisk newer = MemoryLedgerDisk()
      ..files[kPasswordVaultKey] = Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object?>{'v': 99, 'e': <String, Object?>{}}),
        ),
      );
    await _pump(tester, vault: _vault(newer));
    await _open(tester);
    expect(find.byKey(const Key('passwords-newer')), findsOneWidget);
    expect(find.byKey(const Key('passwords-add')), findsNothing);
    // Left as it was.
    expect(
      jsonDecode(utf8.decode(newer.files[kPasswordVaultKey]!)),
      <String, Object?>{'v': 99, 'e': <String, Object?>{}},
    );
  });

  testWidgets('a full store says so above the list', (
    WidgetTester tester,
  ) async {
    final Map<String, Object?> versions = <String, Object?>{
      for (int i = 0; i < kMaxPasswordEntries; i++)
        'v${i.toString().padLeft(9, '0')}': <String, Object?>{
          'i': 'e${i.toString().padLeft(9, '0')}',
          'a': 1000 + i,
          'n': 'Strona $i',
          'p': 'haslo-$i',
        },
    };
    final MemoryLedgerDisk disk = MemoryLedgerDisk()
      ..files[kPasswordVaultKey] = Uint8List.fromList(
        utf8.encode(jsonEncode(<String, Object?>{'v': 1, 'e': versions})),
      );
    await _pump(tester, vault: _vault(disk));
    await _open(tester);
    expect(find.byKey(const Key('passwords-full')), findsOneWidget);
  });

  group('the way in', () {
    Future<void> pumpShell(
      WidgetTester tester, {
      AppSecurityService? security,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            signalTransportProvider.overrideWithValue(MemorySignalTransport()),
            ledgerNodeEnabledProvider.overrideWithValue(true),
            ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
            if (security != null)
              appSecurityServiceProvider.overrideWithValue(security),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: const AppShellScreen(),
          ),
        ),
      );
      for (int i = 0; i < 4; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    Future<void> tearDownShell(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }

    testWidgets('"Hasła" is the row right under "Ponownie przeprowadź '
        'konfigurację" in the settings, and opens the passwords', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpShell(tester);
      await tester.tap(find.byKey(const Key('chats-status-chip')));
      await _frames(tester);
      final Finder rerun = find.byKey(const Key('settings-rerun-setup'));
      final Finder row = find.byKey(const Key('settings-nav-passwords'));
      expect(row, findsOneWidget);
      final double gap =
          tester.getTopLeft(row).dy - tester.getBottomLeft(rerun).dy;
      expect(gap, inInclusiveRange(0, 40));
      // Nothing else between them.
      expect(
        tester.getTopLeft(find.byKey(const Key('settings-nav-invite'))).dy,
        greaterThan(tester.getBottomLeft(row).dy),
      );
      await tester.tap(row);
      await _frames(tester);
      expect(_screen, findsOneWidget);
      await tester.pageBack();
      await _frames(tester);
      await tearDownShell(tester);
    });

    testWidgets('the top bar keeps its buttons on the smallest phone in the '
        'languages with the longest status, and has no passwords button', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      addTearDown(ZenI18n.debugReset);
      // Indonesian and Vietnamese have the widest status ("Tidak ada
      // jaringan", "Đang kết nối…"); with the lock button the status keeps
      // 67 dp there, and a sixth button would leave it 23.
      for (final String code in const <String>['id', 'vi', 'pl']) {
        ZenI18n.debugUse(code, textFitStrings(code));
        await pumpShell(
          tester,
          security: MemoryAppSecurityService(
            hasPassword: true,
            passwordIterations: 10,
          ),
        );
        expect(tester.takeException(), isNull, reason: code);
        final List<Rect> boxes = <Rect>[
          for (final Key key in const <Key>[
            Key('side-tabs-hide'),
            Key('status-notices'),
            Key('status-my-code'),
            Key('side-tabs-lock'),
            Key('account-menu-button'),
          ])
            tester.getRect(find.byKey(key)),
        ];
        for (final Rect box in boxes) {
          expect(box.width, greaterThanOrEqualTo(44), reason: code);
          expect(box.right, lessThanOrEqualTo(320), reason: code);
        }
        for (int i = 0; i < boxes.length; i++) {
          for (int j = i + 1; j < boxes.length; j++) {
            expect(boxes[i].overlaps(boxes[j]), isFalse, reason: '$code $i/$j');
          }
        }
        expect(find.byIcon(Icons.key_rounded), findsNothing, reason: code);
        await tearDownShell(tester);
      }
    });
  });
}
