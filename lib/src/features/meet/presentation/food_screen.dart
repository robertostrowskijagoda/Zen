import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart'
    show pickImageBytes;
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/circle/food_model.dart';
import 'package:zen/src/features/meet/circle/food_providers.dart';
import 'package:zen/src/features/meet/circle/food_service.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/presentation/circle_screen.dart'
    show parseKittyCents;
import 'package:zen/src/features/meet/presentation/meet_thread_sheet.dart';
import 'package:zen/src/features/meet/presentation/safe_photo.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';

/// "Zen nie obsługuje płatności": shown wherever "Za pieniądze" is.
String get kFoodMoneyNote => t(
  'Zen nie obsługuje płatności. Kwotę rozliczacie sami — gotówką albo '
  'własną aplikacją do płatności.',
);

/// The private give/take line of a pair.
String foodBalanceText(String name, FoodBalance b) => t(
  '{name} częstuje Cię {got}×, Ty — {gave}× (widzisz tylko Ty)',
  {'name': name, 'got': b.got, 'gave': b.gave},
);

/// A time of an offer: the hour today, else day and hour.
String foodWhen(int millis, int now) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(millis);
  final DateTime n = DateTime.fromMillisecondsSinceEpoch(now);
  return d.year == n.year && d.month == n.month && d.day == n.day
      ? ZenFormat.time(d)
      : ZenFormat.dayMonthTime(d);
}

/// What the cook said about allergens, in a few words.
String foodAllergenText(FoodOffer o) => switch (o.allergenInfo) {
  FoodAllergenInfo.listed => t('Zawiera: {list}', {
    'list': o.allergens.map((FoodAllergen a) => a.label).join(', '),
  }),
  FoodAllergenInfo.none => t('Bez głównych alergenów'),
  FoodAllergenInfo.unknown => t('Alergeny: brak informacji'),
};

/// Shared food: the offers within reach, and "Podziel się jedzeniem" for
/// circle [circleId]; without a circle, "Gotuję dziś — dosiądź się".
class FoodScreen extends ConsumerWidget {
  const FoodScreen({this.circleId, super.key});

  /// The circle a new offer goes to (`null`: the list, and free seats).
  final String? circleId;

