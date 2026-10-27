import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// The "Animacje" question: three choices and a line saying what the chosen
/// one does. It holds no state, so any screen can ask it (Ustawienia →
/// Wygląd, the first-start setup): give it the current [value] and take the
/// answer in [onChanged]. [AnimationsSettingChoice] ties it to the setting.
class AnimationsChoice extends StatelessWidget {
  const AnimationsChoice({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final AppAnimations value;
  final ValueChanged<AppAnimations> onChanged;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          key: const Key('settings-animations-choice'),
          spacing: 8,
          runSpacing: 0,
          children: <Widget>[
            for (final AppAnimations mode in AppAnimations.values)
              ChoiceChip(
                key: Key('settings-animations-${mode.name}'),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Text(mode.label),
                selected: value == mode,
                onSelected: (_) => onChanged(mode),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          value.description,
          key: const Key('settings-animations-description'),
          style: TextStyle(
            color: zen.textSecondary,
            fontSize: 13.5,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

/// [AnimationsChoice] bound to the saved setting.
class AnimationsSettingChoice extends ConsumerWidget {
  const AnimationsSettingChoice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppAnimations animations = ref.watch(
      appSettingsControllerProvider.select((AppSettings s) => s.animations),
    );
    return AnimationsChoice(
      value: animations,
      onChanged: (AppAnimations value) => unawaited(
        ref.read(appSettingsControllerProvider.notifier).setAnimations(value),
      ),
    );
  }
}
