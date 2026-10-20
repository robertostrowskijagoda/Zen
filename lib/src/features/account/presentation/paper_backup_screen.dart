import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/paper_backup.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// "Kopia klucza konta na papierze" (§6.1): shows the account key as 14
/// groups of four characters (and a QR code on request) to write down,
/// then checks two random groups. Opens only after the app password is
/// entered again, and needs the account password when one is set.
class PaperBackupScreen extends ConsumerStatefulWidget {
  const PaperBackupScreen({super.key});

  static Future<void> open(BuildContext context) async {
    // Always ask again: this is the key to the whole account.
    ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sensitiveAccessClockProvider).forget();
    if (!await confirmSensitiveAccess(
          context,
          reason: t('Kopia klucza konta jest chroniona. Potwierdź, że to Ty.'),
        ) ||
        !context.mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const PaperBackupScreen(),
      ),
    );
  }

  @override
  ConsumerState<PaperBackupScreen> createState() => _PaperBackupScreenState();
}

class _PaperBackupScreenState extends ConsumerState<PaperBackupScreen> {
  final TextEditingController _password = TextEditingController();
  LedgerNode? _node;
  String? _code;
  bool _needPassword = false;
  bool _busy = false;
  bool _weUnlocked = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _node = ref.read(ledgerNodeProvider);
    unawaited(_load());
  }

  @override
  void dispose() {
    // Put the key away again if only this screen had it at hand.
    if (_weUnlocked) {
      _node?.identity.lock();
    }
    _password.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final LedgerNode? node = _node;
    if (node == null) {
      return;
    }
    try {
      await node.start();
    } on Object catch (error, stack) {
      logZenError('Kopia klucza konta', error, stack);
    }
    if (!mounted) {
      return;
    }
    if (!node.isReady) {
      setState(() {});
      return;
    }
    final LedgerKeyPair? key = node.identity.accountKey;
    setState(() {
      if (key == null) {
        _needPassword = true;
      } else {
        _code = encodePaperBackup(key.seed);
      }
    });
  }

  Future<void> _unlock() async {
    final LedgerNode? node = _node;
    if (node == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    final bool ok = await node.identity.unlock(_password.text);
    if (!mounted) {
      return;
    }
    final LedgerKeyPair? key = node.identity.accountKey;
    setState(() {
      _busy = false;
      if (ok && key != null) {
        _weUnlocked = true;
        _needPassword = false;
        _code = encodePaperBackup(key.seed);
        _password.clear();
      } else {
        _message = t('Złe hasło konta.');
      }
    });
  }

  Future<void> _confirmed() async {
    await ref
        .read(appSettingsControllerProvider.notifier)
        .setPaperBackupDone(true);
    ref.invalidate(accountSecureReminderProvider);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String? code = _code;
    final Widget body;
    if (_node == null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t('Konto nie jest jeszcze gotowe.'),
            style: TextStyle(color: zen.textSecondary),
          ),
        ),
      );
    } else if (code != null) {
      body = PaperBackupView(code: code, onConfirmed: _confirmed);
    } else if (_needPassword) {
      body = ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          ZenInfo(
            icon: Icons.lock_outline_rounded,
            text: t('To konto ma hasło. Podaj je, żeby pokazać kopię klucza.'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('paper-backup-password'),
            controller: _password,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: t('Hasło konta')),
            onSubmitted: (_) => unawaited(_unlock()),
          ),
          if (_message != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              _message!,
              key: const Key('paper-backup-message'),
              style: TextStyle(color: zen.danger),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton(
            key: const Key('paper-backup-unlock'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: _busy ? null : () => unawaited(_unlock()),
            child: Text(t('Pokaż kopię klucza')),
          ),
        ],
      );
    } else {
      body = Center(
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 3, color: zen.accent),
        ),
      );
    }
    return SecureScreen(
      child: Scaffold(
        key: const Key('paper-backup-screen'),
        appBar: AppBar(title: Text(t('Kopia klucza na papierze'))),
        body: SafeArea(top: false, child: body),
      ),
    );
  }
}

enum _Step { show, check, done }

/// The copy itself, the "I wrote it down" check and the result. Separate
/// from [PaperBackupScreen] so it needs no account to be shown.
class PaperBackupView extends StatefulWidget {
  const PaperBackupView({
    required this.code,
    required this.onConfirmed,
    this.random,
    super.key,
  });

  /// The 56-character copy ([encodePaperBackup]).
  final String code;

  /// Called once the person typed the asked groups correctly.
  final Future<void> Function() onConfirmed;

  /// Picks the groups to ask for (tests pass a seeded one).
  final Random? random;

  @override
  State<PaperBackupView> createState() => _PaperBackupViewState();
}