  static Future<void> open(BuildContext context, {String? circleId}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => FoodScreen(circleId: circleId),
        ),
      );

  /// "Gotuję dziś — dosiądź się": open seats at this person's table.
  static Future<void> openSeats(BuildContext context) =>
      FoodShareScreen.open(context, '', seats: true);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FoodService food = ref.watch(foodServiceProvider);
    final CircleService circles = ref.watch(circleServiceProvider);
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 3);
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[food, circles]),
      builder: (BuildContext context, Widget? _) {
        final String? id = circleId;
        final DinnerCircle? circle = id == null ? null : circles.circle(id);
        final List<FoodOffer> offers = food.offers();
        return Scaffold(
          key: const Key('food-screen'),
          appBar: AppBar(title: Text(t('Jedzenie do wzięcia'))),
          floatingActionButton: circle == null
              ? FloatingActionButton.extended(
                  key: const Key('food-seats'),
                  onPressed: () => unawaited(FoodScreen.openSeats(context)),
                  icon: const Icon(Icons.event_seat_rounded),
                  label: Text(t('Gotuję dziś')),
                )
              : FloatingActionButton.extended(
                  key: const Key('food-share'),
                  onPressed: () =>
                      unawaited(FoodShareScreen.open(context, circle.id)),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(t('Podziel się jedzeniem')),
                ),
          body: SelectionArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: <Widget>[
                ZenInfo(
                  icon: Icons.health_and_safety_rounded,
                  tone: tone,
                  text: t(
                    'Jedzenie od znajomych — Zen go nie sprawdza. Przy alergii '
                    'zapytaj, zanim zjesz. Coś nie tak? Zgłoś ofertę.',
                  ),
                ),
                const SizedBox(height: 8),
                for (final (FoodOffer o, String who, String name)
                    in food.toVouch)
                  _VouchCard(food: food, offer: o, who: who, name: name),
                if (offers.isEmpty)
                  ZenEmpty(
                    icon: Icons.takeout_dining_rounded,
                    tone: tone,
                    title: t('Nikt teraz niczym się nie dzieli'),
                    text: circle == null
                        ? null
                        : t('Zostało Ci jedzenie? Poczęstuj kółko.'),
                  )
                else
                  for (final FoodOffer o in offers)
                    FoodOfferCard(key: Key('food-offer-${o.id}'), offer: o),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One offer: what, when, how, and the actions of the cook or the one
/// who takes.
class FoodOfferCard extends ConsumerWidget {
  const FoodOfferCard({required this.offer, super.key});

  final FoodOffer offer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FoodService food = ref.watch(foodServiceProvider);
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 3);
    final FoodOffer o = offer;
    final int now = food.now;
    final bool mine = food.isMine(o);
    final String? via = food.viaOf(o.id);
    final String cook = food.cookNameOf(o);
    final String photo = o.photo ?? '';
    final String where = via != null
        ? t('{cook} · przez {via}', {
            'cook': cook,
            'via': ref.read(eventServiceProvider).host.nameOf(via),
          })
        : o.circleName.isEmpty
        ? cook
        : t('{cook} · {circle}', {'cook': cook, 'circle': o.circleName});
    final String time = o.expiredAt(now)
        ? t('Zakończone')
        : o.readyFrom > now
        ? t('od {from} do {until}', {
            'from': foodWhen(o.readyFrom, now),
            'until': foodWhen(o.readyUntil, now),
          })
        : t('do {until}', {'until': foodWhen(o.readyUntil, now)});
    final FoodBalance balance = food.balanceWith(o.cook);
    return ZenCard(
      tone: mine ? tone : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (photo.isNotEmpty) ...<Widget>[
                ClipRRect(
                  borderRadius: context.zenRadius(12),
                  child: SizedBox(
                    width: 64,
                    height: 64,
                    child: SafePhoto(
                      data: photo,
                      clean: !mine,
                      icon: Icons.restaurant_rounded,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ] else ...<Widget>[
                ZenIconBadge(
                  icon: o.seats
                      ? Icons.event_seat_rounded
                      : Icons.takeout_dining_rounded,
                  tone: tone,
                  size: 40,
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      o.title,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$where · $time',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: t('Więcej'),
                onSelected: (String v) async {
                  if (v == 'close') {
                    await food.close(o.id);
                  } else if (v == 'report' && context.mounted) {
                    await reportContent(
                      context,
                      ref,
                      authorAddress: o.cook,
                      text: o.note.isEmpty ? o.title : '${o.title}\n${o.note}',
                      header: t('Oferta jedzenia'),
                      contentId: 'food:${o.id}',
                      deleteLocal: () => food.hide(o.id),
                    );
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  if (mine && !o.closed && !o.expiredAt(now))
                    PopupMenuItem<String>(
                      value: 'close',
                      child: Text(t('Zakończ')),
                    ),
                  if (!mine)
                    PopupMenuItem<String>(
                      value: 'report',
                      child: Text(t('Zgłoś')),
                    ),
                ],
              ),
            ],
          ),
          if (o.note.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              o.note,
              style: TextStyle(color: zen.textPrimary, fontSize: 13.5),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              ZenPill(
                tone: tone,
                text: o.seats
                    ? (o.left == 0
                          ? t('Komplet przy stole')
                          : t('Wolne miejsca: {left} z {all}', {
                              'left': o.left,
                              'all': o.portions,
                            }))
                    : o.left == 0
                    ? t('Wszystko rozdane')
                    : t('{left} z {all} porcji', {
                        'left': o.left,
                        'all': o.portions,
                      }),
              ),
              for (final FoodMode m in o.modes) ZenPill(text: m.label),
              for (final FoodExchange x in o.exchanges)
                ZenPill(
                  text: switch (x) {
                    FoodExchange.points => t('{amount} pkt za porcję', {
                      'amount': food.points.format(o.points),
                    }),
                    FoodExchange.money when o.moneyLabel.isNotEmpty =>
                      '${x.label}: ${o.moneyLabel}',
                    _ => x.label,
                  },
                ),
              for (final FoodDiet d in o.diet)
                ZenPill(tone: zen.success, text: d.label),
              ZenPill(
                tone: o.allergenInfo == FoodAllergenInfo.unknown
                    ? zen.warning
                    : null,
                icon: Icons.warning_amber_rounded,
                text: foodAllergenText(o),
              ),
            ],
          ),
          if (!mine && !balance.isEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              foodBalanceText(cook, balance),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
          ],
          const SizedBox(height: 10),
          if (mine)
            _CookRequests(offer: o, food: food)
          else
            _TakerActions(offer: o, food: food),
        ],
      ),
    );
  }
}

/// The one who takes: "Biorę", then the answer.
class _TakerActions extends StatelessWidget {
  const _TakerActions({required this.offer, required this.food});

  final FoodOffer offer;
  final FoodService food;

  Future<void> _take(BuildContext context) async {
    final FoodOffer o = offer;
    final List<FoodExchange> ways = <FoodExchange>[
      for (final FoodExchange x in FoodExchange.values)
        if (o.exchanges.contains(x) &&
            (x != FoodExchange.points || food.canPayPoints(o)))
          x,
    ];
    final List<FoodMode> modes = <FoodMode>[
      for (final FoodMode m in FoodMode.values)
        if (o.modes.contains(m)) m,
    ];
    if (ways.isEmpty || modes.isEmpty) {
      return;
    }
    int portions = 1;
    FoodMode mode = modes.first;
    FoodExchange exchange = ways.first;
    final int most = o.left < kFoodMaxPerRequest ? o.left : kFoodMaxPerRequest;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ZenColors zen = ZenColors.of(context);
          final String? info = switch (exchange) {
            FoodExchange.free => null,
            FoodExchange.swap => t(
              'Nic teraz — następnym razem Ty częstujesz. Zen liczy tylko '
              'u Was dwojga, kto kogo ile razy.',
            ),
            FoodExchange.points => t(
              '{amount} pkt z Twojego konta w piramidzie, po przyjęciu.',
              {'amount': food.points.format(o.pointsFor(portions))},
            ),
            FoodExchange.money =>
              o.moneyLabel.isEmpty
                  ? kFoodMoneyNote
                  : '${o.moneyLabel}. $kFoodMoneyNote',
          };
          return AlertDialog(
            title: Text(
              o.seats
                  ? t('Dosiądę się: {title}', {'title': o.title})
                  : t('Biorę: {title}', {'title': o.title}),
            ),
            content: SizedBox(
              width: 380,
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  if (most > 1)
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            o.seats
                                ? tn(
                                    portions,
                                    one: '{n} miejsce',
                                    few: '{n} miejsca',
                                    many: '{n} miejsc',
                                  )
                                : tn(
                                    portions,
                                    one: '{n} porcja',
                                    few: '{n} porcje',
                                    many: '{n} porcji',
                                  ),
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: t('Mniej'),
                          onPressed: portions > 1
                              ? () => set(() => portions--)
                              : null,
                          icon: const Icon(Icons.remove_rounded),
                        ),
                        IconButton(
                          tooltip: t('Więcej'),
                          onPressed: portions < most
                              ? () => set(() => portions++)
                              : null,
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    ),
                  if (modes.length > 1) ...<Widget>[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final FoodMode m in modes)
                          ChoiceChip(
                            label: Text(m.label),
                            selected: mode == m,
                            onSelected: (_) => set(() => mode = m),
                          ),
                      ],
                    ),
                  ],
                  if (ways.length > 1) ...<Widget>[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final FoodExchange x in ways)
                          ChoiceChip(
                            label: Text(x.label),
                            selected: exchange == x,
                            onSelected: (_) => set(() => exchange = x),
                          ),
                      ],
                    ),
                  ],
                  if (info != null) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      info,
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    foodAllergenText(o),
                    style: TextStyle(
                      color: o.allergenInfo == FoodAllergenInfo.unknown
                          ? zen.warning
                          : zen.textSecondary,
                      fontSize: 13,
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
                key: const Key('food-take-confirm'),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(o.seats ? t('Dosiądę się') : t('Biorę')),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) {
      return;
    }
    final bool sent = await food.ask(
      o.id,
      mode: mode,
      exchange: exchange,
      portions: portions,
    );
    if (!sent && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('Już nie ma tylu porcji.'))));
    }
  }

  Future<void> _pay(BuildContext context) async {
    final bool ok = await food.payPoints(offer.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? t('Punkty wysłane — przelew zatwierdzą skarbnicy.')
                : t('Nie udało się wysłać punktów (za mało na koncie?).'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final FoodOffer o = offer;
    final FoodRequest? r = food.myRequest(o.id);
    final TextStyle note = TextStyle(color: zen.textSecondary, fontSize: 13.5);
    final Widget cancel = TextButton(
      onPressed: () => unawaited(food.cancelAsk(o.id)),
      child: Text(t('Wycofaj')),
    );
    switch (r?.state) {
      case null || FoodRequestState.cancelled:
        if (!o.openAt(food.now)) {
          return const SizedBox.shrink();
        }
        final bool onlyPoints =
            o.exchanges.length == 1 &&
            o.exchanges.contains(FoodExchange.points) &&
            !food.canPayPoints(o);
        if (onlyPoints) {
          return Text(
            t('Tylko za punkty — dla osób z tej samej piramidy.'),
            style: note,
          );
        }
        return FilledButton.icon(
          key: Key('food-take-${o.id}'),
          onPressed: () => unawaited(_take(context)),
          icon: Icon(
            o.seats ? Icons.event_seat_rounded : Icons.restaurant_rounded,
          ),
          label: Text(o.seats ? t('Dosiądę się') : t('Biorę')),
        );
      case FoodRequestState.pending:
        return Row(
          children: <Widget>[
            Expanded(
              child: Text(
                food.viaOf(o.id) != null && o.seats
                    ? t('Czekasz na odpowiedź (najpierw ręczy {via}).', {
                        'via': food.host.nameOf(food.viaOf(o.id)!),
                      })
                    : t('Czekasz na odpowiedź.'),
                style: note,
              ),
            ),
            cancel,
          ],
        );
      case FoodRequestState.accepted:
        final FoodRequest req = r!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              t('Przyjęte: {portions} · {mode}', {
                'portions': tn(
                  req.portions,
                  one: '{n} porcja',
                  few: '{n} porcje',
                  many: '{n} porcji',
                ),
                'mode': req.mode.label,
              }),
              style: TextStyle(
                color: zen.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Icon(Icons.place_rounded, size: 18, color: zen.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: SelectableText(
                    req.place.isEmpty
                        ? t('Miejsce ustalcie na czacie.')
                        : req.place,
                    key: const Key('food-place'),
                    style: note,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            FoodChatButton(food: food, offer: o),
            if (req.exchange == FoodExchange.points) ...<Widget>[
              const SizedBox(height: 6),
              if (req.paid)
                Text(t('Punkty wysłane.'), style: note)
              else
                FilledButton.tonal(
                  key: const Key('food-pay'),
                  onPressed: () => unawaited(_pay(context)),
                  child: Text(
                    t('Zapłać {amount} pkt', {
                      'amount': food.points.format(o.pointsFor(req.portions)),
                    }),
                  ),
                ),
            ],
            if (req.exchange == FoodExchange.money) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                o.moneyLabel.isEmpty
                    ? kFoodMoneyNote
                    : '${o.moneyLabel}. $kFoodMoneyNote',
                style: note,
              ),
            ],
            if (req.exchange == FoodExchange.swap) ...<Widget>[
              const SizedBox(height: 6),
              Text(t('Następnym razem Ty częstujesz.'), style: note),
            ],
            Align(alignment: Alignment.centerRight, child: cancel),
          ],
        );
      case FoodRequestState.declined:
        return Text(t('Tym razem nie.'), style: note);
      case FoodRequestState.done || FoodRequestState.noShow:
        return Text(t('Smacznego!'), style: note);
    }
  }
}

