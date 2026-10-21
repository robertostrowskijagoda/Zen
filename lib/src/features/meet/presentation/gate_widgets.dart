import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/chat/stranger_chats.dart';
import 'package:zen/src/features/meet/intro/gate_route.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

void _snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// The way a plan goes, in words: "Ania → Bartek".
String gatePlanThrough(IntroService intro, GatePlan plan) {
  final List<String> names = <String>[
    if (plan.steps.isNotEmpty) intro.host.nameOf(plan.steps.first.via),
    for (int i = 0; i < plan.steps.length - 1; i++)
      plan.steps[i].toName.isEmpty ? t('ktoś') : plan.steps[i].toName,
  ];
  return names.join(' → ');
}

/// "5 pkt", "za darmo", with how many gates wait for someone's consent.
String gatePlanCost(GatePlan plan) => <String>[
  if (plan.price > 0) formatPoints(plan.price) else t('za darmo'),
  if (plan.pending > 0)
    tn(
      plan.pending,
      one: '{n} za zgodą',
      few: '{n} za zgodą',
      many: '{n} za zgodą',
    ),
].join(' · ');

/// What [plan] says, line by line: the cheapest way first, then writing
/// directly and the gates.
List<String> reachLines(IntroService intro, ReachPlan plan) {
  final GatePlan? gates = plan.gates;
  final String direct = t('Bezpośrednio: {cost}', {'cost': plan.direct.label});
  final String through = gates == null
      ? t('Przez bramy: brak znanej drogi')
      : t('Przez bramy: {way} ({cost})', {
          'way': gatePlanThrough(intro, gates),
          'cost': gatePlanCost(gates),
        });
  String cheapest(GatePlan g) => t('Najtaniej: przez {way} ({cost})', {
    'way': gatePlanThrough(intro, g),
    'cost': gatePlanCost(g),
  });
  final String best = switch (plan.best) {
    ReachChoice.direct => t('Najtaniej: bezpośrednio ({cost})', {
      'cost': plan.direct.label,
    }),
    ReachChoice.gates => cheapest(gates!),
    ReachChoice.none => t('Nie znamy drogi, która na pewno zadziała.'),
  };
  return <String>[best, direct, through];
}

/// What one gatekeeper's [terms] mean for the asker.
String gateTermsText(String name, GateTerms? terms, {required bool payable}) {
  if (terms == null) {
    return t(
      'Bez punktów: {name} decyduje, czy przekazać, a druga osoba — czy '
      'chce się poznać.',
      {'name': name},
    );
  }
  if (terms.free) {
    return terms.consent
        ? t('{name} otwiera bramę za darmo i decyduje o każdej prośbie.', {
            'name': name,
          })
        : t('{name} otwiera bramę za darmo, od razu.', {'name': name});
  }
  if (!payable) {
    return t(
      '{name} otwiera bramę za {price}. Płatne bramy działają tylko między '
      'członkami piramidy — poza nią tylko darmowe.',
      {'name': name, 'price': formatPoints(terms.price)},
    );
  }
  return terms.consent
      ? t('Brama za {price}, za zgodą: {name}. Gdy odmówi, punkty wrócą.', {
          'name': name,
          'price': formatPoints(terms.price),
        })
      : t(
          'Brama za {price}: otwiera się od razu, bez zgody: {name}. Punkty '
          'trafiają do tej osoby, gdy brama się otworzy.',
          {'name': name, 'price': formatPoints(terms.price)},
        );
}

/// What to do after the introduction dialog.
enum _Reach { ask, cheapest, direct }

