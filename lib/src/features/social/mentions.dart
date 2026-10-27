import 'package:flutter/foundation.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Mentions ("@Ada") in posts, comments and group chats.
//
// A mention is kept apart from the words: the text holds a token `<@N>` at
// the place of the name, N being the index into the list of the people
// mentioned (`men` next to the text: their address, their account when
// known and the name they had when the text was written). Whoever shows
// the text puts the person's current name in place of the token, so a
// later change of name breaks nothing, and the list says exactly whom the
// writer meant, whatever their name. A token whose index is not in the
// list is shown as written.

/// Most people one text mentions.
const int kMaxMentions = 20;

/// Key of the list of mentions next to a text (a post's or a comment's
/// body, a group message's payload).
const String kMentionsKey = 'men';

/// Longest name kept with a mention.
const int _maxMentionName = 60;

/// Longest address and account kept with a mention.
const int _maxMentionId = 128;

/// Longest word typed after "@" that still looks for someone.
const int _maxMentionQuery = 40;

/// The token standing for the [index]-th person of a text's mentions.
String mentionToken(int index) => '<@$index>';

/// A token in a text.
final RegExp mentionTokenPattern = RegExp(r'<@(\d{1,2})>');

/// One person a text mentions.
@immutable
final class Mention {
  const Mention({required this.address, this.account = '', this.name = ''});

  /// Their device address (where the notification about it goes).
  final String address;

  /// Their account, when the writer knew it ('' otherwise).
  final String account;

