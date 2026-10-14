import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';

/// "12,50" → 1250 (hundredths), or null. Spaces of any kind are ignored,
/// so what [formatMoney] wrote ("1 000,00") reads back.
int? parseMoney(String text) {
  final String t = text.replaceAll(RegExp(r'\s'), '').replaceAll('.', ',');
  final List<String> parts = t.split(',');
  if (parts.isEmpty || parts.length > 2) {
    return null;
  }
  final int? whole = int.tryParse(parts[0].isEmpty ? '0' : parts[0]);
  final int? frac = parts.length == 2
      ? int.tryParse(parts[1].padRight(2, '0').substring(0, 2))
      : 0;
  if (whole == null ||
      frac == null ||
      whole < 0 ||
      frac < 0 ||
      whole > kPyrMaxAmount ~/ 100) {
    // Also nothing that could wrap around a 64-bit number.
    return null;
  }
  return whole * 100 + frac;
}

/// Asks again who this is before money leaves (§14.1 point 4): the app
/// password or biometrics, when the app has a password (otherwise yes).
Future<bool> confirmPayment(BuildContext context) => confirmSensitiveAccess(
  context,
  reason: 'Wysyłasz pieniądze. Potwierdź, że to Ty.',
);

/// "Za 100,00 → 95,00": a rate as people read it.
String fxRateText(PyrFxRate r) =>
    'za 100,00 → ${formatMoney(r.payout(10000))}'
    '${r.max > 0 ? ' (najwyżej ${formatMoney(r.max)} naraz)' : ''}';