/// "Poproś o przedstawienie": asks one of [via] (friends who know
/// [targetName]) to open the gate to them — free, or for the price that
/// friend set (then paid from the pyramid wallet). Also shows the cheapest
/// way known (through more gates, or writing directly) and takes it.
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
  final StrangerChatBook strangers = ref.read(strangerChatsProvider);
  final DirectTerms direct =
      strangers.termsOf?.call(target) ?? const DirectTerms.unknown();
  final ReachPlan plan = intro.planTo(target, direct: direct);
  final bool member = intro.wallet?.myKey != null;
  final NavigatorState nav = Navigator.of(context);
  final TextEditingController note = TextEditingController();
  String middle = via.first;
  final _Reach? choice = await showDialog<_Reach>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) {
        final ZenColors zen = ZenColors.of(context);
        final String f = intro.host.nameOf(middle);
        final GateTerms? terms = intro.gateTermsOf(middle);
        final bool payable = intro.canPay(middle);
        final bool blocked = terms != null && !terms.free && !payable;
        final IntroCase? had = intro.pending(
          IntroKind.intro,
          middle,
          target: target,
        );
        final GatePlan? gates = plan.gates;
        // The cheapest way is something else than this one gate.
        final bool otherWay =
            plan.best == ReachChoice.gates &&
            gates != null &&
            (gates.steps.length > 1 ||
                PeerShareCodec.normalizeAddress(gates.steps.first.via) !=
                    PeerShareCodec.normalizeAddress(middle));
        final bool writeDirectly =
            plan.best == ReachChoice.direct && plan.direct.usable;
        return AlertDialog(
          key: const Key('intro-dialog'),
          title: Text(t('Poznaj: {name}', {'name': targetName})),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _ViaChips(
                  via: via,
                  picked: middle,
                  label: (String v) {
                    final GateTerms? g = intro.gateTermsOf(v);
                    final String name = intro.host.nameOf(v);
                    return g == null ? name : '$name · ${g.label}';
                  },
                  onPick: (String v) => set(() => middle = v),
                ),
                if (had != null)
                  ZenInfo(
                    icon: Icons.history_rounded,
                    text: t('Prośba już wysłana — czeka na: {name}.', {
                      'name': f,
                    }),
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
                      labelText: t('Kilka słów dla: {name}', {'name': f}),
                      hintText: t('Dlaczego chcesz poznać tę osobę…'),
                    ),
                  ),
                ZenInfo(
                  key: const Key('intro-terms'),
                  icon: terms == null || terms.free
                      ? Icons.volunteer_activism_rounded
                      : Icons.toll_rounded,
                  tone: zenTone(zen, 5),
                  text: gateTermsText(f, terms, payable: payable),
                ),
                const SizedBox(height: 8),
                ZenInfo(
                  key: const Key('reach-plan'),
                  icon: Icons.route_rounded,
                  tone: zen.accent,
                  title: t('Jak dotrzeć'),
                  text: <String>[
                    ...reachLines(intro, plan),
                    if (!member)
                      t(
                        'Płatne bramy i wiadomości działają tylko między '
                        'członkami piramidy; poza nią — tylko darmowe.',
                      ),
                  ].join('\n'),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t('Anuluj')),
            ),
            if (otherWay)
              TextButton(
                key: const Key('reach-run'),
                onPressed: () => Navigator.of(context).pop(_Reach.cheapest),
                child: Text(
                  t('Najtaniej ({cost})', {'cost': gatePlanCost(gates)}),
                ),
              ),
            if (writeDirectly)
              TextButton(
                key: const Key('reach-direct'),
                onPressed: () => Navigator.of(context).pop(_Reach.direct),
                child: Text(
                  plan.direct.price > 0
                      ? t('Zapłać {price} i napisz', {
                          'price': formatPoints(plan.direct.price),
                        })
                      : t('Napisz bezpośrednio'),
                ),
              ),
            if (had == null)
              FilledButton(
                key: const Key('intro-send'),
                onPressed: blocked
                    ? null
                    : () => Navigator.of(context).pop(_Reach.ask),
                child: Text(
                  terms == null || terms.free
                      ? t('Poproś')
                      : t('Zapłać {price} i poproś', {
                          'price': formatPoints(terms.price),
                        }),
                ),
              ),
          ],
        );
      },
    ),
  );
  final String text = note.text;
  disposeLater(note);
  if (choice == null || !context.mounted) {
    return;
  }
  switch (choice) {
    case _Reach.ask:
      final GateTerms? terms = intro.gateTermsOf(middle);
      if (terms != null && !terms.free) {
        final GatePlan one = GatePlan(<GateStepPlan>[
          GateStepPlan(
            via: middle,
            to: target,
            toName: targetName,
            terms: terms,
          ),
        ]);
        await _openWay(context, intro, one, target, targetName, text);
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
          c == null
              ? t('Nie można teraz poprosić.')
              : t('Prośba poszła do: {name}.', {'name': f}),
        );
      }
    case _Reach.cheapest:
      await _openWay(context, intro, plan.gates!, target, targetName, text);
    case _Reach.direct:
      if (plan.direct.price <= 0) {
        unawaited(
          nav.push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) =>
                  ConversationScreen(peerAddress: target, title: targetName),
            ),
          ),
        );
        return;
      }
      if (!await confirmPayment(context)) {
        return;
      }
      final bool paid = await intro.payToWrite(
        target,
        price: plan.direct.price,
      );
      if (context.mounted) {
        _snack(
          context,
          paid
              ? t(
                  'Płatność w drodze. Gdy {name} ją przyjmie, możesz napisać '
                  '(do {n} wiadomości przed odpowiedzią).',
                  {'name': targetName, 'n': kStrangerMessagesBeforeReply},
                )
              : t('Płatność nie poszła (za mało punktów albo poza piramidą).'),
        );
      }
  }
}