/// The cook: requests to accept or decline, then the hand-over.
class _CookRequests extends ConsumerWidget {
  const _CookRequests({required this.offer, required this.food});

  final FoodOffer offer;
  final FoodService food;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final FoodOffer o = offer;
    final List<FoodRequest> list =
        o.requests.values
            .where((FoodRequest r) => r.state != FoodRequestState.cancelled)
            .toList()
          ..sort((FoodRequest a, FoodRequest b) => a.at.compareTo(b.at));
    if (list.isEmpty) {
      return Text(
        o.place.isEmpty
            ? t('Nikt jeszcze nie prosił.')
            : t(
                'Nikt jeszcze nie prosił. Miejsce ({place}) zobaczą tylko '
                'przyjęte osoby.',
                {'place': o.place},
              ),
        style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
      );
    }
    final String Function(String) nameOf = ref
        .read(eventServiceProvider)
        .host
        .nameOf;
    return Column(
      children: <Widget>[
        for (final FoodRequest r in list)
          Padding(
            key: Key('food-req-${r.address}'),
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  r.via == null
                      ? r.name
                      : r.vouched
                      ? t('{name}, ręczy {via}', {
                          'name': r.name,
                          'via': nameOf(r.via!),
                        })
                      : t('{name}, przez {via}', {
                          'name': r.name,
                          'via': nameOf(r.via!),
                        }),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  <String>[
                    tn(
                      r.portions,
                      one: '{n} porcja',
                      few: '{n} porcje',
                      many: '{n} porcji',
                    ),
                    r.mode.label,
                    r.exchange.label,
                    // Only once the order is in the pyramid.
                    if (food.pointsIn(o, r)) t('punkty wysłane'),
                  ].join(' · '),
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
                if (!food.balanceWith(r.address).isEmpty)
                  Text(
                    foodBalanceText(r.name, food.balanceWith(r.address)),
                    style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                  ),
                if (food.noShowsOf(r.address) > 0)
                  Text(
                    t('Wcześniej nie przyszło: {n}× (widzisz tylko Ty)', {
                      'n': food.noShowsOf(r.address),
                    }),
                    style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                  ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: switch (r.state) {
                    FoodRequestState.pending => <Widget>[
                      FilledButton(
                        key: Key('food-accept-${r.address}'),
                        onPressed: r.portions <= o.left && !o.closed
                            ? () => unawaited(food.accept(o.id, r.address))
                            : null,
                        child: Text(t('Przyjmij')),
                      ),
                      TextButton(
                        onPressed: () =>
                            unawaited(food.decline(o.id, r.address)),
                        child: Text(t('Odmów')),
                      ),
                    ],
                    FoodRequestState.accepted => <Widget>[
                      FoodChatButton(food: food, offer: o, who: r.address),
                      FilledButton.tonal(
                        key: Key('food-done-${r.address}'),
                        onPressed: () =>
                            unawaited(food.handedOver(o.id, r.address)),
                        child: Text(
                          r.mode == FoodMode.dineIn
                              ? t('Było, zjedzone')
                              : t('Odebrane'),
                        ),
                      ),
                      TextButton(
                        onPressed: () =>
                            unawaited(food.markNoShow(o.id, r.address)),
                        child: Text(t('Nie przyszło')),
                      ),
                    ],
                    FoodRequestState.done => <Widget>[
                      Text(
                        t('Oddane'),
                        style: TextStyle(color: zen.success, fontSize: 13),
                      ),
                      FoodChatButton(food: food, offer: o, who: r.address),
                    ],
                    FoodRequestState.declined => <Widget>[
                      Text(
                        t('Odmówione'),
                        style: TextStyle(color: zen.textMuted, fontSize: 13),
                      ),
                    ],
                    FoodRequestState.noShow => <Widget>[
                      Text(
                        t('Nie przyszło'),
                        style: TextStyle(color: zen.textMuted, fontSize: 13),
                      ),
                    ],
                    FoodRequestState.cancelled => const <Widget>[],
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Napisz": the small chat of an accepted request (sealed for the two of
/// them), with the unread count.
class FoodChatButton extends StatelessWidget {
  const FoodChatButton({
    required this.food,
    required this.offer,
    this.who,
    super.key,
  });

  final FoodService food;
  final FoodOffer offer;

  /// The one who asked (the cook's side); `null` on the asker's side.
  final String? who;

  @override
  Widget build(BuildContext context) {
    final FoodOffer o = offer;
    if (!food.canChat(o.id, who: who)) {
      return const SizedBox.shrink();
    }
    final int unread = food.unread(o.id, who: who);
    final String other = who == null
        ? food.cookNameOf(o)
        : o.requests[who!]?.name ?? t('ktoś');
    return TextButton.icon(
      key: Key('food-chat-${o.id}-${who ?? 'cook'}'),
      onPressed: () => unawaited(
        showMeetThreadSheet(
          context,
          title: t('{name} · {title}', {'name': other, 'title': o.title}),
          listenable: food,
          messages: () => food.thread(o.id, who: who),
          nameOf: (String _) => other,
          send: (String text) => food.sendChat(o.id, text, who: who),
          empty: t('Np. „Dzwoń domofonem 12” albo „Spóźnię się 10 min”.'),
          onSeen: () => unawaited(food.markRead(o.id, who: who)),
        ),
      ),
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text('$unread'),
        child: const Icon(Icons.chat_bubble_outline_rounded),
      ),
      label: Text(t('Napisz')),
    );
  }
}

/// As the friend in between of "Gotuję dziś — dosiądź się": a friend of
/// ours wants a seat; their request goes on only with "Ręczę".
class _VouchCard extends StatelessWidget {
  const _VouchCard({
    required this.food,
    required this.offer,
    required this.who,
    required this.name,
  });

  final FoodService food;
  final FoodOffer offer;
  final String who;
  final String name;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      key: Key('food-vouch-${offer.id}-$who'),
      tone: zen.warning,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t('{name} chce się dosiąść u {cook}', {
              'name': name,
              'cook': food.cookNameOf(offer),
            }),
            style: TextStyle(
              color: zen.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t(
              '„{title}”. {cook} nie zna tej osoby — dostanie prośbę tylko, '
              'jeśli za nią ręczysz.',
              {'title': offer.title, 'cook': food.cookNameOf(offer)},
            ),
            style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton(
                key: Key('food-vouch-yes-$who'),
                onPressed: () => unawaited(food.vouch(offer.id, who, true)),
                child: Text(t('Ręczę')),
              ),
              OutlinedButton(
                onPressed: () => unawaited(food.vouch(offer.id, who, false)),
                child: Text(t('Nie tym razem')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Podziel się jedzeniem": the form for a new offer in circle
/// [circleId].
class FoodShareScreen extends ConsumerStatefulWidget {
  const FoodShareScreen({
    required this.circleId,
    this.seats = false,
    super.key,
  });

  /// The circle ('' for free seats without one).
  final String circleId;

  /// "Gotuję dziś — dosiądź się": free seats at this person's table.
  final bool seats;

  static Future<void> open(
    BuildContext context,
    String circleId, {
    bool seats = false,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          FoodShareScreen(circleId: circleId, seats: seats),
    ),
  );

  @override
  ConsumerState<FoodShareScreen> createState() => _FoodShareScreenState();
}

class _FoodShareScreenState extends ConsumerState<FoodShareScreen> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _note = TextEditingController();
  final TextEditingController _place = TextEditingController();
  final TextEditingController _points = TextEditingController();
  final TextEditingController _money = TextEditingController();
  late DateTime _from = widget.seats ? _tonight() : DateTime.now();
  late DateTime _until = _from.add(Duration(hours: widget.seats ? 2 : 4));
  int _portions = 2;
  String? _photo;
  late final Set<FoodMode> _modes = <FoodMode>{
    widget.seats ? FoodMode.dineIn : FoodMode.takeaway,
  };
  final Set<FoodExchange> _exchanges = <FoodExchange>{FoodExchange.free};
  final Set<FoodDiet> _diet = <FoodDiet>{};
  final Set<FoodAllergen> _allergens = <FoodAllergen>{};
  FoodAllergenInfo? _allergenInfo;
  late FoodReach _reach = widget.circleId.isEmpty
      ? FoodReach.friends
      : FoodReach.circle;

  /// Today at 19:00, or in an hour when that is past.
  static DateTime _tonight() {
    final DateTime now = DateTime.now();
    final DateTime seven = DateTime(now.year, now.month, now.day, 19);
    return seven.isAfter(now)
        ? seven
        : DateTime(now.year, now.month, now.day, now.hour + 1);
  }

  bool _sending = false;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    _place.dispose();
    _points.dispose();
    _money.dispose();
    super.dispose();
  }

  int? get _pointsPrice {
    final int? v = parseKittyCents(_points.text);
    return v == null || v <= 0 ? null : v;
  }

  bool get _timeOk =>
      _until.isAfter(_from) &&
      _until.isAfter(DateTime.now()) &&
      _until.difference(_from) <= kFoodMaxWindow;

  bool get _ready =>
      _title.text.trim().isNotEmpty &&
      _modes.isNotEmpty &&
      _exchanges.isNotEmpty &&
      FoodOffer.allergensConsidered(_allergenInfo, _allergens) &&
      (!_exchanges.contains(FoodExchange.points) || _pointsPrice != null) &&
      _timeOk;

  Future<DateTime?> _pick(DateTime initial) async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(kFoodMaxAhead + kFoodMaxWindow),
    );
    if (d == null || !mounted) {
      return null;
    }
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null) {
      return null;
    }
    return DateTime(d.year, d.month, d.day, time.hour, time.minute);
  }

  Future<void> _pickPhoto() async {
    final List<Uint8List> picked;
    try {
      picked = await pickImageBytes(limit: 1);
    } on Object {
      return;
    }
    if (picked.isEmpty) {
      return;
    }
    final Uint8List? jpeg = await compute(compressFlatPhoto, picked.first);
    if (!mounted) {
      return;
    }
    if (jpeg == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Tego zdjęcia nie da się użyć (format?).'))),
      );
      return;
    }
    setState(() => _photo = base64Encode(jpeg));
  }

  Future<void> _submit() async {
    if (!_ready || _sending) {
      return;
    }
    setState(() => _sending = true);
    final FoodOffer? o = await ref
        .read(foodServiceProvider)
        .share(
          circleId: widget.circleId,
          title: _title.text,
          note: _note.text,
          photo: _photo,
          portions: _portions,
          readyFrom: _from.millisecondsSinceEpoch,
          readyUntil: _until.millisecondsSinceEpoch,
          modes: _modes,
          exchanges: _exchanges,
          allergenInfo: _allergenInfo,
          allergens: _allergens,
          diet: _diet,
          pointsPerPortion: _pointsPrice ?? 0,
          moneyLabel: _money.text,
          reach: _reach,
          place: _place.text,
          seats: widget.seats,
        );
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    if (o == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('Uzupełnij nazwę, odbiór, rozliczenie, alergeny i czas.'),
          ),
        ),
      );
      return;
    }
    Navigator.of(context).pop();
  }

