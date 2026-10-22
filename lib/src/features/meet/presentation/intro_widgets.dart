import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/presentation/gate_widgets.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// Gates: the introduction dialog with its prices and the cheapest way, the
// ways being opened, this person's gate terms.
export 'package:zen/src/features/meet/presentation/gate_widgets.dart'
    show GateRunsTile, GateSettingsTile, askIntroduction;

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// Requests waiting for this person: friend lists, introductions
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
                  t('Prośby o kontakt ({count})', {'count': open.length}),
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
      _snack(context, ok ? done : t('Nie udało się. Spróbuj jeszcze raz.'));
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
      t('Przekazano do: {name}.', {'name': target}),
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
        t('{name} prosi o Twoją listę znajomych', {'name': x}),
        t('Zobaczy, kogo znasz. Zgodę możesz cofnąć w Grafie.'),
      ),
      (IntroRole.middle, _) => (
        Icons.waving_hand_rounded,
        t('{name} prosi o przedstawienie', {'name': x}),
        c.price > 0
            ? t('Komu: {name} · zapłacono: {price} (wróci, gdy odmówisz)', {
                'name': intro.host.nameOf(c.target),
                'price': formatPoints(c.price),
              })
            : t('Komu: {name}', {'name': intro.host.nameOf(c.target)}),
      ),
      (_, IntroKind.letter) => (
        Icons.mail_outline_rounded,
        t('List od: {name}', {'name': x}),
        t('Przez: {via}. Możesz zaprosić do znajomych albo zignorować.', {
          'via': via,
        }),
      ),
      (_, IntroKind.friend) => (
        Icons.person_add_alt_rounded,
        t('{name} chce dodać Cię do znajomych', {'name': x}),
        t('Znacie się przez: {via}. Zdecyduj, czy chcesz.', {'via': via}),
      ),
      _ => (
        Icons.waving_hand_rounded,
        t('{via} przedstawia Ci: {name}', {'via': via, 'name': x}),
        t('Zdecyduj, czy chcesz się poznać.'),
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
                      t('Pokazano listę: {name}.', {'name': x}),
                    ),
                  ),
                  icon: const Icon(Icons.visibility_rounded, size: 18),
                  label: Text(t('Pokaż listę')),
                )
              else if (middle)
                FilledButton.icon(
                  key: Key('intro-forward-${c.id}'),
                  onPressed: () => unawaited(_forward(context)),
                  icon: const Icon(Icons.send_rounded, size: 18),
                  label: Text(t('Przekaż')),
                )
              else
                FilledButton.icon(
                  key: Key('intro-accept-${c.id}'),
                  onPressed: () => unawaited(
                    _run(
                      context,
                      () => intro.accept(c.id),
                      t('Wysłano zaproszenie do znajomych.'),
                    ),
                  ),
                  icon: const Icon(Icons.person_add_rounded, size: 18),
                  label: Text(switch (c.kind) {
                    IntroKind.letter => t('Zaproś do znajomych'),
                    IntroKind.friend => t('Dodaj do znajomych'),
                    _ => t('Poznajmy się'),
                  }),
                ),
              if (middle)
                OutlinedButton(
                  key: Key('intro-decline-${c.id}'),
                  onPressed: () => unawaited(
                    _run(context, () => intro.decline(c.id), t('Odmówiono.')),
                  ),
                  child: Text(t('Odmów')),
                )
              else
                OutlinedButton(
                  key: Key('intro-refuse-${c.id}'),
                  onPressed: () => unawaited(
                    _run(context, () => intro.refuse(c.id), t('Gotowe.')),
                  ),
                  child: Text(
                    c.kind == IntroKind.letter
                        ? t('Zignoruj')
                        : t('Nie, dziękuję'),
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
      title: Text(t('Przekaż do: {name}', {'name': target})),
      content: SelectionArea(
        child: TextField(
          key: const Key('intro-forward-note'),
          controller: note,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          maxLength: kIntroNoteMaxChars,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: t('Twoje słowo (nieobowiązkowe)'),
            hintText: t('Skąd się znacie, dlaczego warto…'),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('intro-forward-send'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t('Przekaż')),
        ),
      ],
    ),
  );
  final String text = note.text;
  disposeLater(note);
  return ok == true ? text : null;
}

String _askedTitle(IntroService intro, IntroCase c) => switch (c.kind) {
  IntroKind.intro => t('Przedstawienie: {name}', {'name': c.targetName}),
  IntroKind.letter => t('List do: {name}', {'name': c.targetName}),
  IntroKind.list => t('Lista znajomych: {name}', {
    'name': intro.host.nameOf(c.middle),
  }),
  IntroKind.friend => t('Zaproszenie do znajomych: {name}', {
    'name': c.targetName,
  }),
};

