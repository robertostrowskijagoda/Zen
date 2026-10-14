import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/account/recovery_service.dart';
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
          reason: 'Konto i odzyskiwanie są chronione. Potwierdź, że to Ty.',
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
  StreamSubscription<void>? _changes;
  RecoveryService? _service;
  LedgerNode? _node;
  bool _busy = false;
  String? _message;

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
    super.dispose();
  }

  /// Who keeps the pieces: the mailbox circle, filled up with friends.
  List<String> _helpers() {
    final RelayEngine? engine = ref.read(relayEngineProvider);
    final List<String> circle = <String>[...?engine?.overview.value.relays];
    final SocialHubState social = ref.read(socialHubControllerProvider);
    for (final FriendProfile f in social.acceptedFriends) {
      if (circle.length >= 6) {
        break;
      }
      if (!circle.contains(f.address)) {
        circle.add(f.address);
      }
    }
    return circle;
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
      message = 'Nie udało się: $e';
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
      return 'Konto nie jest jeszcze gotowe.';
    }
    if (_password.text != _repeat.text) {
      return 'Hasła się różnią.';
    }
    checkAccountPassword(_password.text);
    final LedgerIdentity identity = node.identity;
    if (identity.hasPassword && !await identity.unlock(_password.text)) {
      return 'Konto ma już inne hasło. Najpierw podaj obecne.';
    }
    final List<String> helpers = _helpers();
    if (helpers.length < kEmergencyThreshold) {
      return 'Potrzeba co najmniej $kEmergencyThreshold znajomych, którzy '
          'przechowają klucze odzyskiwania.';
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
    return 'Hasło ustawione. Klucze odzyskiwania wysłane do '
        '${helpers.length} osób.';
  }

  Future<String> _recover({required bool emergency}) async {
    final RecoveryService? service = _service;
    final LedgerNode? node = _node;
    if (service == null || node == null) {
      return 'Konto nie jest jeszcze gotowe.';
    }
    final Uint8List? seed = emergency
        ? await recoverWithoutPassword(service.received(RecoveryKind.emergency))
        : await recoverWithPassword(
            service.received(RecoveryKind.normal),
            _recoverPassword.text,
          );
    if (seed == null) {
      return emergency
          ? 'Klucze nie pasują do siebie. Poczekaj na więcej.'
          : 'Złe hasło albo za mało pasujących kluczy.';
    }
    // The friends who helped keep a sealed copy of the friends and groups:
    // greeted first after the restart, they give it back (§6).
    await node.rememberDeviceAddresses(service.helperAddresses);
    await LedgerIdentity.adoptAccount(
      node.disk,
      seed,
      deviceName: thisDeviceName,
    );
    await service.clearReceived();
    return 'Konto odzyskane. Uruchom aplikację ponownie, żeby z niego '
        'korzystać.';
  }

  Future<void> _help(String owner, String name) async {
    final TextEditingController to = TextEditingController();
    RecoveryKind kind = RecoveryKind.normal;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => StatefulBuilder(
        builder: (BuildContext dialog, StateSetter setDialog) => AlertDialog(
          title: Text('Pomóż odzyskać konto: $name'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ZenInfo(
                  icon: Icons.shield_outlined,
                  tone: ZenColors.of(dialog).warning,
                  text:
                      'Zrób to tylko, jeśli na pewno rozmawiasz z tą osobą '
                      '(najlepiej na żywo). Jej stare urządzenia dostaną alarm '
                      'i mogą to zatrzymać.',
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('recovery-help-address'),
                  controller: to,
                  decoration: const InputDecoration(
                    labelText: 'Adres nowego urządzenia',
                    hintText: 'Wklej adres od tej osoby',
                    prefixIcon: Icon(Icons.smartphone_rounded),
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
                      label: const Text('Pamięta hasło (24 h)'),
                      selected: kind == RecoveryKind.normal,
                      onSelected: (_) =>
                          setDialog(() => kind = RecoveryKind.normal),
                    ),
                    ChoiceChip(
                      showCheckmark: false,
                      avatar: const Icon(Icons.timer_outlined, size: 18),
                      label: const Text('Bez hasła (7 dni)'),
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
              child: const Text('Anuluj'),
            ),
            FilledButton(
              key: const Key('recovery-help-confirm'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: const Text('Pomóż'),
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
      return 'Klucz zostanie wysłany po upływie czasu ochronnego.';
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

  String _when(int millis) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
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

    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 5);
    return Scaffold(
      key: const Key('account-recovery-screen'),
      appBar: AppBar(title: const Text('Konto i odzyskiwanie')),
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
                    'Konto się uruchamia…',
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
                                    '${nameOf(a.helper)} wyda klucz Twojego '
                                    'konta ${_when(a.due)}',
                                    style: TextStyle(
                                      color: zen.textPrimary,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 14.5,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    'Dla urządzenia: ${a.to}',
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
                            child: const Text('To nie ja – zatrzymaj'),
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
                        title: 'Hasło konta',
                        status: hasPassword
                            ? ZenPill(
                                text: 'ustawione',
                                tone: zen.success,
                                icon: Icons.check_rounded,
                              )
                            : ZenPill(text: 'brak', tone: zen.warning),
                      ),
                      _paragraph(
                        zen,
                        hasPassword
                            ? 'Hasło jest ustawione. Klucze odzyskiwania '
                                  'przechowuje ${service.acks.length} osób.'
                            : 'Hasło chroni klucz konta: bez niego złodziej '
                                  'telefonu nie przejmie konta. Przy okazji '
                                  'znajomi z kręgu dostaną klucze odzyskiwania.',
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('recovery-password'),
                        controller: _password,
                        obscureText: true,
                        enableIMEPersonalizedLearning: false,
                        decoration: InputDecoration(
                          labelText: hasPassword
                              ? 'Obecne hasło'
                              : 'Nowe hasło',
                          prefixIcon: const Icon(Icons.password_rounded),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        key: const Key('recovery-password-repeat'),
                        controller: _repeat,
                        obscureText: true,
                        enableIMEPersonalizedLearning: false,
                        decoration: const InputDecoration(
                          labelText: 'Powtórz hasło',
                          prefixIcon: Icon(Icons.password_rounded),
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
                              ? 'Rozdaj klucze odzyskiwania ponownie'
                              : 'Ustaw hasło i rozdaj klucze',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ],
                  ),
                ),
                const ZenSection('Przechowujesz klucze dla'),
                if (service.heldFor.isEmpty)
                  ZenInfo(
                    icon: Icons.key_off_rounded,
                    tone: zen.textMuted,
                    text: 'Nikt jeszcze nie powierzył Ci klucza.',
                  ),
                for (final String owner in service.heldFor)
                  ZenTile(
                    icon: Icons.key_rounded,
                    tone: tone,
                    title: nameOf(owner),
                    trailing: TextButton(
                      key: Key('recovery-help-$owner'),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      onPressed: () => unawaited(_help(owner, nameOf(owner))),
                      child: const Text('Pomóż odzyskać'),
                    ),
                  ),
                for (final PendingRelease p in service.pending)
                  ZenTile(
                    icon: Icons.schedule_send_rounded,
                    tone: zen.warning,
                    title: 'Klucz dla: ${nameOf(p.owner)}',
                    subtitle:
                        'Wyślesz klucz ${nameOf(p.owner)} → ${p.to} '
                        '${_when(p.due)}',
                  ),
                const ZenSection('Odzyskaj konto na tym urządzeniu'),
                ZenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _cardHeader(
                        zen,
                        icon: Icons.restore_rounded,
                        tone: zenTone(zen, 6),
                        title: 'Nowy telefon? Odzyskaj konto',
                      ),
                      _paragraph(
                        zen,
                        'Poproś dwie osoby z kręgu, żeby pomogły odzyskać Twoje '
                        'konto, i podaj im adres tego urządzenia. Po 24 h '
                        'wpisz hasło konta. Bez hasła potrzeba czterech osób '
                        'i 7 dni.',
                      ),
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
                                    'ADRES TEGO URZĄDZENIA',
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
                              tooltip: 'Kopiuj adres',
                              icon: const Icon(Icons.copy_rounded),
                              onPressed: myAddress.isEmpty
                                  ? null
                                  : () => unawaited(copyWithExpiry(myAddress)),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _progress(
                        zen,
                        'Klucze z hasłem',
                        service.receivedCount(RecoveryKind.normal),
                        kNormalThreshold,
                      ),
                      _progress(
                        zen,
                        'Klucze bez hasła',
                        service.receivedCount(RecoveryKind.emergency),
                        kEmergencyThreshold,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Otrzymane klucze: ${service.receivedCount(RecoveryKind.normal)}'
                        '/$kNormalThreshold (z hasłem), '
                        '${service.receivedCount(RecoveryKind.emergency)}'
                        '/$kEmergencyThreshold (bez hasła)',
                        key: const Key('recovery-received'),
                        style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        key: const Key('recovery-old-password'),
                        controller: _recoverPassword,
                        obscureText: true,
                        enableIMEPersonalizedLearning: false,
                        decoration: const InputDecoration(
                          labelText: 'Hasło odzyskiwanego konta',
                          prefixIcon: Icon(Icons.lock_open_rounded),
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
                        label: const Text('Odzyskaj z hasłem'),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        key: const Key('recovery-recover-emergency'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed:
                            _busy ||
                                service.receivedCount(RecoveryKind.emergency) <
                                    kEmergencyThreshold
                            ? null
                            : () => unawaited(
                                _run(() => _recover(emergency: true)),
                              ),
                        child: const Text('Odzyskaj bez hasła'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
