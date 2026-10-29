import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/profile/presentation/mini_profile.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/search/presentation/search_highlight.dart';
import 'package:zen/src/features/search/search_text.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// Writing and showing mentions (`mentions.dart`): a text field that knows
// where its "@Ada" are, the list of people under it while a name is typed
// after "@", and a text that shows each mention as a tappable name.

/// The name this phone knows for the mentioned person (a friend's name,
/// the name from their profile), '' when it knows none.
String knownMentionName(SocialHubState state, Mention mention) {
  final FriendProfile? friend = state.friendByAddress(mention.address);
  if (friend != null) {
    return state.nameFor(friend);
  }
  return state.peerProfileOf(mention.address)?.name.trim() ?? '';
}

/// A text field's controller that keeps track of the mentions in its text:
/// they move with the edits around them, and one edited inside becomes
/// plain text.
mixin MentionEditing on TextEditingController {
  List<MentionSpan> _mentionSpans = const <MentionSpan>[];

  /// Where the mentions are in [text].
  List<MentionSpan> get mentionSpans => _mentionSpans;

  @override
  set value(TextEditingValue newValue) {
    _mentionSpans = shiftMentionSpans(
      super.value.text,
      newValue.text,
      _mentionSpans,
    );
    super.value = newValue;
  }

  /// The name being typed after "@" at the cursor, or `null`.
  ({int start, String query})? get mentionQuery {
    final TextSelection sel = selection;
    if (!sel.isValid || !sel.isCollapsed) {
      return null;
    }
    final ({int start, String query})? q = mentionQueryAt(text, sel.baseOffset);
    if (q == null ||
        _mentionSpans.any(
          (MentionSpan s) => q.start >= s.start && q.start < s.end,
        )) {
      return null;
    }
    return q;
  }

  /// Puts [who] in place of the name being typed after "@".
  void insertMention(Mention who) {
    final ({int start, String query})? q = mentionQuery;
    if (q == null) {
      return;
    }
    final String shown = '@${who.name}';
    final int end = selection.baseOffset;
    value = TextEditingValue(
      text: text.replaceRange(q.start, end, '$shown '),
      selection: TextSelection.collapsed(offset: q.start + shown.length + 1),
    );
    _mentionSpans = <MentionSpan>[
      ..._mentionSpans,
      MentionSpan(start: q.start, end: q.start + shown.length, mention: who),
    ];
    notifyListeners();
  }

  /// Fills the field with a stored [stored] text and its [mentions] (an
  /// edit), "@name" in place of each token.
  void setStoredText(
    String stored,
    List<Mention> mentions, {
    String Function(Mention mention)? nameOf,
  }) {
    final ({String text, List<MentionSpan> spans}) d = decodeMentions(
      stored,
      mentions,
      nameOf: nameOf,
    );
    value = TextEditingValue(
      text: d.text,
      selection: TextSelection.collapsed(offset: d.text.length),
    );
    _mentionSpans = d.spans;
    notifyListeners();
  }

  /// Replaces the mentions' places (a text put together from pieces).
  set mentionSpans(List<MentionSpan> spans) {
    _mentionSpans = List<MentionSpan>.unmodifiable(spans);
    notifyListeners();
  }

  /// What is stored for the text: tokens and the list ([encodeMentions]).
  ({String text, List<Mention> mentions}) storedText({
    List<Mention> keep = const <Mention>[],
  }) => encodeMentions(text, _mentionSpans, keep: keep);

  /// [built] (the field's text as styled) with the mentions in [look].
  TextSpan withMentionLook(
    TextSpan built,
    TextStyle Function(TextStyle style) look,
  ) => highlightRanges(built, <(int, int)>[
    for (final MentionSpan s in _mentionSpans) (s.start, s.end),
  ], look);
}

