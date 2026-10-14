import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/pyramid/presentation/wallet_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Addresses of the members of this person's pyramid (empty outside one),
/// e.g. to tell whether a friend may also set a price on the market (§24).
Set<String> pyramidFriendAddresses(PyramidService pyr) {
  if (!pyr.isMember) {
    return const <String>{};
  }
  final PyramidState? s = pyr.state;
  if (s == null) {
    return const <String>{};
  }
  return <String>{
    for (final PyrMember m in s.members.values)
      if (m.active && m.addr.isNotEmpty)
        PeerShareCodec.normalizeAddress(m.addr),
  };
}

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Requests waiting for this person (§24.1): friend lists, introductions
/// to pass on, introductions and letters for them. Nothing when empty.
class IntroInboxSection extends ConsumerWidget {
  const IntroInboxSection({this.padding = EdgeInsets.zero, super.key});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final IntroService intro = ref.watch(introServiceProvider);
    return ListenableBuilder(
      listenable: intro,
      builder: (BuildContext context, Widget? _) {
        final List<IntroCase> open = intro.needsMe;
        if (open.isEmpty) {
          return const SizedBox.shrink();
        }
        final ZenColors zen = ZenColors.of(context);
        return Padding(
          key: const Key('intro-inbox'),
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 0, 4),
                child: Text(
                  'Prośby o kontakt (${open.length})',
                  style: zen.label(color: zen.accent),
                ),
              ),
              for (final IntroCase c in open) _IntroCard(intro: intro, item: c),
            ],
          ),
        );
      },
    );
  }
}

class _IntroCard extends StatelessWidget {
  const _IntroCard({required this.intro, required this.item});

  final IntroService intro;
  final IntroCase item;

  Future<void> _run(
    BuildContext context,
    Future<bool> Function() action,
    String done,
  ) async {
    bool ok = false;
    try {
      ok = await action();
    } on Object {
      ok = false;
    }
    if (context.mounted) {
      _snack(context, ok ? done : 'Nie udało się. Spróbuj jeszcze raz.');
    }
  }

