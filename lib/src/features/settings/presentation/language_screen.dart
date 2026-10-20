import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_language_controller.dart';
import 'package:zen/src/app/i18n/zen_locales.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Ustawienia → Język: "automatically, like the system" or one of the
/// languages Zen speaks, each under its own name. A choice applies at once
/// (the whole app, this screen included, speaks it right away) and is
/// remembered for the next start.
class LanguageScreen extends ConsumerWidget {
  const LanguageScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLanguageState language = ref.watch(zenLanguageControllerProvider);
    final ZenLanguageController controller = ref.read(
      zenLanguageControllerProvider.notifier,
    );
    final ZenLanguage automatic =
        ZenI18n.byCode(controller.automaticCode) ?? kZenSourceLanguage;
    return Scaffold(
      key: const ValueKey<String>('language-screen'),
      appBar: AppBar(title: Text(t('Język'))),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            ZenGroup(
              children: <Widget>[
                _LanguageOption(
                  key: const ValueKey<String>('language-option-auto'),
                  leading: ZenIconBadge(
                    icon: Icons.translate_rounded,
                    tone: zen.accent,
                    size: 40,
                  ),
                  title: t('Automatycznie'),
                  subtitle: t('Jak w systemie: {language}', <String, Object?>{
                    'language': automatic.nativeName,
                  }),
                  selected: language.preference == null,
                  onTap: () => unawaited(controller.choose(null)),
                ),
              ],
            ),
            ZenSection(t('Języki'), top: 22),
            ZenGroup(
              children: <Widget>[
                for (int i = 0; i < kZenLanguages.length; i++)
                  _LanguageOption(
                    key: ValueKey<String>(
                      'language-option-${kZenLanguages[i].code}',
                    ),
                    leading: _CodeBadge(
                      code: kZenLanguages[i].code,
                      tone: zenTone(zen, i),
                    ),
                    title: kZenLanguages[i].nativeName,
                    titleLocale: zenLocaleOf(kZenLanguages[i].code),
                    selected: language.preference == kZenLanguages[i].code,
                    onTap: () =>
                        unawaited(controller.choose(kZenLanguages[i].code)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One row: a badge, the name (and what it means), a check mark when
/// chosen.
class _LanguageOption extends StatelessWidget {
  const _LanguageOption({
    super.key,
    required this.leading,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.titleLocale,
  });

  final Widget leading;
  final String title;
  final String? subtitle;

  /// The language [title] is written in (a language's own name), so it is
  /// drawn with that language's glyphs and read out in its voice.
  final Locale? titleLocale;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        button: true,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 60),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 10),
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(child: leading),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          title,
                          locale: titleLocale,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            height: 1.25,
                            color: zen.textPrimary,
                          ),
                        ),
                        if (subtitle != null) ...<Widget>[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: zen.textSecondary,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox.square(
                    dimension: 24,
                    child: selected
                        ? Icon(Icons.check_rounded, color: zen.accent)
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The language's code ("DE") in a rounded square of its tone, like the
/// icon badges of the other settings rows.
class _CodeBadge extends StatelessWidget {
  const _CodeBadge({required this.code, required this.tone});

  static const double _size = 40;

  final String code;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      width: _size,
      height: _size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_size * 0.32),
        gradient: LinearGradient(
          colors: <Color>[
            tone.withValues(alpha: 0.26),
            tone.withValues(alpha: 0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: tone.withValues(alpha: 0.28)),
      ),
      child: Text(
        code.toUpperCase(),
        maxLines: 1,
        textScaler: TextScaler.noScaling,
        style: zen.label(color: tone, size: 11.5),
      ),
    );
  }
}