/// A plain text field's controller with mentions ([MentionEditing]),
/// shown in the accent colour.
class MentionTextController extends TextEditingController with MentionEditing {
  MentionTextController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final TextSpan built = super.buildTextSpan(
      context: context,
      style: style,
      withComposing: withComposing,
    );
    if (mentionSpans.isEmpty) {
      return built;
    }
    final ZenColors zen = ZenColors.of(context);
    return withMentionLook(
      built,
      (TextStyle s) => s.copyWith(
        color: zen.accent,
        fontWeight: FontWeight.w700,
        decoration: TextDecoration.underline,
        decorationColor: zen.accent,
      ),
    );
  }
}

/// [root] with the characters of [ranges] (start, end) in [look]: the
/// pieces of text are split at the ranges' edges. Nested pieces take what
/// they inherit with them.
TextSpan highlightRanges(
  TextSpan root,
  List<(int, int)> ranges,
  TextStyle Function(TextStyle style) look,
) {
  if (ranges.isEmpty) {
    return root;
  }
  final List<(String, TextStyle?)> leaves = <(String, TextStyle?)>[];
  void walk(InlineSpan span, TextStyle? inherited, {bool top = false}) {
    if (span is! TextSpan) {
      return;
    }
    final TextStyle? own = top
        ? null
        : (inherited == null ? span.style : inherited.merge(span.style));
    final String? text = span.text;
    if (text != null && text.isNotEmpty) {
      leaves.add((text, own));
    }
    for (final InlineSpan child in span.children ?? const <InlineSpan>[]) {
      walk(child, own);
    }
  }

  walk(root, null, top: true);
  bool inRange(int at) => ranges.any(((int, int) r) => at >= r.$1 && at < r.$2);
  final Set<int> cuts = <int>{
    for (final (int, int) r in ranges) ...<int>[r.$1, r.$2],
  };
  final List<InlineSpan> out = <InlineSpan>[];
  int offset = 0;
  for (final (String, TextStyle?) leaf in leaves) {
    final String text = leaf.$1;
    int from = 0;
    for (int i = 1; i <= text.length; i++) {
      if (i == text.length || cuts.contains(offset + i)) {
        final String piece = text.substring(from, i);
        final TextStyle base = leaf.$2 ?? const TextStyle();
        out.add(
          TextSpan(
            text: piece,
            style: inRange(offset + from) ? look(base) : leaf.$2,
          ),
        );
        from = i;
      }
    }
    offset += text.length;
  }
  return TextSpan(style: root.style, children: out);
}

