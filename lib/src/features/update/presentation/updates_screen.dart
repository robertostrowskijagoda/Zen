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
import 'package:zen/src/features/update/canary.dart';
import 'package:zen/src/features/update/presentation/share_app_screen.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_service.dart';

/// "Aktualizacje i Podaj dalej" (§14.2).
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
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          _versionCard(zen),
          ZenSection(t('Aktualizacje'), top: 16),
          // A store build is updated by its store (STAN D12).
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
              title: t('Bez sklepu i bez serwera'),
              text: t(
                'Nowe wersje przychodzą od znajomych, bez sklepu i bez '
                'serwera. Zen czeka 7 dni od pierwszego zobaczenia wersji '
                'i nigdy nie instaluje niczego sam.',
              ),
            ),
          ZenSection(t('Podaj dalej'), top: 24),
          ZenHero(
            title: t('Daj Zen komuś obok'),
            icon: Icons.volunteer_activism_rounded,
            tone: zenTone(zen, 2),
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
    );
  }

  Widget _versionCard(ZenColors zen) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
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
                  alignment: Alignment.centerLeft,
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
        Icons.block_rounded,
        t('Aktualizacje przez sieć jeszcze nie działają'),
        t(
          'Ustalamy, jak zatwierdzać nowe wersje bez osób z kluczami. Nową '
          'wersję zainstalujesz od znajomego przez „Podaj dalej”.',
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
      UpdatePhase.otherPlatform => zenTone(zen, 6),
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
              borderRadius: BorderRadius.circular(99),
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

  /// The signed donation details, the canary and the mirrors (§14.2,
  /// §14.3) — only once something signed by the maintainers is known.
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
