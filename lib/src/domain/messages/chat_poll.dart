import 'package:flutter/foundation.dart';

/// Where a message carries its poll (on the wire and in storage).
const String kPollKey = 'poll';

/// The most answers a poll offers (as many as there are keycap numbers).
const int kMaxPollOptions = 10;

/// The longest question.
const int kMaxPollQuestionChars = 300;

/// The longest answer.
const int kMaxPollOptionChars = 100;

/// The keycap numbers 1️⃣ … 9️⃣, 🔟: a vote for answer n is the reaction
/// `kPollVotes[n]`, so a vote travels, syncs and changes the way any
/// reaction does (one per person), and a Zen without polls shows the poll
/// as its text with the numbers and the votes as these reactions.
const List<String> kPollVotes = <String>[
  '1\u{FE0F}\u{20E3}',
  '2\u{FE0F}\u{20E3}',
  '3\u{FE0F}\u{20E3}',
  '4\u{FE0F}\u{20E3}',
  '5\u{FE0F}\u{20E3}',
  '6\u{FE0F}\u{20E3}',
  '7\u{FE0F}\u{20E3}',
  '8\u{FE0F}\u{20E3}',
  '9\u{FE0F}\u{20E3}',
  '\u{1F51F}',
];

/// The longest a poll can be set to stay open.
const Duration kMaxPollOpen = Duration(days: 30);

/// A poll in a group: a question and its answers, one vote per person;
/// open until [closesAtMillis] (when one was set) or until its author ends
/// it ([closedAtMillis]). Votes cast after that do not count.
@immutable
final class ChatPoll {
  const ChatPoll({
    required this.question,
    required this.options,
    this.closesAtMillis,
    this.closedAtMillis,
  });

  final String question;
  final List<String> options;

  /// Set when the poll was made: it closes by itself then.
  final int? closesAtMillis;

  /// When its author ended it (before [closesAtMillis]).
  final int? closedAtMillis;

  /// Since when it is closed, or `null` while it is open at [nowMillis].
  int? closedSince(int nowMillis) {
    final int? deadline = closesAtMillis;
    final int? ended = closedAtMillis;
    if (ended != null && (deadline == null || ended <= deadline)) {
      return ended;
    }
    return deadline != null && nowMillis >= deadline ? deadline : null;
  }

  /// No more votes count at [nowMillis].
  bool isClosedAt(int nowMillis) => closedSince(nowMillis) != null;

  /// This poll ended by its author at [atMillis] (an ended one stays as it
  /// was).
  ChatPoll endedAt(int atMillis) => closedAtMillis != null
      ? this
      : ChatPoll(
          question: question,
          options: options,
          closesAtMillis: closesAtMillis,
          closedAtMillis: atMillis,
        );

  /// What its author's ending, arrived as [json] (in an edit of the
  /// poll's message) at [receivedAtMillis], makes of this poll; `null` when
  /// it is no ending of this poll (another poll, one not ended) or this one
  /// already ended. An ending claimed later than its arrival counts as
  /// ended on arrival.
  ChatPoll? endingOf(Object? json, {required int receivedAtMillis}) {
    final ChatPoll? sent = fromJson(json);
    final int? at = sent?.closedAtMillis;
    if (sent == null ||
        at == null ||
        closedAtMillis != null ||
        !isSamePollAs(sent)) {
      return null;
    }
    return endedAt(at > receivedAtMillis ? receivedAtMillis : at);
  }

  /// The same poll: question, answers and time limit (whether ended or not).
  bool isSamePollAs(ChatPoll other) =>
      other.question == question &&
      listEquals(other.options, options) &&
      other.closesAtMillis == closesAtMillis;

  /// The answers with the most votes among [voters] (several on a tie);
  /// empty when nobody voted.
  List<int> leading(List<List<String>> voters) {
    int most = 0;
    for (final List<String> v in voters) {
      most = v.length > most ? v.length : most;
    }
    return most == 0
        ? const <int>[]
        : <int>[
            for (int i = 0; i < voters.length; i++)
              if (voters[i].length == most) i,
          ];
  }

  /// The poll made of what was typed: trimmed, empty answers and repeats
  /// left out; `null` without a question or with fewer than two answers.
  static ChatPoll? of(
    String question,
    Iterable<String> options, {
    int? closesAtMillis,
  }) {
    final String q = question.trim();
    final List<String> answers = <String>[];
    for (final String raw in options) {
      final String o = raw.trim();
      if (o.isNotEmpty &&
          o.length <= kMaxPollOptionChars &&
          !answers.contains(o)) {
        answers.add(o);
      }
    }
    if (q.isEmpty ||
        q.length > kMaxPollQuestionChars ||
        answers.length < 2 ||
        answers.length > kMaxPollOptions) {
      return null;
    }
    return ChatPoll(
      question: q,
      options: List<String>.unmodifiable(answers),
      closesAtMillis: closesAtMillis,
    );
  }

  /// The poll as text: the question and the numbered answers (the message's
  /// text, what a Zen without polls shows, previews and notifications).
  String get asText => <String>[
    question,
    for (int i = 0; i < options.length; i++) '${kPollVotes[i]} ${options[i]}',
  ].join('\n');

  Map<String, dynamic> toJson() => <String, dynamic>{
    'q': question,
    'o': options,
    'd': ?closesAtMillis,
    'c': ?closedAtMillis,
  };

  static ChatPoll? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? q = json['q'];
    final Object? o = json['o'];
    if (q is! String || o is! List || o.length > kMaxPollOptions) {
      return null;
    }
    final List<String> options = o.whereType<String>().toList();
    if (options.length != o.length) {
      return null;
    }
    final Object? d = json['d'];
    final Object? c = json['c'];
    if ((d != null && (d is! int || d <= 0)) ||
        (c != null && (c is! int || c <= 0))) {
      return null;
    }
    final ChatPoll? poll = ChatPoll.of(q, options, closesAtMillis: d as int?);
    // Exactly what was sent, or nothing: the numbers must point at the
    // same answers for everyone.
    return poll != null && listEquals(poll.options, options)
        ? (c == null ? poll : poll.endedAt(c as int))
        : null;
  }

  /// Which answer [reaction] votes for; `null` when it is no vote here.
  int? answerOf(String reaction) {
    final int i = kPollVotes.indexOf(reaction);
    return i >= 0 && i < options.length ? i : null;
  }

  /// Who voted for each answer, from a message's reactions.
  List<List<String>> votersIn(Map<String, String> reactions) {
    final List<List<String>> voters = <List<String>>[
      for (int i = 0; i < options.length; i++) <String>[],
    ];
    reactions.forEach((String who, String reaction) {
      final int? i = answerOf(reaction);
      if (i != null) {
        voters[i].add(who);
      }
    });
    return voters;
  }

  @override
  bool operator ==(Object other) =>
      other is ChatPoll &&
      isSamePollAs(other) &&
      other.closedAtMillis == closedAtMillis;

  @override
  int get hashCode => Object.hash(
    question,
    Object.hashAll(options),
    closesAtMillis,
    closedAtMillis,
  );
}