Future<void> _openWay(
  BuildContext context,
  IntroService intro,
  GatePlan plan,
  String target,
  String targetName,
  String note,
) async {
  if (plan.price > 0 && !await confirmPayment(context)) {
    return;
  }
  final GateRun? run = await intro.openWay(
    plan,
    target: target,
    targetName: targetName,
    note: note,
  );
  if (context.mounted) {
    _snack(
      context,
      run == null
          ? t('Nie można teraz otworzyć tej drogi.')
          : t(
              'Otwieram bramy po kolei: {way}. Płacisz za każdą dopiero, '
              'gdy przyjdzie jej kolej.',
              {'way': gatePlanThrough(intro, plan)},
            ),
    );
  }
}

/// Which of the friends in [via] should open the gate.
class _ViaChips extends StatelessWidget {
  const _ViaChips({
    required this.via,
    required this.picked,
    required this.label,
    required this.onPick,
  });

  final List<String> via;
  final String picked;
  final String Function(String address) label;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
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
                  label: Text(label(v)),
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

/// How a way through gates stands, in words.
String gateRunStatus(GateRun run) {
  switch (run.state) {
    case GateRunState.done:
      return t('Droga otwarta — możesz napisać.');
    case GateRunState.failed:
      return run.reason.isEmpty ? t('Nie udało się.') : run.reason;
    case GateRunState.going:
      final int open = run.steps
          .where((GateRunStep s) => s.state == GateStepState.open)
          .length;
      final GateRunStep? now = run.steps
          .where((GateRunStep s) => s.state != GateStepState.open)
          .firstOrNull;
      final String what = switch (now?.state) {
        GateStepState.paying => t('płatność czeka na skarbników'),
        GateStepState.asking => t('czeka na bramę'),
        _ => t('w drodze'),
      };
      return t('Otwarte bramy: {open} z {all} — {what}', {
        'open': open,
        'all': run.steps.length,
        'what': what,
      });
  }
}

/// This person's ways through gates (being opened and done), as a tile
/// that opens.
Widget gateRunsTile(IntroService intro) {
  final List<GateRun> runs = intro.runs;
  final int going = runs.where((GateRun r) => r.going).length;
  return ExpansionTile(
    key: const Key('intro-ways'),
    leading: const Icon(Icons.route_rounded),
    title: Text(t('Drogi przez bramy')),
    subtitle: Text(
      going == 0
          ? t('Wszystkie zakończone')
          : t('W toku: {count}', {'count': going}),
    ),
    children: <Widget>[
      for (final GateRun r in runs)
        ListTile(
          key: Key('intro-way-${r.id}'),
          dense: true,
          title: Text(
            r.price > 0
                ? t('Do: {name} ({price})', {
                    'name': r.targetName,
                    'price': formatPoints(r.price),
                  })
                : t('Do: {name}', {'name': r.targetName}),
          ),
          subtitle: Text(gateRunStatus(r)),
          trailing: r.going
              ? TextButton(
                  key: Key('intro-way-cancel-${r.id}'),
                  onPressed: () => unawaited(intro.cancelWay(r.id)),
                  child: Text(t('Przerwij')),
                )
              : IconButton(
                  tooltip: t('Usuń z listy'),
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => unawaited(intro.forgetWay(r.id)),
                ),
        ),
    ],
  );
}

/// This person's ways through gates on their own (nothing when none).
class GateRunsTile extends ConsumerWidget {
  const GateRunsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final IntroService intro = ref.watch(introServiceProvider);
    return ListenableBuilder(
      listenable: intro,
      builder: (BuildContext context, Widget? _) => intro.runs.isEmpty
          ? const SizedBox.shrink()
          : ZenGroup(children: <Widget>[gateRunsTile(intro)]),
    );
  }
}

