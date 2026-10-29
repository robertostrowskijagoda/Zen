import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_app.dart';
import 'package:zen/src/features/account/account_copy.dart';
import 'package:zen/src/features/account/account_link.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/presentation/account_copy_common.dart';
import 'package:zen/src/features/account/presentation/account_devices_screen.dart';
import 'package:zen/src/features/account/presentation/account_restore_info.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/qr_sticker/presentation/zen_qr_view.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';

/// "Dodaj drugie urządzenie lub przenieś konto": this device shows a code; the other one
/// reads it, both show the same digits, and after "Pozwól" here the whole
/// account goes there (key, friends, conversations with their files,
/// profile, settings, pyramid, dating, neighbours, meetings, films).
class AccountCopySendScreen extends ConsumerStatefulWidget {
  const AccountCopySendScreen({super.key});

  static Future<void> open(BuildContext context) async {
    if (!await confirmSensitiveAccess(
          context,
          reason: t(
            'Przeniesienie daje drugiemu urządzeniu całe konto. Potwierdź, '
            'że to Ty.',
          ),
        ) ||
        !context.mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const AccountCopySendScreen(),
      ),
    );
  }

  @override
  ConsumerState<AccountCopySendScreen> createState() =>
      _AccountCopySendScreenState();
}

class _AccountCopySendScreenState extends ConsumerState<AccountCopySendScreen> {
  AccountCopySource? _source;
  LedgerNode? _node;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    _source?.dispose();
    _node?.identity.lock();
    super.dispose();
  }

  Future<void> _open() async {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    final AccountArchiveCollector? collect = ref.read(
      accountArchiveCollectorProvider,
    );
    final String me = ref.read(runtimeNodeSnapshotProvider).localAddress;
    if (node == null || collect == null || me.isEmpty) {
      setState(() => _message = t('Czekam na połączenie z siecią…'));
      return;
    }
    _node = node;
    await node.start();
    if (!mounted) {
      return;
    }
    final AccountCopySource source = AccountCopySource(
      transport: ref.read(meshTransportProvider),
      address: me,
      prepare: () async => AccountCopyContent(
        build: await collect(kAllAccountScopes),
        siblings: <String>[me, ...node.siblingAddresses],
      ),
    )..addListener(_changed);
    await source.open();
    if (!mounted) {
      source.dispose();
      return;
    }
    setState(() => _source = source);
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _allow() async {
    final AccountCopySource? source = _source;
    final LedgerNode? node = _node;
    if (source == null || node == null) {
      return;
    }
    if (!await unlockAccountKey(
      context,
      node,
      t('Dodaj drugie urządzenie lub przenieś konto'),
      wrong: () => setState(() => _message = t('Złe hasło konta.')),
    )) {
      return;
    }
    try {
      await source.allow();
    } on Object catch (error, stackTrace) {
      logZenError('Preparing the account copy failed', error, stackTrace);
      if (mounted) {
        setState(() => _message = t('Nie udało się przygotować kopii.'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AccountCopySource? source = _source;
    final AccountCopyTicket? ticket = source?.ticket;
    final AccountCopyRequest? request = source?.request;
    final AccountCopySendState state =
        source?.state ?? AccountCopySendState.waiting;
    return Scaffold(
      key: const Key('account-copy-send'),
      appBar: AppBar(title: Text(t('Drugie urządzenie'))),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              ZenInfo(
                key: const Key('account-copy-stays'),
                icon: Icons.devices_rounded,
                text: t(
                  'To urządzenie zostaje na koncie. Po skopiowaniu masz Zen na '
                  'obu i oba dostają wiadomości.',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t(
                  'Na drugim urządzeniu wybierz „Odzyskaj z innego urządzenia” '
                  'i zeskanuj ten kod. Przejdzie całe konto, także zdjęcia i '
                  'pliki. Najszybciej, gdy oba są w tej samej sieci Wi-Fi.',
                ),
                style: TextStyle(color: zen.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 12),
              if (ticket != null && state == AccountCopySendState.waiting)
                ZenCard(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                  child: Column(
                    children: <Widget>[
                      Container(
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: ZenFixed.qrPaper,
                          borderRadius: context.zenRadius(20),
                        ),
                        child: ZenQrView(
                          key: const Key('account-copy-qr'),
                          data: ticket.encode(),
                          size: 224,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextButton.icon(
                        key: const Key('account-copy-code-copy'),
                        // A secret: it expires from the clipboard.
                        onPressed: () =>
                            unawaited(copyWithExpiry(ticket.encode())),
                        icon: const Icon(Icons.copy_rounded),
                        label: Text(t('Kopiuj kod')),
                      ),
                    ],
                  ),
                ),
              if (request != null &&
                  state == AccountCopySendState.asked) ...<Widget>[
                Text(
                  t('„{name}” chce pobrać Twoje konto.', <String, Object?>{
                    'name': request.name,
                  }),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                AccountCopyDigits(request.digits),
                Text(
                  t(
                    'Pozwól tylko, jeśli drugie urządzenie pokazuje te same '
                    'cyfry i jest Twoje.',
                  ),
                  style: TextStyle(color: zen.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  key: const Key('account-copy-allow'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () => unawaited(_allow()),
                  child: Text(t('Pozwól')),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const Key('account-copy-deny'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () => unawaited(source!.deny()),
                  child: Text(t('To nie ja')),
                ),
              ],
              if (state == AccountCopySendState.sending)
                AccountCopyProgress(
                  done: source!.sent,
                  total: source.total,
                  label: source.total == 0
                      ? t('Przygotowuję kopię…')
                      : t('Wysyłam konto…'),
                ),
              if (state == AccountCopySendState.done)
                ZenInfo(
                  key: const Key('account-copy-sent'),
                  icon: Icons.check_circle_outline_rounded,
                  tone: zen.success,
                  text: t(
                    'Gotowe: drugie urządzenie ma całe konto. To urządzenie '
                    'działa dalej jak dotąd.',
                  ),
                ),
              if (state == AccountCopySendState.done) ...<Widget>[
                ZenInfo(
                  key: const Key('account-copy-old-phone'),
                  icon: Icons.phonelink_erase_rounded,
                  tone: zen.warning,
                  title: t('Oddajesz albo sprzedajesz to urządzenie?'),
                  text: t(
                    'Usuń z niego konto (Ustawienia → Usuń to konto z tego '
                    'urządzenia) albo odłącz je na nowym w „Urządzenia”. '
                    'Inaczej dalej będzie odbierać Twoje wiadomości.',
                  ),
                ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    key: const Key('account-copy-open-devices'),
                    onPressed: () =>
                        unawaited(AccountDevicesScreen.open(context)),
                    icon: const Icon(Icons.devices_other_rounded),
                    label: Text(t('Urządzenia')),
                  ),
                ),
              ],
              if (state == AccountCopySendState.failed)
                ZenInfo(
                  icon: Icons.block_rounded,
                  tone: zen.danger,
                  text: t('Przenoszenie przerwane.'),
                ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(_message!, style: TextStyle(color: zen.danger)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Odzyskaj z innego urządzenia": reads the code of the device that has
/// the account, shows the digits to compare, then downloads everything
/// and takes it in (a new device becomes the account's; the same
/// account's device gets what it lacks).
class AccountCopyReceiveScreen extends ConsumerStatefulWidget {
  const AccountCopyReceiveScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const AccountCopyReceiveScreen(),
    ),
  );

  @override
  ConsumerState<AccountCopyReceiveScreen> createState() =>
      _AccountCopyReceiveScreenState();
}

class _AccountCopyReceiveScreenState
    extends ConsumerState<AccountCopyReceiveScreen> {
  final TextEditingController _code = TextEditingController();
  AccountCopyTarget? _target;
  String? _digits;
  bool _busy = false;
  bool _downloading = false;
  int _done = 0;
  int _total = 0;
  String? _message;
  bool _good = false;

  @override
  void dispose() {
    _code.dispose();
    unawaited(_target?.dispose());
    super.dispose();
  }

  Future<void> _scan() async {
    final String? text = await ref.read(peerQrScannerProvider).scan(context);
    if (text != null && text.trim().isNotEmpty) {
      _code.text = text.trim();
      await _connect();
    }
  }

  void _say(String text, {bool good = false}) {
    if (mounted) {
      setState(() {
        _message = text;
        _good = good;
      });
    }
  }

  Future<void> _connect() async {
    final AccountCopyTicket? ticket = AccountCopyTicket.parse(_code.text);
    final AccountArchiveImporter? importer = ref.read(
      accountArchiveImporterProvider,
    );
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    if (ticket == null) {
      final String? other = AccountCopyTicket.otherVersion(_code.text);
      _say(
        other != null
            ? accountLinkVersionText(other == '?' ? null : other)
            : t('To nie jest kod przeniesienia konta.'),
      );
      return;
    }
    if (importer == null || node == null) {
      _say(t('Konto nie jest jeszcze gotowe.'));
      return;
    }
    await _target?.dispose();
    final AccountCopyTarget target = AccountCopyTarget(
      transport: ref.read(meshTransportProvider),
      ticket: ticket,
      staging: importer.staging,
      deviceName: thisDeviceName,
    );
    _target = target;
    setState(() {
      _busy = true;
      _message = null;
      _digits = null;
    });
    try {
      await node.start();
      final String digits = await target.hello();
      if (!mounted) {
        return;
      }
      setState(() => _digits = digits);
      final AccountCopyOffer? offer = await target.offer();
      if (offer == null) {
        final String? other = target.versionMismatch;
        _say(
          other != null
              ? accountLinkVersionText(other == '?' ? null : other)
              : t('Drugie urządzenie nie pozwoliło.'),
        );
        return;
      }
      final String? refused = accountImportRefusal(
        await importer.check(offer.account, withKey: offer.seed != null),
      );
      if (refused != null) {
        _say(refused);
        return;
      }
      await node.rememberDeviceAddresses(offer.siblings);
      setState(() {
        _downloading = true;
        _total = offer.totalBytes;
      });
      final AccountArchive archive = await target.download(
        offer,
        progress: (int done, int total) {
          if (mounted) {
            setState(() {
              _done = done;
              _total = total;
            });
          }
        },
      );
      final AccountImportOutcome outcome = await importer.take(archive);
      final String? refusedLate = accountImportRefusal(outcome);
      if (refusedLate != null) {
        await importer.staging.clear(archive);
        _say(refusedLate);
        return;
      }
      _say(
        t(
          'Wszystko przyszło. Aplikacja uruchamia się ponownie i pokaże, '
          'co wróciło.',
        ),
        good: true,
      );
    } on TimeoutException catch (error) {
      _say(error.message ?? t('Drugie urządzenie nie odpowiada.'));
    } on Object catch (error, stackTrace) {
      logZenError(
        'Taking the account from another device failed',
        error,
        stackTrace,
      );
      _say(
        t('Nie udało się. Spróbuj jeszcze raz — to, co przyszło, zostanie.'),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool canScan = ref.watch(peerQrScannerProvider).isSupported;
    return Scaffold(
      key: const Key('account-copy-receive'),
      appBar: AppBar(title: Text(t('Odzyskaj z innego urządzenia'))),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              Text(
                t(
                  'Na urządzeniu, które ma konto: Konto i odzyskiwanie → '
                  'Dodaj drugie urządzenie lub przenieś konto. Zeskanuj kod, '
                  'który pokaże, '
                  'albo go wklej.',
                ),
                style: TextStyle(color: zen.textSecondary, height: 1.4),
              ),
              const SizedBox(height: 12),
              if (canScan)
                FilledButton.icon(
                  key: const Key('account-copy-scan'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _busy ? null : () => unawaited(_scan()),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: Text(t('Zeskanuj kod')),
                ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('account-copy-code'),
                controller: _code,
                enabled: !_busy,
                enableIMEPersonalizedLearning: false,
                decoration: InputDecoration(
                  labelText: t('Kod z drugiego urządzenia'),
                  prefixIcon: const Icon(Icons.link_rounded),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                key: const Key('account-copy-connect'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : () => unawaited(_connect()),
                child: Text(t('Połącz')),
              ),
              if (_digits != null && !_downloading) ...<Widget>[
                const SizedBox(height: 12),
                AccountCopyDigits(_digits!),
                Text(
                  t(
                    'Sprawdź, czy drugie urządzenie pokazuje te same cyfry, i '
                    'pozwól tam.',
                  ),
                  style: TextStyle(color: zen.textSecondary, height: 1.4),
                ),
              ],
              if (_downloading) ...<Widget>[
                const SizedBox(height: 16),
                AccountCopyProgress(
                  done: _done,
                  total: _total,
                  label: t('Pobieram konto…'),
                ),
              ],
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    _message!,
                    key: const Key('account-copy-message'),
                    style: TextStyle(
                      color: _good ? zen.success : zen.danger,
                      height: 1.4,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () =>
                    unawaited(AccountRestoreInfoScreen.open(context)),
                icon: const Icon(Icons.help_outline_rounded),
                label: Text(t('Co da się odzyskać i jak')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
