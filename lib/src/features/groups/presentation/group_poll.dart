import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/messages/chat_poll.dart';

/// How long a new poll can stay open (null: until its author ends it).
const List<Duration?> kPollLengths = <Duration?>[
  null,
  Duration(hours: 1),
  Duration(days: 1),
  Duration(days: 7),
];

String _lengthLabel(Duration? length) => switch (length?.inHours) {
  null => t('Bez terminu'),
  1 => t('1 godzina'),
  24 => t('1 dzień'),
  _ => t('1 tydzień'),
};

/// Asks for a poll: a question, two to [kMaxPollOptions] answers and how
/// long it stays open; `null` when nothing was made.
Future<ChatPoll?> showPollComposer(BuildContext context) =>
    showDialog<ChatPoll>(
      context: context,
      builder: (BuildContext context) => const _PollComposer(),
    );

class _PollComposer extends StatefulWidget {
  const _PollComposer();

  @override
  State<_PollComposer> createState() => _PollComposerState();
}

class _PollComposerState extends State<_PollComposer> {
  final TextEditingController _question = TextEditingController();
  final List<TextEditingController> _options = <TextEditingController>[
    TextEditingController(),
    TextEditingController(),
  ];
  Duration? _length;

  @override
  void dispose() {
    _question.dispose();
    for (final TextEditingController c in _options) {
      c.dispose();
    }
    super.dispose();
  }

  ChatPoll? get _poll => ChatPoll.of(
    _question.text,
    _options.map((TextEditingController c) => c.text),
    closesAtMillis: _length == null
        ? null
        : DateTime.now().add(_length!).millisecondsSinceEpoch,
  );

  @override
  Widget build(BuildContext context) {
    final ChatPoll? poll = _poll;
    return AlertDialog(
      title: Text(t('Ankieta')),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const Key('poll-question'),
                controller: _question,
                autofocus: true,
                maxLength: kMaxPollQuestionChars,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('Pytanie'),
                  counterText: '',
                ),
                onChanged: (_) => setState(() {}),
              ),
              for (int i = 0; i < _options.length; i++)
                TextField(
                  key: Key('poll-option-$i'),
                  controller: _options[i],
                  maxLength: kMaxPollOptionChars,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: t('Odpowiedź {n}', <String, Object?>{
                      'n': i + 1,
                    }),
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              if (_options.length < kMaxPollOptions)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('poll-add-option'),
                    onPressed: () =>
                        setState(() => _options.add(TextEditingController())),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(t('Dodaj odpowiedź')),
                  ),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  t('Głosowanie trwa'),
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: <Widget>[
                  for (final Duration? length in kPollLengths)
                    ChoiceChip(
                      key: Key('poll-length-${length?.inHours ?? 0}'),
                      label: Text(_lengthLabel(length)),
                      selected: _length == length,
                      onSelected: (_) => setState(() => _length = length),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('poll-send'),
          onPressed: poll == null
              ? null
              : () => Navigator.of(context).pop(poll),
          child: Text(t('Wyślij')),
        ),
      ],
    );
  }
}

/// [millis] as a time, with the day when it is not today.
String _when(int millis, DateTime now) {
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(millis);
  final String clock = '${at.hour}:${at.minute.toString().padLeft(2, '0')}';
  return at.year == now.year && at.month == now.month && at.day == now.day
      ? clock
      : '${at.day}.${at.month.toString().padLeft(2, '0')} $clock';
}

/// A poll in a group chat: what leads (or won) at the top, each answer
/// with its votes; a tap votes for it, a tap on one's own answer takes the
/// vote back, while it is open. Its author can end it ([onEnd]).
class GroupPollCard extends StatelessWidget {
  const GroupPollCard({
    super.key,
    required this.poll,
    required this.reactions,
    required this.nameOf,
    required this.onVote,
    this.onEnd,
    this.nowMillis,
    this.onGradient = false,
  });

  final ChatPoll poll;

  /// The message's reactions: the votes among them.
  final Map<String, String> reactions;
  final String Function(String who) nameOf;

