import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/permissions/presentation/permissions_screen.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/presentation/ios_background_section.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/presentation/animations_choice.dart';
import 'package:zen/src/features/settings/presentation/lock_mode_choice.dart';
import 'package:zen/src/features/settings/presentation/notification_privacy_choice.dart';

/// Whether the first start shows the setup (the lock, notifications,
/// gates, animations) once, right after the app password and before the
/// permissions step. Off in tests and previews; the real app turns it on
/// (like the permissions step).
final Provider<bool> firstRunSetupRequiredProvider = Provider<bool>(
  (Ref ref) => false,
);

/// The gates as the setup asks about them: the same terms for everyone.
enum GateDefault {
  /// "Otwarte za darmo": whoever asks is introduced at once, for free.
  open,

  /// "Za moją zgodą": for free, but this person approves each request.
  consent;

  GateTerms get terms => switch (this) {
    GateDefault.open => GateTerms.standard,
    GateDefault.consent => GateTerms.freeWithConsent,
  };

  String get label => switch (this) {
    GateDefault.open => t('Otwarte za darmo'),
    GateDefault.consent => t('Za moją zgodą'),
  };

  String get description => switch (this) {
    GateDefault.open => t(
      'Kto poprosi, zostaje przedstawiony od razu i bez opłat.',
    ),
    GateDefault.consent => t('Za darmo, ale każdą prośbę zatwierdzasz sam(a).'),
  };

  /// Which of the two [gates] are; `null` for terms of one's own (a price,
  /// different terms per tier).
  static GateDefault? of(GateSettings gates) => switch (gates.sameForAll) {
    GateTerms.standard => GateDefault.open,
    GateTerms.freeWithConsent => GateDefault.consent,
    _ => null,
  };
}

/// Where the setup reads and sets the gates (the introductions service;
/// tests put their own).
abstract interface class GateDefaults {
  /// The gates now; `null` for terms of one's own.
  GateDefault? get current;

  Future<void> set(GateDefault value);

  /// Fires when the gates change.
  Listenable get changes;
}

final class IntroGateDefaults implements GateDefaults {
  const IntroGateDefaults(this.intro);

  final IntroService intro;

  @override
  GateDefault? get current => GateDefault.of(intro.gates);

  @override
  Future<void> set(GateDefault value) async {
    for (final GateTier tier in GateTier.values) {
      await intro.setGateTier(tier, value.terms);
    }
  }

  @override
  Listenable get changes => intro;
}

final Provider<GateDefaults> gateDefaultsProvider = Provider<GateDefaults>(
  (Ref ref) => IntroGateDefaults(ref.watch(introServiceProvider)),
);

/// The first start, right after the app password: the setup once. Then
/// the gate shows the permissions step (the setup's last step).
class FirstRunSetupStage extends StatelessWidget {
  const FirstRunSetupStage({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    key: Key('first-run-setup'),
    body: SafeArea(child: FirstRunSetupFlow(firstStart: true)),
  );
}

/// The setup again, from Ustawienia ("Ponownie przeprowadź konfigurację").
class FirstRunSetupScreen extends StatelessWidget {
  const FirstRunSetupScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const FirstRunSetupScreen(),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('first-run-setup-screen'),
    appBar: AppBar(title: Text(t('Konfiguracja startowa'))),
    body: const SafeArea(top: false, child: FirstRunSetupFlow()),
  );
}

enum _SetupStep { lock, notifications, iphone, gates, animations, permissions }

/// The steps one by one: when Zen locks, what notifications say, on an
/// iPhone how iOS is to wake Zen, the gates, the animations and (from
/// Ustawienia; on the first start the gate shows it next) the permissions. Every answer is saved at once, so
/// skipping keeps what is set (the defaults on the first start).
class FirstRunSetupFlow extends ConsumerStatefulWidget {
  const FirstRunSetupFlow({this.firstStart = false, super.key});

