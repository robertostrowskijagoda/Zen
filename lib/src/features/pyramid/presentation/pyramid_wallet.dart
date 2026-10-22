import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_court_view.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_emission.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';

/// "12,50" → 1250 (hundredths), or null. Spaces of any kind are ignored,
/// so what [formatMoney] wrote ("1 000,00", "1,000.00" in English) reads
/// back (see [ZenFormat.normalizeDecimal]).
int? parseMoney(String text) {
  final String t = ZenFormat.normalizeDecimal(text);
  final List<String> parts = t.split('.');
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

/// A line of the post [entry] (a signed entry's JSON) to pick it by.
String marketPostPreview(Map<String, dynamic> entry) {
  final Object? text = LogEntry.fromJson(entry)?.body['text'];
  final String line = text is String ? text.trim().replaceAll('\n', ' ') : '';
  if (line.isEmpty) {
    return t('(zdjęcia)');
  }
  return line.length > 90 ? '${line.substring(0, 90)}…' : line;
}

/// Asks again who this is before money leaves: the app
/// password or biometrics, when the app has a password (otherwise yes).
Future<bool> confirmPayment(BuildContext context) => confirmSensitiveAccess(
  context,
  reason: t('Wysyłasz pieniądze. Potwierdź, że to Ty.'),
);

/// Picks a member of the pyramid.
Future<String?> pickMember(
  BuildContext context,
  PyramidState s, {
  String? except,
  String? title,
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
      title: Text(title ?? t('Wybierz osobę')),
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
  String? memoHint,
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
              decoration: InputDecoration(
                labelText: t('Kwota'),
                hintText: '0,00',
                prefixIcon: const Icon(Icons.payments_outlined),
              ),
            ),
            if (withMemo) ...<Widget>[
              const SizedBox(height: 14),
              TextField(
                controller: memo,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('Tytuł'),
                  hintText: memoHint ?? t('np. za zakupy'),
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
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t('Dalej')),
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

/// Money and the access market.
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
      title: t('Komu zapłacić?'),
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
          title: Text(
            t('Przelew dla {name}', <String, Object?>{
              'name': s.members[to]?.name,
            }),
          ),
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
                  decoration: InputDecoration(
                    labelText: t('Kwota'),
                    hintText: '0,00',
                    prefixIcon: const Icon(Icons.payments_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: memo,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: t('Tytuł'),
                    hintText: t('np. za zakupy'),
                    prefixIcon: const Icon(Icons.notes_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: conditional,
                  title: Text(t('Warunkowo')),
                  subtitle: Text(
                    t('Pieniądze czekają, aż odbiorca przyjmie (albo wrócą).'),
                  ),
                  onChanged: (bool v) => set(() => conditional = v),
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
              child: Text(t('Zapłać')),
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
            ? t('Nie można teraz (poprzedni przelew jeszcze czeka?).')
            : t(
                'Zlecenie poszło do skarbników — ważne przy podpisach '
                '{count} z {total}.',
                <String, Object?>{
                  'count': s.treasurerMajority,
                  'total': s.treasurers.length,
                },
              ),
      );
    }
  }

  Future<void> _market(BuildContext context) async {
    final String? to = await pickMember(
      context,
      s,
      except: me,
      title: t('Do kogo?'),
    );
    if (to == null || !context.mounted) {
      return;
    }
    String kind = 'inbox';
    int steps = 1;
    // A reshare on order: which of my public posts.
    final List<Map<String, dynamic>> myPosts =
        pyr.ownPublicPosts?.call() ?? const <Map<String, dynamic>>[];
    Map<String, dynamic>? sharedPost;
    final TextEditingController text = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ({int price, String? level}) asked = pyr.priceToSend(to, kind);
          final int price = asked.price;
          final String who = asked.level == null
              ? t(
                  'Nie wiadomo, jak dobrze się znacie — liczona jest '
                  'najwyższa cena z cennika.',
                )
              : t('Cena dla poziomu: {level}.', <String, Object?>{
                  'level': kPriceLevels[asked.level] ?? asked.level,
                });
          final bool chain = kind == 'ad' && steps > 1;
          return AlertDialog(
            title: Text(
              t('Do: {name}', <String, Object?>{'name': s.members[to]?.name}),
            ),
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
                  if (kind == 'reshare') ...<Widget>[
                    Text(
                      t('KTÓRY POST UDOSTĘPNIĆ'),
                      style: ZenColors.of(
                        context,
                      ).label(color: ZenColors.of(context).textSecondary),
                    ),
                    const SizedBox(height: 6),
                    if (myPosts.isEmpty)
                      ZenInfo(
                        icon: Icons.article_outlined,
                        text: t(
                          'Nie masz publicznych postów. Udostępnić na '
                          'zamówienie można tylko post publiczny.',
                        ),
                      ),
                    for (final Map<String, dynamic> post in myPosts.take(10))
                      PyrOption(
                        text: marketPostPreview(post),
                        selected: identical(sharedPost, post),
                        onTap: () => set(() => sharedPost = post),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      t(
                        'Odbiorca zobaczy post przed decyzją i udostępni go '
                        'swoim znajomym; zapłata przechodzi dopiero po '
                        'udostępnieniu.',
                      ),
                      style: TextStyle(
                        color: ZenColors.of(context).textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ] else
                    TextField(
                      controller: text,
                      minLines: 3,
                      maxLines: 5,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: t('Treść'),
                        hintText: t('Napisz, o co chodzi…'),
                        alignLabelWithHint: true,
                      ),
                    ),
                  if (kind == 'ad') ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      t('PRZEZ ILU POŚREDNIKÓW'),
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
                              ? t(
                                  'Za darmo. Każdy pośrednik może przekazać '
                                  'ogłoszenie jednej kolejnej osobie (razem do '
                                  '{steps}).',
                                  <String, Object?>{'steps': steps},
                                )
                              : t('Za darmo.')
                        : chain
                        ? t(
                            'Każdy z maks. {steps} pośredników dostaje '
                            '{price} po akceptacji treści; płacisz z góry '
                            '{total} warunkowo, a za niewykorzystane kroki '
                            'pieniądze wracają. {who}',
                            <String, Object?>{
                              'steps': steps,
                              'price': formatMoney(price),
                              'total': formatMoney(price * steps),
                              'who': who,
                            },
                          )
                        : t(
                            'Cena: {price} — płatność warunkowa: odbiorca ją '
                            'przyjmie albo zwróci. {who}',
                            <String, Object?>{
                              'price': formatMoney(price),
                              'who': who,
                            },
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
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(t('Wyślij')),
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
        post: kind == 'reshare' ? sharedPost : null,
      );
      if (context.mounted) {
        snack(
          context,
          sent ? t('Wysłane.') : t('Nie udało się (brak środków albo adresu).'),
        );
      }
    }
  }

  Future<void> _prices(BuildContext context) async {
    final Map<String, int> current = s.offers[me] ?? const <String, int>{};
    final Map<String, Map<String, int>> currentLevels =
        s.offerLevels[me] ?? const <String, Map<String, int>>{};
    String money(int? v) => v == null || v == 0 ? '' : formatMoney(v);
    // The first-message price is set with the conversations outside
    // friends (and kept here as it is); gates are priced in the graph.
    final Map<String, String> kinds = <String, String>{
      for (final MapEntry<String, String> k in kMarketKinds.entries)
        if (k.key != 'inbox') k.key: k.value,
    };
    final Map<String, TextEditingController> c =
        <String, TextEditingController>{
          for (final String k in kinds.keys)
            k: TextEditingController(text: money(current[k])),
        };
    // kind → level → field, for prices by acquaintance.
    final Map<String, Map<String, TextEditingController>> lc =
        <String, Map<String, TextEditingController>>{
          for (final String k in kinds.keys)
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
          title: Text(t('Mój cennik')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ZenInfo(
                  icon: Icons.sell_outlined,
                  text: t(
                    'Puste = za darmo. Ludzie płacą warunkowo, a Ty '
                    'przyjmujesz albo zwracasz. Poziom znajomości ocenia Twój '
                    'telefon, gdy wiadomość przychodzi.',
                  ),
                ),
                const SizedBox(height: 8),
                ZenInfo(
                  key: const Key('pyr-price-elsewhere'),
                  icon: Icons.toll_outlined,
                  text: t(
                    'Cenę pierwszej wiadomości od osób spoza znajomych '
                    'ustawiasz w: Ustawienia → Wiadomości spoza znajomych. '
                    'Bramy do Twoich znajomych (przedstawienia) — w Grafie.',
                  ),
                ),
                for (final MapEntry<String, String> k
                    in kinds.entries) ...<Widget>[
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
                          hintText: t('za darmo'),
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
                        hintText: t('za darmo'),
                        prefixIcon: const Icon(Icons.payments_outlined),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilterChip(
                      label: Text(t('Różne ceny wg znajomości')),
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
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t('Zapisz')),
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
        if (kinds.containsKey(k))
          k: <String, int>{
            for (final MapEntry<String, TextEditingController> l
                in lc[k]!.entries)
              l.key: read(l.value) ?? 0,
          },
      // Kept as the conversations' settings published it.
      if (currentLevels['inbox'] != null) 'inbox': currentLevels['inbox']!,
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

  /// One line of the history: what came in (+), what went out (−), and
  /// what only waits or went back (no sign).
  Widget _entry(ZenColors zen, PyrLedgerEntry e) {
    final bool incoming = e.to == me;
    final int sign = switch (e.kind) {
      PyrEntryKind.payment => incoming ? 1 : -1,
      PyrEntryKind.emission => 1,
      PyrEntryKind.hold => incoming ? 0 : -1,
      PyrEntryKind.kept => incoming ? 1 : 0,
      PyrEntryKind.returned => incoming ? 1 : 0,
    };
    final String who = switch (e.kind) {
      PyrEntryKind.emission => t('z emisji'),
      _ when incoming => t('od {name}', <String, Object?>{
        'name': pyrAccountName(s, e.from),
      }),
      _ => t('dla {name}', <String, Object?>{'name': pyrAccountName(s, e.to)}),
    };
    final String what = switch (e.kind) {
      PyrEntryKind.hold => t('(warunkowo)'),
      PyrEntryKind.kept => t('przyjęta'),
      PyrEntryKind.returned => t('zwrot'),
      _ => '',
    };
    final Color color = sign > 0
        ? zen.success
        : sign < 0
        ? zen.danger
        : zen.textMuted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: 0.14),
            ),
            child: Icon(
              sign > 0
                  ? Icons.south_west_rounded
                  : sign < 0
                  ? Icons.north_east_rounded
                  : Icons.hourglass_empty_rounded,
              size: 18,
              color: color,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  who,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  <String>[
                    if (e.memo.isNotEmpty) e.memo,
                    if (what.isNotEmpty) what,
                    pyrDate(e.at),
                  ].join(' · '),
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
            '${sign > 0
                ? '+'
                : sign < 0
                ? '−'
                : ''}${formatMoney(e.amount)}',
            style: TextStyle(
              color: sign > 0 ? zen.success : zen.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final int balance = pyr.balance;
    final int now = pyr.now;
    final List<PyrEscrow> escrows = pyr.myEscrows;
    final List<PyrEscrow> toAnswer = escrows
        .where((PyrEscrow e) => e.settled == null && e.condBy == me)
        .toList();
    final List<PyrEmission> emissionRows = s.emissions.values.toList();
    final List<PyrEscrow> refundable = escrows
        .where(
          (PyrEscrow e) => e.settled == null && e.from == me && now >= e.until,
        )
        .toList();
    final List<PyrLedgerEntry> mine = pyr.myEntries.reversed.toList();
    final bool treasurer = s.treasurers.contains(me);
    final PyrStatement? agreed = pyr.agreedStatement;
    final int agreeing = agreed == null
        ? 0
        : pyr.statements.values
              .where(
                (PyrStatement st) =>
                    s.treasurers.contains(st.by) &&
                    st.agreement == agreed.agreement,
              )
              .length;
    final List<String> disagreeing = treasurer
        ? const <String>[]
        : pyr.disagreeingTreasurers;
    final Map<String, List<String>> cheaters = pyr.ledgerCheaters;
    final List<PyrMarketMessage> market = pyr.market.values.toList()
      ..sort((PyrMarketMessage a, PyrMarketMessage b) => b.at.compareTo(a.at));
    final bool top = s.topCell.contains(me);
    // The limit is per 30 days, whatever the terms.
    final int emitted = s.emittedWithin(now);
    // Nobody records or screenshots the wallet.
    return SecureScreen(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          // Pinned: the money may change.
          EmitChangeNotices(pyr: pyr, s: s),
          // The balance.
          Container(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                ZenLook.of(context).radius(28),
              ),
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
              boxShadow: ZenLook.of(context).tinted(
                zen,
                tone,
                radius: 24,
                alpha: 0.18,
                offset: const Offset(0, 10),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.attach_money_rounded, color: tone, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        t('SALDO'),
                        style: zen.label(color: zen.textSecondary),
                      ),
                    ),
                    if (treasurer)
                      ZenPill(
                        text: t('skarbnik'),
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
                    formatMoney(balance),
                    style: zen.display(color: zen.textPrimary, size: 44),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  treasurer
                      ? t('Z Twojej kopii księgi skarbników.')
                      : agreed == null
                      ? t('Czeka na wyciąg od skarbników.')
                      : t(
                          'Wyciąg potwierdziło {count} z {total} skarbników · {date}',
                          <String, Object?>{
                            'count': agreeing,
                            'total': s.treasurers.length,
                            'date': pyrDate(agreed.at),
                          },
                        ),
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
                      label: Text(t('Zapłać')),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_market(context)),
                      icon: const Icon(Icons.storefront_rounded),
                      label: Text(t('Napisz / poproś (rynek)')),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_prices(context)),
                      icon: const Icon(Icons.sell_rounded),
                      label: Text(t('Mój cennik')),
                    ),
                    if (!treasurer)
                      OutlinedButton.icon(
                        key: const Key('pyr-statement'),
                        onPressed: () {
                          unawaited(pyr.refreshStatement());
                          snack(context, t('Poproszono skarbników o wyciąg.'));
                        },
                        icon: const Icon(Icons.receipt_long_rounded),
                        label: Text(t('Wyciąg')),
                      ),
                  ],
                ),
              ],
            ),
          ),
          // Treasurers who state another balance than most of them: the
          // person may take it to the court.
          if (disagreeing.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            ZenCard(
              tone: zen.danger,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ZenInfo(
                    icon: Icons.report_gmailerrorred_rounded,
                    tone: zen.danger,
                    title: t('Skarbnicy podają różne salda'),
                    text: <String>[
                      for (final String k in disagreeing)
                        '• ${pyrWho(s, k)}: ${formatMoney(pyr.statements[k]?.balance ?? 0)}',
                    ].join('\n'),
                  ),
                  const SizedBox(height: 8),
                  _buttons(<Widget>[
                    for (final String k in disagreeing.take(3))
                      OutlinedButton(
                        key: Key('pyr-dispute-$k'),
                        onPressed: () => unawaited(
                          showComplaintDialog(
                            context,
                            pyr,
                            s,
                            k,
                            initialKind: 'ledger',
                          ),
                        ),
                        child: Text(
                          t('Zgłoś spór: {name}', <String, Object?>{
                            'name': s.members[k]?.name ?? '?',
                          }),
                        ),
                      ),
                  ]),
                ],
              ),
            ),
          ],
          if (pyr.pendingPayments.isNotEmpty) ...<Widget>[
            ZenSection(t('W drodze')),
            ZenGroup(
              children: <Widget>[
                for (final PyramidRecord p in pyr.pendingPayments)
                  if (p.pyramid == s.id)
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
                      title: t('{amount} dla {name}', <String, Object?>{
                        'amount': formatMoney(p.integer('amount')),
                        'name': pyrAccountName(s, p.str('to')),
                      }),
                      subtitle: t(
                        'Czeka na skarbników: {count} z {need}',
                        <String, Object?>{
                          'count': p.tsigs.length,
                          'need': s.treasurerMajority,
                        },
                      ),
                      trailing: TextButton(
                        onPressed: () => pyr.cancelPending(p.id),
                        child: Text(t('Anuluj')),
                      ),
                    ),
              ],
            ),
          ],
          if (toAnswer.isNotEmpty) ZenSection(t('Czekają na Twoją decyzję')),
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
                              t('{amount} od {name}', <String, Object?>{
                                'amount': formatMoney(e.amount),
                                'name': s.members[e.from]?.name ?? '?',
                              }),
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
                      child: Text(t('Zwróć')),
                    ),
                    FilledButton(
                      onPressed: () => unawaited(pyr.settle(e.id, true)),
                      child: Text(t('Przyjmij')),
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
                          t(
                            '{amount} dla {name} — bez odpowiedzi',
                            <String, Object?>{
                              'amount': formatMoney(e.amount),
                              'name': pyrAccountName(s, e.to),
                            },
                          ),
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
                      child: Text(t('Odbierz zwrot')),
                    ),
                  ]),
                ],
              ),
            ),
          if (market.isNotEmpty) ...<Widget>[
            ZenSection(t('Rynek: wiadomości i prośby')),
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
                                m.origin != null
                                    ? t('{kind} od {origin} (przez {name})', <
                                        String,
                                        Object?
                                      >{
                                        'kind': kMarketKinds[m.kind] ?? m.kind,
                                        'origin':
                                            s.members[m.origin]?.name ?? '?',
                                        'name': s.members[m.from]?.name ?? '?',
                                      })
                                    : m.mine
                                    ? t('{kind} do {name}', <String, Object?>{
                                        'kind': kMarketKinds[m.kind] ?? m.kind,
                                        'name': s.members[m.from]?.name ?? '?',
                                      })
                                    : t('{kind} od {name}', <String, Object?>{
                                        'kind': kMarketKinds[m.kind] ?? m.kind,
                                        'name': s.members[m.from]?.name ?? '?',
                                      }),
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
                                      t('cena dla: {level}', <String, Object?>{
                                        'level':
                                            (kPriceLevels[m.level] ?? m.level!)
                                                .toLowerCase(),
                                      }),
                                    if (m.hops > 0)
                                      m.mine
                                          ? t(
                                              'do {count} pośredników',
                                              <String, Object?>{
                                                'count': m.hops + 1,
                                              },
                                            )
                                          : t(
                                              'możesz przekazać dalej '
                                              '(jeszcze {count})',
                                              <String, Object?>{
                                                'count': m.hops,
                                              },
                                            ),
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
                          child: Text(m.amount > 0 ? t('Zwróć') : t('Odrzuć')),
                        ),
                        if (m.kind == 'ad' && m.hops > 0)
                          OutlinedButton(
                            key: Key('pyr-ad-pass-${m.id}'),
                            onPressed: () => unawaited(() async {
                              final String? next = await pickMember(
                                context,
                                s,
                                except: me,
                                title: t('Komu przekazać ogłoszenie?'),
                              );
                              if (next != null) {
                                await pyr.answerMarket(
                                  m.id,
                                  accept: true,
                                  next: next,
                                );
                              }
                            }()),
                            child: Text(t('Przyjmij i przekaż dalej')),
                          ),
                        FilledButton(
                          onPressed: () =>
                              unawaited(pyr.answerMarket(m.id, accept: true)),
                          child: Text(
                            m.kind == 'reshare'
                                ? t('Udostępnij znajomym')
                                : t('Przyjmij'),
                          ),
                        ),
                      ]),
                    ],
                  ],
                ),
              ),
          ],
          ZenSection(t('Historia')),
          if (mine.isEmpty)
            ZenCard(
              child: Row(
                children: <Widget>[
                  Icon(Icons.receipt_long_outlined, color: zen.textMuted),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('Jeszcze żadnych przelewów.'),
                      style: TextStyle(color: zen.textSecondary, fontSize: 14),
                    ),
                  ),
                ],
              ),
            )
          else
            ZenGroup(
              children: <Widget>[
                for (final PyrLedgerEntry e in mine.take(100)) _entry(zen, e),
              ],
            ),
          ZenSection(
            t('Emisja (jawna, kadencja {term})', <String, Object?>{
              'term': s.term,
            }),
          ),
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
                        t(
                          'W ostatnich 30 dniach: {amount} z limitu {limit}.',
                          <String, Object?>{
                            'amount': formatMoney(emitted),
                            'limit': formatMoney(s.params.emitLimit),
                          },
                        ),
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
                const SizedBox(height: 8),
                Text(
                  t(
                    'Emisja czeka {hours} h. Wyższy limit obowiązuje 30 dni '
                    'po ogłoszeniu, niższy od razu.',
                    <String, Object?>{'hours': s.params.emitDelayHours},
                  ),
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 12.5,
                    height: 1.35,
                  ),
                ),
                if (top) ...<Widget>[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    key: const Key('emit-limit-change'),
                    onPressed: () =>
                        unawaited(changeEmissionLimit(context, pyr, s)),
                    icon: const Icon(Icons.tune_rounded),
                    label: Text(t('Zmień limity')),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => unawaited(() async {
                      final String? to = await pickMember(
                        context,
                        s,
                        title: t('Emisja dla'),
                      );
                      if (to == null || !context.mounted) {
                        return;
                      }
                      final int? amount = parseMoney(
                        await askText(
                              context,
                              title: t('Kwota emisji'),
                              label: t('Kwota, np. 1000,00'),
                              keyboard: const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                            ) ??
                            '',
                      );
                      if (!context.mounted || amount == null || amount <= 0) {
                        return;
                      }
                      // Never above the rolling limit: a higher limit
                      // applies only 30 days after it is announced.
                      if (amount > s.params.emitLimit - emitted) {
                        snack(
                          context,
                          t(
                            'Ponad limit 30 dni. Wyższy limit obowiązuje '
                            'dopiero 30 dni po ogłoszeniu.',
                          ),
                        );
                        return;
                      }
                      final String? why = await askText(
                        context,
                        title: t('Uzasadnienie (dla skarbników i odbiorcy)'),
                      );
                      if (why == null || !context.mounted) {
                        return;
                      }
                      // New money: asked again who this is.
                      if (!await confirmSensitiveAccess(
                        context,
                        reason: t('Emisja pieniędzy. Potwierdź, że to Ty.'),
                      )) {
                        return;
                      }
                      await pyr.emit(to, amount, why);
                      if (context.mounted) {
                        snack(
                          context,
                          t(
                            'Potrzebny podpis drugiej osoby ze szczytu; ważna '
                            'po {hours} h.',
                            <String, Object?>{'hours': s.params.emitDelayHours},
                          ),
                        );
                      }
                    }()),
                    icon: const Icon(Icons.add_card_rounded),
                    label: Text(t('Zaproponuj emisję')),
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
                    title: t('{amount} · K{term}', <String, Object?>{
                      'amount': formatMoney(e.amount),
                      'term': e.term,
                    }),
                    subtitle: <String>[
                      if (e.vetoed)
                        t('zawetowana')
                      else if (e.done)
                        t('wykonana')
                      else
                        t('czeka do {date}', <String, Object?>{
                          'date': pyrDate(e.effectiveAt),
                        }),
                      if (pyr.seenLate(e.id)) t('dotarła z opóźnieniem'),
                    ].join(' · '),
                    // Who could veto when it was signed, within its time —
                    // also when it reached this phone late.
                    trailing: pyr.canVeto(e)
                        ? TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: zen.danger,
                            ),
                            onPressed: () => unawaited(pyr.veto(e.id)),
                            child: Text(t('Weto')),
                          )
                        : null,
                  ),
              ],
            ),
          if (cheaters.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            ZenInfo(
              icon: Icons.warning_amber_rounded,
              tone: zen.danger,
              title: t(
                'Dowody: skarbnik podpisał dwa przelewy z tym samym numerem',
              ),
              text: cheaters.keys
                  .map((String k) => '• ${pyrWho(s, k)}')
                  .join('\n'),
            ),
          ],
          const SizedBox(height: 8),
          ZenInfo(
            icon: Icons.account_balance_rounded,
            tone: tone,
            text: <String>[
              tn(
                s.treasurers.length,
                one:
                    'Skarbnicy: {n} najwyżej postawiona osoba; przelew jest ważny przy {need} podpisie.',
                few:
                    'Skarbnicy: {n} najwyżej postawione osoby; przelew jest ważny przy {need} podpisach.',
                many:
                    'Skarbnicy: {n} najwyżej postawionych osób; przelew jest ważny przy {need} podpisach.',
                args: <String, Object?>{'need': s.treasurerMajority},
              ),
              t(
                'Przelewy są prywatne: widzą je tylko obie strony i skarbnicy, inni nie wiedzą nawet, że były. Najwyżej {count} przelewów na osobę dziennie.',
                <String, Object?>{'count': s.params.xferLimit},
              ),
            ].join('\n\n'),
          ),
        ],
      ),
    );
  }
}