class _PaperBackupViewState extends State<PaperBackupView> {
  _Step _step = _Step.show;
  bool _qr = false;
  List<int> _asked = const <int>[];
  final List<TextEditingController> _answers = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];
  String? _error;

  @override
  void dispose() {
    for (final TextEditingController c in _answers) {
      c.dispose();
    }
    super.dispose();
  }

  void _startCheck() {
    for (final TextEditingController c in _answers) {
      c.clear();
    }
    setState(() {
      _asked = pickCheckGroups(widget.random ?? Random.secure());
      _error = null;
      _step = _Step.check;
    });
  }

  Future<void> _verify() async {
    for (int i = 0; i < _asked.length; i++) {
      if (!paperBackupGroupMatches(widget.code, _asked[i], _answers[i].text)) {
        setState(() {
          _error = t(
            'Któraś grupa się nie zgadza. Sprawdź kartkę — albo wróć '
            'i przepisz klucz jeszcze raz.',
          );
        });
        return;
      }
    }
    await widget.onConfirmed();
    if (mounted) {
      setState(() => _step = _Step.done);
    }
  }

  Widget _groupChip(ZenColors zen, int index, String group) => Container(
    key: Key('paper-backup-group-$index'),
    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
    decoration: BoxDecoration(
      color: zen.surfaceSunk,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: zen.outlineSoft),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('${index + 1}', style: zen.label(color: zen.textMuted)),
        Text(
          group,
          style: zen.mono(
            color: zen.textPrimary,
            size: 19,
            weight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
      ],
    ),
  );

  List<Widget> _show(ZenColors zen) => <Widget>[
    ZenInfo(
      icon: Icons.warning_amber_rounded,
      tone: zen.danger,
      title: t('Kto to ma, ten ma Twoje konto'),
      text: t(
        'Przepisz ręcznie na kartkę i schowaj w bezpiecznym miejscu. '
        'Nie rób zdjęcia, nie wysyłaj, nie wklejaj do notatek ani '
        'do chmury. Zen nigdy nie poprosi Cię o ten klucz.',
      ),
    ),
    ZenInfo(
      icon: Icons.history_edu_rounded,
      text: t(
        'Z kartki odzyskasz samo konto na nowym telefonie. Znajomych '
        'i grupy odzyskasz tylko z kręgiem odzyskiwania, a historii '
        'czatów i portfela nie odzyska nic.',
      ),
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: <Widget>[
        for (final (int i, String g) in paperBackupGroups(widget.code).indexed)
          _groupChip(zen, i, g),
      ],
    ),
    const SizedBox(height: 12),
    Row(
      children: <Widget>[
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('paper-backup-qr-toggle'),
            onPressed: () => setState(() => _qr = !_qr),
            icon: const Icon(Icons.qr_code_2_rounded),
            label: Text(_qr ? t('Ukryj kod QR') : t('Pokaż kod QR')),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const Key('paper-backup-copy'),
          tooltip: t('Kopiuj'),
          onPressed: () => unawaited(
            Clipboard.setData(
              ClipboardData(text: formatPaperBackup(widget.code)),
            ),
          ),
          icon: const Icon(Icons.copy_rounded),
        ),
      ],
    ),
    if (_qr) ...<Widget>[
      const SizedBox(height: 12),
      Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: QrImageView(
            key: const Key('paper-backup-qr'),
            data: paperBackupQrData(widget.code),
            size: 220,
            backgroundColor: Colors.white,
          ),
        ),
      ),
      const SizedBox(height: 6),
      Text(
        t(
          'Ten kod to ten sam klucz. Pokaż go tylko własnemu urządzeniu '
          'i nigdy nie rób mu zdjęcia.',
        ),
        textAlign: TextAlign.center,
        style: TextStyle(color: zen.textMuted, fontSize: 12.5),
      ),
    ],
    const SizedBox(height: 16),
    FilledButton.icon(
      key: const Key('paper-backup-written'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      onPressed: _startCheck,
      icon: const Icon(Icons.edit_note_rounded),
      label: Text(t('Mam to na papierze')),
    ),
  ];

  List<Widget> _check(ZenColors zen) => <Widget>[
    ZenInfo(
      icon: Icons.fact_check_outlined,
      text: t(
        'Sprawdźmy, czy kartka jest dobra. Przepisz z niej dwie grupy, '
        'o które pytamy.',
      ),
    ),
    const SizedBox(height: 8),
    for (int i = 0; i < _asked.length; i++) ...<Widget>[
      TextField(
        key: Key('paper-check-$i'),
        controller: _answers[i],
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        maxLength: kPaperBackupGroupLength + 1,
        style: zen.mono(color: zen.textPrimary, size: 20, letterSpacing: 1.2),
        decoration: InputDecoration(
          labelText: t('Grupa nr {n}', <String, Object?>{'n': _asked[i] + 1}),
          counterText: '',
        ),
      ),
      const SizedBox(height: 8),
    ],
    if (_error != null)
      Text(
        _error!,
        key: const Key('paper-check-error'),
        style: TextStyle(color: zen.danger, height: 1.4),
      ),
    const SizedBox(height: 8),
    FilledButton(
      key: const Key('paper-check-confirm'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      onPressed: () => unawaited(_verify()),
      child: Text(t('Sprawdź')),
    ),
    TextButton(
      key: const Key('paper-check-back'),
      onPressed: () => setState(() => _step = _Step.show),
      child: Text(t('Wróć do klucza')),
    ),
  ];

  List<Widget> _done(ZenColors zen) => <Widget>[
    const SizedBox(height: 24),
    Icon(Icons.check_circle_rounded, color: zen.success, size: 56),
    const SizedBox(height: 12),
    Text(
      t('Kopia gotowa'),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: zen.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    const SizedBox(height: 8),
    Text(
      t(
        'Schowaj kartkę dobrze. Na nowym telefonie wybierz „Konto '
        'i odzyskiwanie” → „Mam kopię na papierze”.',
      ),
      key: const Key('paper-backup-done'),
      textAlign: TextAlign.center,
      style: TextStyle(color: zen.textSecondary, height: 1.4),
    ),
    const SizedBox(height: 20),
    FilledButton(
      key: const Key('paper-backup-close'),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      onPressed: () => Navigator.of(context).maybePop(),
      child: Text(t('Zamknij')),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: switch (_step) {
        _Step.show => _show(zen),
        _Step.check => _check(zen),
        _Step.done => _done(zen),
      },
    );
  }
}