  /// The first start: finishing or skipping marks the setup done.
  final bool firstStart;

  @override
  ConsumerState<FirstRunSetupFlow> createState() => _FirstRunSetupFlowState();
}

class _FirstRunSetupFlowState extends ConsumerState<FirstRunSetupFlow> {
  int _index = 0;
  bool _finishing = false;

  /// The steps shown here, and how many the setup has in all (on the first
  /// start the permissions step follows as a stage of its own).
  (List<_SetupStep>, int) _steps() {
    final bool permissions = ref.watch(permissionsPlatformProvider).hasAnything;
    final bool iphone = ref.watch(iosBackgroundBridgeEnabledProvider);
    final List<_SetupStep> here = <_SetupStep>[
      _SetupStep.lock,
      _SetupStep.notifications,
      if (iphone) _SetupStep.iphone,
      _SetupStep.gates,
      _SetupStep.animations,
      if (permissions && !widget.firstStart) _SetupStep.permissions,
    ];
    final bool permissionsFollow =
        widget.firstStart &&
        permissions &&
        ref.watch(permissionsSetupRequiredProvider) &&
        !ref.watch(
          appSettingsControllerProvider.select((s) => s.permissionsSetupDone),
        );
    return (here, here.length + (permissionsFollow ? 1 : 0));
  }

