import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/account/presentation/account_import_layer.dart';
import 'package:zen/src/features/account/presentation/circle_backup_card.dart';
import 'package:zen/src/features/account/presentation/key_backup_screen.dart';
import 'package:zen/src/features/account/presentation/key_restore_screen.dart';
import 'package:zen/src/features/account/presentation/recovery_circle_list.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/qr_sticker/presentation/zen_qr_view.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/zen_link_router.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// "Konto i odzyskiwanie": account password, the circle that keeps
/// recovery pieces, helping friends, and recovering on a new device.
class AccountRecoveryScreen extends ConsumerStatefulWidget {
  const AccountRecoveryScreen({super.key});

  /// Opens after the person confirms who they are.
  static Future<void> open(BuildContext context) async {
    if (!await confirmSensitiveAccess(
          context,
          reason: t('Konto i odzyskiwanie są chronione. Potwierdź, że to Ty.'),
        ) ||
        !context.mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const AccountRecoveryScreen(),
      ),
    );
  }

  @override
  ConsumerState<AccountRecoveryScreen> createState() =>
      _AccountRecoveryScreenState();
}

class _AccountRecoveryScreenState extends ConsumerState<AccountRecoveryScreen> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _repeat = TextEditingController();
  final TextEditingController _recoverPassword = TextEditingController();
  final TextEditingController _helperCode = TextEditingController();
  StreamSubscription<void>? _changes;
  RecoveryService? _service;
  LedgerNode? _node;
  bool _busy = false;
  String? _message;

  /// Accounts the received pieces open, waiting for the person to confirm
  /// one by its fingerprint (nothing is taken before that).
  List<RecoveredAccount>? _candidates;

  @override
  void initState() {
    super.initState();
    _service = ref.read(recoveryServiceProvider);
    _node = ref.read(ledgerNodeProvider);
    _changes = _service?.changes.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    unawaited(
      Future.wait(<Future<void>>[
        if (_service != null) _service!.start(),
        if (_node != null) _node!.start(),
      ]).then((_) {
        if (mounted) {
          setState(() {});
        }
        // The close friends as they are now (a level changed a moment
        // ago is not waited for until the next tick).
        unawaited(_service?.reconcile());
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    _current.dispose();
    _password.dispose();
    _repeat.dispose();
    _recoverPassword.dispose();
    _helperCode.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    String message;
    try {
      message = await action();
    } on ArgumentError catch (e) {
      message = '${e.message}';
    } on StateError catch (e) {
      message = e.message;
    } catch (e) {
      message = t('Nie udało się: {error}', {'error': e});
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _message = message;
      });
    }
  }

  /// Sets (or changes) the account password and seals the key under it for
  /// the pieces: the person's explicit act, the only moment the key is at
  /// hand. With a password set and the new fields left empty, the current
  /// one is kept (a circle of 1.16.4, another device that handed the
  /// pieces out): it must pass the same rules.
  Future<String> _setPassword() async {
    final LedgerNode? node = _node;
    final RecoveryService? service = _service;
    if (node == null || service == null) {
      return t('Konto nie jest jeszcze gotowe.');
    }
    final LedgerIdentity identity = node.identity;
    final bool had = identity.hasPassword;
    final String current = _current.text;
    final bool keep = had && _password.text.isEmpty && _repeat.text.isEmpty;
    final String password = keep ? current : _password.text;
    if (!keep && _password.text != _repeat.text) {
      return t('Hasła się różnią.');
    }
    checkRecoveryPassword(password);
    // Two of its holders could guess the account password offline: it
    // must not open this phone too.
    if (await ref.read(appSecurityServiceProvider).verifyPassword(password)) {
      return t('Hasło konta musi być inne niż hasło aplikacji.');
    }
    if (!mounted) {
      return '';
    }
    if (had) {
      final String? problem = await tryAccountPassword(
        context,
        () => identity.unlock(current),
        wrong: t('Konto ma już inne hasło. Najpierw podaj obecne.'),
      );
      if (problem != null) {
        return problem;
      }
    }
    try {
      final RecoverySeal seal = await RecoverySeal.make(
        identity.accountKey!.seed,
        password,
        now: DateTime.now().millisecondsSinceEpoch,
      );
      if (!keep) {
        await identity.setPassword(node.disk, password);
      }
      await service.setSeal(seal);
    } finally {
      identity.lock();
    }
    _current.clear();
    _password.clear();
    _repeat.clear();
    ref
      ..invalidate(accountSecureReminderProvider)
      ..invalidate(circleReminderProvider);
    return t(
      'Hasło konta ustawione. Kawałki klucza dostaną Twoi przyjaciele, gdy '
      'tylko będą w sieci.',
    );
  }

  /// Starts taking pieces on this device.
  Future<String> _beginRecovery() async {
    final RecoveryService? service = _service;
    if (service == null) {
      return t('Konto nie jest jeszcze gotowe.');
    }
    await service.beginRecovery();
    return t(
      'Odzyskiwanie rozpoczęte. Wpisz kody osób z kręgu, które Ci pomogą: '
      'ich urządzenia dostaną prośbę o pomoc. Możesz też pokazać im kod '
      'tego urządzenia.',
    );
  }

  /// Names a helper of this recovery by their code: only named helpers
  /// (and friends) can send pieces here.
  Future<String> _addHelper() async {
    final RecoveryService? service = _service;
    if (service == null) {
      return t('Konto nie jest jeszcze gotowe.');
    }
    if (!await service.allowHelper(_helperCode.text)) {
      return t('Nieprawidłowy kod.');
    }
    _helperCode.clear();
    return t(
      'Dodano. Ta osoba dostała prośbę o pomoc, a jej klucze będą '
      'przyjmowane.',
    );
  }

  /// Gives up the recovery: no more pieces, the received ones are dropped.
  Future<void> _endRecovery() async {
    final RecoveryService? service = _service;
    if (service == null) {
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        scrollable: true,
        title: Text(t('Przerwać odzyskiwanie?')),
        content: Text(
          t(
            'Otrzymane klucze zostaną usunięte, a pomocnicy będą musieli '
            'wysłać je od nowa.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('recovery-stop-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Przerwij')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    await _run(() async {
      await service.endRecovery();
      _candidates = null;
      _recoverPassword.clear();
      return t('Odzyskiwanie przerwane. Otrzymane klucze usunięte.');
    });
  }

  /// Finds the accounts the received pieces open; nothing is taken until
  /// the person confirms one ([_adopt]).
  Future<String> _recover() async {
    final RecoveryService? service = _service;
    if (service == null || _node == null) {
      return t('Konto nie jest jeszcze gotowe.');
    }
    final List<RecoveredAccount> found = await recoverWithPassword(
      service.received(RecoveryKind.normal),
      _recoverPassword.text,
      acceptedCosts: service.acceptedCosts,
    );
    _candidates = found.isEmpty ? null : found;
    if (found.isEmpty) {
      return t('Złe hasło albo za mało pasujących kluczy.');
    }
    return t('Klucze pasują. Sprawdź odcisk konta, zanim je przejmiesz.');
  }

  /// Takes [candidate] after the person confirmed its fingerprint.
  Future<String> _adopt(RecoveredAccount candidate) async {
    final RecoveryService? service = _service;
    final LedgerNode? node = _node;
    if (service == null || node == null) {
      return t('Konto nie jest jeszcze gotowe.');
    }
    // The seed must be the key of exactly the account that was confirmed.
    if ((await LedgerKeyPair.fromSeed(candidate.seed)).id !=
        candidate.account) {
      _candidates = null;
      return t('Otrzymany klucz nie pasuje do konta.');
    }
    // The friends who helped keep a sealed copy of the friends and groups:
    // greeted first after the restart, they give it back. Senders of
    // pieces for other accounts are not greeted.
    await node.rememberDeviceAddresses(<String>{
      ...candidate.helpers,
      for (final RecoveryKind kind in RecoveryKind.values)
        for (final Map<String, dynamic> h in service.received(kind))
          if (claimedRecoveryAccount(h) == candidate.account &&
              h['from'] is String)
            h['from'] as String,
    });
    await LedgerIdentity.adoptAccount(
      node.disk,
      candidate.seed,
      deviceName: thisDeviceName,
    );
    // The pyramid key comes from the account key: the place and the
    // wallet come back with the records friends keep.
    await PyramidService.markRecovered(node.disk);
    // The copy of the data kept by the circle comes back after the
    // restart: asked for from the helpers first, then friends.
    await CircleBackupService.markRestore(
      node.disk,
      helpers: <String>{...candidate.helpers, ...service.helperAddresses},
    );
    await service.endRecovery();
    _candidates = null;
    _recoverPassword.clear();
    return t(
      'Konto odzyskane. Uruchom aplikację ponownie, żeby z niego '
      'korzystać.',
    );
  }

  /// Every account the received pieces name or open: more than one means
  /// someone may be slipping in another account's key.
  Set<String> _accountsSeen(RecoveryService service) => <String>{
    for (final RecoveryKind kind in RecoveryKind.values)
      ...claimedRecoveryAccounts(service.received(kind)),
    for (final RecoveredAccount c in _candidates ?? const <RecoveredAccount>[])
      c.account,
  };

  /// Fingerprint of the account whose piece this device keeps for [owner].
  String? _heldFingerprint(RecoveryService service, String owner) {
    final String? account = service.heldAccount(owner);
    return account == null ? null : accountFingerprint(account);
  }

  /// A new device asked for help: whose piece it wants is not known, so
  /// with several held the person picks the owner first.
  Future<void> _answerRequest(
    RecoveryService service,
    RecoveryHelpRequest request,
    String Function(String) nameOf,
  ) async {
    final List<String> owners = service.heldFor.toList();
    String? owner = owners.length == 1 ? owners.single : null;
    owner ??= await showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => SimpleDialog(
        title: Text(t('Komu pomagasz?')),
        children: <Widget>[
          for (final String o in owners)
            SimpleDialogOption(
              key: Key('recovery-request-owner-$o'),
              onPressed: () => Navigator.of(dialog).pop(o),
              child: Text(_ownerName(service, o, nameOf)),
            ),
        ],
      ),
    );
    if (owner == null || !mounted) {
      return;
    }
    await _help(owner, _ownerName(service, owner, nameOf), to: request.from);
  }

  /// The name of the person whose pieces are kept under [owner] (the
  /// friend they came from).
  String _ownerName(
    RecoveryService service,
    String owner,
    String Function(String) nameOf,
  ) => nameOf(service.heldFrom(owner) ?? owner);

  Future<void> _help(String owner, String name, {String? to}) async {
    final TextEditingController target = TextEditingController(
      text: to == null ? '' : PeerShareCodec.inviteCodeForAddress(to) ?? to,
    );
    String? error;
    const RecoveryKind kind = RecoveryKind.normal;
    final PeerQrScanner scanner = ref.read(peerQrScannerProvider);
    String? check(String text) {
      if (text.trim().isEmpty) {
        return null;
      }
      try {
        parseRecoveryDevice(text);
        return null;
      } on FormatException catch (e) {
        return e.message;
      }
    }

    final String? fingerprint = _heldFingerprint(_service!, owner);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => StatefulBuilder(
        builder: (BuildContext dialog, StateSetter setDialog) => AlertDialog(
          title: Text(t('Pomóż odzyskać konto: {name}', {'name': name})),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ZenInfo(
                  icon: Icons.shield_outlined,
                  tone: ZenColors.of(dialog).warning,
                  text: t(
                    'Zrób to tylko, jeśli na pewno rozmawiasz z tą osobą '
                    '(najlepiej na żywo). Jej stare urządzenia dostaną alarm '
                    'i mogą to zatrzymać.',
                  ),
                ),
                if (fingerprint != null) ...<Widget>[
                  const SizedBox(height: 8),
                  ZenInfo(
                    key: const Key('recovery-help-fingerprint'),
                    icon: Icons.fingerprint_rounded,
                    tone: ZenColors.of(dialog).accent,
                    text: t(
                      'Odcisk konta tej osoby: {fingerprint}. Jej nowe '
                      'urządzenie pokaże ten sam, zanim przejmie konto — '
                      'porównajcie go.',
                      {'fingerprint': fingerprint},
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  key: const Key('recovery-help-address'),
                  controller: target,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (String text) =>
                      setDialog(() => error = check(text)),
                  decoration: InputDecoration(
                    labelText: t('Kod nowego urządzenia'),
                    hintText: t('Kod, link albo QR z ekranu tej osoby'),
                    errorText: error,
                    errorMaxLines: 4,
                    prefixIcon: const Icon(Icons.smartphone_rounded),
                    suffixIcon: scanner.isSupported
                        ? IconButton(
                            key: const Key('recovery-help-scan'),
                            tooltip: t('Zeskanuj QR'),
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            onPressed: () async {
                              final String? scanned = await scanner.scan(
                                dialog,
                              );
                              if (scanned == null) {
                                return;
                              }
                              // Another Zen code (a pebble, a door, one of
                              // Zen's pages): its own screen.
                              if (!_isDeviceCode(scanned) &&
                                  zenLinkIntent(scanned) != null) {
                                if (dialog.mounted) {
                                  Navigator.of(dialog).pop(false);
                                }
                                openZenLink(ref, scanned);
                                return;
                              }
                              target.text = scanned;
                              setDialog(() => error = check(scanned));
                            },
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('recovery-help-confirm'),
              onPressed: () {
                final String text = target.text;
                final String? problem = text.trim().isEmpty
                    ? t('Wpisz kod nowego urządzenia albo zeskanuj jego QR.')
                    : check(text);
                if (problem != null) {
                  setDialog(() => error = problem);
                  return;
                }
                Navigator.of(dialog).pop(true);
              },
              child: Text(t('Pomóż')),
            ),
          ],
        ),
      ),
    );
    final String address = target.text.trim();
    disposeLater(target);
    if (ok != true || address.isEmpty) {
      return;
    }
    await _run(() async {
      try {
        await _service!.startHelping(owner, address, kind: kind);
      } on FormatException catch (e) {
        return e.message;
      }
      return t('Klucz zostanie wysłany po upływie czasu ochronnego.');
    });
  }

  /// A card that opens with an icon, a title and (optionally) a status.
  Widget _cardHeader(
    ZenColors zen, {
    required IconData icon,
    required Color tone,
    required String title,
    Widget? status,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      children: <Widget>[
        ZenIconBadge(icon: icon, tone: tone, size: 40),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 16.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (status != null) ...<Widget>[const SizedBox(width: 8), status],
      ],
    ),
  );

  Widget _paragraph(ZenColors zen, String text) => Text(
    text,
    style: TextStyle(color: zen.textSecondary, fontSize: 14, height: 1.4),
  );

  Widget _progress(ZenColors zen, String label, int got, int needed) {
    final double value = needed == 0
        ? 0
        : (got / needed).clamp(0, 1).toDouble();
    final Color tone = got >= needed ? zen.success : zen.accent;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
              ),
              Text(
                '$got/$needed',
                style: TextStyle(
                  color: tone,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: context.zenRadius(99),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              color: tone,
              backgroundColor: tone.withValues(alpha: 0.14),
            ),
          ),
        ],
      ),
    );
  }

  /// "Co odzyskasz": what comes back with the recovery circle and what
  /// does not, so nobody expects the photos of the chats on a new phone.
  Widget _recoverScope(ZenColors zen, Key key) => Container(
    key: key,
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: zen.surfaceSunk,
      borderRadius: context.zenRadius(16),
      border: Border.all(color: zen.outlineSoft),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t('CO ODZYSKASZ'), style: zen.label(color: zen.textMuted)),
        const SizedBox(height: 6),
        _scopeLine(
          zen,
          Icons.check_circle_outline_rounded,
          zen.success,
          t('Wraca: konto (tożsamość i hasło)'),
        ),
        _scopeLine(
          zen,
          Icons.check_circle_outline_rounded,
          zen.success,
          t(
            'Wraca: znajomi i grupy, z kopii u osób z kręgu, które oddały '
            'klucze',
          ),
        ),
        _scopeLine(
          zen,
          Icons.check_circle_outline_rounded,
          zen.success,
          t(
            'Wraca: teksty rozmów, profil, ustawienia, randki i sąsiedzi — '
            'z kopii u znajomych',
          ),
        ),
        _scopeLine(
          zen,
          Icons.check_circle_outline_rounded,
          zen.success,
          t('Wraca: piramida i portfel, gdy potwierdzą je osoby z piramidy'),
        ),
        _scopeLine(
          zen,
          Icons.cancel_outlined,
          zen.danger,
          t('Nie wraca: zdjęcia i pliki z rozmów, spotkania, filmy'),
        ),
        _scopeLine(
          zen,
          Icons.info_outline_rounded,
          zen.accent,
          t('Wszystko wraca z drugiego urządzenia albo z pliku kopii.'),
        ),
      ],
    ),
  );

  Widget _scopeLine(ZenColors zen, IconData icon, Color tone, String text) =>
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, size: 18, color: tone),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _mixedAccountsWarning(ZenColors zen) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: ZenInfo(
      key: const Key('recovery-mixed-accounts'),
      icon: Icons.warning_amber_rounded,
      tone: zen.danger,
      text: t(
        'Uwaga: przyszły klucze do różnych kont. Ktoś mógł podesłać klucze '
        'do cudzego konta, żeby przejąć to urządzenie. Przejmij tylko '
        'konto, którego odcisk potwierdzi osoba z kręgu.',
      ),
    ),
  );

  /// Before anything is taken: whose account the pieces open, from how many
  /// people, and a warning when pieces for different accounts came.
  Widget _candidatesCard(
    ZenColors zen,
    List<RecoveredAccount> candidates, {
    required bool mixed,
  }) => ZenCard(
    key: const Key('recovery-candidates'),
    tone: mixed ? zen.danger : null,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _cardHeader(
          zen,
          icon: Icons.fingerprint_rounded,
          tone: mixed ? zen.danger : zen.accent,
          title: t('Czyje to konto?'),
        ),
        _paragraph(
          zen,
          t(
            'Osoba z kręgu widzi odcisk Twojego konta u siebie (Konto '
            'i odzyskiwanie → Przechowujesz klucze dla). Porównajcie go, '
            'najlepiej na żywo albo przez telefon. Przejmij konto tylko, '
            'jeśli się zgadza.',
          ),
        ),
        _recoverScope(zen, const Key('recovery-scope-after')),
        if (mixed) _mixedAccountsWarning(zen),
        for (int i = 0; i < candidates.length; i++)
          _candidate(zen, i, candidates[i]),
        const SizedBox(height: 4),
        TextButton(
          key: const Key('recovery-candidates-cancel'),
          onPressed: _busy ? null : () => setState(() => _candidates = null),
          child: Text(t('Anuluj')),
        ),
      ],
    ),
  );

  Widget _candidate(ZenColors zen, int index, RecoveredAccount c) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: zen.surfaceSunk,
      borderRadius: context.zenRadius(16),
      border: Border.all(color: zen.outlineSoft),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t('ODCISK KONTA'), style: zen.label(color: zen.textMuted)),
        const SizedBox(height: 4),
        SelectableText(
          c.fingerprint,
          key: Key('recovery-fingerprint-$index'),
          style: zen.mono(
            color: zen.textPrimary,
            size: 17,
            weight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          tn(
            c.helpers.length,
            one: 'Klucze od {n} osoby',
            few: 'Klucze od {n} różnych osób',
            many: 'Klucze od {n} różnych osób',
          ),
          key: Key('recovery-helpers-$index'),
          style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          key: Key('recovery-adopt-$index'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy ? null : () => unawaited(_run(() => _adopt(c))),
          icon: const Icon(Icons.check_rounded),
          label: Text(
            t('Odcisk się zgadza — przejmij to konto'),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    ),
  );

  /// "Klucz u przyjaciół": the rule (every close friend holds a piece by
  /// itself, how many must agree), who holds one and who confirmed it, and
  /// a circle of 1.16.4 still valid until the new pieces are complete.
  Widget _piecesCard(
    ZenColors zen,
    RecoveryService service,
    LedgerNode node,
    SocialHubState social,
  ) {
    final RecoveryProtection p = service.protection;
    final RecoveryGeneration? g = service.generation;
    final int close = social.acceptedFriends
        .where(
          (FriendProfile f) => node.levelOf(f.address) == FriendLevel.close,
        )
        .length;
    final bool pieces = g != null && g.holders.isNotEmpty;
    return ZenCard(
      key: const Key('recovery-pieces'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _cardHeader(
            zen,
            icon: Icons.diversity_3_rounded,
            tone: zen.tone(ZenTone.privacy),
            title: t('Klucz u przyjaciół'),
            status: pieces
                ? ZenPill(
                    key: const Key('recovery-pieces-acked'),
                    text: '${g.acked}/${g.threshold}',
                    tone: g.complete ? zen.success : zen.warning,
                    icon: g.complete ? Icons.check_rounded : null,
                  )
                : null,
          ),
          _paragraph(
            zen,
            t(
              'Każdy, kogo oznaczysz jako „Przyjaciel”, sam dostaje kawałek '
              'klucza Twojego konta, a kto przestanie nim być, traci go. Na '
              'nowym telefonie odzyskasz konto hasłem konta i zgodą kilku '
              'z nich: 2, gdy kawałki ma do 4 osób, 3 przy 5–9, 4 przy 10 '
              'i więcej.',
            ),
          ),
          const SizedBox(height: 8),
          ZenInfo(
            key: const Key('recovery-pieces-status'),
            icon: p.secured
                ? Icons.verified_user_outlined
                : Icons.info_outline_rounded,
            tone: p.secured ? zen.success : zen.warning,
            text: !p.sealed
                ? t('Kawałków jeszcze nie ma: najpierw ustaw hasło konta.')
                : !pieces
                ? tn(
                    close,
                    one:
                        'Kawałki dostaną co najmniej 2 osoby oznaczone jako '
                        '„Przyjaciel”. Masz {n}.',
                    few:
                        'Kawałki dostaną co najmniej 2 osoby oznaczone jako '
                        '„Przyjaciel”. Masz {n}.',
                    many:
                        'Kawałki dostaną co najmniej 2 osoby oznaczone jako '
                        '„Przyjaciel”. Masz {n}.',
                  )
                : t(
                    'Do odzyskania potrzeba zgody {t} z {n} osób.',
                    <String, Object?>{'t': g.threshold, 'n': g.holders.length},
                  ),
          ),
          if (p.legacy > 0) ...<Widget>[
            const SizedBox(height: 8),
            ZenInfo(
              key: const Key('recovery-pieces-legacy'),
              icon: Icons.history_rounded,
              text: t(
                'Dotychczasowy krąg działa, dopóki nowe kawałki nie potwierdzi '
                '{t} przyjaciół. Potem jego osoby dostaną prośbę o usunięcie '
                'starych kawałków.',
                <String, Object?>{
                  't': pieces ? g.threshold : kRecoveryCircleMinimum,
                },
              ),
            ),
          ],
          const SizedBox(height: 8),
          const RecoveryCircleMembersView(),
          const SizedBox(height: 8),
          Text(
            t('Odcisk Twojego konta: {fingerprint}', {
              'fingerprint': accountFingerprint(node.identity.account),
            }),
            key: const Key('recovery-own-fingerprint'),
            style: TextStyle(color: zen.textMuted, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  /// A release the owner's device stopped: the helper may withdraw it, or
  /// (sure of the person, whose phone may be in someone else's hands) give
  /// the piece after all, [kOverrideDelay] later.
  Widget _stoppedRelease(
    ZenColors zen,
    RecoveryService service,
    PendingRelease p,
    String Function(String) nameOf,
  ) => ZenCard(
    key: Key('recovery-stopped-${p.to}'),
    tone: zen.warning,
    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenInfo(
          icon: Icons.front_hand_outlined,
          tone: zen.warning,
          title: t('Klucz dla: {name}', {
            'name': _ownerName(service, p.owner, nameOf),
          }),
          text: t(
            'Urządzenie tej osoby zatrzymało wydanie klucza. Jeśli na pewno '
            'z nią rozmawiasz, a jej telefon mógł zostać skradziony, możesz '
            'wydać klucz mimo to: za {days} dni, z nowym alarmem, którego '
            'nie da się już zatrzymać.',
            <String, Object?>{'days': kOverrideDelay.inDays},
          ),
        ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          children: <Widget>[
            TextButton(
              onPressed: () => unawaited(service.withdrawRelease(p)),
              child: Text(t('Wycofaj')),
            ),
            FilledButton(
              key: Key('recovery-override-${p.to}'),
              onPressed: _busy
                  ? null
                  : () => unawaited(service.overrideRelease(p)),
              child: Text(t('Wydaj mimo to')),
            ),
          ],
        ),
      ],
    ),
  );

  Future<void> _scanHelper() async {
    // A helper's code is their invitation link; other Zen codes open their
    // own screen.
    final String? scanned = await scanZenCode(
      context,
      ref,
      accepts: _isDeviceCode,
    );
    if (scanned == null || !mounted) {
      return;
    }
    _helperCode.text = scanned;
    await _run(_addHelper);
  }

  /// The new device's invitation code and QR: what the helpers type in or
  /// scan (no raw network address to read out).
  Widget _deviceCodePanel(ZenColors zen, String myAddress) {
    final PeerShareProfile? me = PeerShareCodec.buildLocalProfile(
      address: myAddress,
    );
    return Container(
      key: const Key('recovery-device-code'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: zen.surfaceSunk,
        borderRadius: context.zenRadius(16),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t('KOD TEGO URZĄDZENIA'),
            style: zen.label(color: zen.textMuted),
          ),
          const SizedBox(height: 4),
          if (me == null)
            Text(
              t('Kod pojawi się, gdy urządzenie połączy się z siecią.'),
              style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
            )
          else ...<Widget>[
            SelectableText(
              me.inviteCode,
              key: const Key('recovery-device-invite-code'),
              textAlign: TextAlign.center,
              style: zen.mono(
                color: zen.textPrimary,
                size: 16,
                weight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: ZenFixed.qrPaper,
                  borderRadius: context.zenRadius(16),
                ),
                child: ZenQrView(data: me.qrData, size: 180),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              t(
                'Osoby z kręgu wpisują ten kod albo skanują QR w „Pomóż '
                'odzyskać”. Kod nie jest tajny.',
              ),
              style: TextStyle(color: zen.textSecondary, fontSize: 13),
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                key: const Key('recovery-device-code-copy'),
                onPressed: () => unawaited(copyPublicText(me.inviteCode)),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(t('Kopiuj kod')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _when(int millis) {
    return ZenFormat.dayMonthTime(DateTime.fromMillisecondsSinceEpoch(millis));
  }

  @override
  Widget build(BuildContext context) =>
      SecureScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final RecoveryService? service = _service;
    final LedgerNode? node = _node;
    final SocialHubState social = watchSocialPeople(ref);
    String nameOf(String address) {
      final FriendProfile? f = social.friendByAddress(address);
      return f == null ? address : social.nameFor(f);
    }

    final String myAddress = ref.watch(
      runtimeNodeSnapshotProvider.select(
        (RuntimeTransportSnapshot s) => s.localAddress,
      ),
    );
    final bool ready = service != null && node != null && node.isReady;
    final bool hasPassword = ready && node.identity.hasPassword;
    final List<RecoveredAccount>? candidates = _candidates;
    final bool mixed = ready && _accountsSeen(service).length > 1;
    final int? collectingUntil = ready ? service.collectingUntil : null;
    final ({int got, int needed}) progress = ready
        ? service.receivedProgress
        : (got: 0, needed: kNormalThreshold);

    final ZenColors zen = ZenColors.of(context);
    final Color tone = zen.tone(ZenTone.privacy);
    return Scaffold(
      key: const Key('account-recovery-screen'),
      appBar: AppBar(title: Text(t('Konto i odzyskiwanie'))),
      body: SafeArea(
        top: false,
        child: !ready
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: zen.accent,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      t('Konto się uruchamia…'),
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 14.5,
                      ),
                    ),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: <Widget>[
                  if (_message != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                      decoration: BoxDecoration(
                        color: zen.accent.withValues(alpha: 0.09),
                        borderRadius: context.zenRadius(18),
                        border: Border.all(
                          color: zen.accent.withValues(alpha: 0.24),
                        ),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Icon(
                            Icons.info_outline_rounded,
                            color: zen.accent,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _message!,
                              key: const Key('recovery-message'),
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final RecoveryAlarm a in service.alarms)
                    ZenCard(
                      tone: zen.danger,
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Icon(
                                Icons.warning_amber_rounded,
                                color: zen.danger,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      t(
                                        '{name} wyda klucz Twojego konta {time}',
                                        <String, Object?>{
                                          'name': nameOf(a.helper),
                                          'time': _when(a.due),
                                        },
                                      ),
                                      style: TextStyle(
                                        color: zen.textPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14.5,
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      t('Dla urządzenia: {address}', {
                                        'address':
                                            PeerShareCodec.inviteCodeForAddress(
                                              a.to,
                                            ) ??
                                            a.to,
                                      }),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: zen.textSecondary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (a.override)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(34, 6, 0, 8),
                              child: Text(
                                t(
                                  'Ta osoba wydaje klucz mimo wcześniejszego '
                                  'zatrzymania i zatrzymanie już nie działa. '
                                  'Jeśli to nie Ty, zadzwoń do niej.',
                                ),
                                key: const Key('recovery-alarm-override'),
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            )
                          else
                            Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  foregroundColor: zen.danger,
                                ),
                                onPressed: () =>
                                    unawaited(service.cancelAlarm(a)),
                                child: Text(t('To nie ja – zatrzymaj')),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ZenCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _cardHeader(
                          zen,
                          icon: Icons.lock_rounded,
                          tone: tone,
                          title: t('Hasło konta'),
                          status: hasPassword
                              ? ZenPill(
                                  text: t('ustawione'),
                                  tone: zen.success,
                                  icon: Icons.check_rounded,
                                )
                              : ZenPill(text: t('brak'), tone: zen.warning),
                        ),
                        if (!hasPassword)
                          _paragraph(
                            zen,
                            t(
                              'Hasło konta chroni klucz konta: bez niego '
                              'złodziej telefonu nie przejmie konta, a '
                              'przyjaciele nie dostaną kawałków klucza.',
                            ),
                          ),
                        if (hasPassword && !service.hasSeal)
                          _paragraph(
                            zen,
                            t(
                              'Podaj obecne hasło konta (albo ustaw nowe), '
                              'żeby to urządzenie rozdawało kawałki klucza '
                              'przyjaciołom.',
                            ),
                          ),
                        const SizedBox(height: 8),
                        ZenInfo(
                          key: const Key('recovery-password-explained'),
                          icon: Icons.help_outline_rounded,
                          text: t(
                            'Hasło konta musi być inne niż hasło aplikacji: '
                            'tamto odblokowuje Zen na tym urządzeniu, to '
                            'chroni klucz konta i wpiszesz je na nowym '
                            'telefonie. Przyjaciele z kawałkami mogliby '
                            'próbować je zgadnąć, więc wybierz długie: co '
                            'najmniej {n} znaków, najlepiej kilka słów.',
                            <String, Object?>{'n': kMinRecoveryPasswordLength},
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (hasPassword) ...<Widget>[
                          TextField(
                            key: const Key('recovery-password-current'),
                            controller: _current,
                            obscureText: true,
                            enableIMEPersonalizedLearning: false,
                            decoration: InputDecoration(
                              labelText: t('Obecne hasło'),
                              prefixIcon: const Icon(Icons.lock_open_rounded),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        TextField(
                          key: const Key('recovery-password'),
                          controller: _password,
                          obscureText: true,
                          enableIMEPersonalizedLearning: false,
                          decoration: InputDecoration(
                            labelText: t('Nowe hasło'),
                            helperText: hasPassword
                                ? t('Puste: zostaje obecne')
                                : null,
                            prefixIcon: const Icon(Icons.password_rounded),
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          key: const Key('recovery-password-repeat'),
                          controller: _repeat,
                          obscureText: true,
                          enableIMEPersonalizedLearning: false,
                          decoration: InputDecoration(
                            labelText: t('Powtórz hasło'),
                            prefixIcon: const Icon(Icons.password_rounded),
                          ),
                        ),
                        const SizedBox(height: 12),
                        ZenInfo(
                          key: const Key('recovery-password-warning'),
                          icon: Icons.warning_amber_rounded,
                          text: t(
                            'Zapamiętaj hasło konta: bez niego konta nie da '
                            'się odzyskać, nawet ze wszystkimi znajomymi z '
                            'kręgu. Zen go nie zna i nie przypomni.',
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          key: const Key('recovery-set-password'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: _busy
                              ? null
                              : () => unawaited(_run(_setPassword)),
                          child: Text(
                            hasPassword
                                ? t('Zmień hasło konta')
                                : t('Ustaw hasło konta'),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _piecesCard(zen, service, node, social),
                  // The copy of the data the circle keeps.
                  const CircleBackupCard(),
                  ZenSection(t('Przechowujesz klucze dla')),
                  if (service.heldFor.isNotEmpty)
                    for (final RecoveryHelpRequest r in service.helpRequests)
                      ZenCard(
                        key: Key('recovery-request-${r.from}'),
                        tone: zen.warning,
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            ZenInfo(
                              icon: Icons.support_rounded,
                              tone: zen.warning,
                              title: t('Ktoś prosi o pomoc w odzyskaniu konta'),
                              text: t(
                                'Nowe urządzenie podało Cię jako osobę z kręgu '
                                '({time}). Pomóż tylko, jeśli wiesz na pewno, '
                                'kto to jest — najlepiej porozmawiaj na żywo '
                                'albo przez telefon i porównajcie odcisk konta.',
                                <String, Object?>{'time': _when(r.at)},
                              ),
                            ),
                            Wrap(
                              alignment: WrapAlignment.end,
                              spacing: 8,
                              children: <Widget>[
                                TextButton(
                                  key: Key(
                                    'recovery-request-dismiss-${r.from}',
                                  ),
                                  onPressed: () => unawaited(
                                    service.dismissHelpRequest(r.from),
                                  ),
                                  child: Text(t('Odrzuć')),
                                ),
                                FilledButton(
                                  key: Key('recovery-request-help-${r.from}'),
                                  onPressed: _busy
                                      ? null
                                      : () => unawaited(
                                          _answerRequest(service, r, nameOf),
                                        ),
                                  child: Text(t('Pomóż')),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  if (service.heldFor.isEmpty)
                    ZenInfo(
                      icon: Icons.key_off_rounded,
                      tone: zen.textMuted,
                      text: t('Nikt jeszcze nie powierzył Ci klucza.'),
                    ),
                  for (final String owner in service.heldFor)
                    ZenTile(
                      icon: Icons.key_rounded,
                      tone: tone,
                      title: _ownerName(service, owner, nameOf),
                      // Read it to the person: their new device shows the
                      // same one before it takes the account.
                      subtitle: switch (_heldFingerprint(service, owner)) {
                        final String fingerprint => t(
                          'Odcisk konta: {fingerprint}',
                          {'fingerprint': fingerprint},
                        ),
                        null => null,
                      },
                      trailing: TextButton(
                        key: Key('recovery-help-$owner'),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                        ),
                        onPressed: () => unawaited(
                          _help(owner, _ownerName(service, owner, nameOf)),
                        ),
                        child: Text(t('Pomóż odzyskać')),
                      ),
                    ),
                  for (final PendingRelease p in service.pending)
                    if (p.stopped == null)
                      ZenTile(
                        icon: Icons.schedule_send_rounded,
                        tone: zen.warning,
                        title: t('Klucz dla: {name}', {
                          'name': _ownerName(service, p.owner, nameOf),
                        }),
                        subtitle: t('Wyślesz klucz {name} → {address} {time}', <
                          String,
                          Object?
                        >{
                          'name': _ownerName(service, p.owner, nameOf),
                          'address':
                              PeerShareCodec.inviteCodeForAddress(p.to) ?? p.to,
                          'time': _when(p.due),
                        }),
                        trailing: IconButton(
                          key: Key('recovery-pending-withdraw-${p.to}'),
                          tooltip: t('Wycofaj'),
                          icon: const Icon(Icons.close_rounded),
                          onPressed: () =>
                              unawaited(service.withdrawRelease(p)),
                        ),
                      )
                    else
                      _stoppedRelease(zen, service, p, nameOf),
                  ZenSection(t('Odzyskaj konto na tym urządzeniu')),
                  ZenCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _cardHeader(
                          zen,
                          icon: Icons.restore_rounded,
                          tone: zen.tone(ZenTone.network),
                          title: t('Nowy telefon? Odzyskaj konto'),
                          status: collectingUntil == null
                              ? null
                              : ZenPill(
                                  text: t('trwa'),
                                  tone: zen.accent,
                                  icon: Icons.hourglass_top_rounded,
                                ),
                        ),
                        _paragraph(
                          zen,
                          t(
                            'Poproś przyjaciół z kawałkami klucza, żeby pomogli '
                            'odzyskać Twoje konto: dwóch, trzech albo czterech, '
                            'zależnie od tego, ilu ma kawałki (ich lista jest '
                            'przy kopii klucza albo na starym telefonie). Wpisz '
                            'tu ich kody — dostaną prośbę o pomoc. Po 24 h '
                            'wpisz hasło konta: bez niego konta nie da się '
                            'odzyskać.',
                          ),
                        ),
                        _recoverScope(zen, const Key('recovery-scope-before')),
                        if (collectingUntil == null) ...<Widget>[
                          const SizedBox(height: 8),
                          _paragraph(
                            zen,
                            t(
                              'Najpierw zacznij odzyskiwanie: dopiero wtedy to '
                              'urządzenie przyjmuje klucze od osób z kręgu.',
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            key: const Key('recovery-start'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                            ),
                            onPressed: _busy
                                ? null
                                : () => unawaited(_run(_beginRecovery)),
                            icon: const Icon(Icons.restore_rounded),
                            label: Text(t('Zacznij odzyskiwanie')),
                          ),
                        ] else ...<Widget>[
                          const SizedBox(height: 12),
                          _deviceCodePanel(zen, myAddress),
                          const SizedBox(height: 8),
                          Text(
                            t('To urządzenie przyjmuje klucze do {time}.', {
                              'time': _when(collectingUntil),
                            }),
                            key: const Key('recovery-collecting'),
                            style: TextStyle(
                              color: zen.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                          const SizedBox(height: 12),
                          _paragraph(
                            zen,
                            t(
                              'Kto Ci pomaga? Wpisz kody tych osób: klucze od '
                              'innych nie są przyjmowane.',
                            ),
                          ),
                          for (final String helper in service.allowedHelpers)
                            ZenTile(
                              key: Key('recovery-helper-$helper'),
                              icon: Icons.person_rounded,
                              tone: zen.accent,
                              title:
                                  PeerShareCodec.inviteCodeForAddress(helper) ??
                                  helper,
                              trailing: IconButton(
                                tooltip: t('Usuń'),
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () =>
                                    unawaited(service.removeHelper(helper)),
                              ),
                            ),
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: TextField(
                                  key: const Key('recovery-helper-code'),
                                  controller: _helperCode,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  decoration: InputDecoration(
                                    labelText: t('Kod osoby z kręgu'),
                                    hintText: t('Kod, link albo QR tej osoby'),
                                    prefixIcon: const Icon(
                                      Icons.person_add_alt_1_rounded,
                                    ),
                                    suffixIcon:
                                        ref
                                            .read(peerQrScannerProvider)
                                            .isSupported
                                        ? IconButton(
                                            key: const Key(
                                              'recovery-helper-scan',
                                            ),
                                            tooltip: t('Zeskanuj QR'),
                                            icon: const Icon(
                                              Icons.qr_code_scanner_rounded,
                                            ),
                                            onPressed: () =>
                                                unawaited(_scanHelper()),
                                          )
                                        : null,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                key: const Key('recovery-helper-add'),
                                tooltip: t('Dodaj'),
                                onPressed: _busy
                                    ? null
                                    : () => unawaited(_run(_addHelper)),
                                icon: const Icon(Icons.add_rounded),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          _progress(
                            zen,
                            t('Klucze z hasłem'),
                            progress.got,
                            progress.needed,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            t(
                              'Otrzymane klucze: {normal}/{normalNeeded}',
                              <String, Object?>{
                                'normal': progress.got,
                                'normalNeeded': progress.needed,
                              },
                            ),
                            key: const Key('recovery-received'),
                            style: TextStyle(
                              color: zen.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                          if (mixed && candidates == null)
                            _mixedAccountsWarning(zen),
                          const SizedBox(height: 14),
                          TextField(
                            key: const Key('recovery-old-password'),
                            controller: _recoverPassword,
                            obscureText: true,
                            enableIMEPersonalizedLearning: false,
                            decoration: InputDecoration(
                              labelText: t('Hasło odzyskiwanego konta'),
                              prefixIcon: const Icon(Icons.lock_open_rounded),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            key: const Key('recovery-recover'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(52),
                            ),
                            onPressed: _busy || progress.got < progress.needed
                                ? null
                                : () => unawaited(_run(_recover)),
                            icon: const Icon(Icons.restore_rounded),
                            label: Text(t('Odzyskaj z hasłem')),
                          ),
                          const SizedBox(height: 4),
                          TextButton(
                            key: const Key('recovery-stop'),
                            style: TextButton.styleFrom(
                              foregroundColor: zen.danger,
                            ),
                            onPressed: _busy
                                ? null
                                : () => unawaited(_endRecovery()),
                            child: Text(t('Przerwij odzyskiwanie')),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // The whole account: a backup file, another device.
                  ZenSection(t('Kopia i przenoszenie')),
                  const AccountCopyActions(),
                  ZenSection(t('Kopia klucza (kartka lub plik)')),
                  ZenCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _paragraph(
                          zen,
                          t(
                            'Kopia klucza (kartka z kodem albo plik z hasłem) '
                            'przywraca konto na nowym telefonie, nawet gdy nikt '
                            'z kręgu nie pomoże. Znajomi, grupy i teksty rozmów '
                            'wracają potem z kopii u znajomych, jeśli ją masz. '
                            'To nie jest kopia całego konta: zdjęć i plików z '
                            'rozmów nie przywróci. Kto ma kartkę albo plik '
                            'z hasłem, ma konto.',
                          ),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          key: const Key('key-backup-open'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          onPressed: () =>
                              unawaited(KeyBackupScreen.open(context)),
                          icon: const Icon(Icons.history_edu_rounded),
                          label: Text(t('Zrób kopię klucza')),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          key: const Key('key-restore-open-screen'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          onPressed: () =>
                              unawaited(KeyRestoreScreen.open(context)),
                          icon: const Icon(Icons.restore_page_outlined),
                          label: Text(t('Przywróć klucz')),
                        ),
                      ],
                    ),
                  ),
                  if (candidates != null && candidates.isNotEmpty)
                    _candidatesCard(zen, candidates, mixed: mixed),
                ],
              ),
      ),
    );
  }
}

/// Whether [text] is a device's code (its invitation code, link or QR, or a
/// plain address).
bool _isDeviceCode(String text) {
  try {
    parseRecoveryDevice(text);
    return true;
  } on FormatException {
    return false;
  }
}
