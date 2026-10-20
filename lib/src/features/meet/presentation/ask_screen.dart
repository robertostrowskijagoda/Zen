import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/meet/ask/ask_service.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// "Zapytaj sieć" (§17.5).
class AskScreen extends ConsumerStatefulWidget {
  const AskScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const AskScreen(),
    ),
  );

  @override
  ConsumerState<AskScreen> createState() => _AskScreenState();
}

class _AskScreenState extends ConsumerState<AskScreen> {
  final TextEditingController _text = TextEditingController();
  bool _twoSteps = true;

  @override
  void initState() {
    super.initState();
    unawaited(ref.read(askServiceProvider).load());
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _ask(AskService ask) async {
    final Question? q = await ask.ask(_text.text, twoSteps: _twoSteps);
    if (!mounted) {
      return;
    }
    if (q != null) {
      _text.clear();
    }
  }

  Future<void> _answer(AskService ask, Question q) async {
    final TextEditingController c = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Odpowiedz')),
        content: TextField(
          key: const Key('ask-answer-text'),
          controller: c,
          autofocus: true,
          maxLines: 4,
          maxLength: 1000,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(c.text),
            child: Text(t('Wyślij')),
          ),
        ],
      ),
    );
    disposeLater(c);
    if (text != null && text.trim().isNotEmpty) {
      // A pyramid member signs the answer with its pyramid key, so the
      // asker can give a tip (§24).
      final PyramidService pyr = ref.read(pyramidServiceProvider);
      final bool member = pyr.isMember;
      await ask.answer(
        q.id,
        text,
        pyramidKey: member ? pyr.myKey : null,
        pyramid: member ? pyr.current : null,
      );
    }
  }

  /// "Daj napiwek" (§17.5, §24): a payment in the pyramid's currency to
  /// the one who answered.
  Future<void> _tip(
    AskService ask,
    PyramidService pyr,
    Question q,
    int index,
  ) async {
    final AskAnswer a = q.answers[index];
    final String? key = a.pyramidKey;
    if (key == null || !pyr.canTip(key, pyramid: a.pyramid)) {
      return;
    }
    final String? me = pyr.myKey;
    final int balance = me == null ? 0 : pyr.state?.balanceOf(me) ?? 0;
    final String name = pyr.state?.members[key]?.name ?? answerSource(a.path);
    final (int, String)? amount = await askAmount(
      context,
      title: t('Napiwek dla: {name}', {'name': name}),
      info: t(
        'Przelew w walucie piramidy z tytułem „Napiwek za odpowiedź”. '
        'Masz: {amount}.',
        {'amount': formatMoney(balance)},
      ),
      fieldKey: const Key('ask-tip-amount'),
    );
    if (amount == null || !mounted) {
      return;
    }
    if (amount.$1 > balance) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('Za mało środków.'))));
      return;
    }
    final PyramidRecord? order = await pyr.tip(
      key,
      amount.$1,
      pyramid: a.pyramid,
    );
    if (order != null) {
      await ask.noteTip(q.id, index, amount.$1);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            order == null
                ? t(
                    'Nie udało się wysłać (może czeka jeszcze poprzedni '
                    'przelew).',
                  )
                : t('Napiwek wysłany — przelew zatwierdzą skarbnicy.'),
          ),
        ),
      );
    }
  }

  Future<void> _forward(AskService ask, Question q) async {
    final SocialHubState social = ref.read(socialHubControllerProvider);
    final Set<String> chosen = <String>{};
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) => AlertDialog(
          title: Text(t('Przekaż dalej — komu?')),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final FriendProfile f in social.acceptedFriends)
                  if (f.address != q.from)
                    CheckboxListTile(
                      value: chosen.contains(f.address),
                      title: Text(social.nameFor(f)),
                      onChanged: (bool? v) => set(() {
                        if (v ?? false) {
                          chosen.add(f.address);
                        } else {
                          chosen.remove(f.address);
                        }
                      }),
                    ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t('Przekaż')),
            ),
          ],
        ),
      ),
    );
    if (ok == true && chosen.isNotEmpty) {
      await ask.forward(q.id, chosen.toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    final AskService ask = ref.watch(askServiceProvider);
    final PyramidService pyr = ref.watch(pyramidServiceProvider);
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('ask-screen'),
      appBar: AppBar(title: Text(t('Zapytaj sieć'))),
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[ask, pyr]),
        builder: (BuildContext context, Widget? _) {
          final List<Question> mine = ask.mine;
          final List<Question> others = ask.fromOthers;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              ZenHero(
                title: t('Pytaj ludzi, nie bazę'),
                icon: Icons.help_center_rounded,
                tone: zenTone(zen, 6),
                text: t(
                  '„Znacie dobrego dentystę w Gdańsku?”, „Kto pożyczy '
                  'przyczepkę?”. Odpowiedzi wracają tą samą drogą, z '
                  'informacją, przez kogo — wiesz, komu ufasz.',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('ask-text'),
                controller: _text,
                minLines: 2,
                maxLines: 4,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('Twoje pytanie'),
                  hintText: t('np. Kto zna dobrego hydraulika?'),
                ),
              ),
              ZenGroup(
                children: <Widget>[
                  SwitchListTile(
                    value: _twoSteps,
                    title: Text(t('Znajomi mogą przekazać dalej')),
                    subtitle: Text(
                      t('Pytanie dotrze też do znajomych Twoich znajomych.'),
                    ),
                    onChanged: (bool v) => setState(() => _twoSteps = v),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('ask-send'),
                onPressed: () => unawaited(_ask(ask)),
                icon: const Icon(Icons.send_rounded),
                label: Text(t('Zapytaj')),
              ),
              if (mine.isNotEmpty) ...<Widget>[
                ZenSection(t('Twoje pytania')),
                for (final Question q in mine)
                  ZenCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          q.text,
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (q.answers.isEmpty)
                          ZenPill(
                            text: t('Czeka na odpowiedzi'),
                            tone: zen.textMuted,
                            icon: Icons.hourglass_empty_rounded,
                          )
                        else
                          ZenPill(
                            text: t('Odpowiedzi: {count}', {
                              'count': q.answers.length,
                            }),
                            tone: zen.success,
                            icon: Icons.forum_rounded,
                          ),
                        for (final (int i, AskAnswer a) in q.answers.indexed)
                          Container(
                            margin: const EdgeInsets.only(top: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: zen.surfaceRaised,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  answerSource(a.path),
                                  style: TextStyle(
                                    color: zen.accent,
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  a.text,
                                  style: TextStyle(
                                    color: zen.textPrimary,
                                    fontSize: 14.5,
                                    height: 1.35,
                                  ),
                                ),
                                if (a.tipped > 0 ||
                                    pyr.canTip(
                                      a.pyramidKey,
                                      pyramid: a.pyramid,
                                    )) ...<Widget>[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: <Widget>[
                                      if (a.tipped > 0)
                                        ZenPill(
                                          text: t('Napiwek: {amount}', {
                                            'amount': formatMoney(a.tipped),
                                          }),
                                          tone: zen.success,
                                          icon:
                                              Icons.volunteer_activism_rounded,
                                        ),
                                      if (pyr.canTip(
                                        a.pyramidKey,
                                        pyramid: a.pyramid,
                                      ))
                                        TextButton.icon(
                                          key: Key('ask-tip-${q.id}-$i'),
                                          onPressed: () =>
                                              unawaited(_tip(ask, pyr, q, i)),
                                          icon: const Icon(
                                            Icons.volunteer_activism_rounded,
                                            size: 18,
                                          ),
                                          label: Text(t('Daj napiwek')),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
              if (others.isNotEmpty) ...<Widget>[
                ZenSection(t('Pytają Cię')),
                for (final Question q in others)
                  ZenCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          q.via.isEmpty
                              ? q.askerName
                              : t('{name} · przez {via}', {
                                  'name': q.askerName,
                                  'via': q.via.join(', '),
                                }),
                          style: TextStyle(
                            color: zen.accent,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          q.text,
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 15.5,
                            height: 1.35,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            FilledButton.tonalIcon(
                              onPressed: () => unawaited(_answer(ask, q)),
                              icon: const Icon(Icons.reply_rounded, size: 18),
                              label: Text(
                                q.answeredByMe
                                    ? t('Odpowiedz jeszcze raz')
                                    : t('Odpowiedz'),
                              ),
                            ),
                            if (q.hops > 0 && !q.forwarded)
                              OutlinedButton.icon(
                                onPressed: () => unawaited(_forward(ask, q)),
                                icon: const Icon(
                                  Icons.forward_rounded,
                                  size: 18,
                                ),
                                label: Text(t('Przekaż dalej')),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}