  Future<void> _finish() async {
    if (!widget.firstStart) {
      Navigator.of(context).maybePop();
      return;
    }
    if (_finishing) {
      return;
    }
    setState(() => _finishing = true);
    try {
      // The gate goes on to the next step as soon as this is set.
      await ref
          .read(appSettingsControllerProvider.notifier)
          .setFirstRunSetupDone(true);
    } on Object catch (error, stack) {
      logZenError('Zapis ustawień', error, stack);
      if (mounted) {
        setState(() => _finishing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final (List<_SetupStep> steps, int total) = _steps();
    final int index = _index.clamp(0, steps.length - 1);
    final _SetupStep step = steps[index];
    final bool last = index == steps.length - 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: step == _SetupStep.permissions
              ? const PermissionsPanel()
              : ListView(
                  key: Key('first-run-step-${step.name}'),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  children: <Widget>[
                    if (widget.firstStart && index == 0) _welcome(zen),
                    Text(
                      t('Krok {n} z {total}', {'n': index + 1, 'total': total}),
                      key: const Key('first-run-step-count'),
                      style: zen.label(color: zen.textMuted),
                    ),
                    const SizedBox(height: 6),
                    ..._body(zen, step),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Row(
            children: <Widget>[
              if (index > 0)
                TextButton(
                  key: const Key('first-run-back'),
                  onPressed: () => setState(() => _index = index - 1),
                  child: Text(t('Wstecz')),
                )
              else
                TextButton(
                  key: const Key('first-run-skip'),
                  onPressed: _finishing ? null : () => unawaited(_finish()),
                  child: Text(t('Pomiń')),
                ),
              const Spacer(),
              FilledButton(
                key: const Key('first-run-next'),
                style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
                onPressed: _finishing
                    ? null
                    : last
                    ? () => unawaited(_finish())
                    : () => setState(() => _index = index + 1),
                child: Text(
                  last && !(widget.firstStart && total > steps.length)
                      ? t('Gotowe')
                      : t('Dalej'),
                ),
              ),
            ],
          ),
        ),
        if (widget.firstStart)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              t(
                'Wszystko zmienisz później: Ustawienia → Ponownie przeprowadź '
                'konfigurację.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(color: zen.textMuted, fontSize: 12),
            ),
          ),
      ],
    );
  }

  List<Widget> _body(ZenColors zen, _SetupStep step) => switch (step) {
    _SetupStep.lock => <Widget>[
      ZenHero(
        title: t('Kiedy Zen ma się blokować?'),
        icon: Icons.lock_clock_outlined,
        text: t(
          'Zablokowany Zen pyta o hasło, zanim pokaże rozmowy. Wiadomości '
          'i połączenia nadal przychodzą.',
        ),
      ),
      const ZenCard(child: LockModeSettingChoice()),
    ],
    _SetupStep.notifications => <Widget>[
      ZenHero(
        title: t('Co mają mówić powiadomienia?'),
        icon: Icons.notifications_none_rounded,
        text: t(
          'Powiadomienia widać na ekranie blokady i zostają w historii '
          'systemu. Rozmowa może mieć własny poziom (menu rozmowy → '
          'Powiadomienia).',
        ),
      ),
      const ZenCard(child: NotificationPrivacySettingChoice()),
    ],
    _SetupStep.iphone => <Widget>[
      ZenHero(
        title: t('Jak iPhone ma budzić Zen?'),
        icon: Icons.phone_iphone_rounded,
        text: t(
          'iOS usypia Zen zaraz po wyjściu z aplikacji. Wiadomości czekają '
          'wtedy u znajomych, a Zen odbiera je, gdy się obudzi. Wybierz '
          'sposoby budzenia — możesz łączyć kilka.',
        ),
      ),
      const IosWakeOptions(),
      const ZenCard(child: IosSettingsChecklist()),
    ],
    _SetupStep.gates => <Widget>[
      ZenHero(
        title: t('Bramy do Twoich znajomych'),
        icon: Icons.door_front_door_outlined,
        text: t(
          'Brama to Twoja zgoda na to, żeby ktoś poprosił Cię o '
          'przedstawienie komuś z Twoich znajomych.',
        ),
      ),
      const ZenCard(child: _GateDefaultChoice()),
    ],
    _SetupStep.animations => <Widget>[
      ZenHero(
        title: t('Animacje'),
        icon: Icons.animation_rounded,
        text: t('Ruch teł motywów i drobnych efektów.'),
      ),
      const ZenCard(child: AnimationsSettingChoice()),
    ],
    _SetupStep.permissions => const <Widget>[],
  };

  /// First start only: the welcome above the first step.
  Widget _welcome(ZenColors zen) => ZenCard(
    key: const Key('first-run-welcome'),
    tone: zen.accent,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t('Witaj w Zen'),
          style: TextStyle(
            color: zen.textPrimary,
            fontWeight: FontWeight.w800,
            fontSize: 20,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          t(
            'Sieć ludzi, którzy się znają — bez serwerów, reklam i '
            'algorytmu. Wiadomości idą prosto między telefonami '
            'znajomych.',
          ),
          style: TextStyle(color: zen.textSecondary, fontSize: 14, height: 1.4),
        ),
      ],
    ),
  );
}

/// "Otwarte za darmo" or "Za moją zgodą", saved at once.
class _GateDefaultChoice extends ConsumerWidget {
  const _GateDefaultChoice();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final GateDefaults gates = ref.watch(gateDefaultsProvider);
    return ListenableBuilder(
      listenable: gates.changes,
      builder: (BuildContext context, Widget? child) {
        final ZenColors zen = ZenColors.of(context);
        final GateDefault? current = gates.current;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              key: const Key('first-run-gates-choice'),
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final GateDefault value in GateDefault.values)
                  ChoiceChip(
                    key: Key('first-run-gates-${value.name}'),
                    showCheckmark: false,
                    label: Text(value.label),
                    selected: current == value,
                    onSelected: (_) => unawaited(
                      gates.set(value).catchError((
                        Object error,
                        StackTrace stack,
                      ) {
                        logZenError('Bramy: zapis', error, stack);
                      }),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              current?.description ??
                  t(
                    'Masz własne ceny bram. Wybierz jedną z opcji, żeby je '
                    'zastąpić, albo zostaw je bez zmian.',
                  ),
              key: const Key('first-run-gates-description'),
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t('Ceny i wyjątki ustawisz później na grafie, w trybie Bramy.'),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
          ],
        );
      },
    );
  }
}