String _askedStatus(IntroService intro, IntroCase c) {
  final String via = intro.host.nameOf(c.middle);
  return switch (c.kind) {
    IntroKind.list => switch (c.status) {
      IntroStatus.open ||
      IntroStatus.forwarded => t('Czeka na zgodę: {via}', {'via': via}),
      IntroStatus.accepted => t('Widzisz tę listę'),
      IntroStatus.declined || IntroStatus.refused => t('Bez zgody'),
    },
    IntroKind.intro => switch (c.status) {
      IntroStatus.open => t('Czeka na: {via}', {'via': via}),
      IntroStatus.forwarded => t(
        'Brama otwarta przez: {via}. Możesz napisać; o znajomości decyduje: '
        '{name}',
        {'via': via, 'name': c.targetName},
      ),
      IntroStatus.accepted => t('Przyjęte — zaproszenie do znajomych wysłane'),
      IntroStatus.declined =>
        c.price > 0 && c.payment == null
            ? t('Brama płatna: {price} (przez: {via})', {
                'via': via,
                'price': formatPoints(c.price),
              })
            : t('Nie przekazane przez: {via}', {'via': via}),
      IntroStatus.refused => t('Bez odpowiedzi'),
    },
    IntroKind.letter => switch (c.status) {
      IntroStatus.open => t('Wysłany do: {via}', {'via': via}),
      IntroStatus.forwarded => t('Przekazany przez: {via}', {'via': via}),
      IntroStatus.accepted => t('Odpowiedź: zaproszenie do znajomych'),
      IntroStatus.declined => t('Nie poszedł (przez: {via})', {'via': via}),
      IntroStatus.refused => t('Bez odpowiedzi'),
    },
    IntroKind.friend =>
      intro.host.isFriend(c.target)
          ? t('Jesteście znajomymi')
          : switch (c.status) {
              IntroStatus.open => t('Czeka na: {via}', {'via': via}),
              IntroStatus.forwarded =>
                c.middle.isEmpty
                    ? t('Wysłane bezpośrednio. Decyduje: {name}', {
                        'name': c.targetName,
                      })
                    : t('Dotarło przez: {via}. Decyduje: {name}', {
                        'via': via,
                        'name': c.targetName,
                      }),
              IntroStatus.accepted => t('Przyjęte — jesteście znajomymi'),
              IntroStatus.declined => t('Nie przekazane przez: {via}', {
                'via': via,
              }),
              IntroStatus.refused => t('Bez odpowiedzi'),
            },
  };
}

String _handledLine(IntroService intro, IntroCase c) {
  final String done = switch (c.status) {
    IntroStatus.open => t('czeka'),
    IntroStatus.forwarded => t('przekazane'),
    IntroStatus.accepted => t('przyjęte'),
    IntroStatus.declined => t('odmówione'),
    IntroStatus.refused => t('odrzucone'),
  };
  if (c.role == IntroRole.target) {
    return t('{name} (przez: {via}) — {status}', {
      'name': c.askerName,
      'via': intro.host.nameOf(c.middle),
      'status': done,
    });
  }
  final String x = intro.host.nameOf(c.asker);
  return switch (c.kind) {
    IntroKind.list => t('{name}: Twoja lista znajomych — {status}', {
      'name': x,
      'status': done,
    }),
    IntroKind.intro => '$x → ${intro.host.nameOf(c.target)} — $done',
    IntroKind.letter => t('List: {from} → {to} — {status}', {
      'from': x,
      'to': intro.host.nameOf(c.target),
      'status': done,
    }),
    IntroKind.friend => t('Zaproszenie: {from} → {to} — {status}', {
      'from': x,
      'to': intro.host.nameOf(c.target),
      'status': done,
    }),
  };
}

