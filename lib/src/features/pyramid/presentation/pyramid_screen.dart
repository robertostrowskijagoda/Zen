import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_glyphs.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_decisions.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_power.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/presentation/report_sheet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// "12.10.2026 18:00".
String pyrDate(int millis) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int x) => x.toString().padLeft(2, '0');
  return '${two(d.day)}.${two(d.month)}.${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// A member's name, level and branch: "Kasia · poziom 3 · gałąź 12 os.".
String pyrWho(PyramidState s, String key) {
  final String? p = s.pathOf(key);
  final String name = s.members[key]?.name ?? '?';
  if (p == null) {
    return name;
  }
  return t('{name} · poziom {level} · gałąź {count} os.', <String, Object?>{
    'name': name,
    'level': p.length,
    'count': s.branchSize(p),
  });
}

/// The colour of the pyramid feature.
Color pyrTone(ZenColors zen) => zenTone(zen, 7);

/// The first letter of a name, for avatars.
String pyrInitial(String name) {
  final String t = name.trim();
  return t.isEmpty ? '?' : String.fromCharCode(t.runes.first).toUpperCase();
}

/// A round avatar with an initial or a small text (a level number).
class PyrAvatar extends StatelessWidget {
  const PyrAvatar({
    required this.text,
    this.tone,
    this.size = 36,
    this.filled = false,
    super.key,
  });

  final String text;
  final Color? tone;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color t = tone ?? pyrTone(zen);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? t : null,
        gradient: filled
            ? null
            : LinearGradient(
                colors: <Color>[
                  t.withValues(alpha: 0.30),
                  t.withValues(alpha: 0.12),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
        border: Border.all(color: t.withValues(alpha: filled ? 1 : 0.35)),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: zen.display(
          color: filled ? ZenColors.foregroundFor(t) : t,
          size: size * 0.42,
          weight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// A thin rounded progress bar.
class PyrBar extends StatelessWidget {
  const PyrBar({required this.value, this.tone, this.height = 8, super.key});

  final double value;
  final Color? tone;
  final double height;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: value.isNaN ? 0 : value.clamp(0.0, 1.0).toDouble(),
        minHeight: height,
        backgroundColor: zen.surfaceSunk,
        color: tone ?? pyrTone(zen),
      ),
    );
  }
}

/// One choice of a short list in a dialog (a radio row that wraps long text).
class PyrOption extends StatelessWidget {
  const PyrOption({
    required this.text,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String text;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color t = pyrTone(zen);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? t.withValues(alpha: 0.12) : zen.surfaceMuted,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(
              children: <Widget>[
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected ? t : zen.textMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Simple text input dialog.
Future<String?> askText(
  BuildContext context, {
  required String title,
  String label = '',
  String initial = '',
  int maxLines = 1,
  TextInputType? keyboard,
}) async {
  final TextEditingController c = TextEditingController(text: initial);
  final String? out = await showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        minLines: 1,
        maxLines: maxLines,
        keyboardType: keyboard,
        textCapitalization: keyboard == null
            ? TextCapitalization.sentences
            : TextCapitalization.none,
        decoration: InputDecoration(
          labelText: label.isEmpty ? null : label,
          hintText: maxLines > 1 ? t('Napisz tutaj…') : null,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(c.text.trim()),
          child: Text(t('OK')),
        ),
      ],
    ),
  );
  disposeLater(c);
  return out == null || out.isEmpty ? null : out;
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Tak')),
          ),
        ],
      ),
    ) ??
    false;

void snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

