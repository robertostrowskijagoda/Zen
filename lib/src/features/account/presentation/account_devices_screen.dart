import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_link.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// "Urządzenia": this account's devices, linking a new one and cutting
/// off a lost one.
class AccountDevicesScreen extends ConsumerStatefulWidget {
  const AccountDevicesScreen({super.key});

  /// Opens after the person confirms who they are.
  static Future<void> open(BuildContext context) async {
    if (!await confirmSensitiveAccess(
          context,
          reason: t('Urządzenia konta są chronione. Potwierdź, że to Ty.'),
        ) ||
        !context.mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const AccountDevicesScreen(),
      ),
    );
  }

  @override
  ConsumerState<AccountDevicesScreen> createState() =>
      _AccountDevicesScreenState();
}

class _AccountDevicesScreenState extends ConsumerState<AccountDevicesScreen> {
  LedgerNode? _node;
  StreamSubscription<void>? _changes;
  String? _message;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _node = ref.read(ledgerNodeProvider);
    _changes = _node?.devicesChanged.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    unawaited(
      _node?.start().then((_) {
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  /// The account key, asking for the account password when one is set.
  Future<bool> _unlock(String why) async {
    final LedgerNode node = _node!;
    if (node.identity.accountKey != null) {
      return true;
    }
    final String? password = await askAccountPassword(context, why);
    if (password == null) {
      return false;
    }
    final bool ok = await node.identity.unlock(password);
    if (!ok && mounted) {
      setState(() => _message = t('Złe hasło konta.'));
    }
    return ok;
  }

  Future<void> _unlink(AccountDevice device) async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(t('Odłączyć „{name}”?', {'name': device.name})),
        content: Text(
          t(
            'To urządzenie przestanie należeć do konta: nie dostanie '
            'wiadomości ani nowych wpisów, a to, co by na nim napisano od '
            'teraz, wszyscy odrzucą. Zrób to, gdy urządzenie zginęło albo '
            'zostało skradzione. Tego nie da się cofnąć.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('device-unlink-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialog).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Odłącz')),
          ),
        ],
      ),
    );
    if (sure != true || !await _unlock(t('Odłączenie urządzenia'))) {
      return;
    }
    setState(() => _busy = true);
    try {
      await _node!.unlinkDevice(device.device);
      _message = t('„{name}” jest odłączone.', {'name': device.name});
    } on Object catch (error) {
      _message = t('Nie udało się: {error}', {'error': error});
    } finally {
      _node!.identity.lock();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) =>
      SecureScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final LedgerNode? node = _node;
    final bool ready = node != null && node.isReady;
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('account-devices-screen'),
      appBar: AppBar(title: Text(t('Urządzenia'))),
      body: !ready
          ? const _Starting()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: <Widget>[
                if (_message != null)
                  _MessageBox(
                    text: _message!,
                    textKey: const Key('devices-message'),
                  ),
                if (node.isRevoked)
                  ZenInfo(
                    icon: Icons.warning_amber_rounded,
                    tone: zen.danger,
                    title: t('To urządzenie zostało odłączone od konta'),
                    text: t(
                      'Zrobiło to inne urządzenie tego konta. Nic, co '
                      'tu napiszesz, nie zostanie przyjęte.',
                    ),
                  ),
                ZenHero(
                  title: t('Jedno konto, wiele urządzeń'),
                  icon: Icons.devices_rounded,
                  tone: zen.tone(ZenTone.network),
                  text: t(
                    'Twoje konto może działać na kilku urządzeniach naraz. '
                    'Znajomi widzą je jako jedną osobę: wiadomości i '
                    'połączenia trafiają na każde, a znajomi i grupy są '
                    'wszędzie takie same.',
                  ),
                ),
                ZenSection(t('Twoje urządzenia'), top: 12),
                for (final AccountDevice d in node.ownDevices)
                  ZenTile(
                    key: Key('device-${d.device}'),
                    icon: d.name.contains('Telefon') || d.name == 'iPhone'
                        ? Icons.smartphone_rounded
                        : Icons.computer_rounded,
                    tone: d.isThis ? zen.accent : zen.tone(ZenTone.network),
                    title: d.name,
                    subtitle: d.isThis
                        ? t('To urządzenie')
                        : d.address == null
                        ? t('Jeszcze się nie odezwało')
                        : t('Podłączone'),
                    trailing: d.isThis
                        ? const SizedBox.shrink()
                        : TextButton(
                            key: Key('device-unlink-${d.device}'),
                            style: TextButton.styleFrom(
                              foregroundColor: zen.danger,
                              minimumSize: const Size(0, 36),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                            ),
                            onPressed: _busy
                                ? null
                                : () => unawaited(_unlink(d)),
                            child: Text(t('Odłącz')),
                          ),
                  ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('devices-link-new'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: node.isRevoked
                      ? null
                      : () => unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const _LinkSendScreen(),
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.add_link_rounded),
                  label: Text(t('Podłącz nowe urządzenie')),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  key: const Key('devices-join-account'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () => unawaited(
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _LinkReceiveScreen(),
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.login_rounded),
                  label: Text(
                    t('To nowe urządzenie: dołącz do konta'),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
    );
  }
}

/// "The account is starting" placeholder.
class _Starting extends StatelessWidget {
  const _Starting();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox.square(
            dimension: 28,
            child: CircularProgressIndicator(strokeWidth: 3, color: zen.accent),
          ),
          const SizedBox(height: 14),
          Text(
            t('Konto się uruchamia…'),
            style: TextStyle(color: zen.textSecondary, fontSize: 14.5),
          ),
        ],
      ),
    );
  }
}