/// Picks a member of the pyramid.
Future<String?> pickMember(
  BuildContext context,
  PyramidState s, {
  String? except,
  String title = 'Wybierz osobę',
}) async {
  final List<PyrMember> list =
      s.members.values
          .where((PyrMember m) => s.isMember(m.key) && m.key != except)
          .toList()
        ..sort(
          (PyrMember a, PyrMember b) =>
              a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => SimpleDialog(
      title: Text(title),
      children: <Widget>[
        for (final PyrMember m in list)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(m.key),
            child: Row(
              children: <Widget>[
                PyrAvatar(text: pyrInitial(m.name), size: 32),
                const SizedBox(width: 12),
                Expanded(child: Text(pyrWho(s, m.key))),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Whose account [key] is.
String pyrAccountName(PyramidState s, String key) =>
    s.members[key]?.name ?? '?';

/// Asks for an amount (and a title when [withMemo]); null when cancelled
/// or not a positive amount. With [confirmSend] (money about to leave),
/// asks again who this is ([confirmPayment]).
Future<(int, String)?> askAmount(
  BuildContext context, {
  required String title,
  String? info,
  bool withMemo = false,
  String memoHint = 'np. za zakupy',
  Key? fieldKey,
  bool confirmSend = true,
}) async {
  final TextEditingController amount = TextEditingController();
  final TextEditingController memo = TextEditingController();
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (info != null) ...<Widget>[
              ZenInfo(icon: Icons.info_outline_rounded, text: info),
              const SizedBox(height: 12),
            ],
            TextField(
              key: fieldKey,
              controller: amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Kwota',
                hintText: '0,00',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
            if (withMemo) ...<Widget>[
              const SizedBox(height: 14),
              TextField(
                controller: memo,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Tytuł',
                  hintText: memoHint,
                  prefixIcon: const Icon(Icons.notes_rounded),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Dalej'),
        ),
      ],
    ),
  );
  final int? value = parseMoney(amount.text);
  final String m = memo.text.trim();
  disposeLater(amount);
  disposeLater(memo);
  if (ok != true || value == null || value <= 0 || !context.mounted) {
    return null;
  }
  if (confirmSend && !await confirmPayment(context)) {
    return null;
  }
  return (value, m);
}

/// Money (§23) and the access market (§24).
class PyramidWallet extends StatelessWidget {
  const PyramidWallet({
    required this.pyr,
    required this.s,
    required this.me,
    super.key,
  });

  final PyramidService pyr;
  final PyramidState s;
  final String me;

  Future<void> _pay(BuildContext context) async {
    final String? to = await pickMember(
      context,
      s,
      except: me,
      title: 'Komu zapłacić?',
    );
    if (to == null || !context.mounted) {
      return;
    }
    final TextEditingController amount = TextEditingController();
    final TextEditingController memo = TextEditingController();
    bool conditional = false;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) => AlertDialog(
          title: Text('Przelew dla ${s.members[to]?.name}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(height: 4),
                TextField(
                  key: const Key('pyr-amount'),
                  controller: amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Kwota',
                    hintText: '0,00',
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: memo,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Tytuł',
                    hintText: 'np. za zakupy',
                    prefixIcon: Icon(Icons.notes_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: conditional,
                  title: const Text('Warunkowo'),
                  subtitle: const Text(
                    'Pieniądze czekają, aż odbiorca przyjmie (albo wrócą).',
                  ),
                  onChanged: (bool v) => set(() => conditional = v),
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
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Zapłać'),
            ),
          ],
        ),
      ),
    );
    final int? value = parseMoney(amount.text);
    final String m = memo.text;
    disposeLater(amount);
    disposeLater(memo);
    if (ok != true || value == null || value <= 0 || !context.mounted) {
      return;
    }
    if (!await confirmPayment(context)) {
      return;
    }
    final PyramidRecord? order = await pyr.pay(
      to,
      value,
      memo: m,
      condBy: conditional ? to : null,
    );
    if (context.mounted) {
      snack(
        context,
        order == null
            ? 'Nie można teraz (poprzedni przelew jeszcze czeka?).'
            : 'Zlecenie poszło do skarbników — ważne przy podpisach ${s.treasurerMajority} z ${s.treasurers.length}.',
      );
    }
  }

  Future<void> _market(BuildContext context) async {
    final String? to = await pickMember(
      context,
      s,
      except: me,
      title: 'Do kogo?',
    );
    if (to == null || !context.mounted) {
      return;
    }
    String kind = 'inbox';
    int steps = 1;
    final TextEditingController text = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ({int price, String? level}) asked = pyr.priceToSend(to, kind);
          final int price = asked.price;
          final String who = asked.level == null
              ? 'Nie wiadomo, jak dobrze się znacie — liczona jest najwyższa cena z cennika.'
              : 'Cena dla poziomu: ${kPriceLevels[asked.level] ?? asked.level}.';
          final bool chain = kind == 'ad' && steps > 1;
          return AlertDialog(
            title: Text('Do: ${s.members[to]?.name}'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final MapEntry<String, String> k in kMarketKinds.entries)
                    PyrOption(
                      text: k.value,
                      selected: kind == k.key,
                      onTap: () => set(() => kind = k.key),
                    ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: text,
                    minLines: 3,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Treść',
                      hintText: 'Napisz, o co chodzi…',
                      alignLabelWithHint: true,
                    ),
                  ),
                  if (kind == 'ad') ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      'PRZEZ ILU POŚREDNIKÓW',
                      style: ZenColors.of(
                        context,
                      ).label(color: ZenColors.of(context).textSecondary),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (int n = 1; n <= kMaxAdHops; n++)
                          ChoiceChip(
                            key: Key('pyr-ad-steps-$n'),
                            label: Text('$n'),
                            selected: steps == n,
                            onSelected: (_) => set(() => steps = n),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  ZenInfo(
                    icon: price == 0
                        ? Icons.redeem_rounded
                        : Icons.sell_rounded,
                    text: price == 0
                        ? chain
                              ? 'Za darmo. Każdy pośrednik może przekazać ogłoszenie jednej kolejnej osobie (razem do $steps).'
                              : 'Za darmo.'
                        : chain
                        ? 'Każdy z maks. $steps pośredników dostaje ${formatMoney(price)} po akceptacji treści; '
                              'płacisz z góry ${formatMoney(price * steps)} warunkowo, a za niewykorzystane kroki pieniądze wracają. $who'
                        : 'Cena: ${formatMoney(price)} — płatność warunkowa: odbiorca ją przyjmie albo zwróci. $who',
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
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Wyślij'),
              ),
            ],
          );
        },
      ),
    );
    final String body = text.text;
    disposeLater(text);
    // A paid message is money leaving: asked again who this is.
    if (ok == true && pyr.priceToSend(to, kind).price > 0) {
      if (!context.mounted || !await confirmPayment(context)) {
        return;
      }
    }
    if (ok == true) {
      final bool sent = await pyr.sendMarket(
        to,
        kind,
        body,
        steps: kind == 'ad' ? steps : 1,
      );
      if (context.mounted) {
        snack(
          context,
          sent ? 'Wysłane.' : 'Nie udało się (brak środków albo adresu).',
        );
      }
    }
  }

  Future<void> _prices(BuildContext context) async {
    final Map<String, int> current = s.offers[me] ?? const <String, int>{};
    final Map<String, Map<String, int>> currentLevels =
        s.offerLevels[me] ?? const <String, Map<String, int>>{};
    String money(int? v) => v == null || v == 0 ? '' : formatMoney(v);
    final Map<String, TextEditingController> c =
        <String, TextEditingController>{
          for (final String k in kMarketKinds.keys)
            k: TextEditingController(text: money(current[k])),
        };
    // kind → level → field, for prices by acquaintance (§24).
    final Map<String, Map<String, TextEditingController>> lc =
        <String, Map<String, TextEditingController>>{
          for (final String k in kMarketKinds.keys)
            k: <String, TextEditingController>{
              for (final String l in kPriceLevels.keys)
                l: TextEditingController(
                  text: money(
                    currentLevels[k]?[l] ??
                        (currentLevels[k] == null ? null : current[k]),
                  ),
                ),
            },
        };
    // Kinds whose price differs by level; the same for everybody shows as
    // one field.
    final Set<String> byLevel = <String>{
      for (final MapEntry<String, Map<String, int>> e in currentLevels.entries)
        if (e.value.length < kPriceLevels.length ||
            e.value.values.toSet().length > 1)
          e.key,
    };
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) => AlertDialog(
          title: const Text('Mój cennik'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const ZenInfo(
                  icon: Icons.sell_outlined,
                  text:
                      'Puste = za darmo. Ludzie płacą warunkowo, a Ty przyjmujesz albo zwracasz. '
                      'Poziom znajomości ocenia Twój telefon, gdy wiadomość przychodzi.',
                ),
                for (final MapEntry<String, String> k
                    in kMarketKinds.entries) ...<Widget>[
                  const SizedBox(height: 14),
                  if (byLevel.contains(k.key)) ...<Widget>[
                    for (final MapEntry<String, String> l
                        in kPriceLevels.entries) ...<Widget>[
                      TextField(
                        key: Key('pyr-price-${k.key}-${l.key}'),
                        controller: lc[k.key]![l.key],
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: '${k.value} — ${l.value.toLowerCase()}',
                          hintText: 'za darmo',
                          prefixIcon: const Icon(Icons.payments_outlined),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ] else
                    TextField(
                      key: Key('pyr-price-${k.key}'),
                      controller: c[k.key],
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: k.value,
                        hintText: 'za darmo',
                        prefixIcon: const Icon(Icons.payments_outlined),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilterChip(
                      label: const Text('Różne ceny wg znajomości'),
                      selected: byLevel.contains(k.key),
                      onSelected: (bool v) => set(() {
                        if (v) {
                          byLevel.add(k.key);
                          for (final TextEditingController x
                              in lc[k.key]!.values) {
                            if (x.text.isEmpty) {
                              x.text = c[k.key]!.text;
                            }
                          }
                        } else {
                          byLevel.remove(k.key);
                        }
                      }),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Zapisz'),
            ),
          ],
        ),
      ),
    );
    int? read(TextEditingController x) {
      final int? v = parseMoney(x.text);
      return v != null && v > 0 ? v : null;
    }

    final Map<String, int> prices = <String, int>{
      for (final MapEntry<String, TextEditingController> e in c.entries)
        if (!byLevel.contains(e.key) && read(e.value) != null)
          e.key: read(e.value)!,
    };
    final Map<String, Map<String, int>> levels = <String, Map<String, int>>{
      for (final String k in byLevel)
        k: <String, int>{
          for (final MapEntry<String, TextEditingController> l
              in lc[k]!.entries)
            l.key: read(l.value) ?? 0,
        },
    };
    for (final TextEditingController x in <TextEditingController>[
      ...c.values,
      for (final Map<String, TextEditingController> m in lc.values) ...m.values,
    ]) {
      disposeLater(x);
    }
    if (ok == true) {
      await pyr.setOffers(prices, levels: levels);
    }
  }

  /// "Zapłać komuś z innej piramidy" (§23.5): someone in another pyramid
  /// gets the money there, through an exchanger who is in both.
  Future<void> _payAcross(BuildContext context) async {
    final List<String> others = pyr.knownPyramids
        .where((String p) => p != s.id)
        .toList();
    if (others.isEmpty) {
      final int asked = await pyr.fetchFriendsPyramids();
      if (context.mounted) {
        snack(
          context,
          asked == 0
              ? 'Nie znasz innej piramidy (nikt ze znajomych jej nie ma albo jeszcze się nie odezwał).'
              : 'Poprosiłem znajomych o $asked piramid(y) — spróbuj za chwilę.',
        );
      }
      return;
    }
    final String? other = others.length == 1
        ? others.single
        : await showDialog<String>(
            context: context,
            builder: (BuildContext context) => SimpleDialog(
              title: const Text('Do której piramidy?'),
              children: <Widget>[
                for (final String p in others)
                  SimpleDialogOption(
                    onPressed: () => Navigator.of(context).pop(p),
                    child: Text(pyr.pyramidState(p)?.name ?? p.substring(0, 8)),
                  ),
              ],
            ),
          );
    final PyramidState? q = other == null ? null : pyr.pyramidState(other);
    if (other == null || q == null || q.members.isEmpty || !context.mounted) {
      return;
    }
    final String? to = await pickMember(
      context,
      q,
      except: me,
      title: 'Komu w „${q.name}”?',
    );
    if (to == null || !context.mounted) {
      return;
    }
    final String toName = q.members[to]?.name ?? '?';
    if (s.isMember(to)) {
      snack(
        context,
        '$toName jest też w Twojej piramidzie — zapłać zwyczajnie.',
      );
      return;
    }
    final List<({String key, String name, PyrFxRate? rate})> ex = pyr
        .exchangers(other)
        .where(
          (({String key, String name, PyrFxRate? rate}) x) =>
              x.rate != null && x.key != to,
        )
        .toList();
    if (ex.isEmpty) {
      snack(
        context,
        'Nikt, kto jest w obu piramidach, nie ogłosił jeszcze kursu wymiany.',
      );
      return;
    }
    final String? via = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('Kto wymieni pieniądze?'),
        children: <Widget>[
          for (final ({String key, String name, PyrFxRate? rate}) x in ex)
            SimpleDialogOption(
              key: Key('pyr-fx-via-${x.key}'),
              onPressed: () => Navigator.of(context).pop(x.key),
              child: Text('${x.name}: ${fxRateText(x.rate!)} w „${q.name}”'),
            ),
        ],
      ),
    );
    final PyrFxRate? rate = via == null
        ? null
        : ex
              .firstWhere(
                (({String key, String name, PyrFxRate? rate}) x) =>
                    x.key == via,
              )
              .rate;
    if (via == null || rate == null || !context.mounted) {
      return;
    }
    final (int, String)? asked = await askAmount(
      context,
      title: 'Ile ma dostać $toName?',
      info: 'Kwota w „${q.name}”. Kurs: ${fxRateText(rate)}.',
      fieldKey: const Key('pyr-fx-amount'),
      confirmSend: false,
    );
    if (asked == null || !context.mounted) {
      return;
    }
    final int amount = asked.$1;
    final int cost = pyrConvertUp(amount, rate.numer, rate.denom);
    if (rate.max > 0 && amount > rate.max) {
      snack(
        context,
        'Ta osoba wymienia najwyżej ${formatMoney(rate.max)} naraz.',
      );
      return;
    }
    if (cost > s.balanceOf(me)) {
      snack(context, 'Za mało środków: potrzeba ${formatMoney(cost)}.');
      return;
    }
    final bool go = await confirm(
      context,
      'Wymiana między piramidami',
      'Zapłacisz ${formatMoney(cost)} stąd, $toName dostanie '
          '${formatMoney(amount)} w „${q.name}”.\n\n'
          'Twoje pieniądze czekają zablokowane. Osoba wymieniająca dostanie je '
          'dopiero wtedy, gdy $toName odbierze wypłatę. Jeśli wymiana się nie '
          'uda, wrócą do Ciebie najpóźniej po 3 dniach.',
    );
    if (!go || !context.mounted || !await confirmPayment(context)) {
      return;
    }
    final ({PyramidRecord order, int cost})? done = await pyr.payAcross(
      other: other,
      to: to,
      via: via,
      amount: amount,
    );
    if (context.mounted) {
      snack(
        context,
        done == null
            ? 'Nie można teraz (poprzedni przelew jeszcze czeka albo kurs się zmienił).'
            : 'Zlecenie poszło do skarbników. Resztę telefony zrobią same.',
      );
    }
  }

  /// Sets this person's exchange rate: paid out in [payout] for money of
  /// [from] (§23.5).
  Future<void> _setRate(
    BuildContext context,
    PyramidState payout,
    PyramidState from,
  ) async {
    final PyrFxRate? now = payout.fxRates[me]?[from.id];
    final TextEditingController value = TextEditingController(
      text: now == null ? '' : formatMoney(now.payout(10000)),
    );
    final TextEditingController most = TextEditingController(
      text: now == null || now.max == 0 ? '' : formatMoney(now.max),
    );
    final String? action = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Mój kurs wymiany'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ZenInfo(
                icon: Icons.currency_exchange_rounded,
                text:
                    'Ktoś płaci Ci w „${from.name}”, a Ty wypłacasz w '
                    '„${payout.name}” osobie, którą wskaże. Telefon robi to sam '
                    'według kursu. Pieniądze dostajesz dopiero wtedy, gdy ta '
                    'osoba odbierze wypłatę.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('pyr-fx-rate'),
                controller: value,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Za 100,00 z „${from.name}” wypłacam',
                  hintText: '100,00',
                  prefixIcon: const Icon(Icons.payments_outlined),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: most,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Najwięcej naraz',
                  hintText: 'bez limitu',
                  prefixIcon: Icon(Icons.vertical_align_top_rounded),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          if (now != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop('off'),
              child: const Text('Wycofaj'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('save'),
            child: const Text('Zapisz'),
          ),
        ],
      ),
    );
    final int? numer = parseMoney(value.text);
    final int limit = parseMoney(most.text) ?? 0;
    disposeLater(value);
    disposeLater(most);
    if (action == 'off') {
      await pyr.setFxRate(payoutPy: payout.id, fromPy: from.id, numer: 0);
      return;
    }
    if (action != 'save') {
      return;
    }
    if (numer == null || numer <= 0) {
      if (context.mounted) {
        snack(context, 'Podaj kwotę większą od zera.');
      }
      return;
    }
    await pyr.setFxRate(
      payoutPy: payout.id,
      fromPy: from.id,
      numer: numer,
      most: limit,
    );
  }

  /// What an exchange payment [e] here is, for this person.
  String _exchangeTitle(PyrEscrow e) {
    final PyramidState? q = e.fxPy == null ? null : pyr.pyramidState(e.fxPy!);
    final String where = q == null ? 'innej piramidzie' : '„${q.name}”';
    final String toName = q?.members[e.fxTo]?.name ?? '?';
    if (e.from == me) {
      return e.fxPy == null
          ? '${formatMoney(e.amount)} dla ${pyrAccountName(s, e.to)} (wymiana)'
          : '${formatMoney(e.amount)} przez ${pyrAccountName(s, e.to)} → '
                '$toName: ${formatMoney(e.fxAmount)} w $where';
    }
    if (e.fxPy != null) {
      return 'Od ${pyrAccountName(s, e.from)}: wypłacasz '
          '${formatMoney(e.fxAmount)} w $where ($toName)';
    }
    return 'Wypłata ${formatMoney(e.amount)} z wymiany od '
        '${pyrAccountName(s, e.from)}';
  }

  /// Where an exchange payment [e] stands.
  String _exchangeStatus(PyrEscrow e, int t) {
    if (e.from == me) {
      if (t >= e.until) {
        return 'Nie wyszło — pieniądze wracają do Ciebie.';
      }
      return e.fxPy == null
          ? 'Czeka, aż odbiorca weźmie; wróci po ${pyrDate(e.until)}.'
          : 'Czeka na wypłatę po drugiej stronie; wróci po ${pyrDate(e.until)}.';
    }
    if (e.fxPy != null) {
      return 'Telefon wypłaca sam według Twojego kursu; zapłatę dostaniesz, '
          'gdy odbiorca weźmie wypłatę.';
    }
    final String? lock = e.lock;
    return lock != null && pyr.hasFxKey(lock)
        ? 'Masz klucz — telefon odbierze sam.'
        : 'Czeka na klucz od płacącego (do ${pyrDate(e.until)}).';
  }

  Widget _row({
    required ZenColors zen,
    required Widget leading,
    required String title,
    String? subtitle,
    Widget? trailing,
    Color? titleColor,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
    child: Row(
      children: <Widget>[
        leading,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: titleColor ?? zen.textPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 8), trailing],
      ],
    ),
  );

  Widget _buttons(List<Widget> children) => Align(
    alignment: Alignment.centerRight,
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: children,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final PyrAccount acc = s.accounts[me] ?? PyrAccount();
    final int t = pyr.now;
    // Exchange payments (locked) settle by themselves: not asked here.
    final List<PyrEscrow> toAnswer = s.escrows.values
        .where(
          (PyrEscrow e) =>
              e.settled == null && e.condBy == me && e.lock == null,
        )
        .toList();
    final List<PyrEscrow> exchanges = s.escrows.values
        .where(
          (PyrEscrow e) =>
              e.settled == null &&
              e.lock != null &&
              (e.from == me || e.condBy == me),
        )
        .toList();
    // Other pyramids this person is in: exchange offers can be set there.
    final List<PyramidState> elsewhere = pyr.myPyramids
        .where((PyramidState x) => x.id != s.id)
        .toList();
    // Money converted at a merge comes in parts: one row per merge.
    final Map<String, List<PyrEmission>> parts = <String, List<PyrEmission>>{};
    final List<PyrEmission> emissionRows = <PyrEmission>[];
    for (final PyrEmission e in s.emissions.values) {
      final String? g = e.group;
      if (g == null) {
        emissionRows.add(e);
      } else {
        final List<PyrEmission> list = parts[g] ??= <PyrEmission>[];
        if (list.isEmpty) {
          emissionRows.add(e);
        }
        list.add(e);
      }
    }
    final List<PyrEscrow> refundable = s.escrows.values
        .where(
          (PyrEscrow e) => e.settled == null && e.from == me && t >= e.until,
        )
        .toList();
    final List<PyrTransferInfo> mine = s.transfers
        .where((PyrTransferInfo x) => x.from == me || x.to == me)
        .toList()
        .reversed
        .toList();
    final List<PyrMarketMessage> market = pyr.market.values.toList()
      ..sort((PyrMarketMessage a, PyrMarketMessage b) => b.at.compareTo(a.at));
    final bool top = s.topCell.contains(me);
    // The limit is per 30 days, whatever the terms (§23.4).
    final int emitted = s.emittedWithin(t);
    // Nobody records or screenshots the wallet (§14.1 point 6).
    return SecureScreen(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          // The balance.
          Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: LinearGradient(
                colors: <Color>[
                  Color.alphaBlend(tone.withValues(alpha: 0.42), zen.surface),
                  Color.alphaBlend(
                    zen.accentSecondary.withValues(alpha: 0.26),
                    zen.surface,
                  ),
                  Color.alphaBlend(
                    zen.accentTertiary.withValues(alpha: 0.14),
                    zen.surface,
                  ),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: tone.withValues(alpha: 0.40)),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: tone.withValues(alpha: 0.18),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(
                      Icons.account_balance_wallet_rounded,
                      color: tone,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'SALDO',
                        style: zen.label(color: zen.textSecondary),
                      ),
                    ),
                    if (s.treasurers.contains(me))
                      ZenPill(
                        text: 'skarbnik',
                        tone: zen.success,
                        icon: Icons.account_balance_rounded,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    formatMoney(acc.balance),
                    style: zen.display(color: zen.textPrimary, size: 44),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  acc.buckets.isEmpty
                      ? 'Konto należy do Twojej tożsamości w piramidzie.'
                      : 'Z kadencji: ${acc.buckets.map((List<int> b) => 'K${b[0]}: ${formatMoney(b[1])}').join(', ')}',
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton.icon(
                      key: const Key('pyr-pay'),
                      onPressed: () => unawaited(_pay(context)),
                      icon: const Icon(Icons.send_rounded),
                      label: const Text('Zapłać'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_market(context)),
                      icon: const Icon(Icons.storefront_rounded),
                      label: const Text('Napisz / poproś (rynek)'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_prices(context)),
                      icon: const Icon(Icons.sell_rounded),
                      label: const Text('Mój cennik'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('pyr-pay-across'),
                      onPressed: () => unawaited(_payAcross(context)),
                      icon: const Icon(Icons.currency_exchange_rounded),
                      label: const Text('Zapłać komuś z innej piramidy'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (pyr.pendingPayments.isNotEmpty) ...<Widget>[
            const ZenSection('W drodze'),
            ZenGroup(
              children: <Widget>[
                for (final PyramidRecord p in pyr.pendingPayments)
                  if ((p.pyramid == s.id ? s : pyr.pyramidState(p.pyramid))
                      case final PyramidState ps)
                    _row(
                      zen: zen,
                      leading: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: tone,
                        ),
                      ),
                      title:
                          '${formatMoney(p.integer('amount'))} dla ${pyrAccountName(ps, p.str('to'))}'
                          '${ps.id == s.id ? '' : ' w „${ps.name}”'}',
                      subtitle:
                          'Czeka na skarbników: ${p.tsigs.length} z ${ps.treasurerMajority}',
                      trailing: TextButton(
                        onPressed: () => pyr.cancelPending(p.id),
                        child: const Text('Anuluj'),
                      ),
                    ),
              ],
            ),
          ],
          if (toAnswer.isNotEmpty) const ZenSection('Czekają na Twoją decyzję'),
          for (final PyrEscrow e in toAnswer)
            ZenCard(
              tone: zen.warning,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      ZenIconBadge(
                        icon: Icons.hourglass_top_rounded,
                        tone: zen.warning,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '${formatMoney(e.amount)} od ${s.members[e.from]?.name ?? '?'}',
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (e.memo.isNotEmpty)
                              Text(
                                e.memo,
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 13,
                                  height: 1.3,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buttons(<Widget>[
                    TextButton(
                      onPressed: () => unawaited(pyr.settle(e.id, false)),
                      child: const Text('Zwróć'),
                    ),
                    FilledButton(
                      onPressed: () => unawaited(pyr.settle(e.id, true)),
                      child: const Text('Przyjmij'),
                    ),
                  ]),
                ],
              ),
            ),
          for (final PyrEscrow e in refundable)
            ZenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      ZenIconBadge(
                        icon: Icons.undo_rounded,
                        tone: zen.textMuted,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${formatMoney(e.amount)} dla ${pyrAccountName(s, e.to)} — bez odpowiedzi',
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _buttons(<Widget>[
                    FilledButton.tonal(
                      onPressed: () => unawaited(pyr.settle(e.id, false)),
                      child: const Text('Odbierz zwrot'),
                    ),
                  ]),
                ],
              ),
            ),
          if (exchanges.isNotEmpty) ...<Widget>[
            const ZenSection('Wymiany między piramidami'),
            ZenGroup(
              children: <Widget>[
                for (final PyrEscrow e in exchanges)
                  _row(
                    zen: zen,
                    leading: ZenIconBadge(
                      icon: Icons.currency_exchange_rounded,
                      tone: tone,
                      size: 36,
                    ),
                    title: _exchangeTitle(e),
                    subtitle: _exchangeStatus(e, t),
                  ),
              ],
            ),
          ],
          if (elsewhere.isNotEmpty) ...<Widget>[
            const ZenSection('Kantor: jesteś w kilku piramidach'),
            ZenGroup(
              children: <Widget>[
                for (final PyramidState q in elsewhere) ...<Widget>[
                  _row(
                    zen: zen,
                    leading: ZenIconBadge(
                      icon: Icons.account_balance_wallet_outlined,
                      tone: zen.textMuted,
                      size: 36,
                    ),
                    title:
                        'Saldo w „${q.name}”: ${formatMoney(q.balanceOf(me))}',
                  ),
                  _row(
                    zen: zen,
                    leading: ZenIconBadge(
                      icon: Icons.south_west_rounded,
                      tone: tone,
                      size: 36,
                    ),
                    title: 'Wypłacam tutaj za pieniądze z „${q.name}”',
                    subtitle: s.fxRates[me]?[q.id] == null
                        ? 'bez kursu'
                        : fxRateText(s.fxRates[me]![q.id]!),
                    trailing: TextButton(
                      onPressed: () => unawaited(_setRate(context, s, q)),
                      child: const Text('Kurs'),
                    ),
                  ),
                  _row(
                    zen: zen,
                    leading: ZenIconBadge(
                      icon: Icons.north_east_rounded,
                      tone: tone,
                      size: 36,
                    ),
                    title: 'Wypłacam w „${q.name}” za pieniądze stąd',
                    subtitle: q.fxRates[me]?[s.id] == null
                        ? 'bez kursu'
                        : fxRateText(q.fxRates[me]![s.id]!),
                    trailing: TextButton(
                      onPressed: () => unawaited(_setRate(context, q, s)),
                      child: const Text('Kurs'),
                    ),
                  ),
                ],
              ],
            ),
            const ZenInfo(
              icon: Icons.currency_exchange_rounded,
              text:
                  'Z kursem telefon sam wymienia pieniądze ludziom z obu piramid. '
                  'Wypłacasz pierwszy, a zapłatę odbierasz tym samym kluczem, '
                  'którym odbiorca wziął wypłatę. Telefon musi być wtedy w sieci '
                  '(masz na to dobę).',
            ),
          ],
          if (market.isNotEmpty) ...<Widget>[
            const ZenSection('Rynek: wiadomości i prośby'),
            for (final PyrMarketMessage m in market)
              ZenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ZenIconBadge(
                          icon: m.mine
                              ? Icons.outbox_rounded
                              : Icons.inbox_rounded,
                          tone: zenTone(zen, 3),
                          size: 40,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                m.origin == null
                                    ? '${kMarketKinds[m.kind] ?? m.kind} ${m.mine ? 'do' : 'od'} ${s.members[m.from]?.name ?? '?'}'
                                    : '${kMarketKinds[m.kind] ?? m.kind} od ${s.members[m.origin]?.name ?? '?'} (przez ${s.members[m.from]?.name ?? '?'})',
                                style: TextStyle(
                                  color: zen.textPrimary,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w700,
                                  height: 1.3,
                                ),
                              ),
                              if (m.hops > 0 || m.level != null) ...<Widget>[
                                const SizedBox(height: 4),
                                Text(
                                  <String>[
                                    if (m.level != null)
                                      'cena dla: ${(kPriceLevels[m.level] ?? m.level!).toLowerCase()}',
                                    if (m.hops > 0)
                                      m.mine
                                          ? 'do ${m.hops + 1} pośredników'
                                          : 'możesz przekazać dalej (jeszcze ${m.hops})',
                                  ].join(' · '),
                                  style: TextStyle(
                                    color: zen.textMuted,
                                    fontSize: 12,
                                    height: 1.3,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                m.text,
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 13.5,
                                  height: 1.35,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (m.amount > 0) ...<Widget>[
                          const SizedBox(width: 8),
                          ZenPill(
                            text: formatMoney(m.amount),
                            tone: zenTone(zen, 3),
                            filled: true,
                          ),
                        ],
                      ],
                    ),
                    if (!(m.mine || m.done)) ...<Widget>[
                      const SizedBox(height: 10),
                      _buttons(<Widget>[
                        TextButton(
                          onPressed: () =>
                              unawaited(pyr.answerMarket(m.id, accept: false)),
                          child: Text(m.amount > 0 ? 'Zwróć' : 'Odrzuć'),
                        ),
                        if (m.kind == 'ad' && m.hops > 0)
                          OutlinedButton(
                            key: Key('pyr-ad-pass-${m.id}'),
                            onPressed: () => unawaited(() async {
                              final String? next = await pickMember(
                                context,
                                s,
                                except: me,
                                title: 'Komu przekazać ogłoszenie?',
                              );
                              if (next != null) {
                                await pyr.answerMarket(
                                  m.id,
                                  accept: true,
                                  next: next,
                                );
                              }
                            }()),
                            child: const Text('Przyjmij i przekaż dalej'),
                          ),
                        FilledButton(
                          onPressed: () =>
                              unawaited(pyr.answerMarket(m.id, accept: true)),
                          child: const Text('Przyjmij'),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),
          ],
          const ZenSection('Historia'),
          if (mine.isEmpty)
            ZenCard(
              child: Row(
                children: <Widget>[
                  Icon(Icons.receipt_long_outlined, color: zen.textMuted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Jeszcze żadnych przelewów.',
                      style: TextStyle(color: zen.textSecondary, fontSize: 14),
                    ),
                  ),
                ],
              ),
            )
          else
            ZenGroup(
              children: <Widget>[
                for (final PyrTransferInfo x in mine.take(100))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: (x.to == me ? zen.success : zen.danger)
                                .withValues(alpha: 0.14),
                          ),
                          child: Icon(
                            x.to == me
                                ? Icons.south_west_rounded
                                : Icons.north_east_rounded,
                            size: 18,
                            color: x.to == me ? zen.success : zen.danger,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                '${x.to == me ? 'od' : 'dla'} ${pyrAccountName(s, x.to == me ? x.from : x.to)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: zen.textPrimary,
                                  fontSize: 14.5,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${x.memo}${x.conditional ? ' (warunkowo)' : ''} · ${pyrDate(x.at)}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: zen.textMuted,
                                  fontSize: 12,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${x.to == me ? '+' : '−'}${formatMoney(x.amount)}',
                          style: TextStyle(
                            color: x.to == me ? zen.success : zen.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ZenSection('Emisja (jawna, kadencja ${s.term})'),
          ZenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    ZenIconBadge(
                      icon: Icons.add_card_rounded,
                      tone: tone,
                      size: 40,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'W ostatnich 30 dniach: ${formatMoney(emitted)} z limitu ${formatMoney(s.params.emitLimit)}.',
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 14,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                PyrBar(
                  value: s.params.emitLimit <= 0
                      ? 0.0
                      : emitted / s.params.emitLimit,
                  tone: tone,
                ),
                if (top) ...<Widget>[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(() async {
                      final String? to = await pickMember(
                        context,
                        s,
                        title: 'Emisja dla',
                      );
                      if (to == null || !context.mounted) {
                        return;
                      }
                      final int? amount = parseMoney(
                        await askText(
                              context,
                              title: 'Kwota emisji',
                              label: 'Kwota, np. 1000,00',
                              keyboard: const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                            ) ??
                            '',
                      );
                      if (!context.mounted || amount == null || amount <= 0) {
                        return;
                      }
                      final String? why = await askText(
                        context,
                        title: 'Uzasadnienie (jawne)',
                      );
                      if (why == null || !context.mounted) {
                        return;
                      }
                      // New money: asked again who this is.
                      if (!await confirmSensitiveAccess(
                        context,
                        reason: 'Emisja pieniędzy. Potwierdź, że to Ty.',
                      )) {
                        return;
                      }
                      await pyr.emit(to, amount, why);
                      if (context.mounted) {
                        snack(
                          context,
                          'Potrzebny podpis drugiej osoby ze szczytu; ważna po ${s.params.emitDelayHours} h.',
                        );
                      }
                    }()),
                    icon: const Icon(Icons.add_card_rounded),
                    label: const Text('Zaproponuj emisję'),
                  ),
                ],
              ],
            ),
          ),
          if (emissionRows.isNotEmpty)
            ZenGroup(
              children: <Widget>[
                for (final PyrEmission e in emissionRows.reversed)
                  _row(
                    zen: zen,
                    leading: ZenIconBadge(
                      icon: e.vetoed
                          ? Icons.block_rounded
                          : e.done
                          ? Icons.check_rounded
                          : Icons.schedule_rounded,
                      tone: e.vetoed
                          ? zen.danger
                          : e.done
                          ? zen.success
                          : zen.warning,
                      size: 36,
                    ),
                    title: e.group == null
                        ? '${formatMoney(e.amount)} dla ${s.members[e.to]?.name ?? '?'} · K${e.term}'
                        : 'Przeliczenie po połączeniu: ${formatMoney(parts[e.group]!.fold(0, (int a, PyrEmission x) => pyrAdd(a, x.amount)))} dla ${parts[e.group]!.length} os. · K${e.term}',
                    subtitle:
                        '${e.why} · ${e.vetoed
                            ? 'zawetowana'
                            : e.done
                            ? 'wykonana'
                            : 'czeka do ${pyrDate(e.effectiveAt)}'}'
                        '${pyr.seenLate(e.group ?? e.id) ? ' · dotarła z opóźnieniem' : ''}',
                    // Who could veto when it was signed, within its time —
                    // also when it reached this phone late (§23.4).
                    trailing: pyr.canVeto(e)
                        ? TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: zen.danger,
                            ),
                            onPressed: () => unawaited(pyr.veto(e.id)),
                            child: const Text('Weto'),
                          )
                        : null,
                  ),
              ],
            ),
          if (s.cheaters.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            ZenInfo(
              icon: Icons.warning_amber_rounded,
              tone: zen.danger,
              title:
                  'Dowody: skarbnik podpisał dwa przelewy z tym samym numerem',
              text: s.cheaters.keys
                  .map((String k) => '• ${pyrWho(s, k)}')
                  .join('\n'),
            ),
          ],
          const SizedBox(height: 8),
          ZenInfo(
            icon: Icons.account_balance_rounded,
            tone: tone,
            text:
                'Skarbnicy: ${s.treasurers.length} najwyżej postawionych osób; przelew jest ważny przy '
                '${s.treasurerMajority} podpisach. Skarbnicy widzą przelewy, jak bank.',
          ),
        ],
      ),
    );
  }
}
