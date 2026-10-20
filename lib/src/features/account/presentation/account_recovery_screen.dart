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
import 'package:zen/src/features/account/presentation/key_backup_screen.dart';
import 'package:zen/src/features/account/presentation/key_restore_screen.dart';
import 'package:zen/src/features/account/recovery_circle_pick.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// "Konto i odzyskiwanie" (§6): account password, the circle that keeps
/// recovery pieces, helping friends, and recovering on a new device.
class AccountRecoveryScreen extends ConsumerStatefulWidget {
  const AccountRecoveryScreen({super.key});

  /// Opens after the person confirms who they are (§14.1 point 4).
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
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    _password.dispose();
    _repeat.dispose();
    _recoverPassword.dispose();
    _helperCode.dispose();
    super.dispose();
  }

  /// Who keeps the pieces: the mailbox circle and the other friends,
  /// "Przyjaciel" first (§7).
  List<String> _helpers() {
    final RelayEngine? engine = ref.read(relayEngineProvider);
    final SocialHubState social = ref.read(socialHubControllerProvider);
    final LedgerNode? node = _node;
    return pickRecoveryHelpers(
      mailboxes: <String>[...?engine?.overview.value.relays],
      friends: <String>[
        for (final FriendProfile f in social.acceptedFriends) f.address,
      ],
      levelOf: (String a) => node?.levelOf(a) ?? FriendLevel.friend,
    );
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

  Future<String> _setPassword() async {
    final LedgerNode? node = _node;
    final RecoveryService? service = _service;
    if (node == null || service == null) {
      return t('Konto nie jest jeszcze gotowe.');
    }
    if (_password.text != _repeat.text) {
      return t('Hasła się różnią.');
    }
    checkAccountPassword(_password.text);
    final LedgerIdentity identity = node.identity;
    if (identity.hasPassword && !await identity.unlock(_password.text)) {
      return t('Konto ma już inne hasło. Najpierw podaj obecne.');
    }
    final List<String> helpers = _helpers();
    if (helpers.length < kEmergencyThreshold) {
      return tn(
        kEmergencyThreshold,
        one:
            'Potrzeba co najmniej {n} znajomego, który '
            'przechowa klucze odzyskiwania.',
        few:
            'Potrzeba co najmniej {n} znajomych, którzy '
            'przechowają klucze odzyskiwania.',
        many:
            'Potrzeba co najmniej {n} znajomych, którzy '
            'przechowają klucze odzyskiwania.',
      );
    }
    final List<RecoveryPiece> pieces = await createRecoveryPieces(
      account: identity.account,
      seed: identity.accountKey!.seed,
      password: _password.text,
      helpers: helpers.length,
      now: DateTime.now().millisecondsSinceEpoch,
    );
    await identity.setPassword(node.disk, _password.text);
    await service.distribute(helpers, pieces);
    identity.lock();
    _password.clear();
    _repeat.clear();
    ref.invalidate(accountSecureReminderProvider);
    return tn(
      helpers.length,
      one: 'Hasło ustawione. Klucze odzyskiwania wysłane do {n} osoby.',
      few: 'Hasło ustawione. Klucze odzyskiwania wysłane do {n} osób.',
      many: 'Hasło ustawione. Klucze odzyskiwania wysłane do {n} osób.',
    );
  }

  /// Starts taking pieces on this device (§6.3).
  Future<String> _beginRecovery() async {
    final RecoveryService? service = _service;
    if (service == null) {
      return t('Konto nie jest jeszcze gotowe.');
    }
    await service.beginRecovery();
    return t(
      'Odzyskiwanie rozpoczęte. Podaj adres tego urządzenia osobom '
      'z kręgu, które Ci pomogą, i wpisz tu ich kody.',
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
    return t('Dodano. Klucze od tej osoby będą przyjmowane.');
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
  Future<String> _recover({required bool emergency}) async {
    final RecoveryService? service = _service;
    if (service == null || _node == null) {
      return t('Konto nie jest jeszcze gotowe.');
    }
    final List<RecoveredAccount> found = emergency
        ? await recoverWithoutPassword(service.received(RecoveryKind.emergency))
        : await recoverWithPassword(
            service.received(RecoveryKind.normal),
            _recoverPassword.text,
            acceptedCosts: service.acceptedCosts,
          );
    _candidates = found.isEmpty ? null : found;
    if (found.isEmpty) {
      return emergency
          ? t('Klucze nie pasują do siebie. Poczekaj na więcej.')
          : t('Złe hasło albo za mało pasujących kluczy.');
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
    // greeted first after the restart, they give it back (§6). Senders of
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

  Future<void> _help(String owner, String name) async {
    final TextEditingController to = TextEditingController();
    RecoveryKind kind = RecoveryKind.normal;
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
                  controller: to,
                  decoration: InputDecoration(
                    labelText: t('Adres nowego urządzenia'),
                    hintText: t('Wklej adres od tej osoby'),
                    prefixIcon: const Icon(Icons.smartphone_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    ChoiceChip(
                      showCheckmark: false,
                      avatar: const Icon(Icons.password_rounded, size: 18),
                      label: Text(t('Pamięta hasło (24 h)')),
                      selected: kind == RecoveryKind.normal,
                      onSelected: (_) =>
                          setDialog(() => kind = RecoveryKind.normal),
                    ),
                    ChoiceChip(
                      showCheckmark: false,
                      avatar: const Icon(Icons.timer_outlined, size: 18),
                      label: Text(t('Bez hasła (7 dni)')),
                      selected: kind == RecoveryKind.emergency,
                      onSelected: (_) =>
                          setDialog(() => kind = RecoveryKind.emergency),
                    ),
                  ],
                ),
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
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(t('Pomóż')),
            ),
          ],
        ),
      ),
    );
    final String address = to.text.trim();
    disposeLater(to);
    if (ok != true || address.isEmpty) {
      return;
    }
    await _run(() async {
      await _service!.startHelping(owner, address, kind: kind);
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
            borderRadius: BorderRadius.circular(99),
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

  /// "Co odzyskasz" (§6.3): what comes back with the recovery circle and what
  /// never does, so nobody expects the chat history on a new phone.
  Widget _recoverScope(ZenColors zen, Key key) => Container(
    key: key,
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: zen.surfaceSunk,
      borderRadius: BorderRadius.circular(16),
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
          Icons.cancel_outlined,
          zen.danger,
          t('Nie wraca: historia czatów'),
        ),
        _scopeLine(
          zen,
          Icons.cancel_outlined,
          zen.danger,
          t('Nie wraca: portfel'),
        ),
        _scopeLine(
          zen,
          Icons.cancel_outlined,
          zen.danger,
          t('Nie wraca: profil randkowy'),
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
      borderRadius: BorderRadius.circular(16),
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
        if (!c.claimed) ...<Widget>[
          const SizedBox(height: 8),
          ZenInfo(
            icon: Icons.info_outline_rounded,
            tone: zen.warning,
            text: t(
              'Pomocnicy mają starszą wersję Zen i nie podali, czyje to '
              'konto. Przejmij je tylko, jeśli odcisk się zgadza.',
            ),
          ),
        ],
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

    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 5);
    return Scaffold(
      key: const Key('account-recovery-screen'),
      appBar: AppBar(title: Text(t('Konto i odzyskiwanie'))),
      body: !ready
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
                    style: TextStyle(color: zen.textSecondary, fontSize: 14.5),
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
                      borderRadius: BorderRadius.circular(18),
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
                                      'address': a.to,
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
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: zen.danger,
                            ),
                            onPressed: () => unawaited(service.cancelAlarm(a)),
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
                      _paragraph(
                        zen,
                        hasPassword
                            ? tn(
                                service.acks.length,
                                one:
                                    'Hasło jest ustawione. Klucze odzyskiwania '
                                    'przechowuje {n} osoba.',
                                few:
                                    'Hasło jest ustawione. Klucze odzyskiwania '
                                    'przechowują {n} osoby.',
                                many:
                                    'Hasło jest ustawione. Klucze odzyskiwania '
                                    'przechowuje {n} osób.',
                              )
                            : t(
                                'Hasło chroni klucz konta: bez niego złodziej '
                                'telefonu nie przejmie konta. Przy okazji '
                                'znajomi z kręgu dostaną klucze odzyskiwania.',
                              ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t('Odcisk Twojego konta: {fingerprint}', {
                          'fingerprint': accountFingerprint(
                            node.identity.account,
                          ),
                        }),
                        key: const Key('recovery-own-fingerprint'),
                        style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('recovery-password'),
                        controller: _password,
                        obscureText: true,
                        enableIMEPersonalizedLearning: false,
                        decoration: InputDecoration(
                          labelText: hasPassword
                              ? t('Obecne hasło')
                              : t('Nowe hasło'),
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
                              ? t('Rozdaj klucze odzyskiwania ponownie')
                              : t('Ustaw hasło i rozdaj klucze'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
                ZenSection(t('Przechowujesz klucze dla')),
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
                    title: nameOf(owner),
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
                      onPressed: () => unawaited(_help(owner, nameOf(owner))),
                      child: Text(t('Pomóż odzyskać')),
                    ),
                  ),
                for (final PendingRelease p in service.pending)
                  ZenTile(
                    icon: Icons.schedule_send_rounded,
                    tone: zen.warning,
                    title: t('Klucz dla: {name}', {'name': nameOf(p.owner)}),
                    subtitle: t(
                      'Wyślesz klucz {name} → {address} {time}',
                      <String, Object?>{
                        'name': nameOf(p.owner),
                        'address': p.to,
                        'time': _when(p.due),
                      },
                    ),
                  ),
                ZenSection(t('Odzyskaj konto na tym urządzeniu')),
                ZenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _cardHeader(
                        zen,
                        icon: Icons.restore_rounded,
                        tone: zenTone(zen, 6),
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
                          'Poproś dwie osoby z kręgu, żeby pomogły odzyskać '
                          'Twoje konto, i podaj im adres tego urządzenia. Po '
                          '24 h wpisz hasło konta. Bez hasła potrzeba czterech '
                          'osób i 7 dni.',
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
                        Container(
                          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
                          decoration: BoxDecoration(
                            color: zen.surfaceSunk,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: zen.outlineSoft),
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      t('ADRES TEGO URZĄDZENIA'),
                                      style: zen.label(color: zen.textMuted),
                                    ),
                                    const SizedBox(height: 4),
                                    SelectableText(
                                      myAddress.isEmpty ? '—' : myAddress,
                                      style: zen.mono(
                                        color: zen.textPrimary,
                                        size: 13,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: t('Kopiuj adres'),
                                icon: const Icon(Icons.copy_rounded),
                                onPressed: myAddress.isEmpty
                                    ? null
                                    : () =>
                                          unawaited(copyWithExpiry(myAddress)),
                              ),
                            ],
                          ),
                        ),
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
                            title: helper,
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
                                decoration: InputDecoration(
                                  labelText: t('Kod osoby z kręgu'),
                                  prefixIcon: const Icon(
                                    Icons.person_add_alt_1_rounded,
                                  ),
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
                          service.receivedCount(RecoveryKind.normal),
                          kNormalThreshold,
                        ),
                        _progress(
                          zen,
                          t('Klucze bez hasła'),
                          service.receivedCount(RecoveryKind.emergency),
                          kEmergencyThreshold,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          t(
                            'Otrzymane klucze: {normal}/{normalNeeded} '
                            '(z hasłem), {emergency}/{emergencyNeeded} '
                            '(bez hasła)',
                            <String, Object?>{
                              'normal': service.receivedCount(
                                RecoveryKind.normal,
                              ),
                              'normalNeeded': kNormalThreshold,
                              'emergency': service.receivedCount(
                                RecoveryKind.emergency,
                              ),
                              'emergencyNeeded': kEmergencyThreshold,
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
                          onPressed:
                              _busy ||
                                  service.receivedCount(RecoveryKind.normal) <
                                      kNormalThreshold
                              ? null
                              : () => unawaited(
                                  _run(() => _recover(emergency: false)),
                                ),
                          icon: const Icon(Icons.restore_rounded),
                          label: Text(t('Odzyskaj z hasłem')),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          key: const Key('recovery-recover-emergency'),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          onPressed:
                              _busy ||
                                  service.receivedCount(
                                        RecoveryKind.emergency,
                                      ) <
                                      kEmergencyThreshold
                              ? null
                              : () => unawaited(
                                  _run(() => _recover(emergency: true)),
                                ),
                          child: Text(t('Odzyskaj bez hasła')),
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
                ZenSection(t('Kopia zapasowa klucza')),
                ZenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _paragraph(
                        zen,
                        t(
                          'Kopia klucza (plik z hasłem albo kod) przywraca samo '
                          'konto na nowym telefonie, nawet gdy nikt z kręgu '
                          'nie pomoże; czatów nie wraca. Kto ma plik z '
                          'hasłem lub kod, ma konto.',
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
    );
  }
}
