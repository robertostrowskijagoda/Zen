import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// The age gate (§26.1 #8, §27): sections for adults (Dating, the pyramid)
/// show [child] only to someone who said they are 18 or older. The first
/// time it asks for the date of birth or an 18+ confirmation; the answer
/// stays on this device (it is a declaration, §27).
class AgeGate extends ConsumerWidget {
  const AgeGate({required this.child, this.now, super.key});

  final Widget child;

  /// The current time (tests); the clock when `null`.
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final DateTime today = now?.call() ?? DateTime.now();
    if (settings.isAdultAt(today)) {
      return child;
    }
    final ZenColors zen = ZenColors.of(context);
    final bool answered = settings.ageAnswered;
    return Scaffold(
      key: const Key('age-gate'),
      backgroundColor: zen.background,
      appBar: ModalRoute.of(context)?.canPop ?? false
          ? AppBar(backgroundColor: zen.background)
          : null,
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: answered
                ? ZenEmpty(
                    key: const Key('age-gate-minor'),
                    icon: Icons.lock_outline_rounded,
                    title: t('Dostępne od 18 lat'),
                    text: t(
                      'Ta część aplikacji jest tylko dla dorosłych. Data '
                      'urodzenia zostaje na tym urządzeniu.',
                    ),
                    action: TextButton(
                      key: const Key('age-gate-fix'),
                      onPressed: () => unawaited(_pickDate(context, ref)),
                      child: Text(t('Popraw datę urodzenia')),
                    ),
                  )
                : ZenEmpty(
                    key: const Key('age-gate-ask'),
                    icon: Icons.cake_outlined,
                    title: t('Ile masz lat?'),
                    text: t(
                      'Randki i piramida są tylko dla dorosłych. Podaj datę '
                      'urodzenia albo potwierdź, że masz ukończone 18 lat. '
                      'Odpowiedź zostaje tylko na tym urządzeniu.',
                    ),
                    action: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        FilledButton.icon(
                          key: const Key('age-gate-date'),
                          onPressed: () => unawaited(_pickDate(context, ref)),
                          icon: const Icon(Icons.event_outlined),
                          label: Text(t('Podaj datę urodzenia')),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          key: const Key('age-gate-adult'),
                          onPressed: () => unawaited(
                            ref
                                .read(appSettingsControllerProvider.notifier)
                                .setAgeGate(adult: true),
                          ),
                          child: Text(t('Mam ukończone 18 lat')),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickDate(BuildContext context, WidgetRef ref) async {
    final DateTime today = now?.call() ?? DateTime.now();
    final DateTime? birth = await showDatePicker(
      context: context,
      initialDate: DateTime(today.year - 18, today.month, today.day),
      firstDate: DateTime(today.year - 120),
      lastDate: today,
      initialEntryMode: DatePickerEntryMode.input,
      helpText: t('Data urodzenia'),
    );
    if (birth == null) {
      return;
    }
    await ref
        .read(appSettingsControllerProvider.notifier)
        .setAgeGate(birth: birth);
  }
}
