import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_generator.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_widgets.dart';
import 'package:zen/src/features/security/secure_screen.dart';

/// A new entry of "Hasła", or an edit of the entry [entryId]: the five
/// fields with the vault's limits, the password hidden until shown and the
/// generator. Closes with the id of the entry saved. Going back with
/// something changed asks first.
class PasswordFormScreen extends ConsumerStatefulWidget {
  const PasswordFormScreen({this.entryId, super.key});

  /// The entry edited; null for a new one.
  final String? entryId;

  @override
  ConsumerState<PasswordFormScreen> createState() => _PasswordFormScreenState();
}

class _PasswordFormScreenState extends ConsumerState<PasswordFormScreen> {
  late final PasswordVaultService _vault = ref.read(
    passwordVaultServiceProvider,
  );
  final TextEditingController _name = TextEditingController();
  final TextEditingController _login = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _address = TextEditingController();
  final TextEditingController _note = TextEditingController();
  PasswordFields _start = const PasswordFields();
  bool _shown = false;
  bool _busy = false;
  String? _problem;

  List<TextEditingController> get _all => <TextEditingController>[
    _name,
    _login,
    _password,
    _address,
    _note,
  ];

  @override
  void initState() {
    super.initState();
    final String? id = widget.entryId;
    final PasswordEntry? entry = id == null ? null : _vault.entry(id);
    if (entry != null) {
      _start = entry.fields;
      _name.text = entry.name;
      _login.text = entry.login;
      _password.text = entry.password;
      _address.text = entry.address;
      _note.text = entry.note;
    }
    for (final TextEditingController c in _all) {
      c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    for (final TextEditingController c in _all) {
      // What was typed does not wait in memory for the next collection.
      c
        ..removeListener(_changed)
        ..clear()
        ..dispose();
    }
    super.dispose();
  }

  void _changed() => setState(() => _problem = null);

  PasswordFields get _fields => PasswordFields(
    name: _name.text,
    login: _login.text,
    password: _password.text,
    address: _address.text,
    note: _note.text,
  );

  bool get _dirty => !_fields.sameAs(_start);

  String? _problemText(PasswordFieldsProblem? problem) => switch (problem) {
    PasswordFieldsProblem.noName => t('Wpisz nazwę albo adres.'),
    PasswordFieldsProblem.noPassword => t('Wpisz hasło albo notatkę.'),
    // Each long field says so under itself.
    PasswordFieldsProblem.tooLong || null => null,
  };

  Future<void> _save() async {
    if (_busy) {
      return;
    }
    final PasswordFields fields = _fields;
    final PasswordFieldsProblem? problem = fields.trimmed().problem;
    if (problem != null) {
      setState(() => _problem = _problemText(problem));
      return;
    }
    setState(() => _busy = true);
    final NavigatorState navigator = Navigator.of(context);
    PasswordEntry? saved;
    final bool ok = await runPasswordAction(context, () async {
      final String? id = widget.entryId;
      saved = id == null
          ? await _vault.add(fields)
          : await _vault.edit(id, fields);
    });
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    if (ok) {
      navigator.pop(saved?.id);
    }
  }

  Future<void> _askToLeave() async {
    final NavigatorState navigator = Navigator.of(context);
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        key: const Key('password-discard-dialog'),
        title: Text(t('Porzucić zmiany?')),
        content: Text(t('To, co napisałeś, nie zostanie zapisane.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Pisz dalej')),
          ),
          FilledButton(
            key: const Key('password-discard'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Odrzuć')),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      navigator.pop();
    }
  }

  Future<void> _generate() async {
    final String? made = await showPasswordGenerator(context);
    if (made != null && mounted) {
      _password.text = made;
      setState(() => _shown = true);
    }
  }

  /// "Za długie" under a field over [max]; nothing is cut off what was
  /// typed or pasted (a password cut short would be a wrong one).
  InputDecoration _decoration(
    String label,
    TextEditingController c,
    int max, {
    Widget? suffix,
  }) {
    final bool over = c.text.length > max;
    return InputDecoration(
      labelText: label,
      suffixIcon: suffix,
      errorText: over
          ? t('Za długie: najwyżej {n} znaków.', <String, Object?>{'n': max})
          : null,
      errorMaxLines: 2,
    );
  }

  Widget _field(
    String key,
    String label,
    TextEditingController c,
    int max, {
    TextInputType? type,
    int maxLines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      key: Key(key),
      controller: c,
      keyboardType: type,
      maxLines: maxLines,
      minLines: 1,
      autocorrect: false,
      enableIMEPersonalizedLearning: false,
      textInputAction: maxLines == 1 ? TextInputAction.next : null,
      decoration: _decoration(label, c, max),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool editing = widget.entryId != null;
    final Widget passwordField = NoCopyField(
      child: TextField(
        key: const Key('password-field-password'),
        controller: _password,
        obscureText: !_shown,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        keyboardType: TextInputType.visiblePassword,
        contextMenuBuilder: passwordFieldMenu,
        style: _shown ? zen.mono(color: zen.textPrimary, size: 15) : null,
        decoration: _decoration(
          t('Hasło'),
          _password,
          kMaxPasswordChars,
          suffix: IconButton(
            key: const Key('password-field-reveal'),
            tooltip: _shown ? t('Ukryj hasło') : t('Pokaż hasło'),
            onPressed: () => setState(() => _shown = !_shown),
            icon: Icon(
              _shown ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            ),
          ),
        ),
      ),
    );
    return PopScope<Object?>(
      canPop: !_dirty || _busy,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) {
          unawaited(_askToLeave());
        }
      },
      child: SecureScreen(
        child: Scaffold(
          key: const Key('password-form-screen'),
          appBar: AppBar(title: Text(editing ? t('Edytuj') : t('Dodaj hasło'))),
          body: SafeArea(
            top: false,
            child: passwordPageColumn(
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: <Widget>[
                  _field(
                    'password-field-name',
                    t('Nazwa'),
                    _name,
                    kMaxPasswordNameChars,
                  ),
                  _field(
                    'password-field-login',
                    t('Login'),
                    _login,
                    kMaxPasswordLoginChars,
                    type: TextInputType.emailAddress,
                  ),
                  passwordField,
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _password.text.isEmpty
                            ? const SizedBox.shrink()
                            : PasswordStrengthLine(password: _password.text),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        key: const Key('password-generate'),
                        onPressed: () => unawaited(_generate()),
                        icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                        label: Text(t('Generuj')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _field(
                    'password-field-address',
                    t('Adres'),
                    _address,
                    kMaxPasswordAddressChars,
                    type: TextInputType.url,
                  ),
                  _field(
                    'password-field-note',
                    t('Notatka'),
                    _note,
                    kMaxPasswordNoteChars,
                    type: TextInputType.multiline,
                    maxLines: 6,
                  ),
                  if (_problem != null) ...<Widget>[
                    Text(
                      _problem!,
                      key: const Key('password-form-problem'),
                      style: TextStyle(color: zen.danger, height: 1.4),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    key: const Key('password-save'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed:
                        _busy ||
                            _fields.problem == PasswordFieldsProblem.tooLong
                        ? null
                        : () => unawaited(_save()),
                    child: Text(t('Zapisz')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The generator as a sheet from the bottom: the length, the kinds of
/// characters, the password made and how strong it is. Returns the
/// password chosen ("Użyj"), or null.
Future<String?> showPasswordGenerator(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      routeSettings: const RouteSettings(name: kPasswordVaultRouteName),
      builder: (BuildContext context) => const _GeneratorSheet(),
    );

class _GeneratorSheet extends StatefulWidget {
  const _GeneratorSheet();

  @override
  State<_GeneratorSheet> createState() => _GeneratorSheetState();
}

class _GeneratorSheetState extends State<_GeneratorSheet> {
  PasswordGeneratorOptions _options = const PasswordGeneratorOptions();
  late String _password = generatePassword(_options);

  /// Takes [next] when a password can be made with it (the last kind of
  /// characters cannot be switched off) and makes a new one.
  void _use(PasswordGeneratorOptions next) {
    if (!next.valid) {
      return;
    }
    setState(() {
      _options = next;
      _password = generatePassword(next);
    });
  }

  Widget _switch(String key, String label, bool value, ValueChanged<bool> on) =>
      SwitchListTile(
        key: Key(key),
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: value,
        onChanged: on,
      );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PasswordGeneratorOptions o = _options;
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('password-generator'),
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t('Generator haseł'),
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: zen.surfaceSunk,
                borderRadius: context.zenRadius(14),
                border: Border.all(color: zen.outlineSoft),
              ),
              child: Text(
                _password,
                key: const Key('generator-password'),
                style: zen.mono(
                  color: zen.textPrimary,
                  size: 17,
                  weight: FontWeight.w600,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(height: 10),
            PasswordStrengthLine(password: _password),
            const SizedBox(height: 12),
            Text(
              t('Długość: {n}', <String, Object?>{'n': o.length}),
              style: TextStyle(
                color: zen.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            Slider(
              key: const Key('generator-length'),
              value: o.length.toDouble(),
              min: kMinGeneratedPasswordLength.toDouble(),
              max: kMaxGeneratedPasswordLength.toDouble(),
              divisions:
                  kMaxGeneratedPasswordLength - kMinGeneratedPasswordLength,
              label: '${o.length}',
              onChanged: (double v) => _use(o.copyWith(length: v.round())),
            ),
            _switch(
              'generator-lower',
              t('Małe litery (a–z)'),
              o.lower,
              (bool v) => _use(o.copyWith(lower: v)),
            ),
            _switch(
              'generator-upper',
              t('Wielkie litery (A–Z)'),
              o.upper,
              (bool v) => _use(o.copyWith(upper: v)),
            ),
            _switch(
              'generator-digits',
              t('Cyfry (0–9)'),
              o.digits,
              (bool v) => _use(o.copyWith(digits: v)),
            ),
            _switch(
              'generator-symbols',
              t('Znaki specjalne (!#%…)'),
              o.symbols,
              (bool v) => _use(o.copyWith(symbols: v)),
            ),
            _switch(
              'generator-look-alike',
              t('Bez podobnych znaków (O/0, l/1)'),
              o.avoidLookAlike,
              (bool v) => _use(o.copyWith(avoidLookAlike: v)),
            ),
            const SizedBox(height: 12),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const Key('generator-refresh'),
                  onPressed: () => _use(o),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(t('Odśwież')),
                ),
                FilledButton.icon(
                  key: const Key('generator-use'),
                  onPressed: () => Navigator.of(context).pop(_password),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(t('Użyj')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