  /// Votes for answer i (the same answer again takes the vote back).
  final void Function(int answer) onVote;

  /// Ends the poll for everyone: given on one's own poll.
  final VoidCallback? onEnd;

  /// The time it is looked at (now when null).
  final int? nowMillis;

  /// Drawn on one's own (accent) bubble.
  final bool onGradient;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color text = onGradient ? zen.onAccent : zen.textPrimary;
    final Color muted = onGradient
        ? zen.onAccent.withValues(alpha: 0.78)
        : zen.textMuted;
    final List<List<String>> voters = poll.votersIn(reactions);
    final int total = voters.fold(
      0,
      (int sum, List<String> v) => sum + v.length,
    );
    final int? mine = poll.answerOf(reactions['self'] ?? '');
    final DateTime now = nowMillis == null
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(nowMillis!);
    final bool closed = poll.isClosedAt(now.millisecondsSinceEpoch);
    final List<int> leading = poll.leading(voters);
    final String answers = leading.map((int i) => poll.options[i]).join(', ');
    final String? summary = leading.isEmpty
        ? (closed ? t('Nikt nie zagłosował.') : null)
        : leading.length > 1
        ? t('Remis: {answers}', <String, Object?>{'answers': answers})
        : closed
        ? t('Wynik: {answer}', <String, Object?>{'answer': answers})
        : t('Prowadzi: {answer}', <String, Object?>{'answer': answers});
    final int? deadline = poll.closesAtMillis;
    return Column(
      key: const Key('group-poll'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Icon(Icons.poll_outlined, size: 18, color: muted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                poll.question,
                style: TextStyle(
                  color: text,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        if (summary != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              summary,
              key: const Key('group-poll-summary'),
              style: TextStyle(
                color: text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (closed || deadline != null)
          Text(
            closed
                ? t('Ankieta zakończona')
                : t('Głosowanie do {time}', <String, Object?>{
                    'time': _when(deadline!, now),
                  }),
            key: const Key('group-poll-state'),
            style: TextStyle(color: muted, fontSize: 12),
          ),
        const SizedBox(height: 6),
        for (int i = 0; i < poll.options.length; i++)
          InkWell(
            key: Key('group-poll-option-$i'),
            borderRadius: BorderRadius.circular(8),
            onTap: closed ? null : () => onVote(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(
                        mine == i
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 18,
                        color: mine == i ? text : muted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          poll.options[i],
                          style: TextStyle(
                            color: text,
                            fontSize: 14,
                            fontWeight: closed && leading.contains(i)
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                      ),
                      Text(
                        '${voters[i].length}',
                        style: TextStyle(
                          color: muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: total == 0 ? 0 : voters[i].length / total,
                      minHeight: 5,
                      color: onGradient ? zen.onAccent : zen.accent,
                      backgroundColor: muted.withValues(alpha: 0.2),
                    ),
                  ),
                  if (voters[i].isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        voters[i].map(nameOf).join(', '),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: muted, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ),
        Text(
          tn(total, one: '{n} głos', few: '{n} głosy', many: '{n} głosów'),
          key: const Key('group-poll-total'),
          style: TextStyle(color: muted, fontSize: 11),
        ),
        if (onEnd != null && !closed)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('group-poll-end'),
              style: TextButton.styleFrom(
                foregroundColor: text,
                visualDensity: VisualDensity.compact,
              ),
              onPressed: onEnd,
              icon: const Icon(Icons.how_to_vote_outlined, size: 18),
              label: Text(t('Zakończ ankietę')),
            ),
          ),
      ],
    );
  }
}

/// [reactions] without the votes of [poll] (shown in the poll itself).
Map<String, String> reactionsBesidePoll(
  ChatPoll? poll,
  Map<String, String> reactions,
) => poll == null
    ? reactions
    : <String, String>{
        for (final MapEntry<String, String> e in reactions.entries)
          if (poll.answerOf(e.value) == null) e.key: e.value,
      };
