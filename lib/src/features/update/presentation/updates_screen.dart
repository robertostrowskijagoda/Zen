import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/update/canary.dart';
import 'package:zen/src/features/update/presentation/github_update_banner.dart';
import 'package:zen/src/features/update/presentation/share_app_screen.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/sha256_sums.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_service.dart';

/// "Aktualizacje i Podaj dalej".
class UpdatesScreen extends ConsumerStatefulWidget {
  const UpdatesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const UpdatesScreen(),
    ),
  );

  @override
  ConsumerState<UpdatesScreen> createState() => _UpdatesScreenState();
}

class _UpdatesScreenState extends ConsumerState<UpdatesScreen> {
  String? _message;
  bool _busy = false;

  /// The last on-demand comparison with GitHub's `SHA256SUMS`:
  /// its verdict, or the reason it could not be made.
  Sha256SumsVerdict? _sumsVerdict;
  String? _sumsError;
  bool _sumsBusy = false;

  /// Compares the downloaded file with the release's `SHA256SUMS` from
  /// GitHub. Only on a tap: Zen never connects to GitHub by itself.
  Future<void> _compareSums(UpdateService service) async {
    final ReleaseFile? file = service.status.file;
    final String? version = service.status.release?.manifest.version;
    if (file == null || version == null) {
      return;
    }
    setState(() {
      _sumsBusy = true;
      _sumsVerdict = null;
      _sumsError = null;
    });
    Sha256SumsVerdict? verdict;
    String? error;
    try {
      final Uint8List? bytes = await service.fileBytes();
      if (bytes == null) {
        error = t('Plik aktualizacji jest niepełny albo uszkodzony.');
      } else {
        final String text = await ref.read(sha256SumsFetcherProvider)(
          sha256SumsUri(version),
        );
        verdict = compareWithSha256Sums(
          fileName: file.name,
          sha256Hex: sha256Hex(bytes),
          sumsText: text,
        );
      }
    } on Object catch (e) {
      error = t('Nie udało się pobrać SHA256SUMS z GitHuba: {error}', {
        'error': e,
      });
    }
    if (mounted) {
      setState(() {
        _sumsBusy = false;
        _sumsVerdict = verdict;
        _sumsError = error;
      });
    }
  }

