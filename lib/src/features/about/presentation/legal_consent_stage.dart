import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/about/legal_documents.dart';
import 'package:zen/src/features/about/presentation/legal_document_screen.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// The very first screen (and again when the documents change): the terms,
/// the privacy policy and the licence notice, each readable here, and the
/// person's acceptance before anything else (the app password, the
/// account) is made.
class LegalConsentStage extends ConsumerStatefulWidget {
  const LegalConsentStage({super.key});

  @override
  ConsumerState<LegalConsentStage> createState() => _LegalConsentStageState();
}

class _LegalConsentStageState extends ConsumerState<LegalConsentStage> {
  bool _agreed = false;
  bool _saving = false;

  Future<void> _accept(String version) async {
    setState(() => _saving = true);
    try {
      await ref
          .read(appSettingsControllerProvider.notifier)
          .acceptLegalDocuments(version);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _decline() async {
    final bool? close = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(t('Bez akceptacji nie można korzystać z Zen')),
        content: Text(
          t(
            'Zen działa tylko na tych zasadach. Jeśli się na nie nie '
            'zgadzasz, zamknij aplikację i ją odinstaluj. Na tym urządzeniu '
            'nic jeszcze nie zostało utworzone.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Wróć')),
          ),
          TextButton(
            key: const Key('legal-consent-close-app'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Zamknij aplikację')),
          ),
        ],
      ),
    );
    if (close ?? false) {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String? version = legalVersionNow(ref.watch(legalTextsProvider));
    final String accepted = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings s) => s.legalAcceptedVersion,
      ),
    );
    final bool changed = accepted.isNotEmpty && accepted != version;
    return Scaffold(
      key: const Key('legal-consent'),
      body: SafeArea(
        child: SelectionArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
            children: <Widget>[
              Center(
                child: ZenIconBadge(
                  icon: Icons.gavel_rounded,
                  tone: zen.accent,
                  size: 64,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                changed ? t('Dokumenty się zmieniły') : t('Zanim zaczniesz'),
                textAlign: TextAlign.center,
                style: zen.display(
                  color: zen.textPrimary,
                  size: 26,
                  weight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                changed
                    ? t(
                        'Regulamin, polityka prywatności albo licencja mają '
                        'nową wersję. Przeczytaj je i zaakceptuj, żeby dalej '
                        'korzystać z Zen.',
                      )
                    : t(
                        'Zen nie ma serwera ani firmy pośrodku. Przeczytaj, '
                        'na jakich zasadach z niego korzystasz i co dzieje się '
                        'z Twoimi danymi. Dotknij dokumentu, żeby go otworzyć.',
                      ),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 14.5,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              for (final LegalDocument doc in LegalDocument.values)
                _DocumentTile(
                  document: doc,
                  onTap: () =>
                      unawaited(LegalDocumentScreen.open(context, doc)),
                ),
              if (version == kLegalVersionUnavailable)
                ZenInfo(
                  icon: Icons.error_outline_rounded,
                  tone: zen.warning,
                  text: t(
                    'Nie udało się odczytać dokumentów z aplikacji. '
                    'Przeczytaj je na GitHubie (link w dokumencie).',
                  ),
                ),
              const SizedBox(height: 10),
              Material(
                type: MaterialType.transparency,
                child: CheckboxListTile(
                  key: const Key('legal-consent-agree'),
                  value: _agreed,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: version == null || _saving
                      ? null
                      : (bool? v) => setState(() => _agreed = v ?? false),
                  title: Text(
                    t(
                      'Akceptuję regulamin, politykę prywatności i warunki '
                      'licencji.',
                    ),
                    style: TextStyle(color: zen.textPrimary, height: 1.4),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('legal-consent-accept'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                onPressed: !_agreed || version == null || _saving
                    ? null
                    : () => unawaited(_accept(version)),
                child: Text(t('Akceptuję i przechodzę dalej')),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const Key('legal-consent-decline'),
                onPressed: _saving ? null : () => unawaited(_decline()),
                child: Text(t('Nie akceptuję')),
              ),
              if (version == null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A document to open: its name, what it is about, and a chevron. The
/// texts wrap: nothing is cut in a long language.
class _DocumentTile extends StatelessWidget {
  const _DocumentTile({required this.document, required this.onTap});

  final LegalDocument document;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      key: Key('legal-consent-open-${document.name}'),
      onTap: onTap,
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 10, 12),
      child: Row(
        children: <Widget>[
          ZenIconBadge(
            icon: switch (document) {
              LegalDocument.terms => Icons.gavel_rounded,
              LegalDocument.privacy => Icons.privacy_tip_rounded,
              LegalDocument.licence => Icons.description_outlined,
            },
            tone: zen.accent,
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  document.title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  document.subtitle,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: zen.textMuted),
        ],
      ),
    );
  }
}
