import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/health/clock_skew_tracker.dart';
import 'package:zen/src/features/health/health_report.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/permissions/presentation/permissions_screen.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';

/// "Dlaczego nie działa?" (STAN A22): one list of everything that makes
/// messages and alarms not arrive — network, neighbours, background
/// service, notifications, battery, the clock and free space — each with
/// what to do about it.
class HealthScreen extends ConsumerStatefulWidget {
  const HealthScreen({this.isAndroid, super.key});

  /// Tests: pretend to be (not to be) an Android phone.
  final bool? isAndroid;

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const HealthScreen(),
    ),
  );

  @override
  ConsumerState<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends ConsumerState<HealthScreen>
    with WidgetsBindingObserver {
  PermissionsSnapshot? _permissions;
  StorageInfo? _storage;
  bool? _background;
  bool _loaded = false;
  bool _loading = false;

  bool get _android => widget.isAndroid ?? (!kIsWeb && Platform.isAndroid);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system settings.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    if (_loading) {
      return;
    }
    setState(() => _loading = true);
    PermissionsSnapshot? perms;
    StorageInfo? storage;
    bool? background;
    try {
      perms = await ref.read(permissionsPlatformProvider).check();
    } on Object {
      perms = null;
    }
    final HealthProbe probe = ref.read(healthProbeProvider);
    try {
      storage = await probe.storage();
    } on Object {
      storage = null;
    }
    try {
      background = await probe.backgroundServiceRunning();
    } on Object {
      background = null;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _permissions = perms;
      _storage = storage;
      _background = background;
      _loaded = true;
      _loading = false;
    });
  }

  HealthReport _report(AppShellState shell, ClockSkewTracker clock) {
    return buildHealthReport(
      HealthInputs(
        net: switch (shell.health) {
          ServiceHealth.active => HealthNetState.active,
          ServiceHealth.syncing => HealthNetState.syncing,
          ServiceHealth.stopped => HealthNetState.stopped,
          ServiceHealth.failed => HealthNetState.failed,
        },
        peers: shell.peers,
        routingEntries: shell.routingEntries,
        localAddress: shell.localAddress,
        errorMessage: shell.errorMessage,
        isAndroid: _android,
        backgroundRunning: _background,
        permissions: _permissions,
        clockSkew: clock.estimate,
        clockPeers: clock.peerCount,
        storage: _storage,
      ),
    );
  }

  /// Plain text to send to someone by hand (no addresses, no names).
  String _asText(HealthReport report) {
    final StringBuffer b = StringBuffer('Zen — ${t('Dlaczego nie działa?')}\n');
    for (final HealthItem i in report.items) {
      b.writeln('[${_levelWord(i.level)}] ${i.title}: ${i.detail}');
    }
    return b.toString().trimRight();
  }

  static String _levelWord(HealthLevel l) => switch (l) {
    HealthLevel.ok => 'OK',
    HealthLevel.warn => t('uwaga'),
    HealthLevel.bad => t('błąd'),
    HealthLevel.unknown => '?',
  };

  Future<void> _fix(HealthFix fix) async {
    switch (fix) {
      case HealthFix.permissions:
        await PermissionsScreen.open(context);
      case HealthFix.appSettings:
        await openAndroidAppSettings();
      case HealthFix.none:
        break;
    }
    if (mounted) {
      unawaited(_refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AppShellState shell = ref.watch(appShellControllerProvider);
    final ClockSkewTracker clock = ref.watch(clockSkewTrackerProvider);
    return Scaffold(
      key: const Key('health-screen'),
      appBar: AppBar(
        title: Text(t('Dlaczego nie działa?')),
        actions: <Widget>[
          IconButton(
            key: const Key('health-refresh'),
            tooltip: t('Sprawdź ponownie'),
            onPressed: _loading ? null : () => unawaited(_refresh()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListenableBuilder(
          listenable: clock,
          builder: (BuildContext context, Widget? _) {
            final HealthReport report = _report(shell, clock);
            return ListView(
              key: const Key('health-body'),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: <Widget>[
                _summary(zen, report),
                if (!_loaded)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                for (final HealthItem i in report.items) _row(zen, i),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('health-copy'),
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _asText(report)),
                    );
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(t('Raport skopiowany.'))),
                    );
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(t('Skopiuj raport')),
                ),
                const SizedBox(height: 6),
                Text(
                  t(
                    'Raport nie zawiera adresów ani nazw — możesz go komuś '
                    'wysłać ręcznie.',
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: zen.textMuted, fontSize: 12),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Color _tone(ZenColors zen, HealthLevel l) => switch (l) {
    HealthLevel.ok => zen.success,
    HealthLevel.warn => zen.warning,
    HealthLevel.bad => zen.danger,
    HealthLevel.unknown => zen.textMuted,
  };

  IconData _icon(HealthLevel l) => switch (l) {
    HealthLevel.ok => Icons.check_circle_outline_rounded,
    HealthLevel.warn => Icons.warning_amber_rounded,
    HealthLevel.bad => Icons.error_outline_rounded,
    HealthLevel.unknown => Icons.help_outline_rounded,
  };

  String _levelLabel(HealthLevel l) => switch (l) {
    HealthLevel.ok => t('W porządku'),
    HealthLevel.warn => t('Uwaga'),
    HealthLevel.bad => t('Problem'),
    HealthLevel.unknown => t('Nieznane'),
  };

  Widget _summary(ZenColors zen, HealthReport report) {
    final HealthLevel w = report.worst;
    final String text = switch (w) {
      HealthLevel.ok => t('Wszystko wygląda dobrze.'),
      _ => tn(
        report.problems,
        one: 'Znaleziono {n} rzecz do sprawdzenia.',
        few: 'Znaleziono {n} rzeczy do sprawdzenia.',
        many: 'Znaleziono {n} rzeczy do sprawdzenia.',
      ),
    };
    return ZenCard(
      key: const Key('health-summary'),
      tone: _tone(zen, w),
      child: Row(
        children: <Widget>[
          ZenIconBadge(icon: _icon(w), tone: _tone(zen, w), size: 40),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: zen.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ZenColors zen, HealthItem i) {
    final Color tone = _tone(zen, i.level);
    return ZenCard(
      key: Key('health-row-${i.id}'),
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            label: _levelLabel(i.level),
            child: ExcludeSemantics(
              child: ZenIconBadge(icon: _icon(i.level), tone: tone, size: 40),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  i.title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  i.detail,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                if (i.fix != HealthFix.none &&
                    i.level != HealthLevel.ok) ...<Widget>[
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    key: Key('health-fix-${i.id}'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 38),
                    ),
                    onPressed: () => unawaited(_fix(i.fix)),
                    child: Text(
                      i.fix == HealthFix.permissions
                          ? t('Otwórz uprawnienia')
                          : t('Otwórz ustawienia aplikacji'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A bar under the connection status when this phone's clock is off by
/// more than two minutes (STAN A21): messages, meetings and tickets are
/// otherwise dropped silently. Tap: the health report.
class ClockSkewBanner extends ConsumerWidget {
  const ClockSkewBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ClockSkewTracker clock = ref.watch(clockSkewTrackerProvider);
    return ListenableBuilder(
      listenable: clock,
      builder: (BuildContext context, Widget? _) {
        final Duration? skew = clock.estimate;
        if (skew == null || !clock.skewed) {
          return const SizedBox.shrink();
        }
        final ZenColors zen = ZenColors.of(context);
        final int minutes = skew.abs().inMinutes;
        final String text = skew.isNegative
            ? t('Twój zegar spieszy się o {min} min', {'min': minutes})
            : t('Twój zegar się spóźnia o {min} min', {'min': minutes});
        return Material(
          color: zen.warning.withValues(alpha: 0.16),
          child: InkWell(
            key: const Key('clock-skew-banner'),
            onTap: () => unawaited(HealthScreen.open(context)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.schedule_rounded, size: 18, color: zen.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$text — ${t('wiadomości mogą być odrzucane')}',
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    t('Pokaż'),
                    style: TextStyle(
                      color: zen.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
