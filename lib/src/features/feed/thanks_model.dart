import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// Entry kind of a gratitude card ("karta wdzięczności", §9) in the giver's
/// `acts/<account>` space: a signed "dziękuję" with a short reason.
const String kThanksKind = 'thanks';

/// Cards one person may give another within [kThanksWindow]. More are
/// ignored by everyone, so a reputation cannot be pumped up.
const int kThanksPerWindow = 3;
const Duration kThanksWindow = Duration(days: 30);
const int kMaxThanksChars = 200;

@immutable
final class ThanksCard {
  const ThanksCard({
    required this.id,
    required this.fromAccount,
    required this.fromLabel,
    required this.toAccount,
    required this.text,
    required this.millis,
  });

  final String id;
  final String fromAccount;
  final String fromLabel;
  final String toAccount;
  final String text;
  final int millis;
}

/// Body of a card for [toAccount] (validated, trimmed).
Map<String, dynamic> thanksBody(String toAccount, String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError(t('Napisz, za co dziękujesz.'));
  }
  if (trimmed.length > kMaxThanksChars) {
    throw ArgumentError(
      tn(
        kMaxThanksChars,
        one: 'Za długie (maks. {n} znak).',
        few: 'Za długie (maks. {n} znaki).',
        many: 'Za długie (maks. {n} znaków).',
      ),
    );
  }
  return <String, dynamic>{'to': toAccount, 'text': trimmed};
}

/// Valid cards in one giver's acts, oldest first: at most
/// [kThanksPerWindow] per recipient in any [kThanksWindow], never to self.
List<ThanksCard> _cardsOf(Iterable<LogEntry> acts, String fromLabel) {
  final List<LogEntry> raw =
      acts.where((LogEntry e) => e.kind == kThanksKind).toList()
        ..sort((LogEntry a, LogEntry b) => a.hlc.compareTo(b.hlc));
  final Map<String, List<int>> given = <String, List<int>>{};
  final List<ThanksCard> cards = <ThanksCard>[];
  for (final LogEntry e in raw) {
    final Object? to = e.body['to'];
    final Object? text = e.body['text'];
    if (to is! String ||
        to == e.account ||
        text is! String ||
        text.trim().isEmpty) {
      continue;
    }
    final int at = e.hlc.millis;
    final List<int> times = given[to] ??= <int>[];
    final int recent = times
        .where((int t) => at - t < kThanksWindow.inMilliseconds)
        .length;
    if (recent >= kThanksPerWindow) {
      continue;
    }
    times.add(at);
    cards.add(
      ThanksCard(
        id: e.id,
        fromAccount: e.account,
        fromLabel: fromLabel,
        toAccount: to,
        text: text.length > kMaxThanksChars
            ? text.substring(0, kMaxThanksChars)
            : text,
        millis: at,
      ),
    );
  }
  return cards;
}

/// Cards for [toAccount] that this device can see (its own and friends'),
/// newest first. [nameOf] turns a friend's address into a display name.
List<ThanksCard> thanksFor(
  LedgerNode node,
  String toAccount, {
  required String Function(String address) nameOf,
}) {
  final List<ThanksCard> cards = <ThanksCard>[
    ..._cardsOf(node.entriesOf(spaceKind: 'acts'), t('Ty')),
  ];
  final Set<String> seen = <String>{node.account};
  node.friendAccounts.forEach((String address, String account) {
    if (seen.add(account)) {
      cards.addAll(
        _cardsOf(
          node.entriesOf(spaceKind: 'acts', ofAccount: account),
          nameOf(address),
        ),
      );
    }
  });
  return cards.where((ThanksCard c) => c.toAccount == toAccount).toList()
    ..sort((ThanksCard a, ThanksCard b) => b.millis.compareTo(a.millis));
}

/// How many more cards this account may give [toAccount] right now.
int thanksLeft(LedgerNode node, String toAccount, {required int nowMillis}) {
  final int recent = _cardsOf(node.entriesOf(spaceKind: 'acts'), 'Ty')
      .where(
        (ThanksCard c) =>
            c.toAccount == toAccount &&
            nowMillis - c.millis < kThanksWindow.inMilliseconds,
      )
      .length;
  return (kThanksPerWindow - recent).clamp(0, kThanksPerWindow);
}