/// What this person asked for (introductions, letters, lists) and what
/// went through them. Nothing when both are empty.
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
            if (intro.runs.isNotEmpty) gateRunsTile(intro),
            if (mine.isNotEmpty)
              ExpansionTile(
                key: const Key('intro-mine'),
                leading: const Icon(Icons.outbox_rounded),
                title: Text(t('Twoje prośby i listy')),
                subtitle: Text(
                  going == 0
                      ? t('Wszystkie zakończone')
                      : t('W toku: {count}', {'count': going}),
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
                              tooltip: t('Usuń z listy'),
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
                title: Text(t('Przeszło przez Ciebie')),
                subtitle: Text('${handled.length}'),
                children: <Widget>[
                  for (final IntroCase c in handled)
                    ListTile(
                      dense: true,
                      title: Text(_handledLine(intro, c)),
                      trailing: IconButton(
                        tooltip: t('Usuń z listy'),
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

/// "Kto widzi moją listę znajomych": everyone, friends at level
/// "Znajomy" and up (the default), only those this person let (after
/// they asked; revocable here), or nobody.
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
                t('Kto widzi moją listę znajomych'),
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                switch (audience) {
                  FriendListAudience.all => t(
                    'Znajomi widzą wspólnych znajomych i znajomych znajomych '
                    'w grafie i na wydarzeniach.',
                  ),
                  FriendListAudience.friends => t(
                    'Widzą ją znajomi i przyjaciele. Słaby znajomy może '
                    'poprosić, a Ty zgadzasz się w Skrzynce.',
                  ),
                  FriendListAudience.close => t(
                    'Widzą ją tylko przyjaciele. Inni znajomi mogą poprosić, '
                    'a Ty zgadzasz się w Skrzynce.',
                  ),
                  FriendListAudience.onRequest => t(
                    'Znajomy może poprosić, a Ty zgadzasz się w Skrzynce. '
                    'Zgodę cofniesz w każdej chwili.',
                  ),
                  FriendListAudience.nobody => t(
                    'Nikt nie widzi Twoich znajomych, więc nikt nie poprosi '
                    'Cię przez graf o przedstawienie.',
                  ),
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
                        (FriendListAudience.all, t('Wszyscy znajomi')),
                        (
                          FriendListAudience.friends,
                          t('Znajomi i przyjaciele'),
                        ),
                        (FriendListAudience.close, t('Tylko przyjaciele')),
                        (FriendListAudience.onRequest, t('Tylko na prośbę')),
                        (FriendListAudience.nobody, t('Nikt')),
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
              if ((audience == FriendListAudience.onRequest ||
                      audience == FriendListAudience.close ||
                      audience == FriendListAudience.friends) &&
                  allowed.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  t('Widzą ją ({count})', {'count': allowed.length}),
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
                        child: Text(t('Cofnij')),
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

/// "Przekazuj listy od znajomych": this phone passes friends'
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
        title: Text(t('Przekazuj listy od znajomych')),
        subtitle: Text(
          t(
            'Znajomy może wysłać przez Ciebie jeden list do kogoś z Twoich '
            'znajomych. Limit: {perPerson} tygodniowo od jednej osoby, '
            '{total} łącznie.',
            {'perPerson': kLettersPerWeek, 'total': kLettersRelayedPerWeek},
          ),
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
          Text(t('PRZEZ KOGO'), style: zen.label(color: zen.textSecondary)),
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

/// "Napisz list": one letter to [targetName] through one of [via].
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
          title: Text(t('List do: {name}', {'name': targetName})),
          content: SelectionArea(
            child: SingleChildScrollView(
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
                    decoration: InputDecoration(
                      labelText: t('Treść'),
                      hintText: t('Kim jesteś i dlaczego piszesz…'),
                      alignLabelWithHint: true,
                    ),
                  ),
                  ZenInfo(
                    icon: Icons.mail_outline_rounded,
                    text: left > 0
                        ? t(
                            'Jeden list, bez rozmowy: odbiorca może tylko '
                            'zaprosić Cię do znajomych albo go zignorować. '
                            'List przejdzie przez telefon: {name}. '
                            'Zostało w tym tygodniu: {left} z {limit}.',
                            {'name': f, 'left': left, 'limit': kLettersPerWeek},
                          )
                        : t(
                            'Limit listów przez: {name} na ten tydzień już się '
                            'skończył. Spróbuj przez kogoś innego albo za '
                            'kilka dni.',
                            {'name': f},
                          ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('letter-send'),
              onPressed: left > 0
                  ? () => Navigator.of(context).pop(true)
                  : null,
              child: Text(t('Wyślij')),
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
          ? t('List nie poszedł.')
          : t('List poszedł do: {name}.', {'name': intro.host.nameOf(middle)}),
    );
  }
}

/// "Zapytaj o opinię": a private message to one of [via] about
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
    text: t(
      'Hej! Chcę zapytać o kogoś z Twoich znajomych: {name}. '
      'Co sądzisz o tej osobie?',
      {'name': targetName},
    ),
  );
  String middle = via.first;
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) {
        final String f = meet.host.nameOf(middle);
        return AlertDialog(
          key: const Key('opinion-dialog'),
          title: Text(t('Zapytaj o opinię')),
          content: SelectionArea(
            child: SingleChildScrollView(
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
                    text: t(
                      'Zwykła wiadomość tylko do: {name}. Osoba, o którą '
                      'pytasz, nic nie zobaczy.',
                      {'name': f},
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('opinion-send'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t('Wyślij')),
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
      _snack(context, t('Nie udało się wysłać.'));
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
