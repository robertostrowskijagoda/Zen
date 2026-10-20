import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

/// The locale of Zen's language [code], for `MaterialApp.locale` and
/// `Text.locale`. Chinese is the simplified script, the one Zen speaks (it
/// also picks the matching glyphs of shared Han characters).
Locale zenLocaleOf(String code) => code == 'zh'
    ? const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')
    : Locale(code);

/// The locales the apps declare (`MaterialApp.supportedLocales`): one per
/// language Zen speaks, so Material's own texts and the direction of the
/// layout (right to left for Arabic) follow Zen's language.
final List<Locale> zenSupportedLocales = List<Locale>.unmodifiable(<Locale>[
  for (final ZenLanguage language in kZenLanguages) zenLocaleOf(language.code),
]);

/// Builds every widget of the app again, keeping all state and the
/// navigation stack: after the language changes, each `t()` runs again
/// and returns the new language. Works in release builds too (unlike
/// `reassembleApplication`). Called during a frame's build or layout, it
/// waits for the end of that frame.
void rebuildAllZenElements() {
  final SchedulerBinding scheduler = SchedulerBinding.instance;
  if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
    scheduler.addPostFrameCallback((Duration _) => _markAllElements());
    return;
  }
  _markAllElements();
}

void _markAllElements() {
  final Element? root = WidgetsBinding.instance.rootElement;
  if (root == null) {
    return;
  }
  void mark(Element element) {
    element.markNeedsBuild();
    element.visitChildren(mark);
  }

  mark(root);
}