/// The people offered while a name is typed after "@" in the field of
/// [controller]: only [candidates] (who may be mentioned there), filtered
/// by what follows the "@". A tap puts the person in. Nothing shows while
/// no name is being typed.
class MentionSuggestions extends StatefulWidget {
  const MentionSuggestions({
    required this.controller,
    required this.candidates,
    this.maxHeight = 220,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final MentionEditing controller;

  /// Around the list, while it shows.
  final EdgeInsetsGeometry padding;

  /// Who may be mentioned (asked when a list is about to show).
  final List<MentionCandidate> Function() candidates;
  final double maxHeight;

  @override
  State<MentionSuggestions> createState() => _MentionSuggestionsState();
}

class _MentionSuggestionsState extends State<MentionSuggestions> {
  /// Whether the list was on screen at the last build.
  bool _wasShown = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(MentionSuggestions old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  static String? _reachLabel(MentionReach reach) => switch (reach) {
    MentionReach.member => null,
    MentionReach.author => t('Autor posta'),
    MentionReach.friend => t('Znajomy'),
    MentionReach.friendOfFriend => t('Znajomy znajomego'),
    MentionReach.interacted => t('Reagował(a) na ten post'),
  };

  @override
  Widget build(BuildContext context) {
    final ({int start, String query})? q = widget.controller.mentionQuery;
    if (q == null) {
      _wasShown = false;
      return const SizedBox.shrink();
    }
    final List<MentionCandidate> shown = suggestMentions(
      widget.candidates(),
      q.query,
    );
    final ZenColors zen = ZenColors.of(context);
    if (shown.isEmpty) {
      _wasShown = false;
      // A name was started and nobody matches it: say so instead of
      // leaving the "@" with no answer.
      if (q.query.isEmpty) {
        return const SizedBox.shrink();
      }
      return Padding(
        padding: widget.padding,
        child: Text(
          t('Brak pasujących osób'),
          key: const Key('mention-suggestions-empty'),
          style: TextStyle(color: zen.textMuted, fontSize: 13),
        ),
      );
    }
    if (!_wasShown) {
      // The list came up: keep it in view above the keyboard.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            Scrollable.ensureVisible(
              context,
              duration: const Duration(milliseconds: 150),
            ),
          );
        }
      });
    }
    _wasShown = true;
    return Padding(
      padding: widget.padding,
      child: ConstrainedBox(
        key: const Key('mention-suggestions'),
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: Material(
          color: zen.surfaceRaised,
          borderRadius: context.zenRadius(16),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: <Widget>[
              for (final MentionCandidate c in shown)
                ListTile(
                  key: Key('mention-suggestion-${c.mention.address}'),
                  dense: true,
                  leading: PeerAvatar(
                    address: c.mention.address,
                    name: c.mention.name,
                    size: 32,
                    showStatus: false,
                  ),
                  title: Text(
                    c.mention.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: switch (_reachLabel(c.reach)) {
                    final String label => Text(label),
                    null => null,
                  },
                  onTap: () => widget.controller.insertMention(c.mention),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A text with mentions (tokens of [mentions] in [text]): each one shown
/// as "@name" (this phone's name for the person when it has one), in the
/// accent colour, opening the person's mini-profile on a tap.
/// [mentionColor] replaces the accent (text on an accent bubble).
class MentionText extends ConsumerStatefulWidget {
  const MentionText(
    this.text, {
    required this.mentions,
    required this.style,
    this.mentionColor,
    super.key,
  });

  final String text;
  final List<Mention> mentions;
  final TextStyle style;
  final Color? mentionColor;

  @override
  ConsumerState<MentionText> createState() => _MentionTextState();
}

class _MentionTextState extends ConsumerState<MentionText> {
  final List<TapGestureRecognizer> _taps = <TapGestureRecognizer>[];

  void _clear() {
    for (final TapGestureRecognizer r in _taps) {
      r.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final ZenColors zen = ZenColors.of(context);
    final SocialHubState social = ref.watch(socialHubControllerProvider);
    // A search found this text: its words are marked (in the text between
    // the names).
    final SearchQuery? searched = SearchHighlight.maybeOf(context);
    final List<InlineSpan> spans = <InlineSpan>[];
    void plain(String part) {
      if (searched == null) {
        spans.add(TextSpan(text: part));
      } else {
        spans.addAll(searchMarked(context, part, searched));
      }
    }

    int at = 0;
    for (final RegExpMatch m in mentionTokenPattern.allMatches(widget.text)) {
      final int i = int.parse(m.group(1)!);
      if (i >= widget.mentions.length) {
        continue;
      }
      if (m.start > at) {
        plain(widget.text.substring(at, m.start));
      }
      final Mention who = widget.mentions[i];
      final TapGestureRecognizer tap = TapGestureRecognizer()
        ..onTap = () => unawaited(showMiniProfile(context, who.address));
      _taps.add(tap);
      spans.add(
        TextSpan(
          text:
              '@${mentionLabel(who, nameOf: (Mention m) => knownMentionName(social, m))}',
          recognizer: tap,
          style: TextStyle(
            color: widget.mentionColor ?? zen.accent,
            fontWeight: FontWeight.w700,
            // Not by colour alone.
            decoration: TextDecoration.underline,
            decorationColor: widget.mentionColor ?? zen.accent,
          ),
        ),
      );
      at = m.end;
    }
    if (at < widget.text.length) {
      plain(widget.text.substring(at));
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
