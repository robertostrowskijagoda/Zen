import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

const Map<String, String> kPowerNames = <String, String>{
  'ban': 'Bany (także stałe)',
  'pause': 'Przerwy (ban czasowy)',
  'content': 'Bany treści',
  'reports': 'Przyjmowanie zgłoszeń',
  'referendum': 'Referenda',
  'alarm': 'Ogłoszenia alarmowe',
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
    final String? to = await pickMember(context, s, title: 'Komu?');
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
          title: Text('Delegacja dla ${s.members[to]?.name}'),
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
                  title: const Text('Tylko gałąź tej osoby'),
                  subtitle: const Text('Inaczej: cała piramida.'),
                  onChanged: (bool v) => set(() => branch = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: limit,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Limit na 30 dni',
                    helperText: '0 = bez limitu',
                    prefixIcon: Icon(Icons.speed_rounded),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: days,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Na ile dni',
                    prefixIcon: Icon(Icons.event_rounded),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: sub,
                  title: const Text('Może delegować dalej'),
                  onChanged: (bool v) => set(() => sub = v),
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
              child: const Text('Deleguj'),
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
      snack(context, 'Potrzebny podpis drugiej osoby ze szczytu.');
    }
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
              text:
                  '${r.target.isEmpty ? '' : 'Kogo: ${pyrWho(s, r.target)}\n'}'
                  '${r.datingKey != null ? 'Profil randkowy\n' : ''}'
                  'Dowód: ${r.evidence.isEmpty ? '(brak)' : r.evidence}',
            ),
          ),
          for (final MapEntry<String, String> o in const <String, String>{
            'none': 'Bez naruszenia',
            'pause': 'Przerwa 7 dni',
            'content': 'Ban treści',
            'dating': 'Wyłącz profil randkowy',
            'noadmit': 'Zakaz przyjmowania do piramidy (90 dni)',
            'perm': 'Ban stały',
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
      'none' => 'Bez naruszenia',
      'pause' => 'Przerwa 7 dni',
      'content' => 'Ban treści',
      'dating' => 'Wyłączony profil randkowy',
      'noadmit' => 'Zakaz przyjmowania na 90 dni',
      _ => 'Ban stały',
    };
    final int? until = switch (choice) {
      'pause' => pyr.now + 7 * 24 * 3600 * 1000,
      'noadmit' => pyr.now + 90 * 24 * 3600 * 1000,
      _ => null,
    };
    await pyr.decide(
      r.id,
      outcome,
      via: _top ? null : _myDelegation(<String>['reports']),
      banVia: _top
          ? null
          : _myDelegation(<String>[
              if (choice == 'pause') 'pause',
              if (choice == 'content' || choice == 'dating') 'content',
              'ban',
            ]),
      banKind: choice == 'none' ? null : choice,
      until: until,
    );
  }

  Future<void> _referendum(BuildContext context) async {
    final TextEditingController q = TextEditingController();
    final TextEditingController opts = TextEditingController(text: 'Tak, Nie');
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
            title: const Text('Referendum'),
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
                    decoration: const InputDecoration(
                      labelText: 'Pytanie',
                      hintText: 'np. Czy budujemy świetlicę?',
                      prefixIcon: Icon(Icons.help_outline_rounded),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (kind != 'constitution') ...<Widget>[
                    TextField(
                      controller: opts,
                      decoration: const InputDecoration(
                        labelText: 'Odpowiedzi',
                        helperText: 'Po przecinku, np. Tak, Nie',
                        prefixIcon: Icon(Icons.list_rounded),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextField(
                    controller: days,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Ile dni',
                      prefixIcon: Icon(Icons.event_rounded),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('KTO GŁOSUJE', style: zen.label(color: zen.textMuted)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final MapEntry<String, String> o
                          in const <String, String>{
                            'all': 'Cała piramida',
                            'branch': 'Moja gałąź',
                            'nat': 'Moja narodowość',
                          }.entries)
                        ChoiceChip(
                          label: Text(o.value),
                          selected: scope == o.key,
                          onSelected: (_) => set(() => scope = o.key),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text('RODZAJ', style: zen.label(color: zen.textMuted)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final MapEntry<String, String> o
                          in const <String, String>{
                            'normal': 'Zwykłe',
                            'constitution': 'Zmiana zasad',
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
                      'Odpowiedzi: Tak / Nie.',
                      style: TextStyle(color: zen.textSecondary, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: params,
                      maxLines: 8,
                      style: zen.mono(color: zen.textPrimary, size: 12),
                      decoration: const InputDecoration(
                        labelText: 'Nowe zasady',
                        alignLabelWithHint: true,
                        // Money in the rules is in hundredths.
                        helperText:
                            'emitLimit w setnych: 100000000 = 1 000 000,00',
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
                child: const Text('Anuluj'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Ogłoś'),
              ),
            ],
          );
        },
      ),
    );
    final String question = q.text.trim();
    final List<String> options = kind == 'constitution'
        ? <String>['Tak', 'Nie']
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
      title: 'Ogłoszenie alarmowe (np. powódź)',
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
                  ? 'Nikt ze znajomych nie ma innej piramidy (albo jeszcze się nie odezwał).'
                  : 'Poprosiłem znajomych o $asked piramid(y) — spróbuj za chwilę.',
            ),
          ),
        );
      }
      return;
    }
    final String? into = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('Dołącz naszą piramidę jako gałąź…'),
        children: <Widget>[
          if (others.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Nie znasz innej piramidy.'),
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
      title: 'Pod kim (musi mieć wolne miejsce)?',
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
      snack(context, 'Propozycja połączenia poszła do podpisu.');
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
            title: const Text('Pieniądze przy połączeniu'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: keep,
                    title: const Text('Przenieś nasze pieniądze'),
                    subtitle: Text(
                      keep
                          ? 'Salda przejdą do „$name” po kursie.'
                          : 'Pieniądze zostaną w zamkniętej piramidzie (bez wartości).',
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
                        labelText: 'Za nasze 100,00 w „$name”',
                        prefixIcon: const Icon(Icons.currency_exchange_rounded),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ZenInfo(
                      icon: fits
                          ? Icons.info_outline_rounded
                          : Icons.warning_amber_rounded,
                      text: m == null
                          ? 'Nie znamy jeszcze stanu „$name”.'
                          : 'Razem u nas: ${formatMoney(m.total)} → '
                                '${formatMoney(m.converted)} w „$name”. '
                                'To dla nich nowe pieniądze, więc liczą się jak '
                                'emisja: mieszczą się w limicie 30 dni (wolne: '
                                '${formatMoney(m.room)}), czekają ${pyr.pyramidState(into)?.params.emitDelayHours ?? 24} h '
                                'i ich szczyt może je zawetować. Podpisuje też '
                                '2 z 3 ich szczytu.'
                                '${fits ? '' : ' Za dużo — obniż kurs albo niech zmienią limit w referendum.'}'
                                '${m.waiting > 0 ? ' Uwaga: ${m.waiting} emisja(-e) jeszcze czeka — nie przejdzie.' : ''}',
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
                onPressed: !keep || (typed > 0 && fits)
                    ? () => Navigator.of(context).pop(true)
                    : null,
                child: const Text('Zaproponuj'),
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
    final int t = pyr.now;
    final List<PyrDelegation> delegations = s.delegations.values
        .where((PyrDelegation d) => !d.revoked && d.until > t)
        .toList();
    final List<PyrBan> bans = s.bans.values
        .where((PyrBan b) => b.activeAt(t))
        .toList();
    final List<PyrAlarm> alarms = s.alarms.reversed.toList();
    // Only a referendum that passed, once the sums had their time to come
    // up (the same rule every phone applies, §21.7).
    final List<PyrReferendum> constitutions = s.referenda.values
        .where(
          (PyrReferendum r) =>
              r.kind == 'constitution' &&
              t >= r.end + kPyrTallyGraceMs &&
              s.constitutionPasses(r.id),
        )
        .toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenHero(
          title: _top ? 'Jesteś na szczycie' : 'Twoje delegacje',
          icon: _top ? Icons.workspace_premium_rounded : Icons.badge_rounded,
          tone: tone,
          text: _top
              ? 'Decyzje zapadają 2 z 3. Nie możesz usuwać ludzi z piramidy ani blokować awansów.'
              : 'Każdy akt jest jawny i szczyt może go uchylić.',
          actions: <Widget>[
            if (_top)
              FilledButton.icon(
                onPressed: () => unawaited(_delegate(context)),
                icon: const Icon(Icons.badge_rounded),
                label: const Text('Deleguj'),
              ),
            if (_top ||
                _myDelegation(<String>['referendum']) != null ||
                s.nationalLead(s.members[me]?.nat ?? '') == me)
              OutlinedButton.icon(
                onPressed: () => unawaited(_referendum(context)),
                icon: const Icon(Icons.how_to_vote_rounded),
                label: const Text('Referendum'),
              ),
            if (_top ||
                _myDelegation(<String>['alarm']) != null ||
                s.nationalLead(s.members[me]?.nat ?? '') == me)
              OutlinedButton.icon(
                onPressed: () => unawaited(_alarm(context)),
                icon: const Icon(Icons.warning_amber_rounded),
                label: const Text('Ogłoszenie alarmowe'),
              ),
            if (_top)
              OutlinedButton.icon(
                onPressed: () => unawaited(_merge(context)),
                icon: const Icon(Icons.merge_rounded),
                label: const Text('Połącz piramidy'),
              ),
          ],
        ),
        if (pyr.inbox.isNotEmpty) ...<Widget>[
          ZenSection('Zgłoszenia (${pyr.inbox.length})'),
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
                              '${r.target.isEmpty ? 'treść' : pyrWho(s, r.target)} · ${pyrDate(r.at)}',
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
                      child: const Text('Rozpatrz'),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (pyr.appeals.isNotEmpty && _top) ...<Widget>[
          const ZenSection('Odwołania'),
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
                  subtitle: 'Decyzja: ${s.decisions[a['rep']] ?? '?'}',
                ),
            ],
          ),
        ],
        const ZenSection('Delegacje'),
        if (delegations.isEmpty)
          _none(zen, 'Brak.')
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
                  subtitle:
                      '${d.scope.isEmpty ? 'cała piramida' : 'gałąź'} · do ${pyrDate(d.until)}${d.limit > 0 ? ' · ${d.limit}/30 dni' : ''}${d.sub ? ' · może dalej' : ''}',
                  trailing: _top
                      ? TextButton(
                          onPressed: () => unawaited(
                            pyr.topDecision(<String, dynamic>{
                              't': 'revoke',
                              'd': d.id,
                            }),
                          ),
                          child: const Text('Cofnij'),
                        )
                      : null,
                ),
            ],
          ),
        const ZenSection('Aktywne bany'),
        if (bans.isEmpty)
          _none(zen, 'Brak.')
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
                      '${b.kind}: ${b.target.isEmpty ? 'treść' : s.members[b.target]?.name ?? '?'}',
                  subtitle:
                      '${b.reason}${b.until != null ? ' · do ${pyrDate(b.until!)}' : ''}',
                  trailing: _top
                      ? TextButton(
                          onPressed: () => unawaited(
                            pyr.topDecision(<String, dynamic>{
                              't': 'unban',
                              'ban': b.id,
                            }),
                          ),
                          child: const Text('Uchyl'),
                        )
                      : null,
                ),
            ],
          ),
        const ZenSection('Ogłoszenia alarmowe'),
        if (alarms.isEmpty) _none(zen, 'Brak.'),
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
                            '${pyrDate(a.at)} · do ${pyrDate(a.until)}',
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
                          'Przez Bluetooth do $n telefonów w pobliżu; one podadzą dalej.',
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
        ZenSection('Zasady (wersja ${s.params.version})'),
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
                label: Text('Zastosuj zasady z referendum „${r.question}”'),
              ),
            ),
      ],
    );
  }
}
