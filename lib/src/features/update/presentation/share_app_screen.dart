import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/update/adb_installer.dart';
import 'package:zen/src/features/update/apk_signature.dart';
import 'package:zen/src/features/update/own_copy.dart';
import 'package:zen/src/features/update/presentation/store_share_dialog.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/share_app_channel.dart';
import 'package:zen/src/features/update/share_app_server.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_service.dart';

/// A file that can be passed on.
@immutable
final class _ShareSource {
  const _ShareSource(this.label, this.file, this.name, {this.own = false});

  final String label;
  final File file;
  final String name;

  /// The APK this app was installed from.
  final bool own;
}

/// "Podaj dalej" (§14.2): give the app to someone nearby over Wi-Fi or a
/// hotspot (QR code → their browser downloads it), or — from a computer —
/// install it on a phone connected by USB.
class ShareAppScreen extends ConsumerStatefulWidget {
  const ShareAppScreen({super.key});

  static Future<void> open(BuildContext context) {
    // A store build passes Zen on as a link, never as a file (STAN D12).
    if (isStoreBuild) {
      return showStoreShareDialog(context);
    }
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const ShareAppScreen(),
      ),
    );
  }

  @override
  ConsumerState<ShareAppScreen> createState() => _ShareAppScreenState();
}

class _ShareAppScreenState extends ConsumerState<ShareAppScreen> {
  static const MethodChannel _share = MethodChannel('zen/share_app');
  static const ShareAppChannel _shareSheet = ShareAppChannel(channel: _share);

  final List<_ShareSource> _sources = <_ShareSource>[];
  _ShareSource? _source;
  ShareAppServer? _server;
  List<InternetAddress> _addresses = const <InternetAddress>[];

  /// Networks this device could share on, and the one it shares on (S13:
  /// the server listens on that one address only).
  List<ShareNetwork> _networks = const <ShareNetwork>[];
  ShareNetwork? _network;
  StreamSubscription<int>? _downloadsSub;
  int _downloads = 0;
  String? _message;
  ({String ssid, String password})? _hotspot;

  /// SHA-256 of the file being shared (null while it is being computed).
  String? _sha256;
  _ShareSource? _sha256Of;

  /// What the signature of the chosen file says (§14.3), and of which
  /// file; null while it is being checked.
  ApkSignatureCheck? _signature;
  _ShareSource? _signatureOf;

  AdbInstaller? _adb;
  List<AdbDevice> _devices = const <AdbDevice>[];
  bool _busy = false;

  /// The installer is being prepared for the system share sheet.
  bool _sending = false;

