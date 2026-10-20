import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

Map<String, String> get kPowerNames => <String, String>{
  'ban': t('Bany (także stałe)'),
  'pause': t('Przerwy (ban czasowy)'),
  'content': t('Bany treści'),
  'reports': t('Przyjmowanie zgłoszeń'),
  'referendum': t('Referenda'),
  'alarm': t('Ogłoszenia alarmowe'),
};

/// Power (§21): delegations, reports, bans, referenda, alarms, the rules,
/// joining pyramids — for the top and the delegates.
class PyramidPower extends StatelessWidget {
  const PyramidPower({
    required this.pyr,
    required this.s,
    required this.me,
    super.key,
  });

  final PyramidService pyr;
  final PyramidState s;
  final String me;

  bool get _top => s.topCell.contains(me);

  /// My valid delegation with one of [powers], if any.
  String? _myDelegation(List<String> powers) {
    for (final PyrDelegation d in s.delegations.values) {
      if (d.to == me &&
          !d.revoked &&
          d.until > pyr.now &&
          powers.contains(d.power)) {
        return d.id;
      }
    }
    return null;
  }

  Future<void> _delegate(BuildContext context) async {
    final String? to = await pickMember(context, s, title: t('Komu?'));
    if (to == null || !context.mounted) {
      return;
    }
    String power = 'reports';
    bool sub = false;
    bool branch = false;
    final TextEditingController limit = TextEditingController(text: '0');
    final TextEditingController days = TextEditingController(text: '90');
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) => AlertDialog(
          title: Text(
            t('Delegacja dla {name}', <String, Object?>{
              'name': s.members[to]?.name,
            }),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final MapEntry<String, String> p in kPowerNames.entries)
                  PyrOption(
                    text: p.value,
                    selected: power == p.key,
                    onTap: () => set(() => power = p.key),
                  ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: branch,
                  title: Text(t('Tylko gałąź tej osoby')),
                  subtitle: Text(t('Inaczej: cała piramida.')),
                  onChanged: (bool v) => set(() => branch = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: limit,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t('Limit na 30 dni'),
                    helperText: t('0 = bez limitu'),
                    prefixIcon: const Icon(Icons.speed_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: days,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: t('Na ile dni'),
                    prefixIcon: const Icon(Icons.event_rounded),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: sub,
                  title: Text(t('Może delegować dalej')),
                  onChanged: (bool v) => set(() => sub = v),
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
              child: Text(t('Deleguj')),
            ),
          ],
        ),
      ),
    );
    final int l = int.tryParse(limit.text) ?? 0;
    final int d = int.tryParse(days.text) ?? 90;
    disposeLater(limit);
    disposeLater(days);
    if (ok != true) {
      return;
    }
    await pyr.delegate(
      to: to,
      power: power,
      scope: branch ? s.pathOf(to) ?? '' : '',
      limit: l,
      until: pyr.now + d * 24 * 3600 * 1000,
      sub: sub,
    );
    if (context.mounted) {
      snack(context, t('Potrzebny podpis drugiej osoby ze szczytu.'));
    }
  }

  /// What an appeal is about (§21.4): the ban it names, else the decision
  /// on the report it names.
  String _appealedDecision(Object? rep) {
    final PyrBan? ban = rep is String ? s.bans[rep] : null;
    if (ban != null) {
      return t('Ban ({kind}): {reason}', <String, Object?>{
        'kind': ban.kind,
        'reason': ban.reason,
      });
    }
    return s.decisions[rep] ?? '?';
  }

  Future<void> _decide(BuildContext context, PyrReport r) async {
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(kReportReasons[r.reason] ?? r.reason),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: ZenInfo(
              icon: Icons.description_outlined,
              text: <String>[
                if (r.target.isNotEmpty)
                  t('Kogo: {who}', <String, Object?>{
                    'who': pyrWho(s, r.target),
                  }),
                if (r.datingKey != null) t('Profil randkowy'),
                t('Dowód: {evidence}', <String, Object?>{
                  'evidence': r.evidence.isEmpty ? t('(brak)') : r.evidence,
                }),
                // S36: the signed original came with it and checked out.
                if (r.entry != null)
                  t('Dołączony podpisany oryginał wpisu (sprawdzony).'),
                if (r.stage > 0 || r.escalated)
                  t('Przekazane wyżej: brak decyzji niżej.'),
              ].join('\n'),
            ),
          ),
          for (final MapEntry<String, String> o in <String, String>{
            'none': t('Bez naruszenia'),
            // §21.1: breaks of 24 h, 7 days or 30 days.
            'pause1': t('Przerwa 24 h'),
            'pause7': t('Przerwa 7 dni'),
            'pause30': t('Przerwa 30 dni'),
            'content': t('Ban treści'),
            'dating': t('Wyłącz profil randkowy'),
            'noadmit': t('Zakaz przyjmowania do piramidy (90 dni)'),
            'perm': t('Ban stały'),
          }.entries)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(o.key),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Text(o.value),
            ),
        ],
      ),
    );
    if (choice == null) {
      return;
    }
    final String outcome = switch (choice) {
      'none' => t('Bez naruszenia'),
      'pause1' => t('Przerwa 24 h'),
      'pause7' => t('Przerwa 7 dni'),
      'pause30' => t('Przerwa 30 dni'),
      'content' => t('Ban treści'),
      'dating' => t('Wyłączony profil randkowy'),
      'noadmit' => t('Zakaz przyjmowania na 90 dni'),
      _ => t('Ban stały'),
    };
    final int? until = switch (choice) {
      'pause1' => pyr.now + 24 * 3600 * 1000,
      'pause7' => pyr.now + 7 * 24 * 3600 * 1000,
      'pause30' => pyr.now + 30 * 24 * 3600 * 1000,
      'noadmit' => pyr.now + 90 * 24 * 3600 * 1000,
      _ => null,
    };
    final bool pause = choice.startsWith('pause');
    await pyr.decide(
      r.id,
      outcome,
      via: _top ? null : _myDelegation(<String>['reports']),
      banVia: _top
          ? null
          : _myDelegation(<String>[
              if (pause) 'pause',
              if (choice == 'content' || choice == 'dating') 'content',
              'ban',
            ]),
      banKind: choice == 'none' ? null : (pause ? 'pause' : choice),
      until: until,
    );
  }

  Future<void> _referendum(BuildContext context) async {
    final TextEditingController q = TextEditingController();
    final TextEditingController opts = TextEditingController(
      text: t('Tak, Nie'),
    );
    final TextEditingController days = TextEditingController(text: '7');
    final TextEditingController params = TextEditingController(
      text: const JsonEncoder.withIndent(' ').convert(s.params.toJson()),
    );
    String scope = 'all';
    String kind = 'normal';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ZenColors zen = ZenColors.of(context);
          return AlertDialog(
            title: Text(t('Referendum')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const SizedBox(height: 4),
                  TextField(
                    controller: q,
                    minLines: 1,
                    maxLines: 3,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: t('Pytanie'),
                      hintText: t('np. Czy budujemy świetlicę?'),
                      prefixIcon: const Icon(Icons.help_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (kind != 'constitution') ...<Widget>[
                    TextField(
                      controller: opts,
                      decoration: InputDecoration(
                        labelText: t('Odpowiedzi'),
                        helperText: t('Po przecinku, np. Tak, Nie'),
                        prefixIcon: const Icon(Icons.list_rounded),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: days,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: t('Ile dni'),
                      prefixIcon: const Icon(Icons.event_rounded),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    t('KTO GŁOSUJE'),
                    style: zen.label(color: zen.textMuted),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final MapEntry<String, String> o in <String, String>{
                        'all': t('Cała piramida'),
                        'branch': t('Moja gałąź'),
                        'nat': t('Moja narodowość'),
                      }.entries)
                        ChoiceChip(
                          label: Text(o.value),
                          selected: scope == o.key,
                          onSelected: (_) => set(() => scope = o.key),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(t('RODZAJ'), style: zen.label(color: zen.textMuted)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final MapEntry<String, String> o in <String, String>{
                        'normal': t('Zwykłe'),
                        'constitution': t('Zmiana zasad'),
                      }.entries)
                        ChoiceChip(
                          label: Text(o.value),
                          selected: kind == o.key,
                          onSelected: (_) => set(() => kind = o.key),
                        ),
                    ],
                  ),
                  if (kind == 'constitution') ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      t('Odpowiedzi: Tak / Nie.'),
                      style: TextStyle(color: zen.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: params,
                      maxLines: 8,
                      style: zen.mono(color: zen.textPrimary, size: 12),
                      decoration: InputDecoration(
                        labelText: t('Nowe zasady'),
                        alignLabelWithHint: true,
                        // Money in the rules is in hundredths.
                        helperText: t(
                          'emitLimit w setnych: 100000000 = 1 000 000,00',
                        ),
                        helperMaxLines: 2,
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
                child: Text(t('Ogłoś')),
              ),
            ],
          );
        },
      ),
    );
    final String question = q.text.trim();
    final List<String> options = kind == 'constitution'
        ? <String>[t('Tak'), t('Nie')]
        : opts.text
              .split(',')
              .map((String o) => o.trim())
              .where((String o) => o.isNotEmpty)
              .toList();
    final int d = int.tryParse(days.text) ?? 7;
    Map<String, dynamic>? newParams;
    try {
      final Object? json = jsonDecode(params.text);
      newParams = json is Map ? Map<String, dynamic>.from(json) : null;
    } on FormatException {
      newParams = null;
    }
    for (final TextEditingController c in <TextEditingController>[
      q,
      opts,
      days,
      params,
    ]) {
      disposeLater(c);
    }
    if (ok != true || question.isEmpty || options.length < 2) {
      return;
    }
    await pyr.referendum(
      question: question,
      options: options,
      end: pyr.now + d * 24 * 3600 * 1000,
      scopeKind: scope,
      scopePath: scope == 'branch' ? s.pathOf(me) ?? '' : '',
      scopeNat: s.members[me]?.nat ?? '',
      kind: kind,
      params: kind == 'constitution' ? newParams : null,
      via: _top ? null : _myDelegation(<String>['referendum']),
    );
  }

  Future<void> _alarm(BuildContext context) async {
    final String? text = await askText(
      context,
      title: t('Ogłoszenie alarmowe (np. powódź)'),
      maxLines: 3,
    );
    if (text == null) {
      return;
    }
    final String? lead = s.nationalLead(s.members[me]?.nat ?? '');
    await pyr.alarm(
      text,
      scopeKind: _top || _myDelegation(<String>['alarm']) != null
          ? 'all'
          : (lead == me ? 'nat' : 'all'),
      scopeNat: s.members[me]?.nat ?? '',
      via: _top ? null : _myDelegation(<String>['alarm']),
    );
  }

  Future<void> _merge(BuildContext context) async {
    final List<String> others = pyr.knownPyramids
        .where((String p) => p != s.id)
        .toList();
    if (others.isEmpty) {
      final int asked = await pyr.fetchFriendsPyramids();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              asked == 0
                  ? t(
                      'Nikt ze znajomych nie ma innej piramidy (albo jeszcze '
                      'się nie odezwał).',
                    )
                  : tn(
                      asked,
                      one:
                          'Poprosiłem znajomych o {n} piramidę — spróbuj za '
                          'chwilę.',
                      few:
                          'Poprosiłem znajomych o {n} piramidy — spróbuj za '
                          'chwilę.',
                      many:
                          'Poprosiłem znajomych o {n} piramid — spróbuj za '
                          'chwilę.',
                    ),
            ),
          ),
        );
      }
      return;
    }
    final String? into = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(t('Dołącz naszą piramidę jako gałąź…')),
        children: <Widget>[
          if (others.isEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(t('Nie znasz innej piramidy.')),
            ),
          for (final String p in others)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(p),
              child: Text(pyr.stateOf(p)?.name ?? p.substring(0, 8)),
            ),
        ],
      ),
    );
    final PyramidState? other = into == null ? null : pyr.stateOf(into);
    if (other == null || !context.mounted) {
      return;
    }
    final String? under = await pickMember(
      context,
      other,
      title: t('Pod kim (musi mieć wolne miejsce)?'),
    );
    if (under == null || !context.mounted) {
      return;
    }
    // Our money: converted into theirs at an agreed rate, or left behind.
    final String target = into!;
    final ({int numer, int denom})? rate = await _askMergeRate(
      context,
      target,
      other.name,
    );
    if (rate == null || !context.mounted) {
      return;
    }
    await pyr.proposeMerge(
      target,
      under,
      other.members[under]?.addr ?? '',
      rate: rate.numer == 0 ? null : rate,
    );
    if (context.mounted) {
      snack(context, t('Propozycja połączenia poszła do podpisu.'));
    }
  }

  /// How our money goes over in a merge (§20.5): a rate (default 1:1;
  /// numer 0 = the money stays behind), or null when cancelled.
  Future<({int numer, int denom})?> _askMergeRate(
    BuildContext context,
    String into,
    String name,
  ) async {
    final TextEditingController value = TextEditingController(text: '100,00');
    bool keep = true;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final int typed = parseMoney(value.text) ?? 0;
          final ({int total, int converted, int room, int waiting})? m = pyr
              .mergeMoney(into, numer: typed <= 0 ? 1 : typed, denom: 10000);
          final bool fits = m == null || m.converted <= m.room;
          return AlertDialog(
            title: Text(t('Pieniądze przy połączeniu')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: keep,
                    title: Text(t('Przenieś nasze pieniądze')),
                    subtitle: Text(
                      keep
                          ? t(
                              'Salda przejdą do „{name}” po kursie.',
                              <String, Object?>{'name': name},
                            )
                          : t(
                              'Pieniądze zostaną w zamkniętej piramidzie '
                              '(bez wartości).',
                            ),
                    ),
                    onChanged: (bool v) => set(() => keep = v),
                  ),
                  if (keep) ...<Widget>[
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('pyr-merge-rate'),
                      controller: value,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (_) => set(() {}),
                      decoration: InputDecoration(
                        labelText: t(
                          'Za nasze 100,00 w „{name}”',
                          <String, Object?>{'name': name},
                        ),
                        prefixIcon: const Icon(Icons.currency_exchange_rounded),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ZenInfo(
                      icon: fits
                          ? Icons.info_outline_rounded
                          : Icons.warning_amber_rounded,
                      text: m == null
                          ? t(
                              'Nie znamy jeszcze stanu „{name}”.',
                              <String, Object?>{'name': name},
                            )
                          : <String>[
                              t(
                                'Razem u nas: {total} → {converted} w '
                                '„{name}”. To dla nich nowe pieniądze, więc '
                                'liczą się jak emisja: mieszczą się w limicie '
                                '30 dni (wolne: {room}), czekają {hours} h i '
                                'ich szczyt może je zawetować. Podpisuje też '
                                '2 z 3 ich szczytu.',
                                <String, Object?>{
                                  'total': formatMoney(m.total),
                                  'converted': formatMoney(m.converted),
                                  'name': name,
                                  'room': formatMoney(m.room),
                                  'hours':
                                      pyr
                                          .pyramidState(into)
                                          ?.params
                                          .emitDelayHours ??
                                      24,
                                },
                              ),
                              if (!fits)
                                t(
                                  'Za dużo — obniż kurs albo niech zmienią '
                                  'limit w referendum.',
                                ),
                              if (m.waiting > 0)
                                tn(
                                  m.waiting,
                                  one:
                                      'Uwaga: {n} emisja jeszcze czeka — nie '
                                      'przejdzie.',
                                  few:
                                      'Uwaga: {n} emisje jeszcze czekają — nie '
                                      'przejdą.',
                                  many:
                                      'Uwaga: {n} emisji jeszcze czeka — nie '
                                      'przejdzie.',
                                ),
                            ].join(' '),
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
                onPressed: !keep || (typed > 0 && fits)
                    ? () => Navigator.of(context).pop(true)
                    : null,
                child: Text(t('Zaproponuj')),
              ),
            ],
          );
        },
      ),
    );
    final int numer = parseMoney(value.text) ?? 0;
    disposeLater(value);
    if (ok != true) {
      return null;
    }
    if (!keep) {
      return (numer: 0, denom: 1);
    }
    return numer <= 0 ? null : (numer: numer, denom: 10000);
  }

  Widget _none(ZenColors zen, String text) => ZenCard(
    child: Row(
      children: <Widget>[
        Icon(
          Icons.check_circle_outline_rounded,
          color: zen.textMuted,
          size: 20,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: zen.textSecondary, fontSize: 14),
          ),
        ),
      ],
    ),
  );

  Widget _row(
    ZenColors zen, {
    required String title,
    String? subtitle,
    Widget? trailing,
    Widget? leading,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
    child: Row(
      children: <Widget>[
        if (leading != null) ...<Widget>[leading, const SizedBox(width: 12)],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle,
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

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final int now = pyr.now;
    final List<PyrDelegation> delegations = s.delegations.values
        .where((PyrDelegation d) => !d.revoked && d.until > now)
        .toList();
    final List<PyrBan> bans = s.bans.values
        .where((PyrBan b) => b.activeAt(now))
        .toList();
    final List<PyrAlarm> alarms = s.alarms.reversed.toList();
    // Only a referendum that passed, once the sums had their time to come
    // up (the same rule every phone applies, §21.7).
    final List<PyrReferendum> constitutions = s.referenda.values
        .where(
          (PyrReferendum r) =>
              r.kind == 'constitution' &&
              now >= r.end + kPyrTallyGraceMs &&
              s.constitutionPasses(r.id),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenHero(
          title: _top ? t('Jesteś na szczycie') : t('Twoje delegacje'),
          icon: _top ? Icons.workspace_premium_rounded : Icons.badge_rounded,
          tone: tone,
          text: _top
              ? t(
                  'Decyzje zapadają 2 z 3. Nie możesz usuwać ludzi z piramidy '
                  'ani blokować awansów.',
                )
              : t('Każdy akt jest jawny i szczyt może go uchylić.'),
          actions: <Widget>[
            if (_top)
              FilledButton.icon(
                onPressed: () => unawaited(_delegate(context)),
                icon: const Icon(Icons.badge_rounded),
                label: Text(t('Deleguj')),
              ),
            if (_top ||
                _myDelegation(<String>['referendum']) != null ||
                s.nationalLead(s.members[me]?.nat ?? '') == me)
              OutlinedButton.icon(
                onPressed: () => unawaited(_referendum(context)),
                icon: const Icon(Icons.how_to_vote_rounded),
                label: Text(t('Referendum')),
              ),
            if (_top ||
                _myDelegation(<String>['alarm']) != null ||
                s.nationalLead(s.members[me]?.nat ?? '') == me)
              OutlinedButton.icon(
                onPressed: () => unawaited(_alarm(context)),
                icon: const Icon(Icons.warning_amber_rounded),
                label: Text(t('Ogłoszenie alarmowe')),
              ),
            if (_top)
              OutlinedButton.icon(
                onPressed: () => unawaited(_merge(context)),
                icon: const Icon(Icons.merge_rounded),
                label: Text(t('Połącz piramidy')),
              ),
          ],
        ),
        if (pyr.inbox.isNotEmpty) ...<Widget>[
          ZenSection(
            t('Zgłoszenia ({count})', <String, Object?>{
              'count': pyr.inbox.length,
            }),
          ),
          for (final PyrReport r in pyr.inbox.values)
            ZenCard(
              tone: zen.danger,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      ZenIconBadge(
                        icon: Icons.flag_rounded,
                        tone: zen.danger,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              kReportReasons[r.reason] ?? r.reason,
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${r.target.isEmpty ? t('treść') : pyrWho(s, r.target)} · ${pyrDate(r.at)}',
                              style: TextStyle(
                                color: zen.textSecondary,
                                fontSize: 12.5,
                                height: 1.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => unawaited(_decide(context, r)),
                      child: Text(t('Rozpatrz')),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (pyr.appeals.isNotEmpty && _top) ...<Widget>[
          ZenSection(t('Odwołania')),
          ZenGroup(
            children: <Widget>[
              for (final Map<String, dynamic> a in pyr.appeals)
                _row(
                  zen,
                  leading: ZenIconBadge(
                    icon: Icons.replay_rounded,
                    tone: zen.warning,
                    size: 36,
                  ),
                  title: '${s.members[a['k']]?.name ?? '?'}: ${a['t']}',
                  subtitle: t('Decyzja: {decision}', <String, Object?>{
                    'decision': _appealedDecision(a['rep']),
                  }),
                  // The answer to an appeal against a ban: lift it.
                  trailing: _top && (s.bans[a['rep']]?.activeAt(now) ?? false)
                      ? TextButton(
                          key: Key('appeal-lift-${a['rep']}'),
                          onPressed: () => unawaited(
                            pyr.topDecision(<String, dynamic>{
                              't': 'unban',
                              'ban': a['rep'],
                            }),
                          ),
                          child: Text(t('Uchyl')),
                        )
                      : null,
                ),
            ],
          ),
        ],
        ZenSection(t('Delegacje')),
        if (delegations.isEmpty)
          _none(zen, t('Brak.'))
        else
          ZenGroup(
            children: <Widget>[
              for (final PyrDelegation d in delegations)
                _row(
                  zen,
                  leading: ZenIconBadge(
                    icon: Icons.badge_outlined,
                    tone: tone,
                    size: 36,
                  ),
                  title:
                      '${kPowerNames[d.power] ?? d.power}: ${s.members[d.to]?.name ?? '?'}',
                  subtitle: <String>[
                    if (d.scope.isEmpty) t('cała piramida') else t('gałąź'),
                    t('do {date}', <String, Object?>{'date': pyrDate(d.until)}),
                    if (d.limit > 0)
                      t('{limit}/30 dni', <String, Object?>{'limit': d.limit}),
                    if (d.sub) t('może dalej'),
                  ].join(' · '),
                  trailing: _top
                      ? TextButton(
                          onPressed: () =>
                              unawaited(pyr.revokeDelegation(d.id)),
                          child: Text(t('Cofnij')),
                        )
                      : null,
                ),
            ],
          ),
        ZenSection(t('Aktywne bany')),
        if (bans.isEmpty)
          _none(zen, t('Brak.'))
        else
          ZenGroup(
            children: <Widget>[
              for (final PyrBan b in bans)
                _row(
                  zen,
                  leading: ZenIconBadge(
                    icon: Icons.block_rounded,
                    tone: zen.danger,
                    size: 36,
                  ),
                  title:
                      '${b.kind}: ${b.target.isEmpty ? t('treść') : s.members[b.target]?.name ?? '?'}',
                  subtitle: <String>[
                    b.reason,
                    if (b.until != null)
                      t('do {date}', <String, Object?>{
                        'date': pyrDate(b.until!),
                      }),
                  ].join(' · '),
                  trailing: _top
                      ? TextButton(
                          onPressed: () => unawaited(
                            pyr.topDecision(<String, dynamic>{
                              't': 'unban',
                              'ban': b.id,
                            }),
                          ),
                          child: Text(t('Uchyl')),
                        )
                      : null,
                ),
            ],
          ),
        ZenSection(t('Ogłoszenia alarmowe')),
        if (alarms.isEmpty) _none(zen, t('Brak.')),
        for (final PyrAlarm a in alarms)
          ZenCard(
            tone: zen.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.warning_amber_rounded, color: zen.warning),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            a.text,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              height: 1.35,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            <String>[
                              pyrDate(a.at),
                              t('do {date}', <String, Object?>{
                                'date': pyrDate(a.until),
                              }),
                            ].join(' · '),
                            style: TextStyle(
                              color: zen.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => unawaited(() async {
                      final int n = await pyr.broadcastCrisis(a.id);
                      if (context.mounted) {
                        snack(
                          context,
                          tn(
                            n,
                            one:
                                'Przez Bluetooth do {n} telefonu w pobliżu; '
                                'on poda dalej.',
                            few:
                                'Przez Bluetooth do {n} telefonów w pobliżu; '
                                'one podadzą dalej.',
                            many:
                                'Przez Bluetooth do {n} telefonów w pobliżu; '
                                'one podadzą dalej.',
                          ),
                        );
                      }
                    }()),
                    icon: const Icon(Icons.bluetooth_rounded, size: 18),
                    label: const Text('Bluetooth'),
                  ),
                ),
              ],
            ),
          ),
        ZenSection(
          t('Zasady (wersja {version})', <String, Object?>{
            'version': s.params.version,
          }),
        ),
        ZenCard(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              const JsonEncoder.withIndent('  ').convert(s.params.toJson()),
              style: zen.mono(color: zen.textSecondary, size: 12, height: 1.4),
            ),
          ),
        ),
        if (_top)
          for (final PyrReferendum r in constitutions)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: FilledButton.tonalIcon(
                onPressed: () => unawaited(
                  pyr.topDecision(<String, dynamic>{'t': 'const', 'ref': r.id}),
                ),
                icon: const Icon(Icons.gavel_rounded),
                label: Text(
                  t(
                    'Zastosuj zasady z referendum „{question}”',
                    <String, Object?>{'question': r.question},
                  ),
                ),
              ),
            ),
      ],
    );
  }
}
