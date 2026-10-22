import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/about/legal_documents.dart';
import 'package:zen/src/features/about/presentation/legal_markdown.dart';
import 'package:zen/src/features/settings/presentation/page_title.dart';

/// Opens [url] in the browser; where that is not possible, copies it and
/// says so.
Future<void> openOrCopyLink(BuildContext context, String url) async {
  if (await openWebLink(url)) {
    return;
  }
  await Clipboard.setData(ClipboardData(text: url));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t('Link skopiowany — otwórz go w przeglądarce.'))),
    );
  }
}

/// One of the documents, read in the app: scrollable, selectable, its links
/// open the other documents here and web pages in the browser.
class LegalDocumentScreen extends ConsumerWidget {
  const LegalDocumentScreen({required this.document, super.key});

  final LegalDocument document;

  static Future<void> open(BuildContext context, LegalDocument document) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              LegalDocumentScreen(document: document),
        ),
      );

  void _onLink(BuildContext context, String href) {
    final LegalLinkTarget? target = resolveLegalLink(document, href);
    final LegalDocument? doc = target?.document;
    if (doc != null) {
      unawaited(LegalDocumentScreen.open(context, doc));
      return;
    }
    final String? url = target?.url;
    if (url != null) {
      unawaited(openOrCopyLink(context, url));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AsyncValue<LegalTexts> texts = ref.watch(legalTextsProvider);
    // The documents exist in English only; another language says so.
    final String language = ZenI18n.code;
    return Scaffold(
      key: Key('legal-document-${document.name}'),
      appBar: AppBar(
        title: PageTitle(document.title),
        actions: <Widget>[
          IconButton(
            key: const Key('legal-document-online'),
            tooltip: t('Otwórz na GitHubie'),
            onPressed: () => unawaited(openOrCopyLink(context, document.url)),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: switch (texts) {
          AsyncData<LegalTexts>(:final LegalTexts value) => SelectionArea(
            child: ListView(
              key: const Key('legal-document-body'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: <Widget>[
                if (language != 'en' && document != LegalDocument.licence)
                  ZenInfo(
                    icon: Icons.translate_rounded,
                    text: t(
                      'Dokument jest po angielsku. Ta sama treść jest na '
                      'GitHubie (przycisk u góry).',
                    ),
                  ),
                LegalMarkdownView(
                  key: Key('legal-document-text-${document.name}'),
                  source: value.of(document),
                  onLink: (String href) => _onLink(context, href),
                ),
              ],
            ),
          ),
          AsyncError<LegalTexts>() => ListView(
            padding: const EdgeInsets.all(16),
            children: <Widget>[
              ZenInfo(
                icon: Icons.error_outline_rounded,
                tone: zen.warning,
                text: t(
                  'Nie udało się odczytać dokumentu z aplikacji. Przeczytaj '
                  'go na GitHubie.',
                ),
              ),
              const SizedBox(height: 8),
              SelectableText(document.url),
            ],
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}
