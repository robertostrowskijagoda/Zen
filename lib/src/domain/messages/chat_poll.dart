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

/// A poll in a group: a question and its answers, one vote per person.
@immutable
final class ChatPoll {
  const ChatPoll({required this.question, required this.options});

  final String question;
  final List<String> options;

  /// The poll made of what was typed: trimmed, empty answers and repeats
  /// left out; `null` without a question or with fewer than two answers.
  static ChatPoll? of(String question, Iterable<String> options) {
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
    return ChatPoll(question: q, options: List<String>.unmodifiable(answers));
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
    final ChatPoll? poll = ChatPoll.of(q, options);
    // Exactly what was sent, or nothing: the numbers must point at the
    // same answers for everyone.
    return poll != null && listEquals(poll.options, options) ? poll : null;
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
      other.question == question &&
      listEquals(other.options, options);

  @override
  int get hashCode => Object.hash(question, Object.hashAll(options));
}