  /// Their name as the writer saw it (shown when this phone knows none).
  final String name;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'd': address,
    if (account.isNotEmpty) 'a': account,
    if (name.isNotEmpty) 'n': name,
  };

  /// The mention in [json], or `null` when it names nobody.
  static Mention? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? d = json['d'];
    final Object? a = json['a'];
    final Object? n = json['n'];
    final String address = d is String
        ? PeerShareCodec.normalizeAddress(d)
        : '';
    if (address.isEmpty || address.length > _maxMentionId) {
      return null;
    }
    final String name = n is String ? n.trim() : '';
    return Mention(
      address: address,
      account: a is String && a.length <= _maxMentionId ? a : '',
      name: name.length > _maxMentionName
          ? name.substring(0, _maxMentionName)
          : name,
    );
  }

  /// Whether this names the device at one of [addresses], or [account].
  bool names({Iterable<String> addresses = const <String>[], String? account}) {
    if (account != null &&
        account.isNotEmpty &&
        this.account.isNotEmpty &&
        this.account == account) {
      return true;
    }
    return addresses.any(
      (String a) => a.isNotEmpty && PeerShareCodec.addressesEqual(a, address),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Mention &&
      other.address == address &&
      other.account == account &&
      other.name == name;

  @override
  int get hashCode => Object.hash(address, account, name);
}

/// The mentions in [json] (a `men` list), at most [kMaxMentions].
List<Mention> mentionsFromJson(Object? json) => <Mention>[
  if (json is List)
    for (final Object? m in json.take(kMaxMentions)) ?Mention.fromJson(m),
];

List<Map<String, dynamic>> mentionsToJson(List<Mention> mentions) =>
    <Map<String, dynamic>>[
      for (final Mention m in mentions.take(kMaxMentions)) m.toJson(),
    ];

/// The mentions [text] really names (each once, in the order of the list).
List<Mention> usedMentions(String text, List<Mention> mentions) {
  final Set<int> used = <int>{
    for (final RegExpMatch m in mentionTokenPattern.allMatches(text))
      int.parse(m.group(1)!),
  };
  return <Mention>[
    for (int i = 0; i < mentions.length; i++)
      if (used.contains(i)) mentions[i],
  ];
}

/// Whether [text] with its [mentions] names the device at one of
/// [addresses] or [account] (a token in the text, not only the list).
bool mentionsAnyOf(
  String text,
  List<Mention> mentions, {
  Iterable<String> addresses = const <String>[],
  String? account,
}) => usedMentions(
  text,
  mentions,
).any((Mention m) => m.names(addresses: addresses, account: account));

/// [text] with "@name" in place of each token (previews, notifications,
/// copies). [nameOf] gives the name to show (this phone's name for the
/// person); the name kept with the mention otherwise.
String mentionsAsPlainText(
  String text,
  List<Mention> mentions, {
  String Function(Mention mention)? nameOf,
}) {
  if (mentions.isEmpty) {
    return text;
  }
  return text.replaceAllMapped(mentionTokenPattern, (Match m) {
    final int i = int.parse(m.group(1)!);
    if (i >= mentions.length) {
      return m.group(0)!;
    }
    return '@${mentionLabel(mentions[i], nameOf: nameOf)}';
  });
}

/// The name a mention shows (without the "@").
String mentionLabel(
  Mention mention, {
  String Function(Mention mention)? nameOf,
}) {
  final String known = nameOf?.call(mention).trim() ?? '';
  if (known.isNotEmpty) {
    return known;
  }
  return mention.name.isNotEmpty ? mention.name : '…';
}

// ---- writing ----------------------------------------------------------------

/// A mention in a text being written: "@Ada" from [start] to [end].
@immutable
final class MentionSpan {
  const MentionSpan({
    required this.start,
    required this.end,
    required this.mention,
  });

  final int start;
  final int end;
  final Mention mention;

  MentionSpan shifted(int by) =>
      MentionSpan(start: start + by, end: end + by, mention: mention);

  @override
  bool operator ==(Object other) =>
      other is MentionSpan &&
      other.start == start &&
      other.end == end &&
      other.mention == mention;

  @override
  int get hashCode => Object.hash(start, end, mention);
}

/// What is stored for [display] (the text as written, "@Ada" in it) with
/// its [spans]: the text with tokens and the list they point into. [keep]
/// is the list a stored text already had (an edit): its people keep their
/// places, new ones come after them. A mention past [kMaxMentions] stays
/// plain text.
({String text, List<Mention> mentions}) encodeMentions(
  String display,
  List<MentionSpan> spans, {
  List<Mention> keep = const <Mention>[],
}) {
  final List<Mention> list = <Mention>[...keep];
  final List<MentionSpan> sorted = <MentionSpan>[
    for (final MentionSpan s in spans)
      if (s.start >= 0 && s.end <= display.length && s.start < s.end) s,
  ]..sort((MentionSpan a, MentionSpan b) => a.start.compareTo(b.start));
  final StringBuffer out = StringBuffer();
  int at = 0;
  for (final MentionSpan s in sorted) {
    if (s.start < at) {
      continue; // overlaps the previous one
    }
    int index = list.indexWhere(
      (Mention m) =>
          PeerShareCodec.addressesEqual(m.address, s.mention.address),
    );
    if (index < 0) {
      if (list.length >= kMaxMentions) {
        continue;
      }
      list.add(s.mention);
      index = list.length - 1;
    }
    out
      ..write(display.substring(at, s.start))
      ..write(mentionToken(index));
    at = s.end;
  }
  out.write(display.substring(at));
  final String text = out.toString();
  // Only the people the text names travel with it (an edit may have
  // removed some; the kept ones stay where they were).
  final int last = <int>[
    -1,
    for (final RegExpMatch m in mentionTokenPattern.allMatches(text))
      int.parse(m.group(1)!),
  ].reduce((int a, int b) => a > b ? a : b);
  return (
    text: text,
    mentions: last < 0
        ? const <Mention>[]
        : list.sublist(0, last + 1 > list.length ? list.length : last + 1),
  );
}

/// The text as it is edited: "@name" in place of each token of [text],
/// and where each one is. [nameOf] as in [mentionsAsPlainText].
({String text, List<MentionSpan> spans}) decodeMentions(
  String text,
  List<Mention> mentions, {
  String Function(Mention mention)? nameOf,
}) {
  final StringBuffer out = StringBuffer();
  final List<MentionSpan> spans = <MentionSpan>[];
  int at = 0;
  for (final RegExpMatch m in mentionTokenPattern.allMatches(text)) {
    final int i = int.parse(m.group(1)!);
    if (i >= mentions.length) {
      continue;
    }
    out.write(text.substring(at, m.start));
    final String shown = '@${mentionLabel(mentions[i], nameOf: nameOf)}';
    final int start = out.length;
    out.write(shown);
    spans.add(MentionSpan(start: start, end: out.length, mention: mentions[i]));
    at = m.end;
  }
  out.write(text.substring(at));
  return (text: out.toString(), spans: spans);
}

/// [spans] of [before] as they are in [after] (one edit between them): the
/// ones before and after the change move along, a mention the change
/// touched becomes plain text.
List<MentionSpan> shiftMentionSpans(
  String before,
  String after,
  List<MentionSpan> spans,
) {
  if (spans.isEmpty || before == after) {
    return spans;
  }
  int prefix = 0;
  final int shorter = before.length < after.length
      ? before.length
      : after.length;
  while (prefix < shorter &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  int suffix = 0;
  while (suffix < shorter - prefix &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  final int changedEnd = before.length - suffix;
  final int delta = after.length - before.length;
  return <MentionSpan>[
    for (final MentionSpan s in spans)
      if (s.end <= prefix) s else if (s.start >= changedEnd) s.shifted(delta),
  ];
}

/// The word being typed after "@" at [cursor] in [text]: where the "@" is
/// and what follows it; `null` when the cursor is not in such a word.
({int start, String query})? mentionQueryAt(String text, int cursor) {
  if (cursor < 1 || cursor > text.length) {
    return null;
  }
  for (int i = cursor - 1; i >= 0 && cursor - i <= _maxMentionQuery + 1; i--) {
    final String c = text[i];
    if (c == '@') {
      final bool wordStart = i == 0 || _breaksWord(text[i - 1]);
      return wordStart
          ? (start: i, query: text.substring(i + 1, cursor))
          : null;
    }
    if (_breaksWord(c)) {
      return null;
    }
  }
  return null;
}

bool _breaksWord(String c) => c.trim().isEmpty || '([{"\'„«'.contains(c);

// ---- who can be mentioned ---------------------------------------------------

/// Why someone may be mentioned in a place (shown under their name in the
/// suggestions).
enum MentionReach {
  /// A member of the group chat.
  member,

  /// The author of the post.
  author,

  /// A friend of the writer.
  friend,

  /// A friend of one of the writer's friends (from the friend lists they
  /// share with the writer).
  friendOfFriend,

  /// Someone who commented on or liked the post.
  interacted,
}

/// One person the suggestions may offer.
@immutable
final class MentionCandidate {
  const MentionCandidate({required this.mention, required this.reach});

  final Mention mention;
  final MentionReach reach;
}

/// The members of [group] but this device ([selfAddress]): the only people
/// a group message may mention. [nameOf] gives a member's name.
List<MentionCandidate> groupMentionCandidates(
  GroupProfile group, {
  required String selfAddress,
  required String Function(String address) nameOf,
}) {
  final Set<String> seen = <String>{};
  return <MentionCandidate>[
    for (final String member in group.memberAddresses)
      if (!PeerShareCodec.addressesEqual(member, selfAddress) &&
          seen.add(PeerShareCodec.normalizeAddress(member)))
        MentionCandidate(
          mention: Mention(
            address: PeerShareCodec.normalizeAddress(member),
            name: nameOf(member),
          ),
          reach: MentionReach.member,
        ),
  ];
}

/// [name] in lower case without Polish diacritics, for matching.
String _folded(String name) {
  const String from = 'ąćęłńóśźż';
  const String to = 'acelnoszz';
  final StringBuffer out = StringBuffer();
  for (final String c in name.toLowerCase().split('')) {
    final int i = from.indexOf(c);
    out.write(i < 0 ? c : to[i]);
  }
  return out.toString();
}

/// Whether [name] fits [query] (typed after "@"): it or one of its words
/// begins with it, ignoring case and diacritics; everyone for an empty
/// query.
bool mentionNameMatches(String name, String query) {
  final String q = _folded(query.trim());
  if (q.isEmpty) {
    return true;
  }
  final String n = _folded(name.trim());
  return n.startsWith(q) ||
      n.split(RegExp(r'\s+')).any((String word) => word.startsWith(q));
}

/// The suggestions for [query] out of [candidates] (in their order, each
/// person once), at most [limit].
List<MentionCandidate> suggestMentions(
  List<MentionCandidate> candidates,
  String query, {
  int limit = 6,
}) {
  final Set<String> seen = <String>{};
  final List<MentionCandidate> out = <MentionCandidate>[];
  for (final MentionCandidate c in candidates) {
    if (out.length >= limit) {
      break;
    }
    if (c.mention.name.trim().isEmpty ||
        !mentionNameMatches(c.mention.name, query) ||
        !seen.add(PeerShareCodec.normalizeAddress(c.mention.address))) {
      continue;
    }
    out.add(c);
  }
  return out;
}