/// The "Piramida" tab (§20–24).
class PyramidScreen extends ConsumerWidget {
  const PyramidScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final PyramidService pyr = ref.watch(pyramidServiceProvider);
    return ListenableBuilder(
      listenable: pyr,
      builder: (BuildContext context, Widget? _) {
        final PyramidState? s = pyr.state;
        final String? me = pyr.myKey;
        if (s == null || me == null || !s.isMember(me)) {
          return Scaffold(
            key: const Key('pyramid-screen'),
            appBar: ZenSectionBar(title: t('Piramida')),
            body: _JoinView(pyr: pyr),
          );
        }
        final bool power =
            s.topCell.contains(me) ||
            s.delegations.values.any(
              (PyrDelegation d) => d.to == me && !d.revoked,
            ) ||
            pyr.inbox.isNotEmpty;
        final List<Tab> tabs = <Tab>[
          Tab(text: t('Ja')),
          Tab(text: t('Polityka')),
          Tab(text: t('Kraj')),
          Tab(text: t('Głosowania')),
          Tab(text: t('Portfel')),
          if (power) Tab(text: t('Władza')),
          Tab(text: t('Historia')),
        ];
        return DefaultTabController(
          length: tabs.length,
          child: Scaffold(
            key: const Key('pyramid-screen'),
            appBar: _PyramidAppBar(
              title: s.name.isEmpty ? t('Piramida') : s.name,
              actions: <Widget>[
                if (pyr.proposals.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: IconButton(
                      key: const Key('pyr-proposals'),
                      tooltip: t('Do podpisania'),
                      onPressed: () => unawaited(showProposals(context, pyr)),
                      icon: Badge(
                        label: Text('${pyr.proposals.length}'),
                        child: const Icon(Icons.draw_rounded),
                      ),
                    ),
                  ),
              ],
              tabs: tabs,
            ),
            body: TabBarView(
              children: <Widget>[
                _MeTab(pyr: pyr, s: s, me: me),
                _PoliticsTab(pyr: pyr, s: s, me: me),
                _NationTab(pyr: pyr, s: s, me: me),
                _VotesTab(pyr: pyr, s: s, me: me),
                PyramidWallet(pyr: pyr, s: s, me: me),
                if (power) PyramidPower(pyr: pyr, s: s, me: me),
                _HistoryTab(s: s),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The section bar of the pyramid, with its tabs below.
class _PyramidAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _PyramidAppBar({
    required this.title,
    required this.tabs,
    this.actions = const <Widget>[],
  });

  final String title;
  final List<Widget> actions;
  final List<Tab> tabs;

  @override
  Size get preferredSize =>
      const Size.fromHeight(kToolbarHeight + kTextTabBarHeight);

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return AppBar(
      titleSpacing: 20,
      actions: actions,
      title: Row(
        children: <Widget>[
          Container(
            width: 5,
            height: 24,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: <Color>[pyrTone(zen), zen.accentSecondary],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: zen.display(
                color: zen.textPrimary,
                size: 24,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      bottom: TabBar(
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        tabs: tabs,
      ),
    );
  }
}

/// What waits for this person's signature.
Future<void> showProposals(
  BuildContext context,
  PyramidService pyr,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (BuildContext context) => ListenableBuilder(
    listenable: pyr,
    builder: (BuildContext context, Widget? _) {
      final ZenColors zen = ZenColors.of(context);
      final Color tone = pyrTone(zen);
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: <Widget>[
            Row(
              children: <Widget>[
                ZenIconBadge(icon: Icons.draw_rounded, tone: tone, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    t('Do podpisania'),
                    style: zen.display(
                      color: zen.textPrimary,
                      size: 22,
                      weight: FontWeight.w600,
                    ),
                  ),
                ),
                if (pyr.proposals.isNotEmpty)
                  ZenPill(
                    text: '${pyr.proposals.length}',
                    tone: tone,
                    filled: true,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (pyr.proposals.isEmpty)
              ZenEmpty(
                icon: Icons.task_alt_rounded,
                title: t('Nic nie czeka.'),
                tone: zen.success,
              ),
            for (final PyrProposal p in pyr.proposals.values)
              ZenCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      pyr.describeRecord(p.record),
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    // Everything the signature decides, the record's own
                    // time first (§20.5).
                    for (final String line in pyr.recordDetails(p.record))
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          line,
                          style: TextStyle(
                            // The service writes its warnings as
                            // "Uwaga: …" (translated too).
                            color: line.startsWith(t('Uwaga'))
                                ? zen.warning
                                : zen.textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ),
                    if (p.record.type == PyrT.admit) ...<Widget>[
                      const SizedBox(height: 8),
                      ZenInfo(
                        icon: Icons.verified_user_outlined,
                        tone: zen.warning,
                        title: t('Potwierdzasz, że to prawda — ręczysz za to:'),
                        text: t(
                          'pseudonim: {name}\n'
                          'narodowość: {nat}\n'
                          'rok urodzenia: {year} · płeć: {gender}',
                          <String, Object?>{
                            'name': (p.record.body['m'] as Map?)?['n'],
                            'nat': (p.record.body['m'] as Map?)?['nat'],
                            'year': p.extra['by'],
                            'gender': p.extra['g'],
                          },
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            t(
                              'Podpisy: {count} z {need} potrzebnych',
                              <String, Object?>{
                                'count': p.record.sigs.length,
                                'need': p.need,
                              },
                            ),
                            style: TextStyle(
                              color: zen.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          pyrDate(p.at),
                          style: TextStyle(color: zen.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    PyrBar(
                      value: p.need <= 0 ? 1.0 : p.record.sigs.length / p.need,
                      tone: tone,
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.end,
                        children: <Widget>[
                          TextButton(
                            onPressed: () => unawaited(pyr.reject(p.record.id)),
                            child: Text(t('Odrzuć')),
                          ),
                          FilledButton.icon(
                            key: Key('pyr-approve-${p.record.type}'),
                            onPressed: () =>
                                unawaited(pyr.approve(p.record.id)),
                            icon: const Icon(Icons.draw_rounded, size: 18),
                            label: Text(t('Podpisz')),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  ),
);

class _JoinView extends ConsumerStatefulWidget {
  const _JoinView({required this.pyr});

  final PyramidService pyr;

  @override
  ConsumerState<_JoinView> createState() => _JoinViewState();
}

class _JoinViewState extends ConsumerState<_JoinView> {
  Future<Map<String, Object>?> _askData({bool withPyramidName = false}) async {
    final TextEditingController pname = TextEditingController();
    final TextEditingController name = TextEditingController();
    final TextEditingController nat = TextEditingController(text: 'PL');
    final TextEditingController year = TextEditingController();
    String gender = 'k';
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ZenColors zen = ZenColors.of(context);
          return AlertDialog(
            title: Text(withPyramidName ? t('Nowa piramida') : t('Dołączenie')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 4),
                  if (withPyramidName) ...<Widget>[
                    TextField(
                      controller: pname,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: t('Nazwa piramidy / ruchu'),
                        hintText: t('np. Sąsiedzi z Mokotowa'),
                        prefixIcon: const ZenIcon(kPyramidIcon),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextField(
                    key: const Key('pyr-pseudonym'),
                    controller: name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: t('Pseudonim w piramidzie'),
                      hintText: t('np. Kasia_K'),
                      prefixIcon: const Icon(Icons.badge_outlined),
                      helperText: t(
                        'Komórka zna Cię osobiście, reszta tylko pseudonim.',
                      ),
                      helperMaxLines: 3,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nat,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: t('Narodowość'),
                      hintText: 'PL',
                      prefixIcon: const Icon(Icons.flag_outlined),
                      helperText: t('Kod kraju, np. PL, UA, DE.'),
                      helperMaxLines: 2,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: year,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: t('Rok urodzenia'),
                      hintText: t('np. 1990'),
                      prefixIcon: const Icon(Icons.cake_outlined),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(t('PŁEĆ'), style: zen.label(color: zen.textMuted)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final MapEntry<String, String> g in <String, String>{
                        'k': t('kobieta'),
                        'm': t('mężczyzna'),
                        'i': t('inna'),
                      }.entries)
                        ChoiceChip(
                          showCheckmark: false,
                          avatar: Icon(switch (g.key) {
                            'k' => Icons.female_rounded,
                            'm' => Icons.male_rounded,
                            _ => Icons.transgender_rounded,
                          }, size: 18),
                          label: Text(g.value),
                          selected: gender == g.key,
                          onSelected: (_) => set(() => gender = g.key),
                        ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ZenInfo(
                    icon: Icons.lock_outline_rounded,
                    tone: zen.warning,
                    text: t(
                      'Tych danych nie da się później zmienić. Osoba, '
                      'która Cię przyjmuje, potwierdza je podpisem. Publicznie '
                      'widać tylko narodowość; rok i płeć — tylko jako skrót.',
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
                child: Text(t('Dalej')),
              ),
            ],
          );
        },
      ),
    );
    final int? y = int.tryParse(year.text.trim());
    final Map<String, Object>? out =
        ok == true && name.text.trim().isNotEmpty && y != null && y > 1900
        ? <String, Object>{
            'pname': pname.text.trim(),
            'name': name.text.trim(),
            'nat': nat.text.trim(),
            'year': y,
            'g': gender,
          }
        : null;
    for (final TextEditingController c in <TextEditingController>[
      pname,
      name,
      nat,
      year,
    ]) {
      disposeLater(c);
    }
    return out;
  }

  Future<void> _join() async {
    final String? code = await scanOrPaste(
      context,
      ref,
      title: t('Kod zaproszenia do piramidy'),
    );
    if (code == null || !mounted) {
      return;
    }
    if (PyramidService.parseInvite(code) == null) {
      snack(context, t('To nie jest zaproszenie do piramidy.'));
      return;
    }
    final Map<String, Object>? d = await _askData();
    if (d == null) {
      return;
    }
    await widget.pyr.askToJoin(
      invite: code,
      myName: d['name']! as String,
      nat: d['nat']! as String,
      birthYear: d['year']! as int,
      gender: d['g']! as String,
    );
    if (mounted) {
      snack(
        context,
        t('Wysłane. Gdy osoba przyjmująca potwierdzi, będziesz w piramidzie.'),
      );
    }
  }

  Future<void> _create() async {
    final Map<String, Object>? d = await _askData(withPyramidName: true);
    if (d == null) {
      return;
    }
    await widget.pyr.createPyramid(
      name: (d['pname']! as String).isEmpty
          ? t('Piramida')
          : d['pname']! as String,
      myName: d['name']! as String,
      nat: d['nat']! as String,
      birthYear: d['year']! as int,
      gender: d['g']! as String,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final PyramidState? browsing = widget.pyr.state;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenHero(
          title: t('Piramida ludzi, którzy się znają'),
          icon: kPyramidIcon,
          tone: tone,
          text: t(
            'Komórki po trzy osoby, każdy przyjęty osobiście przez znajomego. '
            'Z piramidy wynikają głosowania, sekcja krajowa i waluta.',
          ),
        ),
        ZenSection(t('Jak to działa'), top: 12),
        ZenCard(
          child: Column(
            children: <Widget>[
              _Fact(
                icon: Icons.groups_rounded,
                tone: tone,
                title: t('Komórki po trzy'),
                text: t('Znasz osobiście szefa i dwie osoby pod sobą.'),
              ),
              const SizedBox(height: 14),
              _Fact(
                icon: Icons.swap_vert_rounded,
                tone: zenTone(zen, 1),
                title: t('Władza oddolna'),
                text: t(
                  'Szefów zmienia się 2 z 3, a szczyt ma tylko tyle władzy, '
                  'ile dają mu podpisy.',
                ),
              ),
              const SizedBox(height: 14),
              _Fact(
                icon: Icons.visibility_rounded,
                tone: zenTone(zen, 3),
                title: t('Wszystko jawne'),
                text: t('Każda zmiana to podpisany wpis w historii.'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('pyr-join'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => unawaited(_join()),
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: Text(t('Dołącz — zeskanuj kod znajomego')),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('pyr-create'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
          onPressed: () => unawaited(_create()),
          icon: const Icon(Icons.add_rounded),
          label: Text(t('Załóż nową piramidę')),
        ),
        if (browsing != null) ...<Widget>[
          ZenSection(t('Piramida Twoich znajomych')),
          ZenCard(
            tone: tone,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '„${browsing.name}”',
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 20,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _Stat(
                        value: '${browsing.members.length}',
                        label: tn(
                          browsing.members.length,
                          one: 'osoba',
                          few: 'osoby',
                          many: 'osób',
                        ),
                        tone: tone,
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        value: '${browsing.depth}',
                        label: tn(
                          browsing.depth,
                          one: 'poziom',
                          few: 'poziomy',
                          many: 'poziomów',
                        ),
                        tone: tone,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  t('Szczyt: {names}', <String, Object?>{
                    'names': browsing.topCell
                        .map((String k) => browsing.members[k]?.name ?? '?')
                        .join(', '),
                  }),
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({
    required this.icon,
    required this.tone,
    required this.title,
    required this.text,
  });

  final IconData icon;
  final Color tone;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ZenIconBadge(icon: icon, tone: tone, size: 38),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                text,
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A big number with a small caption below.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, required this.tone});

  final String value;
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: zen.display(color: tone, size: 26)),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: zen.textSecondary, fontSize: 12.5),
        ),
      ],
    );
  }
}

class _MeTab extends StatelessWidget {
  const _MeTab({required this.pyr, required this.s, required this.me});

  final PyramidService pyr;
  final PyramidState s;
  final String me;

  Future<void> _invite(BuildContext context) async {
    final String? code = pyr.inviteCode();
    if (code == null) {
      snack(context, t('Twoja komórka jest pełna (2 osoby pod Tobą).'));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        final ZenColors zen = ZenColors.of(context);
        return AlertDialog(
          title: Text(t('Zaproszenie do Twojej komórki')),
          content: SizedBox(
            width: 280,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: QrImageView(
                      data: code,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ZenInfo(
                    icon: Icons.handshake_outlined,
                    tone: zen.warning,
                    text: t(
                      'Pokaż tylko osobie, którą znasz i spotykasz osobiście. '
                      'Ty ręczysz, że to prawdziwa osoba, i potwierdzasz jej '
                      'dane.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton.icon(
              onPressed: () =>
                  unawaited(Clipboard.setData(ClipboardData(text: code))),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(t('Kopiuj kod')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t('Gotowe')),
            ),
          ],
        );
      },
    );
  }

  Widget _cell(BuildContext context, String title, String cell) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final List<String> members = <String>[
      for (final String p in <String>[cell, ...PyrPath.children(cell)])
        if (s.occupant[p] != null) s.occupant[p]!,
    ];
    final List<PyrElection> open = s.elections.values
        .where((PyrElection e) => e.cell == cell && !e.closed)
        .toList();
    final int requests =
        s.requestCounts[cell]?.values.fold<int>(0, (int a, int b) => a + b) ??
        0;
    final int maxSame =
        s.requestCounts[cell]?.values.fold<int>(
          0,
          (int a, int b) => a > b ? a : b,
        ) ??
        0;
    return ZenCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              children: <Widget>[
                ZenIconBadge(icon: Icons.hub_rounded, tone: tone, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      height: 1.25,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ZenPill(text: '${members.length}/3', tone: tone),
              ],
            ),
          ),
          const SizedBox(height: 10),
          for (final String k in members)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  if (s.occupant[cell] == k)
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: tone,
                      ),
                      child: Icon(
                        Icons.star_rounded,
                        size: 20,
                        color: ZenColors.foregroundFor(tone),
                      ),
                    )
                  else
                    PyrAvatar(
                      text: pyrInitial(s.members[k]?.name ?? '?'),
                      tone: tone,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          k == me
                              ? t('{name} (Ty)', <String, Object?>{
                                  'name': s.members[k]?.name ?? '?',
                                })
                              : s.members[k]?.name ?? '?',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 15,
                            fontWeight: k == me
                                ? FontWeight.w800
                                : FontWeight.w600,
                          ),
                        ),
                        Text(
                          s.occupant[cell] == k
                              ? t('szef komórki')
                              : t('członek'),
                          style: TextStyle(
                            color: s.occupant[cell] == k
                                ? tone
                                : zen.textSecondary,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (k == me)
                    const SizedBox(width: 40)
                  else
                    PopupMenuButton<String>(
                      icon: Icon(Icons.more_vert_rounded, color: zen.textMuted),
                      onSelected: (String v) =>
                          unawaited(_memberAction(context, v, cell, k)),
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<String>>[
                            if (s.occupant[cell] != k)
                              PopupMenuItem<String>(
                                value: 'swap',
                                child: Text(t('Niech zostanie szefem (2 z 3)')),
                              ),
                            PopupMenuItem<String>(
                              value: 'absent',
                              child: Text(t('Uznaj za nieobecnego (60 dni)')),
                            ),
                            if (s.ownCellOf(k).contains(me))
                              PopupMenuItem<String>(
                                value: 'remove',
                                child: Text(
                                  t('Usuń z piramidy (jego komórka, 2 z 3)'),
                                ),
                              ),
                            PopupMenuItem<String>(
                              value: 'report',
                              child: Text(t('Zgłoś')),
                            ),
                          ],
                    ),
                ],
              ),
            ),
          for (final String p in PyrPath.children(cell))
            if (s.vacant.contains(p))
              _vacant(zen, t('Wolne miejsce (gałąź pod nim została)'), null),
          if (s.vacant.contains(cell))
            _vacant(
              zen,
              t('Miejsce szefa jest wolne'),
              PyrPath.children(cell).contains(s.pathOf(me))
                  ? TextButton(
                      onPressed: () => unawaited(pyr.proposeFill(cell, me)),
                      child: Text(t('Zajmij')),
                    )
                  : null,
            ),
          if (requests > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ZenInfo(
                icon: Icons.campaign_outlined,
                tone: zen.warning,
                text: maxSame > 1
                    ? t(
                        'Anonimowe żądania głosowania: {count} '
                        '(ta sama osoba już {same} razy)',
                        <String, Object?>{'count': requests, 'same': maxSame},
                      )
                    : t(
                        'Anonimowe żądania głosowania: {count}',
                        <String, Object?>{'count': requests},
                      ),
              ),
            ),
          for (final PyrElection e in open)
            Container(
              margin: const EdgeInsets.fromLTRB(0, 8, 8, 4),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: tone.withValues(alpha: 0.25)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(Icons.how_to_vote_rounded, color: tone, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          t('Głosowanie na szefa'),
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t('Do {date}. Głos jest anonimowy.', <String, Object?>{
                      'date': pyrDate(e.deadline),
                    }),
                    style: TextStyle(color: zen.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final String k in e.ring)
                        OutlinedButton(
                          onPressed: () => unawaited(() async {
                            final bool ok = await pyr.voteInCell(e.id, k);
                            if (context.mounted) {
                              snack(
                                context,
                                ok
                                    ? t('Głos oddany.')
                                    : t('Nie można (już głosowano?).'),
                              );
                            }
                          }()),
                          child: Text(s.members[k]?.name ?? '?'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          if (members.contains(me) && open.isEmpty && members.length >= 2)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: TextButton.icon(
                onPressed: () => unawaited(() async {
                  if (await confirm(
                    context,
                    t('Nowe głosowanie?'),
                    t(
                      'Szef zobaczy tylko, że ktoś z komórki żąda głosowania '
                      '— nie kto.',
                    ),
                  )) {
                    await pyr.requestElection(cell);
                  }
                }()),
                icon: const Icon(Icons.how_to_vote_rounded),
                label: Text(t('Zażądaj głosowania (anonimowo)')),
              ),
            ),
        ],
      ),
    );
  }

  Widget _vacant(ZenColors zen, String text, Widget? action) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: <Widget>[
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: zen.outlineStrong),
          ),
          child: Icon(
            Icons.event_seat_outlined,
            size: 18,
            color: zen.textMuted,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13.5,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
        if (action != null) action else const SizedBox(width: 8),
      ],
    ),
  );

  Future<void> _memberAction(
    BuildContext context,
    String action,
    String cell,
    String key,
  ) async {
    switch (action) {
      case 'swap':
        await pyr.proposeSwap(cell, key);
        if (context.mounted) {
          snack(context, t('Propozycja wysłana do komórki.'));
        }
      case 'absent':
        await pyr.proposeAbsent(key);
      case 'remove':
        if (await confirm(
          context,
          t('Usunąć z piramidy?'),
          t('Potrzebna zgoda drugiej osoby z jego komórki.'),
        )) {
          await pyr.proposeRemove(key);
        }
      case 'report':
        if (context.mounted) {
          await showReportSheet(context, pyr, target: key);
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final String myPath = s.pathOf(me)!;
    final PyrMember m = s.members[me]!;
    final List<String> up = s.lineUp(me).reversed.toList();
    final int depth = s.depth < 1 ? 1 : s.depth;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        // Hero: where I am in the pyramid.
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              colors: <Color>[
                Color.alphaBlend(tone.withValues(alpha: 0.34), zen.surface),
                Color.alphaBlend(
                  zen.accentSecondary.withValues(alpha: 0.12),
                  zen.surface,
                ),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: tone.withValues(alpha: 0.35)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  PyrAvatar(
                    text: '${myPath.length + 1}',
                    tone: tone,
                    size: 60,
                    filled: true,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          m.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 24,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: <Widget>[
                            ZenPill(
                              text: m.nat,
                              tone: tone,
                              icon: Icons.flag_rounded,
                            ),
                            if (myPath.isEmpty)
                              ZenPill(
                                text: t('szczyt'),
                                tone: zen.warning,
                                icon: Icons.workspace_premium_rounded,
                              ),
                            if (s.treasurers.contains(me))
                              ZenPill(
                                text: t('skarbnik'),
                                tone: zen.success,
                                icon: Icons.account_balance_rounded,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _Stat(
                      value: '${myPath.length + 1}',
                      label: t('poziom z {depth}', <String, Object?>{
                        'depth': s.depth,
                      }),
                      tone: tone,
                    ),
                  ),
                  Expanded(
                    child: _Stat(
                      value: '${s.branchSize(myPath)}',
                      label: t('os. w gałęzi'),
                      tone: tone,
                    ),
                  ),
                  Expanded(
                    child: _Stat(
                      value: pyrDate(m.joinedAt).split(' ').first,
                      label: t('dołączenie'),
                      tone: zen.textPrimary,
                    ),
                  ),
                ],
              ),
              if (depth <= 24) ...<Widget>[
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    for (int i = 0; i < depth; i++)
                      Expanded(
                        child: Container(
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 1.5),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(3),
                            color: i == myPath.length
                                ? tone
                                : i < myPath.length
                                ? tone.withValues(alpha: 0.35)
                                : zen.surfaceSunk,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        t('szczyt'),
                        style: TextStyle(color: zen.textMuted, fontSize: 11.5),
                      ),
                    ),
                    Text(
                      t('dół'),
                      style: TextStyle(color: zen.textMuted, fontSize: 11.5),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        DecisionsAgainstMe(pyr: pyr, s: s, me: me),
        ZenSection(t('Twoja linia do szczytu')),
        ZenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final String k in up) ...<Widget>[
                Row(
                  children: <Widget>[
                    PyrAvatar(
                      text: '${s.pathOf(k)!.length + 1}',
                      tone: tone,
                      size: 30,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        pyrWho(s, k),
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 14,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
                Container(
                  width: 2,
                  height: 14,
                  margin: const EdgeInsets.only(left: 14),
                  color: tone.withValues(alpha: 0.35),
                ),
              ],
              Row(
                children: <Widget>[
                  PyrAvatar(
                    text: '${myPath.length + 1}',
                    tone: tone,
                    size: 30,
                    filled: true,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('Ty · gałąź {count} os.', <String, Object?>{
                        'count': s.branchSize(myPath),
                      }),
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        ZenSection(t('Komórki')),
        if (myPath.isNotEmpty)
          _cell(
            context,
            t('Komórka wyżej (jesteś członkiem)'),
            PyrPath.parent(myPath),
          ),
        _cell(
          context,
          myPath.isEmpty
              ? t('Szczyt (2 z 3, równa władza)')
              : t('Twoja komórka (jesteś szefem)'),
          myPath,
        ),
        ZenSection(t('Działania')),
        FilledButton.icon(
          key: const Key('pyr-invite'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: s.freeSlot(myPath) == null
              ? null
              : () => unawaited(_invite(context)),
          icon: const Icon(Icons.qr_code_2_rounded),
          label: Text(
            s.freeSlot(myPath) == null
                ? t('Komórka pełna')
                : t('Zaproś do swojej komórki'),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () => unawaited(() async {
            final List<String> heads = <String>[
              for (final MapEntry<String, String> e in s.position.entries)
                if (e.key != me &&
                    !PyrPath.within(e.value, myPath) &&
                    s.freeSlot(e.value) != null)
                  e.key,
            ];
            final String? to = await showDialog<String>(
              context: context,
              builder: (BuildContext context) => SimpleDialog(
                title: Text(t('Przejdź pod (ma wolne miejsce)')),
                children: <Widget>[
                  for (final String k in heads)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(context).pop(k),
                      child: Row(
                        children: <Widget>[
                          PyrAvatar(
                            text: pyrInitial(s.members[k]?.name ?? '?'),
                            size: 30,
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Text(pyrWho(s, k))),
                        ],
                      ),
                    ),
                ],
              ),
            );
            if (to == null || !context.mounted) {
              return;
            }
            bool branch = false;
            if (pyr.myCellBelow.isNotEmpty) {
              // §20.4: alone (the cell below picks who moves up), or with
              // the whole branch when the whole cell agrees.
              final bool? withBranch = await showDialog<bool>(
                context: context,
                builder: (BuildContext context) => SimpleDialog(
                  title: Text(t('Jak przejść?')),
                  children: <Widget>[
                    SimpleDialogOption(
                      key: const Key('pyr-migrate-alone'),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: ListTile(
                        leading: const Icon(Icons.person_rounded),
                        title: Text(t('Sam(a)')),
                        subtitle: Text(
                          t(
                            'Twoje miejsce zostaje wolne; ktoś z Twojej '
                            'komórki je zajmie.',
                          ),
                        ),
                      ),
                    ),
                    SimpleDialogOption(
                      key: const Key('pyr-migrate-branch'),
                      onPressed: () => Navigator.of(context).pop(true),
                      child: ListTile(
                        leading: const Icon(Icons.account_tree_rounded),
                        title: Text(t('Z całą gałęzią')),
                        subtitle: Text(
                          t(
                            'Wszyscy pod Tobą przechodzą razem, na tych samych '
                            'miejscach. Podpisuje cała Twoja komórka.',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
              if (withBranch == null) {
                return;
              }
              branch = withBranch;
            }
            await pyr.proposeMigrate(to, branch: branch);
          }()),
          icon: const Icon(Icons.swap_horiz_rounded),
          label: Text(t('Przejdź do innej komórki')),
        ),
        const SizedBox(height: 6),
        Center(
          child: TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: zen.danger),
            onPressed: () => unawaited(() async {
              if (await confirm(
                context,
                t('Wyjść z piramidy?'),
                t(
                  'Twoje miejsce zwolni się, a Twoja komórka wskaże następcę. '
                  'Możesz wrócić — od dołu.',
                ),
              )) {
                await pyr.leave();
              }
            }()),
            icon: const Icon(Icons.logout_rounded),
            label: Text(t('Wyjdź z piramidy')),
          ),
        ),
      ],
    );
  }
}

/// A political post with its numbers (§22.1a) and comments. A post the
/// person reported is hidden behind a line they can tap to see it anyway.
class PyrPostCard extends ConsumerWidget {
  const PyrPostCard({
    required this.pyr,
    required this.s,
    required this.me,
    required this.post,
    super.key,
  });

  final PyramidService pyr;
  final PyramidState s;
  final String me;
  final PyrPost post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(hiddenByMeProvider).hides(id: post.id)) {
      return HiddenContentPlaceholder(
        key: Key('pyr-hidden-${post.id}'),
        byMe: true,
        onShow: () => showHiddenAnyway(ref, id: post.id),
      );
    }
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final int? myLevel = s.levelOf(me);
    final String? authorPath = s.pathOf(post.author);
    final int above = myLevel == null ? 0 : myLevel - post.level;
    final String name = s.members[post.author]?.name ?? '?';
    final Color levelTone = post.level == 0 ? zen.warning : tone;
    return ZenCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                PyrAvatar(text: pyrInitial(name), tone: levelTone, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        <String>[
                          if (authorPath != null)
                            t('szef gałęzi {count} os.', <String, Object?>{
                              'count': s.branchSize(authorPath),
                            }),
                          if (post.nat != null) post.nat!,
                          pyrDate(post.at),
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
                ZenPill(
                  text: t('Poziom {level}/{depth}', <String, Object?>{
                    'level': post.level + 1,
                    'depth': s.depth,
                  }),
                  tone: levelTone,
                  icon: Icons.arrow_upward_rounded,
                ),
              ],
            ),
          ),
          if (above > 0) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              tn(
                above,
                one: '▲ {n} poziom nad Tobą',
                few: '▲ {n} poziomy nad Tobą',
                many: '▲ {n} poziomów nad Tobą',
              ),
              style: TextStyle(
                color: levelTone,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              post.text,
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 15,
                height: 1.45,
              ),
            ),
          ),
          if (post.comments.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(0, 10, 8, 0),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: zen.surfaceMuted,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final PyrComment c in post.comments)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              text: '${s.members[c.author]?.name ?? '?'}  ',
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            TextSpan(text: c.text),
                          ],
                        ),
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                          height: 1.35,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton.icon(
                onPressed: () => unawaited(() async {
                  final String? text = await askText(
                    context,
                    title: t('Komentarz'),
                    maxLines: 3,
                  );
                  if (text != null) {
                    await pyr.comment(post.id, text);
                  }
                }()),
                icon: const Icon(Icons.mode_comment_outlined, size: 18),
                label: Text(
                  post.comments.isEmpty
                      ? t('Komentuj')
                      : t('Komentuj ({count})', <String, Object?>{
                          'count': post.comments.length,
                        }),
                ),
              ),
              IconButton(
                tooltip: t('Zgłoś'),
                icon: Icon(Icons.flag_outlined, color: zen.textMuted),
                onPressed: () => unawaited(
                  showReportSheet(
                    context,
                    pyr,
                    target: post.author,
                    evidence: post.text,
                    contentHash: contentHash(post.text),
                    contentId: post.id,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PoliticsTab extends StatelessWidget {
  const _PoliticsTab({required this.pyr, required this.s, required this.me});

  final PyramidService pyr;
  final PyramidState s;
  final String me;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final Set<String> up = s.lineUp(me).toSet();
    final Set<String> banned = s.bannedContent(pyr.now);
    // §22.1: the top first, then the line up from the highest, newest first
    // within a level; then this person's own posts.
    final List<PyrPost> list =
        s.posts.values
            .where(
              (PyrPost p) =>
                  (up.contains(p.author) ||
                      p.author == me ||
                      p.author == s.head) &&
                  !banned.contains(contentHash(p.text)),
            )
            .toList()
          ..sort(
            (PyrPost a, PyrPost b) => a.level != b.level
                ? a.level.compareTo(b.level)
                : b.at.compareTo(a.at),
          );
    final String myPath = s.pathOf(me)!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenCard(
          tone: tone,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ZenIconBadge(
                    icon: Icons.campaign_rounded,
                    tone: tone,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t('Twoja gałąź'),
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          t(
                            '{count} os. przeczyta, co napiszesz',
                            <String, Object?>{
                              'count': s.branchSize(myPath) - 1,
                            },
                          ),
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('pyr-post'),
                onPressed: () => unawaited(() async {
                  final String? text = await askText(
                    context,
                    title: t(
                      'Do Twojej gałęzi ({count} os.)',
                      <String, Object?>{'count': s.branchSize(myPath) - 1},
                    ),
                    maxLines: 6,
                  );
                  if (text != null) {
                    await pyr.post(text);
                  }
                }()),
                icon: const Icon(Icons.edit_rounded),
                label: Text(t('Napisz do swojej gałęzi')),
              ),
            ],
          ),
        ),
        if (list.isEmpty)
          ZenEmpty(
            icon: Icons.forum_outlined,
            tone: tone,
            title: t('Cisza w linii'),
            text: t('Nikt z Twojej linii jeszcze nic nie napisał.'),
          )
        else ...<Widget>[
          ZenSection(t('Od szczytu w dół'), top: 16),
          for (final PyrPost p in list)
            PyrPostCard(pyr: pyr, s: s, me: me, post: p),
        ],
      ],
    );
  }
}

class _NationTab extends StatelessWidget {
  const _NationTab({required this.pyr, required this.s, required this.me});

  final PyramidService pyr;
  final PyramidState s;
  final String me;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 1);
    final String nat = s.members[me]!.nat;
    final String? lead = s.nationalLead(nat);
    final Map<String, int> grants = s.natGrants[nat] ?? const <String, int>{};
    final int now = pyr.now;
    final List<PyrPost> posts =
        s.natPosts.values.where((PyrPost p) => p.nat == nat).toList()
          ..sort((PyrPost a, PyrPost b) {
            int prio(PyrPost p) =>
                p.author == lead ? 0 : ((grants[p.author] ?? 0) > now ? 1 : 2);
            final int c = prio(a).compareTo(prio(b));
            if (c != 0) {
              return c;
            }
            return a.level != b.level
                ? a.level.compareTo(b.level)
                : b.at.compareTo(a.at);
          });
    final int count = s.members.values
        .where((PyrMember m) => m.nat == nat && s.isMember(m.key))
        .length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: LinearGradient(
              colors: <Color>[
                Color.alphaBlend(tone.withValues(alpha: 0.28), zen.surface),
                Color.alphaBlend(
                  zen.accentSecondary.withValues(alpha: 0.10),
                  zen.surface,
                ),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: tone.withValues(alpha: 0.30)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    constraints: const BoxConstraints(
                      minWidth: 64,
                      minHeight: 64,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: tone.withValues(alpha: 0.35)),
                    ),
                    child: Text(nat, style: zen.display(color: tone, size: 26)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t('Sekcja krajowa'),
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 20,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t(
                            'Członków piramidy z narodowością {nat}: {count}',
                            <String, Object?>{'nat': nat, 'count': count},
                          ),
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    lead == null
                        ? Icons.person_off_outlined
                        : Icons.record_voice_over_rounded,
                    color: tone,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      lead == null
                          ? t(
                              'Sekcja bez osoby prowadzącej (nikt nie ma '
                              '{count} os. tej narodowości w gałęzi)',
                              <String, Object?>{'count': s.params.nationalMin},
                            )
                          : t(
                              'Prowadzi: {name} · poziom {level} · {count} os. '
                              '{nat} w gałęzi',
                              <String, Object?>{
                                'name': s.members[lead]?.name,
                                'level': s.levelOf(lead),
                                'count': s.branchNat(s.pathOf(lead)!, nat),
                                'nat': nat,
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
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () => unawaited(() async {
                      final String? text = await askText(
                        context,
                        title: t('Post w sekcji {nat}', <String, Object?>{
                          'nat': nat,
                        }),
                        maxLines: 6,
                      );
                      if (text != null) {
                        await pyr.natPost(text);
                      }
                    }()),
                    icon: const Icon(Icons.edit_rounded),
                    label: Text(t('Napisz w sekcji')),
                  ),
                  if (lead == me)
                    OutlinedButton.icon(
                      onPressed: () => unawaited(() async {
                        final String? name = await askText(
                          context,
                          title: t('Komu dać priorytet (pseudonim)?'),
                        );
                        final String? key = s.members.values
                            .where(
                              (PyrMember m) => m.name == name && m.nat == nat,
                            )
                            .map((PyrMember m) => m.key)
                            .firstOrNull;
                        if (key != null) {
                          await pyr.propose(
                            <String, dynamic>{
                              't': PyrT.natGrant,
                              'nat': nat,
                              'to': key,
                              'until': pyr.now + 30 * 24 * 3600 * 1000,
                            },
                            candidates: <String>[me],
                            need: 1,
                          );
                        }
                      }()),
                      icon: const Icon(Icons.star_outline_rounded),
                      label: Text(t('Nadaj priorytet (30 dni)')),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (posts.isEmpty)
          ZenEmpty(
            icon: Icons.flag_outlined,
            tone: tone,
            title: t('Jeszcze nic'),
            text: t('W sekcji {nat} nikt jeszcze nie pisał.', <String, Object?>{
              'nat': nat,
            }),
          )
        else ...<Widget>[
          ZenSection(t('Posty w sekcji'), top: 16),
          for (final PyrPost p in posts)
            PyrPostCard(pyr: pyr, s: s, me: me, post: p),
        ],
      ],
    );
  }
}

class _VotesTab extends StatelessWidget {
  const _VotesTab({required this.pyr, required this.s, required this.me});

  final PyramidService pyr;
  final PyramidState s;
  final String me;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final int now = pyr.now;
    final List<PyrReferendum> list =
        s.referenda.values
            .where((PyrReferendum r) => s.eligible(r, me))
            .toList()
          ..sort((PyrReferendum a, PyrReferendum b) => b.at.compareTo(a.at));
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenSection(t('Referenda'), top: 4),
        if (list.isEmpty)
          ZenEmpty(
            icon: Icons.how_to_vote_outlined,
            tone: tone,
            title: t('Brak głosowań'),
            text: t('Nie ma referendów, w których głosujesz.'),
          ),
        for (final PyrReferendum r in list)
          ZenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ZenIconBadge(
                      icon: r.kind == 'constitution'
                          ? Icons.gavel_rounded
                          : Icons.how_to_vote_rounded,
                      tone: tone,
                      size: 40,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        r.question,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    ZenPill(
                      text: switch (r.scopeKind) {
                        'branch' => t('gałąź'),
                        'nat' => t('sekcja {nat}', <String, Object?>{
                          'nat': r.scopeNat,
                        }),
                        _ => t('cała piramida'),
                      },
                      tone: tone,
                      icon: Icons.groups_rounded,
                    ),
                    if (r.kind == 'constitution')
                      ZenPill(text: t('zmiana zasad'), tone: zen.warning),
                    ZenPill(
                      text: now < r.end
                          ? t('do {date}', <String, Object?>{
                              'date': pyrDate(r.end),
                            })
                          : t('zakończone'),
                      tone: now < r.end ? zen.success : zen.textMuted,
                      icon: now < r.end
                          ? Icons.schedule_rounded
                          : Icons.check_rounded,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (now < r.end && !pyr.myVotes.containsKey(r.id))
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (int i = 0; i < r.options.length; i++)
                        OutlinedButton(
                          key: Key('pyr-vote-$i'),
                          onPressed: () =>
                              unawaited(pyr.voteReferendum(r.id, i)),
                          child: Text(r.options[i]),
                        ),
                    ],
                  )
                else if (now < r.end)
                  ZenInfo(
                    icon: Icons.check_circle_rounded,
                    tone: zen.success,
                    title: t('Zagłosowano: {option}', <String, Object?>{
                      'option': r.options[pyr.myVotes[r.id]!],
                    }),
                    text: t('Głos zna tylko szef Twojej komórki.'),
                  ),
                if (now >= r.end) _Result(s: s, r: r),
              ],
            ),
          ),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({required this.s, required this.r});

  final PyramidState s;
  final PyrReferendum r;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final List<int>? res = s.resultOf(r.id);
    if (res == null) {
      return Row(
        children: <Widget>[
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: tone),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              t('Liczenie trwa (sumy idą w górę drzewa)…'),
              style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
            ),
          ),
        ],
      );
    }
    final int total = res.fold(0, (int a, int b) => a + b);
    final int best = res.fold(0, (int a, int b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < r.options.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (best > 0 &&
                        i < res.length &&
                        res[i] == best) ...<Widget>[
                      Icon(Icons.emoji_events_rounded, size: 16, color: tone),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        r.options[i],
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 14,
                          fontWeight:
                              i < res.length && res[i] == best && best > 0
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      i >= res.length
                          ? '0'
                          : '${res[i]} · ${total == 0 ? 0 : (res[i] * 100 / total).round()}%',
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                PyrBar(
                  value: total == 0 || i >= res.length ? 0.0 : res[i] / total,
                  tone: i < res.length && res[i] == best && best > 0
                      ? tone
                      : zen.textMuted,
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        Text(
          t(
            'Oddane głosy: {count} · sumy podpisane przez każdą komórkę.',
            <String, Object?>{'count': total},
          ),
          style: TextStyle(color: zen.textMuted, fontSize: 12.5),
        ),
      ],
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.s});

  final PyramidState s;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final List<PyrHistory> h = s.history.reversed.toList();
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: h.length + 1,
      itemBuilder: (BuildContext context, int i) {
        if (i == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ZenInfo(
                icon: Icons.history_edu_rounded,
                tone: tone,
                title: t(
                  'Kadencja {term} · zasady w wersji {version}',
                  <String, Object?>{
                    'term': s.term,
                    'version': s.params.version,
                  },
                ),
                text: t(
                  'Każda zmiana to podpisany, jawny wpis. Kadencja trwa od '
                  '{date}.',
                  <String, Object?>{'date': pyrDate(s.termStart[s.term] ?? 0)},
                ),
              ),
              if (h.isEmpty)
                ZenEmpty(
                  icon: Icons.timeline_rounded,
                  tone: tone,
                  title: t('Historia jest pusta'),
                )
              else
                const SizedBox(height: 12),
            ],
          );
        }
        final PyrHistory e = h[i - 1];
        final bool first = i == 1;
        final bool last = i == h.length;
        return Stack(
          children: <Widget>[
            if (!(first && last))
              Positioned(
                left: 7,
                top: first ? 18.0 : 0.0,
                bottom: last ? null : 0,
                height: last ? 18.0 : null,
                child: Container(width: 2, color: tone.withValues(alpha: 0.30)),
              ),
            Positioned(
              left: 1,
              top: 12,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: first ? tone : zen.surface,
                  border: Border.all(color: tone, width: 2.5),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 30, bottom: 10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  color: zen.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: zen.outlineSoft),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      e.text,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: <Widget>[
                        Icon(
                          Icons.schedule_rounded,
                          size: 13,
                          color: zen.textMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          pyrDate(e.at),
                          style: TextStyle(color: zen.textMuted, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