  Future<void> _run(Future<String> Function() work) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final String message = await work();
      if (mounted) {
        setState(() => _message = message);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _message = t('Nie udało się: {error}', {'error': error}),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _importFile(UpdateService service) async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
    );
    final String? path = picked?.files.firstOrNull?.path;
    if (path == null) {
      return;
    }
    await _run(() async {
      final Uint8List data = await File(path).readAsBytes();
      return service.importBundle(data);
    });
  }

  @override
  Widget build(BuildContext context) {
    final UpdateService? service = ref.watch(updateServiceProvider);
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('updates-screen'),
      appBar: AppBar(title: Text(t('Aktualizacje i Podaj dalej'))),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            _versionCard(zen),
            // The newest release on GitHub (not in the store build).
            if (!isStoreBuild) const GithubUpdateCard(),
            ZenSection(t('Aktualizacje'), top: 16),
            // A store build is updated by its store.
            if (isStoreBuild)
              ZenInfo(
                key: const Key('updates-store'),
                icon: Icons.storefront_rounded,
                title: t('Aktualizacje ze sklepu'),
                text: t('Tę wersję Zen aktualizuje sklep, z którego ją masz.'),
              )
            else if (service == null)
              ZenCard(
                child: Row(
                  children: <Widget>[
                    SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: zen.accent,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        t('Konto się uruchamia…'),
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 14.5,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              ListenableBuilder(
                listenable: service,
                builder: (BuildContext context, Widget? _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _statusCard(context, service),
                    ..._integrity(context, service),
                  ],
                ),
              ),
            if (_message != null)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 6),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: zen.accent.withValues(alpha: 0.09),
                  borderRadius: context.zenRadius(18),
                  border: Border.all(color: zen.accent.withValues(alpha: 0.24)),
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
                        key: const Key('updates-message'),
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
            if (service != null) ...<Widget>[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const Key('updates-import'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : () => unawaited(_importFile(service)),
                icon: const Icon(Icons.file_open_rounded),
                label: Text(t('Wczytaj aktualizację z pliku')),
              ),
            ],
            const SizedBox(height: 8),
            if (!isStoreBuild)
              ZenInfo(
                icon: Icons.verified_user_outlined,
                title: t('Bez sklepu'),
                text: t(
                  'Nowe wersje przychodzą z GitHuba albo od znajomych, bez '
                  'sklepu. Zen nie instaluje niczego bez Twojej zgody.',
                ),
              ),
            ZenSection(t('Podaj dalej'), top: 24),
            ZenHero(
              title: t('Daj Zen komuś obok'),
              icon: Icons.volunteer_activism_rounded,
              tone: zen.tone(ZenTone.people),
              text: isStoreBuild
                  ? t('Wyślij znajomemu link do Zen.')
                  : t(
                      'Bez internetu i bez sklepu: z telefonu przez Wi-Fi albo '
                      'hotspot, z komputera także kablem USB.',
                    ),
              actions: <Widget>[
                FilledButton.icon(
                  key: const Key('updates-share-app'),
                  onPressed: () => unawaited(ShareAppScreen.open(context)),
                  icon: const Icon(Icons.share_rounded),
                  label: Text(t('Podaj dalej')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _versionCard(ZenColors zen) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        borderRadius: context.zenRadius(26),
        gradient: LinearGradient(
          colors: <Color>[
            Color.alphaBlend(zen.accent.withValues(alpha: 0.26), zen.surface),
            Color.alphaBlend(
              zen.accentSecondary.withValues(alpha: 0.12),
              zen.surface,
            ),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: zen.accent.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(t('TWOJA WERSJA'), style: zen.label(color: zen.textMuted)),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    'Zen $kAppVersion',
                    maxLines: 1,
                    style: zen.display(
                      color: zen.textPrimary,
                      size: 34,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                ZenPill(
                  text: t('kompilacja {build}', {'build': kAppBuild}),
                  icon: Icons.tag_rounded,
                  tone: zen.accent,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          ZenIconBadge(icon: Icons.spa_rounded, size: 56, tone: zen.accent),
        ],
      ),
    );
  }

  Widget _statusCard(BuildContext context, UpdateService service) {
    final ZenColors zen = ZenColors.of(context);
    final UpdateStatus s = service.status;
    final ReleaseRevocation? vetoed = s.vetoed;
    final String? version = s.release?.manifest.version;
    final (IconData icon, String title, String subtitle) = switch (s.phase) {
      UpdatePhase.disabled => (
        Icons.schedule_rounded,
        t('Aktualizacje od znajomych jeszcze wyłączone'),
        t(
          'Włączą się, gdy opiekunowie projektu opublikują swoje klucze do '
          'podpisywania wydań. Aktualizacje z GitHuba działają już teraz '
          '(wyżej), a nową wersję możesz też dostać od znajomego przez '
          '„Podaj dalej”.',
        ),
      ),
      UpdatePhase.upToDate => (
        Icons.check_circle_outline_rounded,
        t('Masz najnowszą znaną wersję'),
        t('Gdy znajomy będzie miał nowszą, przyjdzie sama.'),
      ),
      UpdatePhase.downloading => (
        Icons.downloading_rounded,
        t('Pobieram wersję {version}', {'version': version}),
        t('{percent}% — od znajomych, którzy ją mają.', {
          'percent': (s.progress * 100).round(),
        }),
      ),
      UpdatePhase.waiting => (
        Icons.schedule_rounded,
        t('Wersja {version} pobrana', {'version': version}),
        t(
          'Będzie gotowa {date} — 7 dni ochrony, w których '
          'opiekun może wstrzymać wydanie.',
          {'date': _date(s.readyAt!)},
        ),
      ),
      UpdatePhase.ready => (
        Icons.system_update_rounded,
        t('Wersja {version} gotowa do instalacji', {'version': version}),
        s.release!.manifest.notes.isEmpty
            ? t('Podpisana przez opiekunów projektu.')
            : s.release!.manifest.notes,
      ),
      UpdatePhase.otherPlatform => (
        Icons.devices_other_rounded,
        t('Jest wersja {version}', {'version': version}),
        t('Na razie bez pliku dla tego urządzenia.'),
      ),
    };
    final Color tone = switch (s.phase) {
      UpdatePhase.disabled => zen.textMuted,
      UpdatePhase.upToDate => zen.success,
      UpdatePhase.downloading => zen.accent,
      UpdatePhase.waiting => zen.warning,
      UpdatePhase.ready => zen.accent,
      UpdatePhase.otherPlatform => zen.tone(ZenTone.system),
    };
    return ZenCard(
      key: Key('updates-status-${s.phase.name}'),
      tone: s.phase == UpdatePhase.ready ? zen.accent : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ZenIconBadge(icon: icon, tone: tone),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 13.5,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (s.phase == UpdatePhase.downloading) ...<Widget>[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: context.zenRadius(99),
              child: LinearProgressIndicator(
                value: s.progress,
                minHeight: 6,
                color: zen.accent,
                backgroundColor: zen.accent.withValues(alpha: 0.14),
              ),
            ),
          ],
          if (vetoed != null)
            ZenInfo(
              icon: Icons.pan_tool_rounded,
              tone: zen.danger,
              text: t('Opiekun wstrzymał wersję o numerze {build}: {reason}', {
                'build': vetoed.build,
                'reason': vetoed.reason,
              }),
            ),
          if (s.phase == UpdatePhase.waiting ||
              s.phase == UpdatePhase.ready) ...<Widget>[
            const SizedBox(height: 14),
            ..._sumsCheck(zen, service),
          ],
          if (s.phase == UpdatePhase.ready) ...<Widget>[
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('updates-install'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _busy ? null : () => unawaited(_run(service.install)),
              icon: const Icon(Icons.install_mobile_rounded),
              label: Text(
                !kIsWeb && Platform.isAndroid
                    ? t('Zainstaluj')
                    : t('Zapisz instalator'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// "Porównaj sumę z GitHubem" and what came of it.
  List<Widget> _sumsCheck(ZenColors zen, UpdateService service) {
    final Sha256SumsVerdict? verdict = _sumsVerdict;
    final String? error = _sumsError;
    return <Widget>[
      OutlinedButton.icon(
        key: const Key('updates-check-sums'),
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _sumsBusy ? null : () => unawaited(_compareSums(service)),
        icon: _sumsBusy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.fact_check_outlined),
        label: Text(t('Porównaj sumę z GitHubem')),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          t(
            'Łączy się z github.com tylko po naciśnięciu i porównuje '
            'pobrany plik z plikiem SHA256SUMS tego wydania.',
          ),
          style: TextStyle(color: zen.textMuted, fontSize: 12.5, height: 1.35),
        ),
      ),
      if (verdict == Sha256SumsVerdict.match)
        ZenInfo(
          key: const Key('updates-sums-match'),
          icon: Icons.verified_rounded,
          tone: zen.success,
          text: t('Suma pobranego pliku zgadza się z SHA256SUMS tego wydania.'),
        )
      else if (verdict == Sha256SumsVerdict.mismatch)
        ZenInfo(
          key: const Key('updates-sums-mismatch'),
          icon: Icons.gpp_bad_rounded,
          tone: zen.danger,
          title: t('Suma się nie zgadza'),
          text: t(
            'Suma kontrolna się nie zgadza — to nie jest oficjalny Zen '
            '(link do zbiórki mógł zostać podmieniony). Nie instaluj tego '
            'pliku.',
          ),
        )
      else if (verdict == Sha256SumsVerdict.notListed)
        ZenInfo(
          key: const Key('updates-sums-unlisted'),
          icon: Icons.help_outline_rounded,
          tone: zen.warning,
          text: t(
            'Tego pliku nie ma w SHA256SUMS tego wydania na GitHubie '
            '(może jeszcze go tam nie ma). Nie da się potwierdzić sumy.',
          ),
        )
      else if (error != null)
        ZenInfo(
          key: const Key('updates-sums-error'),
          icon: Icons.cloud_off_rounded,
          tone: zen.textMuted,
          text: error,
        ),
    ];
  }

  /// The signed donation details, the canary and the mirrors
  /// — only once something signed by the maintainers is known.
  List<Widget> _integrity(BuildContext context, UpdateService service) {
    final ZenColors zen = ZenColors.of(context);
    final List<String> differences = service.officialDifferences;
    final SignedCanary? canary = service.canary;
    final List<String> mirrors = service.book.enabled
        ? service.book.mirrors
        : const <String>[];
    String fieldName(String field) => switch (field) {
      'donation' => t('link do zbiórki'),
      'author' => t('autor'),
      _ => t('repozytorium'),
    };
    return <Widget>[
      if (differences.isNotEmpty)
        ZenInfo(
          key: const Key('updates-official-differs'),
          icon: Icons.gpp_bad_rounded,
          tone: zen.danger,
          title: t('To może nie być oficjalny Zen'),
          text: t(
            'Ta kopia pokazuje inne dane niż podpisane przez opiekunów '
            '({fields}). Link do zbiórki mógł zostać podmieniony. '
            'Podpisany link: {url}',
            {
              'fields': differences.map(fieldName).join(', '),
              'url': service.book.signedOfficial?.donation ?? '—',
            },
          ),
        )
      else if (service.book.enabled && service.book.signedOfficial != null)
        ZenInfo(
          key: const Key('updates-official-ok'),
          icon: Icons.verified_rounded,
          tone: zen.success,
          text: t(
            'Link do zbiórki i autor zgadzają się z podpisanym wydaniem '
            '{version}.',
            {'version': service.book.officialSource!.manifest.version},
          ),
        ),
      if (canary != null)
        ZenInfo(
          key: Key(
            service.canaryExpired
                ? 'updates-canary-expired'
                : 'updates-canary-fresh',
          ),
          icon: service.canaryExpired
              ? Icons.warning_amber_rounded
              : Icons.campaign_rounded,
          tone: service.canaryExpired ? zen.danger : zen.success,
          title: service.canaryExpired
              ? t('Oświadczenie opiekunów nie zostało odnowione')
              : t('Oświadczenie opiekunów (kanarek)'),
          text: service.canaryExpired
              ? t(
                  'Miało zostać odnowione do {date}. Opiekunowie mogli '
                  'zostać zmuszeni do milczenia — ostrożnie z nowymi '
                  'wersjami. Ostatnia treść: {text}',
                  {
                    'date': _date(
                      DateTime.fromMillisecondsSinceEpoch(
                        canary.statement.until,
                      ),
                    ),
                    'text': canary.statement.text,
                  },
                )
              : t('{text} (podpisane {date}, następne do {until})', {
                  'text': canary.statement.text,
                  'date': _date(
                    DateTime.fromMillisecondsSinceEpoch(canary.statement.at),
                  ),
                  'until': _date(
                    DateTime.fromMillisecondsSinceEpoch(canary.statement.until),
                  ),
                }),
        ),
      if (mirrors.isNotEmpty)
        ZenInfo(
          key: const Key('updates-mirrors'),
          icon: Icons.alt_route_rounded,
          title: t('Lustra repozytorium'),
          text: mirrors.join('\n'),
        ),
    ];
  }

  static String _date(DateTime d) {
    return t('{date} o {time}', {
      'date': ZenFormat.date(d),
      'time': ZenFormat.time(d),
    });
  }
}