/// Edits one set of gate terms: free or a price, and whether this
/// person's consent is needed (by default not when there is a price).
/// Null when cancelled.
Future<GateTerms?> editGateTerms(
  BuildContext context, {
  required GateTerms initial,
  required String title,
  required bool member,
}) async {
  bool paid = !initial.free;
  bool consent = initial.consent;
  final TextEditingController price = TextEditingController(
    text: initial.free ? '' : formatMoney(initial.price),
  );
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) => AlertDialog(
        key: const Key('gate-terms-dialog'),
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(t('Otwieram bramę:')),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  ChoiceChip(
                    key: const Key('gate-free'),
                    showCheckmark: false,
                    label: Text(t('za darmo')),
                    selected: !paid,
                    onSelected: (_) => set(() {
                      paid = false;
                      consent = true;
                    }),
                  ),
                  ChoiceChip(
                    key: const Key('gate-paid'),
                    showCheckmark: false,
                    label: Text(t('za cenę')),
                    selected: paid,
                    onSelected: (_) => set(() {
                      paid = true;
                      // Buying opens it: no consent asked by default.
                      consent = false;
                    }),
                  ),
                ],
              ),
              if (paid) ...<Widget>[
                const SizedBox(height: 8),
                TextField(
                  key: const Key('gate-price-field'),
                  controller: price,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: t('Cena (punkty)'),
                    prefixIcon: const Icon(Icons.toll_outlined),
                  ),
                ),
              ],
              SwitchListTile(
                key: const Key('gate-consent'),
                contentPadding: EdgeInsets.zero,
                value: consent,
                title: Text(t('Wymagaj mojej zgody')),
                subtitle: Text(
                  paid
                      ? consent
                            ? t(
                                'Zatwierdzasz każdą prośbę; odmowa zwraca '
                                'punkty.',
                              )
                            : t(
                                'Kupienie otwiera bramę od razu — Twoja '
                                'aplikacja odpowiada sama.',
                              )
                      : consent
                      ? t('Decydujesz o każdej prośbie.')
                      : t('Przedstawienie idzie od razu, bez pytania.'),
                ),
                onChanged: (bool v) => set(() => consent = v),
              ),
              if (paid && !member)
                ZenInfo(
                  icon: Icons.info_outline_rounded,
                  text: t(
                    'Cena działa tylko między członkami piramidy (punkty z '
                    'portfela). Kto nie jest w piramidzie, nie zapłaci — dla '
                    'takich osób zostają darmowe bramy.',
                  ),
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
            key: const Key('gate-terms-save'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Zapisz')),
          ),
        ],
      ),
    ),
  );
  final int? value = parseMoney(price.text);
  disposeLater(price);
  if (ok != true) {
    return null;
  }
  final int amount = paid && value != null && value > 0
      ? value.clamp(1, kGateMaxPrice)
      : 0;
  return GateTerms(price: amount, consent: consent);
}