/// A status line of a screen (result of the last action), in a tinted box.
class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.text, required this.textKey, this.tone});

  final String text;
  final Key textKey;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color t = tone ?? zen.accent;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: t.withValues(alpha: 0.09),
        borderRadius: context.zenRadius(18),
        border: Border.all(color: t.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.info_outline_rounded, color: t, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              key: textKey,
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A "waiting for…" line with a small spinner.
class _Waiting extends StatelessWidget {
  const _Waiting(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: zen.accent),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: zen.textSecondary, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the account password.
Future<String?> askAccountPassword(BuildContext context, String title) async {
  final TextEditingController controller = TextEditingController();
  final String? result = await showDialog<String>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('account-password-field'),
        controller: controller,
        obscureText: true,
        autofocus: true,
        enableIMEPersonalizedLearning: false,
        decoration: InputDecoration(
          labelText: t('Hasło konta'),
          prefixIcon: const Icon(Icons.lock_outline_rounded),
        ),
        onSubmitted: (String v) => Navigator.of(dialog).pop(v),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('account-password-ok'),
          onPressed: () => Navigator.of(dialog).pop(controller.text),
          child: Text(t('Dalej')),
        ),
      ],
    ),
  );
  disposeLater(controller);
  return result;
}

Widget _digitsBox(BuildContext context, String digits) {
  final ZenColors zen = ZenColors.of(context);
  return Container(
    margin: const EdgeInsets.symmetric(vertical: 14),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
    decoration: BoxDecoration(
      borderRadius: context.zenRadius(24),
      gradient: LinearGradient(
        colors: <Color>[
          Color.alphaBlend(zen.accent.withValues(alpha: 0.22), zen.surface),
          Color.alphaBlend(
            zen.accentSecondary.withValues(alpha: 0.10),
            zen.surface,
          ),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
      border: Border.all(color: zen.accent.withValues(alpha: 0.35)),
    ),
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        digits,
        key: const Key('link-digits'),
        textAlign: TextAlign.center,
        style: zen.display(
          color: zen.textPrimary,
          size: 40,
          weight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    ),
  );
}

/// On the device that has the account: send it to a new device.
class _LinkSendScreen extends ConsumerStatefulWidget {
  const _LinkSendScreen();

  @override
  ConsumerState<_LinkSendScreen> createState() => _LinkSendScreenState();
}

class _LinkSendScreenState extends ConsumerState<_LinkSendScreen> {
  final TextEditingController _code = TextEditingController();
  AccountLinkSender? _sender;
  String? _digits;
  String? _message;
  bool _busy = false;
  bool _done = false;

  @override
  void dispose() {
    _code.dispose();
    unawaited(_sender?.dispose());
    super.dispose();
  }

  Future<void> _scan() async {
    final String? text = await ref.read(peerQrScannerProvider).scan(context);
    if (text != null && text.trim().isNotEmpty) {
      final String? code = _codeOf(text);
      _code.text = code ?? text.trim();
    }
  }

  String? _codeOf(String input) {
    try {
      final PeerDialTarget t = PeerShareCodec.parseTarget(input);
      return PeerShareCodec.inviteCodeForAddress(t.address);
    } on FormatException {
      return null;
    }
  }

  Future<void> _connect() async {
    final String address;
    try {
      address = PeerShareCodec.parseTarget(_code.text).address;
    } on FormatException catch (e) {
      setState(() => _message = e.message);
      return;
    }
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    final String me = ref.read(runtimeNodeSnapshotProvider).localAddress;
    if (node == null || PeerShareCodec.addressesEqual(address, me)) {
      setState(() => _message = t('To jest kod tego urządzenia.'));
      return;
    }
    await _sender?.dispose();
    final AccountLinkSender sender = AccountLinkSender(
      transport: ref.read(meshTransportProvider),
      target: address,
    );
    _sender = sender;
    setState(() {
      _busy = true;
      _message = t('Łączę się z nowym urządzeniem…');
      _digits = null;
    });
    try {
      final String digits = await sender.start();
      setState(() {
        _digits = digits;
        _message = null;
      });
    } on Object catch (error) {
      setState(
        () => _message = '$error'.replaceFirst('TimeoutException: ', ''),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _send() async {
    final LedgerNode node = ref.read(ledgerNodeProvider)!;
    if (node.identity.accountKey == null) {
      final String? password = await askAccountPassword(
        context,
        t('Podłączenie urządzenia'),
      );
      if (password == null) {
        return;
      }
      if (!await node.identity.unlock(password)) {
        setState(() => _message = t('Złe hasło konta.'));
        return;
      }
    }
    final LedgerKeyPair key = node.identity.accountKey!;
    setState(() {
      _busy = true;
      _message = t('Wysyłam konto…');
    });
    try {
      final String me = ref.read(runtimeNodeSnapshotProvider).localAddress;
      await _sender!.send(
        seed: key.seed,
        account: node.account,
        siblings: <String>[if (me.isNotEmpty) me, ...node.siblingAddresses],
      );
      setState(() {
        _done = true;
        _message = t(
          'Gotowe. Nowe urządzenie za chwilę dostanie Twoich znajomych '
          'i grupy.',
        );
      });
    } on Object catch (error) {
      logZenWarning('Podłączenie urządzenia: $error');
      setState(
        () => _message = '$error'.replaceFirst('TimeoutException: ', ''),
      );
    } finally {
      node.identity.lock();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t('Podłącz nowe urządzenie'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          ZenHero(
            title: t('Przenieś konto na nowe urządzenie'),
            icon: Icons.add_link_rounded,
            tone: zen.tone(ZenTone.network),
            text: t(
              'Na nowym urządzeniu otwórz Ustawienia → Urządzenia → „To nowe '
              'urządzenie: dołącz do konta”. Pokaże kod. Zeskanuj go albo '
              'przepisz tutaj.',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('link-code'),
            controller: _code,
            enabled: !_done,
            decoration: InputDecoration(
              labelText: t('Kod nowego urządzenia'),
              hintText: t('Zeskanuj albo wpisz kod'),
              prefixIcon: const Icon(Icons.key_rounded),
              suffixIcon: IconButton(
                tooltip: t('Zeskanuj kod QR'),
                onPressed: _done ? null : () => unawaited(_scan()),
                icon: const Icon(Icons.qr_code_scanner_rounded),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_digits == null)
            FilledButton.icon(
              key: const Key('link-connect'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _busy ? null : () => unawaited(_connect()),
              icon: const Icon(Icons.link_rounded),
              label: Text(t('Połącz')),
            ),
          if (_digits != null && !_done) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              t('Czy na nowym urządzeniu widać dokładnie te cyfry?'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            _digitsBox(context, _digits!),
            FilledButton.icon(
              key: const Key('link-digits-match'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _busy ? null : () => unawaited(_send()),
              icon: const Icon(Icons.check_rounded),
              label: Text(
                t('Tak, te same — wyślij konto'),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 6),
            TextButton(
              key: const Key('link-digits-differ'),
              style: TextButton.styleFrom(foregroundColor: zen.danger),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _digits = null;
                      _message = t(
                        'Cyfry się różniły — nic nie zostało wysłane. '
                        'Spróbuj jeszcze raz.',
                      );
                    }),
              child: Text(t('Nie, są inne')),
            ),
          ],
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _MessageBox(
                text: _message!,
                textKey: const Key('link-message'),
                tone: _done ? zen.success : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// On the new device: show the code, compare digits, take the account.
class _LinkReceiveScreen extends ConsumerStatefulWidget {
  const _LinkReceiveScreen();

  @override
  ConsumerState<_LinkReceiveScreen> createState() => _LinkReceiveScreenState();
}

class _LinkReceiveScreenState extends ConsumerState<_LinkReceiveScreen> {
  late final AccountLinkReceiver _receiver;
  StreamSubscription<void>? _offers;
  String? _message;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _receiver = AccountLinkReceiver(transport: ref.read(meshTransportProvider))
      ..start();
    // Every greeting device shows its own digits: a stranger who greets
    // first cannot block the real one.
    _offers = _receiver.changes.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    unawaited(_offers?.cancel());
    unawaited(_receiver.dispose());
    super.dispose();
  }

  Future<void> _take(LinkedAccount got) async {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    if (node == null) {
      return;
    }
    final LedgerKeyPair key = await LedgerKeyPair.fromSeed(got.seed);
    if (key.id != got.account) {
      setState(() => _message = t('Otrzymany klucz nie pasuje do konta.'));
      return;
    }
    await node.rememberDeviceAddresses(got.siblings);
    await LedgerIdentity.adoptAccount(
      node.disk,
      got.seed,
      deviceName: thisDeviceName,
    );
    await _receiver.confirm(got);
    setState(() {
      _done = true;
      _message = t(
        'To urządzenie należy teraz do Twojego konta. Uruchom aplikację '
        'ponownie — znajomi i grupy pojawią się po chwili.',
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<AccountLinkOffer> offers = _receiver.offers;
    final String me = ref.watch(
      runtimeNodeSnapshotProvider.select(
        (RuntimeTransportSnapshot s) => s.localAddress,
      ),
    );
    final PeerShareProfile? profile = PeerShareCodec.buildLocalProfile(
      address: me,
    );
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t('Dołącz do konta'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          ZenHero(
            title: t('Dołącz to urządzenie'),
            icon: Icons.login_rounded,
            tone: zen.tone(ZenTone.network),
            text: t(
              'Na urządzeniu, które już ma Twoje konto, otwórz Ustawienia → '
              'Urządzenia → „Podłącz nowe urządzenie” i zeskanuj ten kod '
              '(albo go przepisz).',
            ),
          ),
          ZenInfo(
            icon: Icons.warning_amber_rounded,
            tone: zen.warning,
            text: t(
              'Uwaga: jeśli to urządzenie miało już swoje konto, przejdzie na '
              'konto z drugiego urządzenia, a dotychczasowe przestanie być '
              'używane.',
            ),
          ),
          const SizedBox(height: 12),
          if (profile == null)
            _Waiting(t('Czekam na połączenie z siecią…'))
          else
            ZenCard(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
              child: Column(
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: context.zenRadius(20),
                    ),
                    child: QrImageView(
                      data: profile.qrData,
                      size: 180,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    t('KOD TEGO URZĄDZENIA'),
                    style: zen.label(color: zen.textMuted),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    profile.inviteCode,
                    key: const Key('link-my-code'),
                    textAlign: TextAlign.center,
                    style: zen.mono(
                      color: zen.textPrimary,
                      size: 16,
                      weight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          if (offers.isEmpty)
            _Waiting(t('Czekam na drugie urządzenie…'))
          else if (!_done) ...<Widget>[
            Text(
              t('Sprawdź, czy drugie urządzenie pokazuje te same cyfry:'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (offers.length > 1)
              ZenInfo(
                key: const Key('link-several'),
                icon: Icons.warning_amber_rounded,
                tone: zen.warning,
                text: t(
                  'Łączy się więcej niż jedno urządzenie. Dołącz tylko '
                  'tam, gdzie cyfry są takie same jak na Twoim drugim '
                  'urządzeniu.',
                ),
              ),
            for (int i = 0; i < offers.length; i++) ...<Widget>[
              _digitsBox(context, offers[i].digits),
              if (offers[i].account == null)
                _Waiting(t('Potwierdź je na drugim urządzeniu.'))
              else
                FilledButton.icon(
                  key: Key(i == 0 ? 'link-take' : 'link-take-$i'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () => unawaited(_take(offers[i].account!)),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(
                    t('Cyfry były te same — dołącz do konta'),
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ],
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: _MessageBox(
                text: _message!,
                textKey: const Key('link-message'),
                tone: _done ? zen.success : null,
              ),
            ),
        ],
      ),
    );
  }
}
