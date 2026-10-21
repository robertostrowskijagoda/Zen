import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_glyphs.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_court_view.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_decisions.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_emission.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_national.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_power.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_timeline_view.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/presentation/report_sheet.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// "12.10.2026 18:00".
String pyrDate(int millis) {
  return ZenFormat.dateTime(DateTime.fromMillisecondsSinceEpoch(millis));
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
Color pyrTone(ZenColors zen) => zen.tone(ZenTone.money);

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
      borderRadius: BorderRadius.circular(ZenLook.of(context).radius(height)),
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
    final BorderRadius radius = BorderRadius.circular(
      ZenLook.of(context).radius(14),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? t.withValues(alpha: 0.12) : zen.surfaceMuted,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
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

/// The "Piramida" tab. Its posts are read on the Tablica only; here are
/// the actions (votes, signatures, money).
class PyramidScreen extends ConsumerWidget {
  const PyramidScreen({this.openVotes = false, super.key});

  /// Opens on „Głosowania” (a referendum's „Głosuj →” on the Tablica).
  final bool openVotes;

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
          Tab(text: t('Głosowania')),
          Tab(text: t('Portfel')),
          if (power) Tab(text: t('Władza')),
          Tab(text: t('Historia')),
        ];
        return DefaultTabController(
          length: tabs.length,
          initialIndex: openVotes ? 1 : 0,
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
                _VotesTab(pyr: pyr, s: s, me: me),
                PyramidWallet(pyr: pyr, s: s, me: me),
                if (power) PyramidPower(pyr: pyr, s: s, me: me),
                _HistoryTab(s: s, me: me),
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
              borderRadius: BorderRadius.circular(
                ZenLook.of(context).radius(3),
              ),
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
                    // time first.
                    for (final String line in pyr.recordDetails(
                      p.record,
                      extra: p.extra,
                    ))
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
                    if (p.record.type == PyrT.admit &&
                        p.record.str('sp') != pyr.myKey) ...<Widget>[
                      const SizedBox(height: 8),
                      ZenInfo(
                        key: const Key('pyr-admit-recommended'),
                        icon: Icons.group_add_rounded,
                        tone: zen.success,
                        text: t(
                          'Za tę osobę ręczy polecający. Ty tylko przyjmujesz ją '
                          'do swojej komórki — potem możecie się poznać.',
                        ),
                      ),
                    ],
                    if (p.record.type == PyrT.admit &&
                        p.record.str('sp') == pyr.myKey) ...<Widget>[
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
                            'year': (p.record.body['m'] as Map?)?['yr'],
                            'gender': p.extra['g'],
                          },
                        ),
                      ),
                      // Only a friend at "Znajomy" or above.
                      if (pyr.admitProblem(p)
                          case final String problem) ...<Widget>[
                        const SizedBox(height: 8),
                        ZenInfo(
                          key: const Key('pyr-admit-problem'),
                          icon: Icons.person_search_rounded,
                          tone: zen.danger,
                          text: problem,
                        ),
                      ],
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
                            onPressed: pyr.admitProblem(p) != null
                                ? null
                                : () => unawaited(pyr.approve(p.record.id)),
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
  Future<Map<String, Object>?> _askData({bool founding = false}) async {
    final TextEditingController name = TextEditingController();
    final TextEditingController nat = TextEditingController(text: 'PL');
    final TextEditingController year = TextEditingController();
    String gender = 'k';
    // Required: any plausible year, minors too.
    int? yearOf() {
      final int? y = int.tryParse(year.text.trim());
      return y != null && pyrBirthYearValid(y, widget.pyr.now) ? y : null;
    }

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ZenColors zen = ZenColors.of(context);
          return AlertDialog(
            title: Text(founding ? t('Założenie piramidy') : t('Dołączenie')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 4),
                  TextField(
                    key: const Key('pyr-pseudonym'),
                    controller: name,
                    onChanged: (_) => set(() {}),
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
                    key: const Key('pyr-birth-year'),
                    controller: year,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => set(() {}),
                    decoration: InputDecoration(
                      labelText: t('Rok urodzenia'),
                      hintText: t('np. 1990'),
                      prefixIcon: const Icon(Icons.cake_outlined),
                      helperText: t('Wiek widać w Twoim profilu w piramidzie.'),
                      helperMaxLines: 3,
                      errorText: year.text.trim().isNotEmpty && yearOf() == null
                          ? t('Podaj prawdziwy rok urodzenia, np. 1990.')
                          : null,
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
                      'która Cię przyjmuje, potwierdza je podpisem. W '
                      'piramidzie widać narodowość i wiek; płeć — tylko jako '
                      'skrót, chyba że pokażesz odznakę.',
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
                key: const Key('pyr-data-next'),
                onPressed: name.text.trim().isEmpty || yearOf() == null
                    ? null
                    : () => Navigator.of(context).pop(true),
                child: Text(t('Dalej')),
              ),
            ],
          );
        },
      ),
    );
    final int? y = yearOf();
    final Map<String, Object>? out =
        ok == true && name.text.trim().isNotEmpty && y != null
        ? <String, Object>{
            'name': name.text.trim(),
            'nat': nat.text.trim(),
            'year': y,
            'g': gender,
          }
        : null;
    for (final TextEditingController c in <TextEditingController>[
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
    // Only the original pyramid: a code of any other is refused.
    if (!widget.pyr.invitesHere(code)) {
      snack(
        context,
        t('To nie jest piramida Zen — ten kod pochodzi z innej piramidy.'),
      );
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

  /// The founder seats themselves at the top with the power key (once,
  /// while the pyramid is empty).
  Future<void> _found() async {
    String? secret;
    if (widget.pyr.foundNeedsKey) {
      secret = await askText(
        context,
        title: t('Klucz władzy założyciela'),
        label: t('Wklej klucz z narzędzia zen_pyramid'),
        keyboard: TextInputType.visiblePassword,
      );
      if (secret == null || !mounted) {
        return;
      }
    }
    final Map<String, Object>? d = await _askData(founding: true);
    if (d == null) {
      return;
    }
    final String? id = await widget.pyr.found(
      myName: d['name']! as String,
      nat: d['nat']! as String,
      birthYear: d['year']! as int,
      gender: d['g']! as String,
      powerSecret: secret,
    );
    if (id == null && mounted) {
      snack(context, t('Ten klucz nie pasuje do piramidy Zen.'));
    }
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
        if (browsing != null &&
            widget.pyr.myKey != null &&
            widget.pyr.myMatters().isNotEmpty)
          DecisionsAgainstMe(
            pyr: widget.pyr,
            s: browsing,
            me: widget.pyr.myKey!,
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
        if (widget.pyr.current == null) ...<Widget>[
          ZenInfo(
            icon: Icons.hourglass_empty_rounded,
            tone: zen.warning,
            text: t(
              'Piramida Zen jeszcze nie wystartowała w tej wersji aplikacji.',
            ),
          ),
          const SizedBox(height: 10),
        ],
        FilledButton.icon(
          key: const Key('pyr-join'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => unawaited(_join()),
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: Text(t('Dołącz — zeskanuj kod znajomego')),
        ),
        // The test pyramid (debug builds) is founded by anyone; the original
        // one only by its founder, with the power key (a quiet link below).
        if (widget.pyr.canFound && !widget.pyr.foundNeedsKey) ...<Widget>[
          const SizedBox(height: 10),
          ZenInfo(
            icon: Icons.key_rounded,
            tone: zen.warning,
            title: t('Piramida jeszcze nie ma szefa'),
            text: t(
              'Zakłada ją raz założyciel, kluczem władzy z rekordu początkowego '
              'zapisanego w aplikacji. Każdy inny dołącza przez znajomego.',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('pyr-found'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: () => unawaited(_found()),
            icon: const Icon(Icons.key_rounded),
            label: Text(t('Załóż piramidę kluczem władzy')),
          ),
        ],
        if (browsing != null && browsing.members.isNotEmpty) ...<Widget>[
          ZenSection(t('Piramida Zen')),
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
        // What somebody outside reads of the pyramid — the top's posts, the
        // section of the profile's nationality — is on the Tablica.
        PyramidNationalEntry(
          pyr: widget.pyr,
          nationalities: ref.watch(userProfileControllerProvider).nationalities,
        ),
        if (widget.pyr.canFound && widget.pyr.foundNeedsKey)
          Center(
            child: TextButton.icon(
              key: const Key('pyr-found-key'),
              onPressed: () => unawaited(_found()),
              icon: const Icon(Icons.key_rounded, size: 18),
              label: Text(t('Jestem założycielem — mam klucz władzy')),
            ),
          ),
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

  /// A free place in words: under whom, on which level.
  String _placeText(String place) {
    final String? head = s.occupant[PyrPath.parent(place)];
    return head == me
        ? t('Pod Tobą · poziom {level}', <String, Object?>{
            'level': place.length + 1,
          })
        : t('Pod {name} · poziom {level}', <String, Object?>{
            'name': s.members[head]?.name ?? '?',
            'level': place.length + 1,
          });
  }

  /// "Polecenie": the place in this person's branch the newcomer goes to
  /// (nearest the top by default), then the QR to show them.
  Future<void> _invite(BuildContext context) async {
    final List<String> places = pyr.freePlaces();
    if (places.isEmpty) {
      snack(context, t('Brak wolnego miejsca w Twojej gałęzi.'));
      return;
    }
    String slot = places.first;
    if (places.length > 1) {
      final String? picked = await showDialog<String>(
        context: context,
        builder: (BuildContext context) => SimpleDialog(
          title: Text(t('Gdzie trafi nowa osoba?')),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                t(
                  'Wolne miejsca w Twojej gałęzi, najbliżej szczytu na górze. '
                  'Szef wybranej komórki dopisze swój podpis.',
                ),
              ),
            ),
            for (final String p in places)
              SimpleDialogOption(
                key: Key('pyr-place-$p'),
                onPressed: () => Navigator.of(context).pop(p),
                child: Text(
                  p == places.first
                      ? t('{place} (domyślnie)', <String, Object?>{
                          'place': _placeText(p),
                        })
                      : _placeText(p),
                ),
              ),
          ],
        ),
      );
      if (picked == null || !context.mounted) {
        return;
      }
      slot = picked;
    }
    final String? code = pyr.inviteCode(slot: slot);
    if (code == null) {
      snack(context, t('To miejsce jest już zajęte.'));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        final ZenColors zen = ZenColors.of(context);
        return AlertDialog(
          title: Text(t('Zaproszenie do piramidy')),
          content: SizedBox(
            width: 280,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    // A QR code reads black on white, whatever the theme.
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(
                        ZenLook.of(context).radius(20),
                      ),
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
                  const SizedBox(height: 8),
                  Text(
                    t('Miejsce: {place}', <String, Object?>{
                      'place': _placeText(slot),
                    }),
                    style: TextStyle(color: zen.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton.icon(
              onPressed: () => unawaited(copyWithExpiry(code)),
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
                          <String>[
                            if (s.occupant[cell] == k)
                              t('szef komórki')
                            else
                              t('członek'),
                            if (s.members[k] case final PyrMember m)
                              pyrAgeText(m.birthYear, pyr.now),
                            ?pyrVoteText(s, k, pyr.now),
                          ].join(' · '),
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
                            if (s.cellmates(k).contains(me) &&
                                s.canVote(me, pyr.now) &&
                                !s.canVote(k, pyr.now))
                              PopupMenuItem<String>(
                                value: 'known',
                                child: Text(t('Poznaliśmy się (daje głos)')),
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
                            PopupMenuItem<String>(
                              value: 'sue',
                              child: Text(t('Złóż skargę do sądu')),
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
              decoration: ZenLook.of(
                context,
              ).panel(zen, radius: 16, tone: tone),
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
                  if (e.tokens == null || pyr.voteWaiting(e.id))
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        pyr.voteWaiting(e.id)
                            ? t('Twój głos wyjdzie sam, gdy karty będą gotowe.')
                            : t(
                                'Telefony komórki wymieniają jednorazowe karty.',
                              ),
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13,
                        ),
                      ),
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
                                !ok
                                    ? t('Nie można (już głosowano?).')
                                    : pyr.voteWaiting(e.id)
                                    ? t('Głos wyjdzie, gdy karty będą gotowe.')
                                    : t('Głos oddany.'),
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
          if (open.isEmpty && pyr.requestWaiting(cell))
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                t(
                  'Twoje żądanie wyjdzie samo, gdy telefony komórki '
                  'przygotują karty.',
                ),
                style: TextStyle(color: zen.textSecondary, fontSize: 13),
              ),
            )
          else if (members.contains(me) && open.isEmpty && members.length >= 2)
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
      case 'known':
        if (await confirm(
          context,
          t('Znacie się?'),
          t(
            'Potwierdzasz, że znasz tę osobę (nie musicie się spotkać). '
            'Od razu dostanie głos w komórce i w referendach.',
          ),
        )) {
          await pyr.confirmKnown(key);
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
      case 'sue':
        if (context.mounted) {
          await showComplaintDialog(context, pyr, s, key);
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
        // Pinned for every member: the money may change.
        EmitChangeNotices(pyr: pyr, s: s),
        // Hero: where I am in the pyramid.
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ZenLook.of(context).radius(26)),
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
                            if (pyr.holdsPowerKey)
                              ZenPill(
                                key: const Key('pyr-power-pill'),
                                text: t('klucz władzy'),
                                tone: zen.warning,
                                icon: Icons.key_rounded,
                              ),
                            if (s.treasurers.contains(me))
                              ZenPill(
                                text: t('skarbnik'),
                                tone: zen.success,
                                icon: Icons.account_balance_rounded,
                              ),
                            ZenPill(
                              text: pyrAgeText(m.birthYear, pyr.now),
                              tone: zen.textSecondary,
                              icon: Icons.cake_outlined,
                            ),
                            if (s.badges[me] case final String g)
                              ZenPill(
                                text: pyrGenderText(g),
                                tone: zen.textSecondary,
                                icon: Icons.verified_rounded,
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
                            borderRadius: BorderRadius.circular(
                              ZenLook.of(context).radius(3),
                            ),
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
        PyramidPostsEntry(pyr: pyr),
        CourtDuties(pyr: pyr, s: s),
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
          onPressed: () => unawaited(_invite(context)),
          icon: const Icon(Icons.qr_code_2_rounded),
          label: Text(t('Zaproś do piramidy')),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () => unawaited(() async {
            // Sideways, down, or one level up (not again within 7 days):
            // promotion goes step by step.
            final bool canRise = pyr.now >= s.nextRiseAt(me);
            final List<String> heads = <String>[
              for (final MapEntry<String, String> e in s.position.entries)
                if (e.key != me &&
                    !PyrPath.within(e.value, myPath) &&
                    s.freeSlot(e.value) != null &&
                    e.value.length + 1 >= myPath.length - (canRise ? 1 : 0))
                  e.key,
            ];
            if (heads.isEmpty) {
              snack(
                context,
                t('Brak wolnego miejsca, do którego wolno przejść.'),
              );
              return;
            }
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
            // A branch never moves up: one level up only alone.
            final bool rises = (s.pathOf(to)?.length ?? 0) + 1 < myPath.length;
            if (pyr.myCellBelow.isNotEmpty && !rises) {
              // Alone (the cell below picks who moves up), or with
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
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('pyr-sue'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () => unawaited(() async {
            final String? who = await pickMember(
              context,
              s,
              except: me,
              title: t('Skarga przeciw komu?'),
            );
            if (who != null && context.mounted) {
              await showComplaintDialog(context, pyr, s, who);
            }
          }()),
          icon: const Icon(Icons.balance_rounded),
          label: Text(t('Złóż skargę do sądu')),
        ),
        const SizedBox(height: 12),
        PyrBadgeAndStats(pyr: pyr, s: s, me: me),
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

/// A member's vote in words, for their cell: "poznany(-a) przez Ola",
/// "głos od 12.11.2026", or null when they simply vote (14 days in, or the
/// founder).
String? pyrVoteText(PyramidState s, String key, int nowMs) {
  final List<String> by = s.knownByOf(key);
  if (by.isNotEmpty) {
    return t('poznany(-a) przez {names}', <String, Object?>{
      'names': by.map((String k) => s.members[k]?.name ?? '?').join(', '),
    });
  }
  final PyrMember? m = s.members[key];
  if (m == null || s.canVote(key, nowMs)) {
    return null;
  }
  return t('głos od {date}', <String, Object?>{
    'date': pyrDate(m.joinedAt + kPyrVoteAfterMs).split(' ').first,
  });
}

/// A member's badge for people: "34 l. · K".
/// A member's age, from the birth year confirmed at entry.
String pyrAgeText(int birthYear, int nowMs) =>
    t('{age} l.', <String, Object?>{'age': pyrAge(birthYear, nowMs)});

/// A gender badge a member shows.
String pyrGenderText(String gender) => switch (gender) {
  'k' => t('K'),
  'm' => t('M'),
  _ => t('inna'),
};

/// The badge this person may show and the anonymous statistics of
/// their branch: gender and age, summed up the tree, shown only from
/// [kPyrStatsMinPeople] people.
class PyrBadgeAndStats extends StatelessWidget {
  const PyrBadgeAndStats({
    required this.pyr,
    required this.s,
    required this.me,
    super.key,
  });

  final PyramidService pyr;
  final PyramidState s;
  final String me;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool shown = s.badges.containsKey(me);
    final List<int>? stats = pyr.branchStats();
    final List<String> ages = <String>[
      t('do 24'),
      t('25–39'),
      t('40–59'),
      t('60+'),
    ];
    final List<String> genders = <String>[
      t('Kobiety'),
      t('Mężczyźni'),
      t('Inne'),
    ];
    return ZenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SwitchListTile(
            key: const Key('pyr-badge'),
            contentPadding: EdgeInsets.zero,
            value: shown,
            title: Text(t('Pokaż odznakę płci')),
            subtitle: Text(
              t(
                'Płeć potwierdzona przy wejściu; każdy może ją sprawdzić. '
                'Bez odznaki trafia tylko do anonimowych statystyk. Wiek '
                'widać zawsze.',
              ),
            ),
            onChanged: (bool v) => unawaited(pyr.showBadge(v)),
          ),
          const SizedBox(height: 4),
          Text(
            t('STATYSTYKI TWOJEJ GAŁĘZI (ANONIMOWE)'),
            style: zen.label(color: zen.textMuted),
          ),
          const SizedBox(height: 6),
          if (stats == null)
            Text(
              t(
                'Pokażą się, gdy z gałęzi spłyną sumy co najmniej {count} osób.',
                <String, Object?>{'count': kPyrStatsMinPeople},
              ),
              style: TextStyle(color: zen.textSecondary, fontSize: 13),
            )
          else
            for (int g = 0; g < genders.length; g++)
              if (stats
                      .sublist(g * ages.length, (g + 1) * ages.length)
                      .fold(0, (int a, int b) => a + b) >
                  0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                    '${genders[g]}: ${<String>[for (int a = 0; a < ages.length; a++)
                      if (stats[g * ages.length + a] > 0) '${ages[a]} — ${stats[g * ages.length + a]}'].join(' · ')}',
                    style: TextStyle(color: zen.textPrimary, fontSize: 13.5),
                  ),
                ),
        ],
      ),
    );
  }
}

/// Shows the Tablica on [filter] (from a pushed Pyramid too: back to the
/// shell first).
void pyrOpenFeed(BuildContext context, FeedFilter filter) {
  Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
  openFeed(filter);
}

/// „Posty piramidy: N nowe · Otwórz na Tablicy →” and „Napisz do gałęzi”:
/// the pyramid's posts are read on the Tablica only (its „Piramida”
/// filter), never here.
class PyramidPostsEntry extends StatelessWidget {
  const PyramidPostsEntry({required this.pyr, super.key});

  final PyramidService pyr;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    final PyramidFeed feed = pyr.feed;
    final int fresh = feed.unread(pyr.wasRead, pyr.now).length;
    final int national = feed.unreadNational(pyr.wasRead, pyr.now).length;
    return ZenCard(
      key: const Key('pyr-posts-entry'),
      tone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ZenIconBadge(icon: Icons.forum_rounded, tone: tone, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      fresh == 0
                          ? t('Posty piramidy')
                          : tn(
                              fresh,
                              one: 'Posty piramidy: {n} nowy',
                              few: 'Posty piramidy: {n} nowe',
                              many: 'Posty piramidy: {n} nowych',
                            ),
                      key: const Key('pyr-posts-new'),
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      <String>[
                        t('od szczytu i Twojej linii, na Tablicy'),
                        if (national > 0)
                          t('{n} nowe z sekcji {nat}', <String, Object?>{
                            'n': national,
                            'nat': feed.nat,
                          }),
                      ].join(' · '),
                      style: TextStyle(color: zen.textSecondary, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: const Key('pyr-open-feed'),
                onPressed: () => pyrOpenFeed(context, FeedFilter.pyramid),
                icon: const Icon(Icons.newspaper_rounded),
                label: Text(t('Otwórz na Tablicy →')),
              ),
              PyramidBranchPostButton(pyr: pyr, branch: feed.branch),
            ],
          ),
        ],
      ),
    );
  }
}

/// „Napisz do gałęzi”: a signed post, under the pseudonym, to everybody
/// below this person; it shows on the Tablica.
class PyramidBranchPostButton extends StatelessWidget {
  const PyramidBranchPostButton({
    required this.pyr,
    required this.branch,
    super.key,
  });

  final PyramidService pyr;

  /// How many people are below.
  final int branch;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      key: const Key('pyr-post'),
      onPressed: () => unawaited(() async {
        final String? text = await askText(
          context,
          title: t('Do Twojej gałęzi ({count} os.)', <String, Object?>{
            'count': branch,
          }),
          maxLines: 6,
        );
        if (text != null && await pyr.post(text) != null && context.mounted) {
          snack(
            context,
            t(
              'Wysłane pod pseudonimem jako podpisany rekord. Post jest na '
              'Tablicy.',
            ),
          );
        }
      }()),
      icon: const Icon(Icons.edit_rounded),
      label: Text(t('Napisz do gałęzi')),
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
        s.referenda.values.where((PyrReferendum r) => s.inScope(r, me)).toList()
          ..sort((PyrReferendum a, PyrReferendum b) => b.at.compareTo(a.at));
    // A newcomer votes 14 days in, or once somebody of their cell
    // confirmed knowing them.
    final bool met = s.canVote(me, now);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenSection(t('Referenda'), top: 4),
        if (!met)
          ZenInfo(
            key: const Key('pyr-vote-not-met'),
            icon: Icons.handshake_outlined,
            tone: zen.warning,
            title: t('Głos jeszcze przed Tobą'),
            text: t(
              'Nowa osoba głosuje w komórce i w referendach po 14 dniach '
              '(u Ciebie od {date}) albo od razu, gdy ktoś z Twojej komórki '
              'potwierdzi, że się znacie.',
              <String, Object?>{
                'date': pyrDate(
                  (s.members[me]?.joinedAt ?? now) + kPyrVoteAfterMs,
                ).split(' ').first,
              },
            ),
          ),
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
                      icon: Icons.how_to_vote_rounded,
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
                    ZenPill(text: t('doradcze'), tone: zen.textMuted),
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
                if (now < r.end &&
                    s.eligible(r, me) &&
                    !pyr.myVotes.containsKey(r.id))
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
                else if (now < r.end && pyr.myVotes.containsKey(r.id))
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
            'Oddane głosy: {count} · sumy podpisane przez każdą komórkę. '
            'Wynik jest doradczy: decyduje szczyt.',
            <String, Object?>{'count': total},
          ),
          style: TextStyle(color: zen.textMuted, fontSize: 12.5),
        ),
      ],
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.s, required this.me});

  final PyramidState s;
  final String me;

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
              // The places through time, animated.
              ZenSection(t('Miejsca w czasie')),
              ZenCard(
                child: PyramidTimelineView(s: s, me: me),
              ),
              if (h.isEmpty)
                ZenEmpty(
                  icon: Icons.timeline_rounded,
                  tone: tone,
                  title: t('Historia jest pusta'),
                )
              else ...<Widget>[
                ZenSection(t('Wszystkie zmiany')),
                const SizedBox(height: 4),
              ],
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
                decoration: ZenLook.of(context).panel(zen, radius: 16),
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