/// "Bramy do moich znajomych": how this person opens the way to their
/// friends — for everyone and for chosen friends — and whether the terms
/// may travel further.
class GateSettingsTile extends ConsumerWidget {
  const GateSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final IntroService intro = ref.watch(introServiceProvider);
    final SocialHubState social = watchSocialPeople(ref);
    return ListenableBuilder(
      listenable: intro,
      builder: (BuildContext context, Widget? _) {
        final ZenColors zen = ZenColors.of(context);
        final GateSettings gates = intro.gates;
        final bool member = intro.wallet?.myKey != null;
        final Map<String, FriendProfile> byAddress = <String, FriendProfile>{
          for (final FriendProfile f in social.acceptedFriends)
            PeerShareCodec.normalizeAddress(f.address): f,
        };
        String nameOf(String a) {
          final FriendProfile? f = byAddress[a];
          return f == null ? intro.host.nameOf(a) : social.nameFor(f);
        }

        Future<void> addException() async {
          final List<FriendProfile> left = <FriendProfile>[
            for (final MapEntry<String, FriendProfile> e in byAddress.entries)
              if (!gates.perFriend.containsKey(e.key)) e.value,
          ];
          final String? who = await showDialog<String>(
            context: context,
            builder: (BuildContext context) => SimpleDialog(
              key: const Key('gate-pick-friend'),
              title: Text(t('Dla kogo inne warunki?')),
              children: <Widget>[
                if (left.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(t('Wszyscy znajomi mają już swoje warunki.')),
                  ),
                for (final FriendProfile f in left)
                  SimpleDialogOption(
                    key: Key(
                      'gate-pick-'
                      '${PeerShareCodec.normalizeAddress(f.address)}',
                    ),
                    onPressed: () => Navigator.of(
                      context,
                    ).pop(PeerShareCodec.normalizeAddress(f.address)),
                    child: Text(social.nameFor(f)),
                  ),
              ],
            ),
          );
          if (who == null || !context.mounted) {
            return;
          }
          final GateTerms? terms = await editGateTerms(
            context,
            initial: gates.defaults,
            title: t('Brama dla: {name}', {'name': nameOf(who)}),
            member: member,
          );
          if (terms != null) {
            await intro.setGateFor(who, terms);
          }
        }

        return Padding(
          key: const Key('gate-settings'),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                t('Bramy do moich znajomych'),
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                t(
                  'Znajomy prosi, żebyś przedstawił(a) go komuś ze swoich '
                  'znajomych — to otwiera mu bramę. Ustal, czy robisz to za '
                  'darmo, czy za punkty, i czy chcesz o tym decydować.',
                ),
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.35,
                ),
              ),
              ListTile(
                key: const Key('gate-defaults'),
                contentPadding: EdgeInsets.zero,
                title: Text(t('Dla wszystkich')),
                subtitle: Text(gates.defaults.label),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => unawaited(() async {
                  final GateTerms? terms = await editGateTerms(
                    context,
                    initial: gates.defaults,
                    title: t('Brama dla wszystkich'),
                    member: member,
                  );
                  if (terms != null) {
                    await intro.setGateDefaults(terms);
                  }
                }()),
              ),
              for (final MapEntry<String, GateTerms> e
                  in gates.perFriend.entries)
                ListTile(
                  key: Key('gate-friend-${e.key}'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(nameOf(e.key)),
                  subtitle: Text(e.value.label),
                  onTap: () => unawaited(() async {
                    final GateTerms? terms = await editGateTerms(
                      context,
                      initial: e.value,
                      title: t('Brama dla: {name}', {'name': nameOf(e.key)}),
                      member: member,
                    );
                    if (terms != null) {
                      await intro.setGateFor(e.key, terms);
                    }
                  }()),
                  trailing: IconButton(
                    key: Key('gate-friend-remove-${e.key}'),
                    tooltip: t('Jak dla wszystkich'),
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => unawaited(intro.setGateFor(e.key, null)),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('gate-add-exception'),
                  onPressed: () => unawaited(addException()),
                  icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                  label: Text(t('Inne warunki dla znajomego')),
                ),
              ),
              SwitchListTile(
                key: const Key('gate-relay'),
                contentPadding: EdgeInsets.zero,
                value: gates.relay,
                title: Text(t('Pokazuj moje bramy dalej')),
                subtitle: Text(
                  t(
                    'Znajomi przekażą swoim znajomym (do {n} kroków), kogo '
                    'znasz i na jakich warunkach otwierasz bramę — dzięki '
                    'temu ktoś dalej znajdzie drogę przez Ciebie.',
                    {'n': kGateRelayDepth},
                  ),
                ),
                onChanged: (bool v) => unawaited(intro.setGateRelay(v)),
              ),
              if (!member)
                ZenInfo(
                  icon: Icons.info_outline_rounded,
                  text: t(
                    'Płatne bramy działają tylko między członkami piramidy '
                    '(punkty z portfela). Poza nią — tylko darmowe.',
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