  /// What came of the last share-sheet attempt, when worth saying.
  String? _sendNote;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid;
  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    unawaited(_loadSources());
    if (_isDesktop) {
      unawaited(_findAdb());
    }
  }

  @override
  void dispose() {
    unawaited(_downloadsSub?.cancel());
    unawaited(_server?.dispose());
    if (_hotspot != null) {
      unawaited(_share.invokeMethod<void>('stopHotspot').catchError((_) {}));
    }
    super.dispose();
  }

  Future<void> _loadSources() async {
    final List<_ShareSource> found = <_ShareSource>[];
    final String? own = await ownApkPath();
    if (own != null && await File(own).exists()) {
      found.add(
        _ShareSource(
          t('Zen {version} (ta aplikacja)', {'version': kAppVersion}),
          File(own),
          'zen-$kAppVersion.apk',
          own: true,
        ),
      );
    }
    final UpdateService? service = ref.read(updateServiceProvider);
    final SignedRelease? release = service?.book.candidate;
    final ReleaseFile? apk = release?.manifest.fileFor('android');
    if (service != null && release != null && apk != null) {
      final Uint8List? bytes = await service.fileBytes(forPlatform: 'android');
      if (bytes != null) {
        final Directory dir = await getTemporaryDirectory();
        final File f = File('${dir.path}${Platform.pathSeparator}${apk.name}');
        await f.writeAsBytes(bytes, flush: true);
        found.insert(
          0,
          _ShareSource(
            t('Zen {version} (nowsza, podpisana)', {
              'version': release.manifest.version,
            }),
            f,
            apk.name,
          ),
        );
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _sources
        ..clear()
        ..addAll(found);
      _source ??= found.firstOrNull;
    });
    unawaited(_checkSignature(_source));
  }

  /// Checks the signing certificate of [source] (§14.3): the APK this app
  /// came from needs no check.
  Future<ApkSignatureCheck?> _checkSignature(_ShareSource? source) async {
    if (source == null) {
      return null;
    }
    if (identical(_signatureOf, source) && _signature != null) {
      return _signature;
    }
    if (mounted) {
      setState(() {
        _signatureOf = source;
        _signature = null;
      });
    }
    final ApkSignatureCheck check = source.own
        ? const ApkSignatureCheck(ApkSignatureVerdict.matches)
        : await checkApkSignature(source.file);
    if (mounted && identical(_signatureOf, source)) {
      setState(() => _signature = check);
    }
    return check;
  }

  /// Whether to go on with the chosen file: a file signed with another key,
  /// or one whose signature cannot be read, is passed on only when the
  /// person says so.
  Future<bool> _confirmSignature() async {
    final ApkSignatureCheck? check = await _checkSignature(_source);
    if (!mounted) {
      return false;
    }
    if (check == null ||
        check.verdict == ApkSignatureVerdict.matches ||
        check.verdict == ApkSignatureVerdict.unknown) {
      return true;
    }
    final bool differs = check.verdict == ApkSignatureVerdict.differs;
    final ZenColors zen = ZenColors.of(context);
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        key: const Key('share-app-signature-warning'),
        icon: Icon(Icons.gpp_bad_rounded, color: zen.danger),
        title: Text(
          differs
              ? t('Podpis się nie zgadza')
              : t('Nie da się sprawdzić podpisu'),
        ),
        content: Text(
          differs
              ? t(
                  'Ten plik podpisano innym kluczem niż {reference}. To '
                  'może nie być prawdziwy Zen: podróbka może szpiegować '
                  'albo podmienić link do zbiórki.\n\n'
                  'Odcisk klucza tego pliku:\n'
                  '{fingerprints}'
                  '\n\nPorównaj go z odciskiem w README: '
                  'github.com/robertostrowskijagoda/Zen.',
                  {
                    'reference': _referenceLabel,
                    'fingerprints': check.certificates
                        .map(formatCertificateFingerprint)
                        .join('\n'),
                  },
                )
              : t(
                  'Nie udało się odczytać podpisu tego pliku. To może nie być '
                  'prawdziwy Zen. Przekaż go dalej tylko, jeśli wiesz, skąd '
                  'pochodzi.',
                ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('share-app-signature-anyway'),
            style: TextButton.styleFrom(foregroundColor: zen.danger),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Mimo to')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Anuluj')),
          ),
        ],
      ),
    );
    return go ?? false;
  }

  /// What the file is compared with.
  String get _referenceLabel =>
      _isAndroid ? t('ta aplikacja') : t('oficjalny Zen');

  Future<void> _pickApk() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
    );
    final String? path = picked?.files.firstOrNull?.path;
    if (path == null || !mounted) {
      return;
    }
    if (!path.toLowerCase().endsWith('.apk')) {
      setState(() => _message = t('Wybierz plik .apk z aplikacją Zen.'));
      return;
    }
    final _ShareSource source = _ShareSource(
      t('Plik: {name}', {'name': path.split(Platform.pathSeparator).last}),
      File(path),
      'zen.apk',
    );
    setState(() {
      _sources.add(source);
      _source = source;
    });
    await _stopServer();
    unawaited(_checkSignature(source));
  }

  Future<void> _startServer() async {
    final _ShareSource? source = _source;
    if (source == null || !await _confirmSignature()) {
      return;
    }
    await _stopServer();
    // Listen only where the friend can reach this device: the network the
    // person picked, else the hotspot or the Wi-Fi - one address, never
    // every interface.
    final List<ShareNetwork> networks = await localShareNetworks();
    final ShareNetwork? network = chooseShareNetwork(
      networks,
      chosen: _network,
    );
    if (network == null) {
      if (mounted) {
        setState(
          () => _message = t(
            'To urządzenie nie jest w żadnej sieci Wi-Fi. Włącz hotspot albo '
            'połącz się z tą samą siecią co znajomy.',
          ),
        );
      }
      return;
    }
    final ShareAppServer server = ShareAppServer(
      file: source.file,
      fileName: source.name,
    );
    try {
      await server.start(addresses: <InternetAddress>[network.address]);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _message = t('Nie udało się udostępnić pliku: {error}', {
            'error': error,
          }),
        );
      }
      return;
    }
    _downloadsSub = server.downloadsChanged.listen((int n) {
      if (mounted) {
        setState(() => _downloads = n);
      }
    });
    if (!mounted) {
      await server.dispose();
      return;
    }
    setState(() {
      _server = server;
      _addresses = server.servedAddresses;
      _networks = networks;
      _network = network;
      _downloads = 0;
      _message = null;
    });
    unawaited(_computeSha256(source));
  }

  Future<void> _computeSha256(_ShareSource source) async {
    if (identical(_sha256Of, source) && _sha256 != null) {
      return;
    }
    setState(() {
      _sha256Of = source;
      _sha256 = null;
    });
    try {
      final String hex = await fileSha256Hex(source.file);
      if (mounted && identical(_sha256Of, source)) {
        setState(() => _sha256 = hex);
      }
    } on Object catch (error) {
      logZenWarning('Podaj dalej: suma kontrolna: $error');
    }
  }

  Future<void> _stopServer() async {
    await _downloadsSub?.cancel();
    _downloadsSub = null;
    await _server?.dispose();
    if (mounted) {
      setState(() => _server = null);
    }
  }

  Future<void> _startHotspot() async {
    setState(() => _busy = true);
    try {
      final Map<Object?, Object?>? r = await _share
          .invokeMethod<Map<Object?, Object?>>('startHotspot');
      final Object? error = r?['error'];
      final Object? ssid = r?['ssid'];
      final Object? password = r?['password'];
      if (!mounted) {
        return;
      }
      if (error != null || ssid is! String || password is! String) {
        setState(
          () => _message = switch (error) {
            'permission' => t(
              'Zezwól Zen na dostęp do urządzeń w pobliżu i naciśnij jeszcze '
              'raz.',
            ),
            'location_off' => t(
              'Włącz lokalizację (Android wymaga jej do hotspotu) i spróbuj '
              'jeszcze raz.',
            ),
            _ => t(
              'Nie udało się włączyć hotspotu. Włącz go w ustawieniach '
              'telefonu i naciśnij „Udostępnij”.',
            ),
          },
        );
        return;
      }
      setState(() => _hotspot = (ssid: ssid, password: password));
      // The hotspot's address appears a moment later.
      await Future<void>.delayed(const Duration(seconds: 2));
      await _startServer();
    } on Object {
      if (mounted) {
        setState(
          () => _message = t(
            'Hotspot nie działa na tym urządzeniu. Włącz go w ustawieniach.',
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  /// Quick Share, Bluetooth...: the chosen file goes through the system share
  /// sheet, phone to phone, no internet needed.
  Future<void> _sendViaShareSheet() async {
    if (!await _confirmSignature() || !mounted) {
      return;
    }
    final _ShareSource? source = _source;
    // Another file than this app's own; the installed APK is found natively
    // (also when it came in parts).
    final _ShareSource? other = source != null && !source.own ? source : null;
    setState(() {
      _sending = true;
      _sendNote = null;
    });
    final ApkShareResult result = await _shareSheet.shareApk(
      path: other?.file.path,
      fileName: other?.name,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _sending = false;
      _sendNote = switch (result.status) {
        ApkShareStatus.opened =>
          result.baseOnly
              ? t(
                  'Ta instalacja Zen składa się z kilku plików, a wysłać da '
                  'się tylko główny. U znajomego może się nie zainstalować.',
                )
              : null,
        ApkShareStatus.noFile => t(
          'Nie znalazłem pliku instalacyjnego do wysłania.',
        ),
        ApkShareStatus.unsupported => t(
          'Ten telefon nie pozwala wysłać aplikacji w ten sposób. Użyj kodu '
          'QR poniżej.',
        ),
        ApkShareStatus.failed => t(
          'Nie udało się otworzyć udostępniania. Spróbuj jeszcze raz albo '
          'użyj kodu QR poniżej.',
        ),
      };
    });
  }

  Future<void> _findAdb() async {
    final AdbInstaller adb = await AdbInstaller.find();
    if (!mounted) {
      return;
    }
    setState(() => _adb = adb);
    await _refreshDevices();
  }

  Future<void> _refreshDevices() async {
    final AdbInstaller? adb = _adb;
    if (adb == null || !adb.available) {
      return;
    }
    final List<AdbDevice> devices = await adb.devices();
    if (mounted) {
      setState(() => _devices = devices);
    }
  }

  Future<void> _installUsb(AdbDevice device) async {
    final AdbInstaller? adb = _adb;
    final _ShareSource? source = _source;
    if (adb == null || source == null || !await _confirmSignature()) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _message = t('Instaluję na {device}…', {'device': device.label});
    });
    final String result = await adb.install(device, source.file.path);
    if (mounted) {
      setState(() {
        _busy = false;
        _message = result;
      });
    }
  }

  /// A QR code on a white rounded tile (scanners need the contrast).
  Widget _qr(String data, double size, {Key? key}) => Center(
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: QrImageView(
        key: key,
        data: data,
        size: size,
        backgroundColor: Colors.white,
      ),
    ),
  );

  /// The shared file's SHA-256, for whoever wants to check the download.
  Widget _checksum(ZenColors zen) {
    final String? hex = _sha256;
    return Container(
      key: const Key('share-app-sha256'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: zen.surfaceSunk,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.verified_user_outlined, size: 18, color: zen.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t('SUMA KONTROLNA (SHA-256)'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: zen.label(color: zen.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (hex == null)
            Text(
              t('Liczę…'),
              style: TextStyle(color: zen.textMuted, fontSize: 13),
            )
          else
            SelectableText(
              groupedHex(hex),
              style: zen.mono(
                color: zen.textPrimary,
                size: 12.5,
                letterSpacing: 0.2,
                height: 1.5,
              ),
            ),
          if (hex != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              t('Kod kopii: {code}', {'code': buildShortCode(hex)}),
              key: const Key('share-app-short-code'),
              style: zen.mono(
                color: zen.textPrimary,
                size: 15,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              t(
                'Po instalacji znajomy zobaczy ten sam kod w „O aplikacji”. '
                'Porównajcie go: jeśli się różni, to nie jest ten sam plik.',
              ),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            t(
              'Ostrożny znajomy może sprawdzić sumę pobranego pliku. Musi być '
              'dokładnie taka sama, inaczej ktoś po drodze podmienił plik.',
            ),
            style: TextStyle(
              color: zen.textMuted,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  /// What the signature of the chosen file says (§14.3).
  Widget _signatureInfo(ZenColors zen) {
    final ApkSignatureCheck? check = identical(_signatureOf, _source)
        ? _signature
        : null;
    final String fingerprints = check == null
        ? ''
        : check.certificates.map(formatCertificateFingerprint).join('\n');
    return switch (check?.verdict) {
      null => ZenInfo(
        key: const Key('share-app-signature'),
        icon: Icons.hourglass_top_rounded,
        tone: zen.textMuted,
        text: t('Sprawdzam podpis pliku…'),
      ),
      ApkSignatureVerdict.matches => ZenInfo(
        key: const Key('share-app-signature'),
        icon: Icons.verified_rounded,
        tone: zen.success,
        text: t('Podpis zgodny: ten sam klucz co {reference}.', {
          'reference': _referenceLabel,
        }),
      ),
      ApkSignatureVerdict.differs => ZenInfo(
        key: const Key('share-app-signature'),
        icon: Icons.gpp_bad_rounded,
        tone: zen.danger,
        title: t('Podpis się nie zgadza'),
        text: t(
          'Inny klucz niż {reference} — to może być podróbka.\n'
          '{fingerprints}',
          {'reference': _referenceLabel, 'fingerprints': fingerprints},
        ),
      ),
      ApkSignatureVerdict.unknown => ZenInfo(
        key: const Key('share-app-signature'),
        icon: Icons.fingerprint_rounded,
        tone: zen.warning,
        title: t('Odcisk klucza tego pliku'),
        text: t(
          '{fingerprints}\nPorównaj go z odciskiem w README: '
          'github.com/robertostrowskijagoda/Zen.',
          {'fingerprints': fingerprints},
        ),
      ),
      ApkSignatureVerdict.unreadable => ZenInfo(
        key: const Key('share-app-signature'),
        icon: Icons.gpp_maybe_rounded,
        tone: zen.warning,
        text: t(
          'Nie udało się odczytać podpisu tego pliku. To może nie być '
          'prawdziwy Zen.',
        ),
      ),
    };
  }

  /// "Wyślij przez Quick Share / Bluetooth": the quickest way to hand Zen to
  /// someone standing next to you.
  Widget _shareSheetCard(ZenColors zen) {
    final Color tone = zenTone(zen, 3);
    final String? note = _sendNote;
    return ZenCard(
      key: const Key('share-app-system-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ZenIconBadge(icon: Icons.near_me_rounded, tone: tone, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t(
                    'Quick Share, Bluetooth albo inna aplikacja z menu '
                    'udostępniania. Bez internetu, wystarczy, że telefony są '
                    'blisko siebie.',
                  ),
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            key: const Key('share-app-system'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: _sending ? null : () => unawaited(_sendViaShareSheet()),
            icon: _sending
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: zen.accent,
                    ),
                  )
                : const Icon(Icons.share_rounded),
            label: Text(
              t('Wyślij przez Quick Share / Bluetooth'),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: zen.textMuted,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  t(
                    'Odbiorca musi zezwolić na instalowanie aplikacji z '
                    'nieznanych źródeł (telefon sam o to zapyta przy '
                    'otwieraniu pliku).',
                  ),
                  style: TextStyle(
                    color: zen.textMuted,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
          if (note != null) ...<Widget>[
            const SizedBox(height: 8),
            ZenInfo(
              key: const Key('share-app-system-note'),
              icon: Icons.warning_amber_rounded,
              tone: zen.warning,
              text: note,
            ),
          ],
        ],
      ),
    );
  }

  /// A numbered (or plain) instruction line above a QR code.
  Widget _step(ZenColors zen, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: zen.textPrimary,
        fontSize: 15,
        fontWeight: FontWeight.w700,
        height: 1.35,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ShareAppServer? server = _server;
    final InternetAddress? first = _addresses.firstOrNull;
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 2);
    return Scaffold(
      key: const Key('share-app-screen'),
      appBar: AppBar(title: Text(t('Podaj dalej'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          ZenHero(
            title: t('Podaj Zen dalej'),
            icon: Icons.volunteer_activism_rounded,
            tone: tone,
            text: t(
              'Znajomy nie potrzebuje sklepu ani internetu. Wystarczy, że jest '
              'obok: w tej samej sieci Wi-Fi albo podłączony do Twojego '
              'hotspotu.',
            ),
          ),
          if (!kIsWeb && Platform.isIOS)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ZenInfo(
                icon: Icons.phone_iphone_rounded,
                tone: zen.warning,
                text: t(
                  'iPhone nie pozwala przekazać aplikacji z ręki do ręki. '
                  'Znajomy z iPhonem instaluje Zen z GitHuba (opis w README, '
                  'sekcja „iPhone”). Stąd możesz podać plik .apk znajomemu '
                  'z Androidem.',
                ),
              ),
            ),
          ZenSection(t('Co udostępnić'), top: 12),
          if (_sources.isEmpty)
            ZenInfo(
              icon: Icons.inventory_2_outlined,
              tone: zen.warning,
              text: _isAndroid
                  ? t('Nie znalazłem pliku instalacyjnego tej aplikacji.')
                  : t(
                      'Wybierz plik .apk z Zen (np. z aktualizacji albo ze '
                      'strony projektu).',
                    ),
            )
          else
            for (final _ShareSource s in _sources)
              ZenTile(
                icon: Icons.android_rounded,
                tone: s == _source ? zen.accent : zenTone(zen, 5),
                title: s.label,
                subtitle: s.name,
                trailing: Icon(
                  s == _source
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: s == _source ? zen.accent : zen.textMuted,
                ),
                onTap: () {
                  setState(() => _source = s);
                  unawaited(_stopServer());
                  unawaited(_checkSignature(s));
                },
              ),
          if (_source != null && !_source!.own) _signatureInfo(zen),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('share-app-pick'),
              onPressed: () => unawaited(_pickApk()),
              icon: const Icon(Icons.folder_open_rounded),
              label: Text(t('Wybierz inny plik .apk')),
            ),
          ),
          if (_isAndroid) ...<Widget>[
            ZenSection(t('Prosto na telefon obok'), top: 16),
            _shareSheetCard(zen),
          ],
          ZenSection(t('Przez Wi-Fi albo hotspot'), top: 16),
          ZenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_isAndroid && _hotspot == null) ...<Widget>[
                  OutlinedButton.icon(
                    key: const Key('share-app-hotspot'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: _busy || _source == null
                        ? null
                        : () => unawaited(_startHotspot()),
                    icon: const Icon(Icons.wifi_tethering_rounded),
                    label: Text(t('Włącz hotspot (bez internetu)')),
                  ),
                  const SizedBox(height: 10),
                ],
                if (_hotspot != null) ...<Widget>[
                  _step(
                    zen,
                    t('1. Znajomy skanuje ten kod, żeby połączyć się z Wi-Fi:'),
                  ),
                  _qr(
                    wifiQrText(
                      ssid: _hotspot!.ssid,
                      password: _hotspot!.password,
                    ),
                    180,
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    t('Sieć: {ssid}\nHasło: {password}', {
                      'ssid': _hotspot!.ssid,
                      'password': _hotspot!.password,
                    }),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontSize: 14,
                      height: 1.45,
                    ),
                  ),
                  Divider(height: 28, color: zen.outlineSoft),
                ],
                if (server == null)
                  FilledButton.icon(
                    key: const Key('share-app-start'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: _source == null
                        ? null
                        : () => unawaited(_startServer()),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: Text(t('Udostępnij')),
                  )
                else if (first != null) ...<Widget>[
                  _step(
                    zen,
                    _hotspot != null
                        ? t('2. Potem skanuje ten kod i pobiera Zen:')
                        : t('Znajomy skanuje ten kod aparatem i pobiera Zen:'),
                  ),
                  _qr(
                    server.pageUri(first).toString(),
                    200,
                    key: const Key('share-app-qr'),
                  ),
                  const SizedBox(height: 10),
                  for (final InternetAddress a in _addresses)
                    SelectableText(
                      server.pageUri(a).toString(),
                      textAlign: TextAlign.center,
                      style: zen.mono(
                        color: zen.textSecondary,
                        size: 12.5,
                        letterSpacing: 0.2,
                      ),
                    ),
                  if (_networks.length > 1) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      t('Sieć, w której udostępniasz:'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final ShareNetwork n in _networks)
                          ChoiceChip(
                            label: Text(n.label),
                            selected: n == _network,
                            onSelected: (bool selected) {
                              if (!selected || n == _network) {
                                return;
                              }
                              setState(() => _network = n);
                              unawaited(_startServer());
                            },
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  _checksum(zen),
                  const SizedBox(height: 12),
                  Center(
                    child: _downloads == 0
                        ? ZenPill(
                            text: t('Czekam na pobranie…'),
                            icon: Icons.hourglass_top_rounded,
                            tone: zen.warning,
                          )
                        : ZenPill(
                            text: t('Pobrano: {count}', {'count': _downloads}),
                            icon: Icons.download_done_rounded,
                            tone: zen.success,
                          ),
                  ),
                  if (_downloads == 0) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      t(
                        'Udostępnianie wyłączy się po 20 minutach albo po '
                        'zamknięciu tego ekranu.',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                    ),
                  ],
                  const SizedBox(height: 4),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: zen.danger),
                    onPressed: () => unawaited(_stopServer()),
                    child: Text(t('Zakończ udostępnianie')),
                  ),
                ],
              ],
            ),
          ),
          if (_message != null)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: zen.accent.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: zen.accent.withValues(alpha: 0.24)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(Icons.info_outline_rounded, color: zen.accent, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _message!,
                      key: const Key('share-app-message'),
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
          if (_isDesktop) ...<Widget>[
            ZenSection(t('Kablem USB na telefon z Androidem'), top: 24),
            ZenInfo(
              icon: Icons.usb_rounded,
              title: t('Działa nawet tam, gdzie sklep i strony są zablokowane'),
              text: t(
                'Na telefonie włącz „Debugowanie USB” (Ustawienia → '
                'Informacje o telefonie → 7 razy dotknij „Numer '
                'kompilacji”, potem Opcje programisty), podłącz kabel i '
                'zezwól na debugowanie.',
              ),
            ),
            const SizedBox(height: 4),
            if (_adb == null)
              ZenCard(
                child: Row(
                  children: <Widget>[
                    SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: zen.accent,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        t('Szukam narzędzia adb…'),
                        style: TextStyle(color: zen.textSecondary),
                      ),
                    ),
                  ],
                ),
              )
            else if (!_adb!.available)
              ZenInfo(
                icon: Icons.build_circle_outlined,
                tone: zen.warning,
                text: t(
                  'Nie znalazłem narzędzia adb. Zainstaluj „Android SDK '
                  'Platform-Tools” od Google (albo Android Studio) i otwórz '
                  'ten ekran ponownie.',
                ),
              )
            else ...<Widget>[
              if (_devices.isEmpty)
                ZenEmpty(
                  icon: Icons.phonelink_off_rounded,
                  title: t('Nie widzę podłączonego telefonu.'),
                ),
              for (final AdbDevice d in _devices)
                ZenTile(
                  icon: Icons.smartphone_rounded,
                  tone: d.ready ? zen.success : zen.warning,
                  title: d.label,
                  subtitle: d.ready
                      ? t('Gotowy')
                      : d.state == 'unauthorized'
                      ? t('Zezwól na debugowanie USB na telefonie')
                      : d.state,
                  trailing: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                    ),
                    onPressed: _busy || _source == null
                        ? null
                        : () => unawaited(_installUsb(d)),
                    child: Text(t('Zainstaluj')),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => unawaited(_refreshDevices()),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(t('Odśwież')),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
