import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';

/// "Ścieżka odpowiedzi": through whom this person's question went and who
/// answered — names only, never the words. Folded until opened.
class AskPathView extends StatelessWidget {
  const AskPathView({required this.question, required this.nameOf, super.key});

  final Question question;
  final String Function(String address) nameOf;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ({List<AskPathBranch> branches, int quiet}) path = askPathOf(
      question,
    );
    final TextStyle line = TextStyle(
      color: zen.textPrimary,
      fontSize: 13.5,
      height: 1.35,
    );
    final TextStyle faint = TextStyle(color: zen.textMuted, fontSize: 12.5);
    String branchLine(AskPathBranch b) => <String>[
      nameOf(b.friend),
      if (b.answered) t('odpowiedź'),
      if (b.passedTo > 0)
        tn(
          b.passedTo,
          one: 'przekazał(a) {n} osobie',
          few: 'przekazał(a) {n} osobom',
          many: 'przekazał(a) {n} osobom',
        ),
    ].join(' · ');
    return ExpansionTile(
      key: Key('ask-path-${question.id}'),
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: 4, bottom: 6),
      leading: Icon(Icons.account_tree_rounded, color: zen.accent, size: 20),
      title: Text(
        t('Ścieżka odpowiedzi'),
        style: TextStyle(color: zen.textPrimary, fontSize: 14),
      ),
      subtitle: Text(
        t('Przez kogo poszło pytanie i kto odpowiedział — bez treści.'),
        style: faint,
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(t('Ty'), style: line.copyWith(fontWeight: FontWeight.w700)),
        for (final AskPathBranch b in path.branches)
          Padding(
            key: Key('ask-path-${question.id}-${b.friend}'),
            padding: const EdgeInsets.only(left: 12, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('└ ${branchLine(b)}', style: line),
                for (final String name in b.further)
                  Padding(
                    padding: const EdgeInsets.only(left: 16, top: 2),
                    child: Text(
                      '└ ${t('{name} · odpowiedź', {'name': name})}',
                      style: line.copyWith(color: zen.textSecondary),
                    ),
                  ),
              ],
            ),
          ),
        if (path.quiet > 0)
          Padding(
            padding: const EdgeInsets.only(left: 12, top: 6),
            child: Text(
              tn(
                path.quiet,
                one: 'i {n} znajomy jeszcze bez odpowiedzi',
                few: 'i {n} znajomych jeszcze bez odpowiedzi',
                many: 'i {n} znajomych jeszcze bez odpowiedzi',
              ),
              style: faint,
            ),
          ),
        if (path.branches.isEmpty && path.quiet == 0)
          ZenInfo(
            icon: Icons.hourglass_empty_rounded,
            tone: zen.textSecondary,
            text: t('Nikt jeszcze nie odpowiedział ani nie przekazał dalej.'),
          ),
      ],
    );
  }
}
