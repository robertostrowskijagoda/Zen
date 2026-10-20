import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/paper_backup.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';

/// "Mam kopię na papierze" (§6.1): takes the account back on a new device
/// from the typed or scanned paper copy. As with recovery through the
/// circle, nothing is taken before the person confirms the account by its
/// fingerprint.
class PaperRestoreScreen extends ConsumerStatefulWidget {
  const PaperRestoreScreen({super.key});

  /// Opened from "Konto i odzyskiwanie", which has asked who the person is.
  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const PaperRestoreScreen(),
    ),
  );

  @override
  ConsumerState<PaperRestoreScreen> createState() => _PaperRestoreScreenState();
}

class _PaperRestoreScreenState extends ConsumerState<PaperRestoreScreen> {
  final TextEditingController _input = TextEditingController();
  PaperBackupAccount? _found;
  bool _busy = false;
  bool _restored = false;
  String? _message;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  String _errorText(PaperBackupError error) => switch (error) {
    PaperBackupError.length => t(
      'To nie wygląda na cały klucz: powinno być 14 grup po 4 znaki.',
    ),
    PaperBackupError.characters => t(
      'W kluczu są znaki, których nie ma w kopii. Sprawdź kartkę.',
    ),
    PaperBackupError.checksum => t(
      'Suma kontrolna się nie zgadza: gdzieś jest literówka. Sprawdź '
      'kartkę znak po znaku.',
    ),
  };

  Future<void> _check() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _found = null;
    });
    final PaperBackupDecoded decoded = decodePaperBackup(_input.text);
    PaperBackupAccount? found;
    String? message;
    if (decoded.isOk) {
      found = await PaperBackupAccount.fromSeed(decoded.seed!);
    } else {
      message = _errorText(decoded.error!);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _found = found;
      _message = message;
    });
  }

  Future<void> _scan() async {
    final PeerQrScanner scanner = ref.read(peerQrScannerProvider);
    final String? scanned = await scanner.scan(context);
    if (scanned == null || !mounted) {
      return;
    }
    _input.text = scanned;
    await _check();
  }

  Future<void> _adopt(PaperBackupAccount account) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    String? message;
    bool restored = false;
    try {
      final LedgerDisk disk = ref.read(ledgerDiskProvider);
      await adoptPaperBackup(disk, account, deviceName: thisDeviceName);
      restored = true;
      _input.clear();
    } on Object catch (e) {
      message = t('Nie udało się: {error}', <String, Object?>{'error': e});
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _restored = restored;
      _message = message;
      if (restored) {
        _found = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PaperBackupAccount? found = _found;
    final bool canScan = ref.watch(peerQrScannerProvider).isSupported;
    return SecureScreen(
      child: Scaffold(
        key: const Key('paper-restore-screen'),
        appBar: AppBar(title: Text(t('Konto z kopii na papierze'))),
        body: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              if (_restored)
                ZenInfo(
                  icon: Icons.check_circle_outline_rounded,
                  tone: zen.success,
                  text: t(
                    'Konto odzyskane. Uruchom aplikację ponownie, żeby '
                    'z niego korzystać.',
                  ),
                  key: const Key('paper-restore-done'),
                )
              else ...<Widget>[
                ZenInfo(
                  icon: Icons.history_edu_rounded,
                  text: t(
                    'Wpisz klucz z kartki (14 grup po 4 znaki) albo zeskanuj '
                    'jego kod QR. To urządzenie stanie się Twoim kolejnym '
                    'urządzeniem tego konta. Znajomych i grupy przywróci '
                    'dopiero krąg odzyskiwania; kopia na papierze zwraca '
                    'samo konto.',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('paper-restore-input'),
                  controller: _input,
                  minLines: 2,
                  maxLines: 5,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  style: zen.mono(color: zen.textPrimary, size: 16),
                  decoration: InputDecoration(
                    labelText: t('Klucz z kartki'),
                    hintText: 'ABCD-EFGH-…',
                  ),
                  onChanged: (_) {
                    if (_found != null || _message != null) {
                      setState(() {
                        _found = null;
                        _message = null;
                      });
                    }
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton(
                        key: const Key('paper-restore-check'),
                        onPressed: _busy ? null : () => unawaited(_check()),
                        child: Text(t('Sprawdź klucz')),
                      ),
                    ),
                    if (canScan) ...<Widget>[
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        key: const Key('paper-restore-scan'),
                        tooltip: t('Skanuj kod QR'),
                        onPressed: _busy ? null : () => unawaited(_scan()),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                      ),
                    ],
                  ],
                ),
                if (_message != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    _message!,
                    key: const Key('paper-restore-message'),
                    style: TextStyle(color: zen.danger, height: 1.4),
                  ),
                ],
                if (found != null) ...<Widget>[
                  const SizedBox(height: 14),
                  _FingerprintCard(
                    account: found,
                    busy: _busy,
                    onAdopt: () => unawaited(_adopt(found)),
                  ),
                ],
              ],
              if (_restored && _message != null)
                Text(_message!, style: TextStyle(color: zen.danger)),
            ],
          ),
        ),
      ),
    );
  }
}

class _FingerprintCard extends StatelessWidget {
  const _FingerprintCard({
    required this.account,
    required this.busy,
    required this.onAdopt,
  });

  final PaperBackupAccount account;
  final bool busy;
  final VoidCallback onAdopt;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: zen.surfaceSunk,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t('ODCISK KONTA'), style: zen.label(color: zen.textMuted)),
          const SizedBox(height: 4),
          SelectableText(
            account.fingerprint,
            key: const Key('paper-restore-fingerprint'),
            style: zen.mono(
              color: zen.textPrimary,
              size: 17,
              weight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t(
              'Porównaj z odciskiem w „Konto i odzyskiwanie” na swoim '
              'drugim urządzeniu albo ze znajomym, który go widzi. '
              'Przejęcie zastępuje konto, które ten telefon ma teraz.',
            ),
            style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            key: const Key('paper-restore-adopt'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: busy ? null : onAdopt,
            icon: const Icon(Icons.check_rounded),
            label: Text(
              t('Odcisk się zgadza — przejmij to konto'),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