  Future<void> _forward(BuildContext context) async {
    final String target = intro.host.nameOf(item.target);
    final String? note = await _forwardNote(context, target);
    if (note == null || !context.mounted) {
      return;
    }
    await _run(
      context,
      () => intro.forward(item.id, note: note),
      'Przekazano do: $target.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final IntroCase c = item;
    final bool middle = c.role == IntroRole.middle;
    final String x = middle ? intro.host.nameOf(c.asker) : c.askerName;
    final String via = intro.host.nameOf(c.middle);
    final (IconData icon, String title, String sub) = switch ((
      c.role,
      c.kind,
    )) {
      (IntroRole.middle, IntroKind.list) => (
        Icons.visibility_rounded,
        '$x prosi o Twoją listę znajomych',
        'Zobaczy, kogo znasz. Zgodę możesz cofnąć w Grafie.',
      ),
      (IntroRole.middle, _) => (
        Icons.waving_hand_rounded,
        '$x prosi o przedstawienie',
        'Komu: ${intro.host.nameOf(c.target)}',
      ),
      (_, IntroKind.letter) => (
        Icons.mail_outline_rounded,
        'List od: $x',
        'Przez: $via. Możesz zaprosić do znajomych albo zignorować.',
      ),
      _ => (
        Icons.waving_hand_rounded,
        '$via przedstawia Ci: $x',
        'Zdecyduj, czy chcesz się poznać.',
      ),
    };
    final TextStyle quote = TextStyle(
      color: zen.textPrimary,
      fontSize: 14.5,
      height: 1.4,
    );
    return ZenCard(
      key: Key('intro-card-${c.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ZenIconBadge(icon: icon, tone: zenTone(zen, 2), size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sub,
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (c.note.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text('„${c.note}” — $via', style: quote),
          ],
          if (c.text.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              c.kind == IntroKind.letter ? c.text : '„${c.text}” — $x',
              style: quote,
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (middle && c.kind == IntroKind.list)
                FilledButton.icon(
                  key: Key('intro-approve-${c.id}'),
                  onPressed: () => unawaited(
                    _run(
                      context,
                      () => intro.approveList(c.id),
                      'Pokazano listę: $x.',
                    ),
                  ),
                  icon: const Icon(Icons.visibility_rounded, size: 18),
                  label: const Text('Pokaż listę'),
                )
              else if (middle)
                FilledButton.icon(
                  key: Key('intro-forward-${c.id}'),
                  onPressed: () => unawaited(_forward(context)),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Przekaż'),
                )
              else
                FilledButton.icon(
                  key: Key('intro-accept-${c.id}'),
                  onPressed: () => unawaited(
                    _run(
                      context,
                      () => intro.accept(c.id),
                      'Wysłano zaproszenie do znajomych.',
                    ),
                  ),
                  icon: const Icon(Icons.person_add_rounded, size: 18),
                  label: Text(
                    c.kind == IntroKind.letter
                        ? 'Zaproś do znajomych'
                        : 'Poznajmy się',
                  ),
                ),
              if (middle)
                OutlinedButton(
                  key: Key('intro-decline-${c.id}'),
                  onPressed: () => unawaited(
                    _run(context, () => intro.decline(c.id), 'Odmówiono.'),
                  ),
                  child: const Text('Odmów'),
                )
              else
                OutlinedButton(
                  key: Key('intro-refuse-${c.id}'),
                  onPressed: () => unawaited(
                    _run(context, () => intro.refuse(c.id), 'Gotowe.'),
                  ),
                  child: Text(
                    c.kind == IntroKind.letter ? 'Zignoruj' : 'Nie, dziękuję',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// This person's own words when passing an introduction on; `null` when
/// they changed their mind.
Future<String?> _forwardNote(BuildContext context, String target) async {
  final TextEditingController note = TextEditingController();
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text('Przekaż do: $target'),
      content: TextField(
        key: const Key('intro-forward-note'),
        controller: note,
        autofocus: true,
        minLines: 2,
        maxLines: 4,
        maxLength: kIntroNoteMaxChars,
        textCapitalization: TextCapitalization.sentences,
        decoration: const InputDecoration(
          labelText: 'Twoje słowo (nieobowiązkowe)',
          hintText: 'Skąd się znacie, dlaczego warto…',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          key: const Key('intro-forward-send'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Przekaż'),
        ),
      ],
    ),
  );
  final String text = note.text;
  disposeLater(note);
  return ok == true ? text : null;
}

String _askedTitle(IntroService intro, IntroCase c) => switch (c.kind) {
  IntroKind.intro => 'Przedstawienie: ${c.targetName}',
  IntroKind.letter => 'List do: ${c.targetName}',
  IntroKind.list => 'Lista znajomych: ${intro.host.nameOf(c.middle)}',
};

String _askedStatus(IntroService intro, IntroCase c) {
  final String via = intro.host.nameOf(c.middle);
  return switch (c.kind) {
    IntroKind.list => switch (c.status) {
      IntroStatus.open || IntroStatus.forwarded => 'Czeka na zgodę: $via',
      IntroStatus.accepted => 'Widzisz tę listę',
      IntroStatus.declined || IntroStatus.refused => 'Bez zgody',
    },
    IntroKind.intro => switch (c.status) {
      IntroStatus.open => 'Czeka na: $via',
      IntroStatus.forwarded =>
        'Przekazane przez: $via. Decyduje: ${c.targetName}',
      IntroStatus.accepted => 'Przyjęte — zaproszenie do znajomych wysłane',
      IntroStatus.declined => 'Nie przekazane przez: $via',
      IntroStatus.refused => 'Bez odpowiedzi',
    },
    IntroKind.letter => switch (c.status) {
      IntroStatus.open => 'Wysłany do: $via',
      IntroStatus.forwarded => 'Przekazany przez: $via',
      IntroStatus.accepted => 'Odpowiedź: zaproszenie do znajomych',
      IntroStatus.declined => 'Nie poszedł (przez: $via)',
      IntroStatus.refused => 'Bez odpowiedzi',
    },
  };
}

String _handledLine(IntroService intro, IntroCase c) {
  final String done = switch (c.status) {
    IntroStatus.open => 'czeka',
    IntroStatus.forwarded => 'przekazane',
    IntroStatus.accepted => 'przyjęte',
    IntroStatus.declined => 'odmówione',
    IntroStatus.refused => 'odrzucone',
  };
  if (c.role == IntroRole.target) {
    return '${c.askerName} (przez: ${intro.host.nameOf(c.middle)}) — $done';
  }
  final String x = intro.host.nameOf(c.asker);
  return switch (c.kind) {
    IntroKind.list => '$x: Twoja lista znajomych — $done',
    IntroKind.intro => '$x → ${intro.host.nameOf(c.target)} — $done',
    IntroKind.letter => 'List: $x → ${intro.host.nameOf(c.target)} — $done',
  };
}

/// What this person asked for (introductions, letters, lists) and what
/// went through them (§24.1). Nothing when both are empty.
class MyIntrosTile extends ConsumerWidget {
  const MyIntrosTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final IntroService intro = ref.watch(introServiceProvider);
    return ListenableBuilder(
      listenable: intro,
      builder: (BuildContext context, Widget? _) {
        final List<IntroCase> mine = intro.mine;
        final List<IntroCase> handled = intro.handled;
        if (mine.isEmpty && handled.isEmpty) {
          return const SizedBox.shrink();
        }
        final int going = mine.where((IntroCase c) => c.isPending).length;
        return ZenGroup(
          children: <Widget>[
            if (mine.isNotEmpty)
              ExpansionTile(
                key: const Key('intro-mine'),
                leading: const Icon(Icons.outbox_rounded),
                title: const Text('Twoje prośby i listy'),
                subtitle: Text(
                  going == 0 ? 'Wszystkie zakończone' : 'W toku: $going',
                ),
                children: <Widget>[
                  for (final IntroCase c in mine)
                    ListTile(
                      dense: true,
                      title: Text(_askedTitle(intro, c)),
                      subtitle: Text(_askedStatus(intro, c)),
                      trailing: c.isPending
                          ? null
                          : IconButton(
                              tooltip: 'Usuń z listy',
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () => unawaited(intro.forget(c.id)),
                            ),
                    ),
                ],
              ),
            if (handled.isNotEmpty)
              ExpansionTile(
                key: const Key('intro-handled'),
                leading: const Icon(Icons.history_rounded),
                title: const Text('Przeszło przez Ciebie'),
                subtitle: Text('${handled.length}'),
                children: <Widget>[
                  for (final IntroCase c in handled)
                    ListTile(
                      dense: true,
                      title: Text(_handledLine(intro, c)),
                      trailing: IconButton(
                        tooltip: 'Usuń z listy',
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => unawaited(intro.forget(c.id)),
                      ),
                    ),
                ],
              ),
          ],
        );
      },
    );
  }
}

/// "Kto widzi moją listę znajomych" (§24.1): everyone, only those this
/// person let (after they asked; revocable here), or nobody.
class FriendListAudienceTile extends ConsumerWidget {
  const FriendListAudienceTile({super.key});

  static Future<void> _set(MeetService meet, FriendListAudience a) async {
    await meet.setFriendListAudience(a);
    final Map<String, String>? names = meet.friendNames?.call();
    if (names != null && names.isNotEmpty) {
      await meet.shareFriendList(names, force: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MeetService meet = ref.watch(meetServiceProvider);
    final SocialHubState social = watchSocialPeople(ref);
    return ListenableBuilder(
      listenable: meet,
      builder: (BuildContext context, Widget? _) {
        final ZenColors zen = ZenColors.of(context);
        final FriendListAudience audience = meet.book.friendListAudience;
        final List<FriendProfile> allowed = <FriendProfile>[
          for (final FriendProfile f in social.acceptedFriends)
            if (meet.book.friendListAllowed.contains(
              PeerShareCodec.normalizeAddress(f.address),
            ))
              f,
        ];
        return Padding(
          key: const Key('meet-list-audience'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Kto widzi moją listę znajomych',
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                switch (audience) {
                  FriendListAudience.all =>
                    'Znajomi widzą wspólnych znajomych i znajomych znajomych '
                        'w grafie i na wydarzeniach.',
                  FriendListAudience.onRequest =>
                    'Znajomy może poprosić, a Ty zgadzasz się w Skrzynce. '
                        'Zgodę cofniesz w każdej chwili.',
                  FriendListAudience.nobody =>
                    'Nikt nie widzi Twoich znajomych, więc nikt nie poprosi '
                        'Cię przez graf o przedstawienie.',
                },
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final (FriendListAudience a, String label)
                      in <(FriendListAudience, String)>[
                        (FriendListAudience.all, 'Wszyscy znajomi'),
                        (FriendListAudience.onRequest, 'Tylko na prośbę'),
                        (FriendListAudience.nobody, 'Nikt'),
                      ])
                    ChoiceChip(
                      key: Key('meet-list-audience-${a.name}'),
                      showCheckmark: false,
                      label: Text(label),
                      selected: audience == a,
                      onSelected: (_) => unawaited(_set(meet, a)),
                    ),
                ],
              ),
              if (audience == FriendListAudience.onRequest &&
                  allowed.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  'Widzą ją (${allowed.length})',
                  style: zen.label(color: zen.textMuted),
                ),
                for (final FriendProfile f in allowed)
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          social.nameFor(f),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: zen.textPrimary),
                        ),
                      ),
                      TextButton(
                        key: Key(
                          'meet-list-revoke-'
                          '${PeerShareCodec.normalizeAddress(f.address)}',
                        ),
                        onPressed: () => unawaited(
                          meet.allowFriendList(f.address, allow: false),
                        ),
                        child: const Text('Cofnij'),
                      ),
                    ],
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// "Przekazuj listy od znajomych" (§24.1): this phone passes friends'
/// letters on to its friends, within limits.
class RelayLettersSwitch extends ConsumerWidget {
  const RelayLettersSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final IntroService intro = ref.watch(introServiceProvider);
    return ListenableBuilder(
      listenable: intro,
      builder: (BuildContext context, Widget? _) => SwitchListTile(
        key: const Key('intro-relay-letters'),
        value: intro.relayLetters,
        title: const Text('Przekazuj listy od znajomych'),
        subtitle: const Text(
          'Znajomy może wysłać przez Ciebie jeden list do kogoś z Twoich '
          'znajomych. Limit: $kLettersPerWeek tygodniowo od jednej osoby, '
          '$kLettersRelayedPerWeek łącznie.',
        ),
        onChanged: (bool v) => unawaited(intro.setRelayLetters(v)),
      ),
    );
  }
}

/// Which of the friends in [via] should help.
class _ViaPicker extends StatelessWidget {
  const _ViaPicker({
    required this.via,
    required this.picked,
    required this.nameOf,
    required this.onPick,
  });

  final List<String> via;
  final String picked;
  final String Function(String address) nameOf;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (via.length < 2) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('PRZEZ KOGO', style: zen.label(color: zen.textSecondary)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String v in via)
                ChoiceChip(
                  key: Key('intro-via-$v'),
                  showCheckmark: false,
                  label: Text(nameOf(v)),
                  selected: v == picked,
                  onSelected: (_) => onPick(v),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Consent is the currency; in a shared pyramid the friend may also set a
/// price on its market (§24) — linked, not done here.
class _EconomyNote extends StatelessWidget {
  const _EconomyNote({
    required this.friend,
    required this.inPyramid,
    required this.onOpenMarket,
  });

  final String friend;
  final bool inPyramid;
  final VoidCallback onOpenMarket;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    if (!inPyramid) {
      return ZenInfo(
        icon: Icons.volunteer_activism_rounded,
        tone: zenTone(zen, 5),
        text:
            'Bez pieniędzy i punktów: $friend decyduje, czy przekazać, '
            'a druga osoba — czy chce się poznać.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenInfo(
          key: const Key('intro-pyramid-note'),
          icon: Icons.change_history_rounded,
          tone: zenTone(zen, 2),
          title: 'Jesteście w jednej piramidzie',
          text:
              '$friend może też ustalić cenę za przedstawienie na rynku '
              'piramidy. Tu prosisz za darmo — walutą jest zgoda.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('intro-open-market'),
            onPressed: onOpenMarket,
            icon: const Icon(Icons.storefront_rounded, size: 18),
            label: const Text('Otwórz rynek'),
          ),
        ),
      ],
    );
  }
}

/// "Poproś o przedstawienie" (§24.1): asks one of [via] (friends who know
/// [targetName]) to introduce this person to them.
Future<void> askIntroduction(
  BuildContext context,
  WidgetRef ref, {
  required String target,
  required String targetName,
  required List<String> via,
}) async {
  if (via.isEmpty) {
    return;
  }
  final IntroService intro = ref.read(introServiceProvider);
  final Set<String> pyramid = pyramidFriendAddresses(
    ref.read(pyramidServiceProvider),
  );
  final NavigatorState nav = Navigator.of(context);
  final TextEditingController note = TextEditingController();
  String middle = via.first;
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) {
        final String f = intro.host.nameOf(middle);
        final IntroCase? had = intro.pending(
          IntroKind.intro,
          middle,
          target: target,
        );
        return AlertDialog(
          key: const Key('intro-dialog'),
          title: Text('Poznaj: $targetName'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _ViaPicker(
                  via: via,
                  picked: middle,
                  nameOf: intro.host.nameOf,
                  onPick: (String v) => set(() => middle = v),
                ),
                if (had != null)
                  ZenInfo(
                    icon: Icons.history_rounded,
                    text: 'Prośba już wysłana — czeka na: $f.',
                  )
                else
                  TextField(
                    key: const Key('intro-note'),
                    controller: note,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: kIntroNoteMaxChars,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Kilka słów dla: $f',
                      hintText: 'Dlaczego chcesz poznać tę osobę…',
                    ),
                  ),
                _EconomyNote(
                  friend: f,
                  inPyramid: pyramid.contains(middle),
                  onOpenMarket: () {
                    Navigator.of(context).pop(false);
                    unawaited(
                      nav.push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) =>
                              const WalletScreen(),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            if (had == null)
              FilledButton(
                key: const Key('intro-send'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Poproś'),
              ),
          ],
        );
      },
    ),
  );
  final String text = note.text;
  disposeLater(note);
  if (ok != true) {
    return;
  }
  final String f = intro.host.nameOf(middle);
  final IntroCase? c = await intro.askIntro(
    middle: middle,
    target: target,
    targetName: targetName,
    note: text,
  );
  if (context.mounted) {
    _snack(
      context,
      c == null ? 'Nie można teraz poprosić.' : 'Prośba poszła do: $f.',
    );
  }
}

/// "Napisz list" (§24.1): one letter to [targetName] through one of [via].
Future<void> sendLetterTo(
  BuildContext context,
  WidgetRef ref, {
  required String target,
  required String targetName,
  required List<String> via,
}) async {
  if (via.isEmpty) {
    return;
  }
  final IntroService intro = ref.read(introServiceProvider);
  final TextEditingController text = TextEditingController();
  String middle = via.first;
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) {
        final String f = intro.host.nameOf(middle);
        final int left = intro.lettersLeft(middle);
        return AlertDialog(
          key: const Key('letter-dialog'),
          title: Text('List do: $targetName'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _ViaPicker(
                  via: via,
                  picked: middle,
                  nameOf: intro.host.nameOf,
                  onPick: (String v) => set(() => middle = v),
                ),
                TextField(
                  key: const Key('letter-text'),
                  controller: text,
                  enabled: left > 0,
                  minLines: 4,
                  maxLines: 8,
                  maxLength: kLetterMaxChars,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Treść',
                    hintText: 'Kim jesteś i dlaczego piszesz…',
                    alignLabelWithHint: true,
                  ),
                ),
                ZenInfo(
                  icon: Icons.mail_outline_rounded,
                  text: left > 0
                      ? 'Jeden list, bez rozmowy: odbiorca może tylko '
                            'zaprosić Cię do znajomych albo go zignorować. '
                            'List przejdzie przez telefon: $f. '
                            'Zostało w tym tygodniu: $left z $kLettersPerWeek.'
                      : 'Limit listów przez: $f na ten tydzień już się '
                            'skończył. Spróbuj przez kogoś innego albo za '
                            'kilka dni.',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              key: const Key('letter-send'),
              onPressed: left > 0
                  ? () => Navigator.of(context).pop(true)
                  : null,
              child: const Text('Wyślij'),
            ),
          ],
        );
      },
    ),
  );
  final String body = text.text;
  disposeLater(text);
  if (ok != true) {
    return;
  }
  final IntroCase? c = body.trim().isEmpty
      ? null
      : await intro.sendLetter(
          middle: middle,
          target: target,
          targetName: targetName,
          text: body,
        );
  if (context.mounted) {
    _snack(
      context,
      c == null
          ? 'List nie poszedł.'
          : 'List poszedł do: ${intro.host.nameOf(middle)}.',
    );
  }
}