  Widget _chips<T>(
    Iterable<T> values,
    String Function(T) label,
    bool Function(T) selected,
    void Function(T, bool) onChanged,
  ) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: <Widget>[
      for (final T v in values)
        FilterChip(
          label: Text(label(v)),
          selected: selected(v),
          onSelected: (bool on) => setState(() => onChanged(v, on)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 3);
    final FoodService food = ref.watch(foodServiceProvider);
    final bool canPoints = food.points.myKey != null;
    final bool seats = widget.seats;
    final DinnerCircle? circle = widget.circleId.isEmpty
        ? null
        : ref.watch(circleServiceProvider).circle(widget.circleId);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final TextStyle hint = TextStyle(color: zen.textSecondary, fontSize: 12.5);
    return Scaffold(
      key: const Key('food-share-screen'),
      appBar: AppBar(
        title: Text(
          seats ? t('Gotuję dziś — dosiądź się') : t('Podziel się jedzeniem'),
        ),
      ),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            TextField(
              key: const Key('food-title'),
              controller: _title,
              maxLength: kFoodMaxTitle,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: seats ? t('Co gotujesz') : t('Co'),
                hintText: t('np. Pierogi ruskie, zupa dyniowa'),
                prefixIcon: const Icon(Icons.restaurant_rounded),
              ),
            ),
            TextField(
              controller: _note,
              maxLength: kFoodMaxNote,
              maxLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: t('Kilka słów (opcjonalnie)'),
              ),
            ),
            Row(
              children: <Widget>[
                if (_photo != null) ...<Widget>[
                  ClipRRect(
                    borderRadius: context.zenRadius(12),
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: SafePhoto(data: _photo!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => setState(() => _photo = null),
                    child: Text(t('Usuń zdjęcie')),
                  ),
                ] else
                  TextButton.icon(
                    onPressed: () => unawaited(_pickPhoto()),
                    icon: const Icon(Icons.add_a_photo_rounded),
                    label: Text(t('Dodaj zdjęcie (opcjonalnie)')),
                  ),
              ],
            ),
            if (seats)
              ZenInfo(
                icon: Icons.event_seat_rounded,
                tone: tone,
                text: t(
                  'Wolne miejsca przy Twoim stole dziś. Pierwsze prośby '
                  'przyjmujesz Ty, adres dostaje tylko przyjęty gość. Znajomi '
                  'znajomych proszą przez kogoś, kto za nich ręczy.',
                ),
              ),
            ZenSection(
              seats ? t('Ile wolnych miejsc') : t('Ile porcji'),
              top: 12,
            ),
            Row(
              children: <Widget>[
                IconButton(
                  tooltip: t('Mniej'),
                  onPressed: _portions > 1
                      ? () => setState(() => _portions--)
                      : null,
                  icon: const Icon(Icons.remove_rounded),
                ),
                Text(
                  seats
                      ? tn(
                          _portions,
                          one: '{n} miejsce',
                          few: '{n} miejsca',
                          many: '{n} miejsc',
                        )
                      : tn(
                          _portions,
                          one: '{n} porcja',
                          few: '{n} porcje',
                          many: '{n} porcji',
                        ),
                  key: const Key('food-portions'),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                IconButton(
                  tooltip: t('Więcej'),
                  onPressed: _portions < (seats ? 8 : kFoodMaxPortions)
                      ? () => setState(() => _portions++)
                      : null,
                  icon: const Icon(Icons.add_rounded),
                ),
              ],
            ),
            ZenSection(t('Kiedy'), top: 12),
            ZenGroup(
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.schedule_rounded),
                  title: Text(seats ? t('Kolacja o') : t('Gotowe od')),
                  trailing: Text(foodWhen(_from.millisecondsSinceEpoch, now)),
                  onTap: () async {
                    final DateTime? d = await _pick(_from);
                    if (d != null) {
                      setState(() {
                        _from = d;
                        if (!_until.isAfter(d)) {
                          _until = d.add(const Duration(hours: 4));
                        }
                      });
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.timer_off_rounded),
                  title: Text(t('Do')),
                  subtitle: Text(t('Potem oferta zamyka się sama.')),
                  trailing: Text(foodWhen(_until.millisecondsSinceEpoch, now)),
                  onTap: () async {
                    final DateTime? d = await _pick(_until);
                    if (d != null) {
                      setState(() => _until = d);
                    }
                  },
                ),
              ],
            ),
            if (!_timeOk)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 0, 0),
                child: Text(
                  t(
                    '„Do” musi być później niż teraz i „od”, najwyżej 48 godzin.',
                  ),
                  style: TextStyle(color: zen.warning, fontSize: 12.5),
                ),
              ),
            ZenSection(seats ? t('Gdzie') : t('Jak'), top: 16),
            if (!seats)
              _chips<FoodMode>(
                FoodMode.values,
                (FoodMode m) => m.label,
                _modes.contains,
                (FoodMode m, bool on) => on ? _modes.add(m) : _modes.remove(m),
              ),
            if (_modes.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              TextField(
                controller: _place,
                maxLength: kFoodMaxPlace,
                decoration: InputDecoration(
                  labelText: t('Gdzie (adres, piętro)'),
                  helperText: t('Zobaczą to tylko osoby, które przyjmiesz.'),
                  prefixIcon: const Icon(Icons.place_rounded),
                ),
              ),
            ],
            ZenSection(t('W zamian'), top: 16),
            _chips<FoodExchange>(
              <FoodExchange>[
                for (final FoodExchange x in FoodExchange.values)
                  if (x != FoodExchange.points || canPoints) x,
              ],
              (FoodExchange x) => x.label,
              _exchanges.contains,
              (FoodExchange x, bool on) =>
                  on ? _exchanges.add(x) : _exchanges.remove(x),
            ),
            const SizedBox(height: 6),
            Text(
              t(
                'Możesz zaznaczyć kilka — biorący wybiera. „Dziś Ty, jutro ja”: '
                'Zen liczy tylko u Was, kto kogo częstował.',
              ),
              style: hint,
            ),
            if (_exchanges.contains(FoodExchange.points))
              TextField(
                key: const Key('food-points'),
                controller: _points,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: t('Punkty za porcję'),
                  helperText: t('Tylko dla osób z Twojej piramidy.'),
                ),
              ),
            if (_exchanges.contains(FoodExchange.money)) ...<Widget>[
              TextField(
                controller: _money,
                maxLength: kFoodMaxMoneyLabel,
                decoration: InputDecoration(
                  labelText: t('Kwota (np. 10 zł za porcję)'),
                ),
              ),
              ZenInfo(
                icon: Icons.payments_outlined,
                tone: zen.warning,
                text: kFoodMoneyNote,
              ),
            ],
            ZenSection(t('Dieta i alergeny'), top: 16),
            _chips<FoodDiet>(
              FoodDiet.values,
              (FoodDiet d) => d.label,
              _diet.contains,
              (FoodDiet d, bool on) => on ? _diet.add(d) : _diet.remove(d),
            ),
            const SizedBox(height: 10),
            Text(t('Alergeny — wybierz jedno:'), style: hint),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                ChoiceChip(
                  key: const Key('food-allergens-listed'),
                  label: Text(t('Zawiera…')),
                  selected: _allergenInfo == FoodAllergenInfo.listed,
                  onSelected: (_) =>
                      setState(() => _allergenInfo = FoodAllergenInfo.listed),
                ),
                ChoiceChip(
                  key: const Key('food-allergens-none'),
                  label: Text(t('Bez głównych alergenów')),
                  selected: _allergenInfo == FoodAllergenInfo.none,
                  onSelected: (_) =>
                      setState(() => _allergenInfo = FoodAllergenInfo.none),
                ),
                ChoiceChip(
                  key: const Key('food-allergens-unknown'),
                  label: Text(t('Brak informacji')),
                  selected: _allergenInfo == FoodAllergenInfo.unknown,
                  onSelected: (_) =>
                      setState(() => _allergenInfo = FoodAllergenInfo.unknown),
                ),
              ],
            ),
            if (_allergenInfo == FoodAllergenInfo.listed) ...<Widget>[
              const SizedBox(height: 8),
              _chips<FoodAllergen>(
                FoodAllergen.values,
                (FoodAllergen a) => a.label,
                _allergens.contains,
                (FoodAllergen a, bool on) =>
                    on ? _allergens.add(a) : _allergens.remove(a),
              ),
            ],
            ZenSection(t('Kto widzi'), top: 16),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final FoodReach r in FoodReach.values)
                  if (circle != null || r != FoodReach.circle)
                    ChoiceChip(
                      key: Key('food-reach-${r.code}'),
                      label: Text(circle == null ? r.seatsLabel : r.label),
                      selected: _reach == r,
                      onSelected: (_) => setState(() => _reach = r),
                    ),
              ],
            ),
            if (circle != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(t('Kółko: {name}', {'name': circle.name}), style: hint),
            ],
            const SizedBox(height: 16),
            ZenInfo(
              icon: Icons.health_and_safety_rounded,
              tone: tone,
              text: t(
                'Dziel się tylko świeżym jedzeniem, trzymanym w lodówce albo '
                'ciepłym prosto z garnka. Opisz alergeny. Po godzinie „do” '
                'oferta zamyka się sama.',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('food-submit'),
              onPressed: _ready && !_sending
                  ? () => unawaited(_submit())
                  : null,
              icon: Icon(
                seats ? Icons.event_seat_rounded : Icons.takeout_dining_rounded,
              ),
              label: Text(seats ? t('Zaproś do stołu') : t('Udostępnij')),
            ),
          ],
        ),
      ),
    );
  }
}