/// "Zapytaj o opinię" (§16.1): a private message to one of [via] about
/// [targetName], then the conversation opens.
Future<void> askOpinion(
  BuildContext context,
  WidgetRef ref, {
  required String targetName,
  required List<String> via,
}) async {
  if (via.isEmpty) {
    return;
  }
  final MeetService meet = ref.read(meetServiceProvider);
  final SocialHubController social = ref.read(
    socialHubControllerProvider.notifier,
  );
  final SocialHubState people = ref.read(socialHubControllerProvider);
  final NavigatorState nav = Navigator.of(context);
  final TextEditingController text = TextEditingController(
    text:
        'Hej! Chcę zapytać o kogoś z Twoich znajomych: $targetName. '
        'Co sądzisz o tej osobie?',
  );
  String middle = via.first;
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) {
        final String f = meet.host.nameOf(middle);
        return AlertDialog(
          key: const Key('opinion-dialog'),
          title: const Text('Zapytaj o opinię'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _ViaPicker(
                  via: via,
                  picked: middle,
                  nameOf: meet.host.nameOf,
                  onPick: (String v) => set(() => middle = v),
                ),
                TextField(
                  key: const Key('opinion-text'),
                  controller: text,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: kLetterMaxChars,
                  textCapitalization: TextCapitalization.sentences,
                ),
                ZenInfo(
                  icon: Icons.lock_outline_rounded,
                  text:
                      'Zwykła wiadomość tylko do: $f. Osoba, o którą pytasz, '
                      'nic nie zobaczy.',
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              key: const Key('opinion-send'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Wyślij'),
            ),
          ],
        );
      },
    ),
  );
  final String message = text.text.trim();
  disposeLater(text);
  if (ok != true || message.isEmpty) {
    return;
  }
  final String peer = people.friendByAddress(middle)?.address ?? middle;
  final String title = meet.host.nameOf(middle);
  try {
    await social.sendLocalMessage(peerAddress: peer, text: message);
  } on Object {
    if (context.mounted) {
      _snack(context, 'Nie udało się wysłać.');
    }
    return;
  }
  unawaited(
    nav.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            ConversationScreen(peerAddress: peer, title: title),
      ),
    ),
  );
}
