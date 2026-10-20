import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/meet/circle/circle_service.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/presentation/events_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Kółka obiadowe (§17.3).
class CirclesScreen extends ConsumerStatefulWidget {
  const CirclesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const CirclesScreen(),
    ),
  );

  @override
  ConsumerState<CirclesScreen> createState() => _CirclesScreenState();
}

class _CirclesScreenState extends ConsumerState<CirclesScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(circleServiceProvider).load());
  }

  Future<void> _create() async {
    final SocialHubState social = ref.read(socialHubControllerProvider);
    final TextEditingController name = TextEditingController(text: t('Obiady'));
    final Set<String> chosen = <String>{};
    DateTime first = DateTime.now().add(const Duration(days: 7));
    TimeOfDay time = const TimeOfDay(hour: 19, minute: 0);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ZenColors zen = ZenColors.of(context);
          return AlertDialog(
            title: Text(t('Nowe kółko obiadowe')),
            content: SizedBox(
              width: 380,
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  TextField(
                    controller: name,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: t('Nazwa'),
                      hintText: t('np. Obiady czwartkowe'),
                      prefixIcon: const Icon(Icons.soup_kitchen_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ZenCard(
                    tone: zenTone(zen, 3),
                    padding: const EdgeInsets.all(12),
                    onTap: () async {
                      final DateTime? d = await showDatePicker(
                        context: context,
                        initialDate: first,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 180)),
                      );
                      if (d == null || !context.mounted) {
                        return;
                      }
                      final TimeOfDay? t = await showTimePicker(
                        context: context,
                        initialTime: time,
                      );
                      set(() {
                        first = d;
                        time = t ?? time;
                      });
                    },
                    child: Row(
                      children: <Widget>[
                        ZenIconBadge(
                          icon: Icons.edit_calendar_rounded,
                          tone: zenTone(zen, 3),
                          size: 38,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                t('Pierwszy obiad: {date}', {
                                  'date': eventDate(
                                    DateTime(
                                      first.year,
                                      first.month,
                                      first.day,
                                      time.hour,
                                      time.minute,
                                    ).millisecondsSinceEpoch,
                                  ),
                                }),
                                style: TextStyle(
                                  color: zen.textPrimary,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14.5,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                t('Potem co tydzień, w ten sam dzień.'),
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 12.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 14, 0, 4),
                    child: Text(
                      t('KTO (4–8 OSÓB LUB PAR)'),
                      style: zen.label(color: zen.textMuted),
                    ),
                  ),
                  if (social.acceptedFriends.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        t('Najpierw dodaj znajomych.'),
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  for (final FriendProfile f in social.acceptedFriends)
                    CheckboxListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      value: chosen.contains(f.address),
                      title: Text(
                        social.nameFor(f),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
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
                child: Text(t('Utwórz')),
              ),
            ],
          );
        },
      ),
    );
    final String n = name.text.trim();
    disposeLater(name);
    if (ok != true || chosen.isEmpty || !mounted) {
      return;
    }
    final DinnerCircle c = await ref
        .read(circleServiceProvider)
        .create(
          name: n.isEmpty ? t('Obiady') : n,
          friends: chosen.toList(),
          weekday: first.weekday,
          hour: time.hour,
          firstDinner: first,
        );
    if (mounted) {
      await CircleScreen.open(context, c.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final CircleService circles = ref.watch(circleServiceProvider);
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('circles-screen'),
      appBar: AppBar(title: Text(t('Kółka obiadowe'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => unawaited(_create()),
        icon: const Icon(Icons.add_rounded),
        label: Text(t('Nowe kółko')),
      ),
      body: ListenableBuilder(
        listenable: circles,
        builder: (BuildContext context, Widget? _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: <Widget>[
              ZenHero(
                title: t('Gotujecie na zmianę'),
                icon: Icons.soup_kitchen_rounded,
                tone: zenTone(zen, 3),
                text: t(
                  'Kółko to kilka osób, które na zmianę gotują dla siebie — '
                  'np. „Obiady czwartkowe”. Zen układa kolejkę, przypomina, '
                  'kto gotuje, zbiera alergie i listę, kto co przynosi.',
                ),
              ),
              if (circles.circles.isEmpty)
                ZenEmpty(
                  icon: Icons.ramen_dining_rounded,
                  tone: zenTone(zen, 3),
                  title: t('Nie masz jeszcze kółka'),
                  text: t('Zaproś 4–8 znajomych i ustalcie dzień tygodnia.'),
                  action: FilledButton.icon(
                    onPressed: () => unawaited(_create()),
                    icon: const Icon(Icons.add_rounded),
                    label: Text(t('Załóż kółko')),
                  ),
                )
              else ...<Widget>[
                ZenSection(t('Twoje kółka')),
                for (final DinnerCircle c in circles.circles)
                  ZenTile(
                    icon: Icons.soup_kitchen_rounded,
                    tone: zenTone(zen, 3),
                    title: c.name,
                    subtitle: () {
                      final List<(DateTime, CircleMember)> s = c.schedule(
                        circles.now,
                        count: 1,
                      );
                      return s.isEmpty
                          ? ''
                          : t('{date} · gotuje {name}', {
                              'date': eventDate(
                                s.first.$1.millisecondsSinceEpoch,
                              ),
                              'name':
                                  PeerShareCodec.addressesEqual(
                                    s.first.$2.address,
                                    ref
                                        .read(eventServiceProvider)
                                        .host
                                        .ownAddress(),
                                  )
                                  ? t('Ty')
                                  : s.first.$2.name,
                            });
                    }(),
                    badge: circles.swapRequests[c.id] != null
                        ? t('zamiana')
                        : null,
                    onTap: () => unawaited(CircleScreen.open(context, c.id)),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class CircleScreen extends ConsumerWidget {
  const CircleScreen({required this.circleId, super.key});

  final String circleId;

  static Future<void> open(BuildContext context, String id) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => CircleScreen(circleId: id),
        ),
      );

  Future<String?> _ask(
    BuildContext context,
    String title, {
    String initial = '',
  }) async {
    final TextEditingController c = TextEditingController(text: initial);
    final String? v = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 300,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(c.text),
            child: Text(t('Zapisz')),
          ),
        ],
      ),
    );
    disposeLater(c);
    return v;
  }

  /// "Przyprowadzę kogoś" (kółko otwarte): a friend (who gets an
  /// invitation) or anyone by name.
  Future<void> _bringGuest(
    BuildContext context,
    WidgetRef ref,
    DinnerCircle c,
    DateTime day,
  ) async {
    final SocialHubState social = ref.read(socialHubControllerProvider);
    final List<FriendProfile> friends = <FriendProfile>[
      for (final FriendProfile f in social.acceptedFriends)
        if (!c.hasMember(f.address)) f,
    ];
    final Object? picked = await showDialog<Object>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(t('Kogo przyprowadzisz?')),
        children: <Widget>[
          for (final FriendProfile f in friends)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(f),
              child: Text(
                social.nameFor(f),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          SimpleDialogOption(
            key: const Key('circle-guest-other'),
            onPressed: () => Navigator.of(context).pop('other'),
            child: Text(t('Ktoś inny — wpiszę imię')),
          ),
        ],
      ),
    );
    if (picked == null || !context.mounted) {
      return;
    }
    String? name;
    String? address;
    if (picked is FriendProfile) {
      name = social.nameFor(picked);
      address = picked.address;
    } else {
      name = await _ask(context, t('Imię osoby, którą przyprowadzisz'));
    }
    if (name == null || name.trim().isEmpty) {
      return;
    }
    final bool ok = await ref
        .read(circleServiceProvider)
        .bringGuest(c.id, day, name: name, address: address);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? address != null
                      ? t('Zapisane. {name} dostanie zaproszenie.', {
                          'name': name,
                        })
                      : t('Zapisane — reszta kółka wie, że przyjdzie {name}.', {
                          'name': name,
                        })
                : t('W tym miesiącu już kogoś przyprowadzasz.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CircleService circles = ref.watch(circleServiceProvider);
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 3);
    return ListenableBuilder(
      listenable: circles,
      builder: (BuildContext context, Widget? _) {
        final DinnerCircle? c = circles.circle(circleId);
        if (c == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: ZenEmpty(
                icon: Icons.no_meals_rounded,
                title: t('Nie ma tego kółka.'),
              ),
            ),
          );
        }
        final String me = PeerShareCodec.normalizeAddress(
          ref.read(eventServiceProvider).host.ownAddress(),
        );
        final List<(DateTime, CircleMember)> schedule = c.schedule(circles.now);
        final DateTime? next = schedule.isEmpty ? null : schedule.first.$1;
        final CircleGuest? myGuest = next == null ? null : c.guestOf(me, next);
        final List<(String, CircleGuest)> guestsNext = next == null
            ? const <(String, CircleGuest)>[]
            : c.guestsOn(next);
        final Map<String, String> items = next == null
            ? const <String, String>{}
            : c.items[DinnerCircle.dayKey(next)] ?? const <String, String>{};
        String nameOf(String a) =>
            c.members
                .where((CircleMember m) => m.address == a)
                .firstOrNull
                ?.name ??
            t('ktoś');
        return Scaffold(
          appBar: AppBar(title: Text(c.name)),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              if (circles.swapRequests[c.id] != null)
                ZenCard(
                  tone: zen.warning,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(Icons.swap_horiz_rounded, color: zen.warning),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              t('{name} chce zamienić się kolejką', {
                                'name': nameOf(circles.swapRequests[c.id]!),
                              }),
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 14.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          FilledButton(
                            onPressed: () =>
                                unawaited(circles.acceptSwap(c.id)),
                            child: Text(t('Zgoda')),
                          ),
                          OutlinedButton(
                            onPressed: () => circles.declineSwap(c.id),
                            child: Text(t('Nie')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ZenSection(
                t('Kolejka'),
                top: circles.swapRequests[c.id] != null ? 20 : 4,
              ),
              if (schedule.isEmpty)
                ZenCard(
                  child: Text(
                    t('Brak zaplanowanych obiadów.'),
                    style: TextStyle(color: zen.textSecondary),
                  ),
                )
              else
                ZenCard(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    children: <Widget>[
                      for (int i = 0; i < schedule.length; i++) ...<Widget>[
                        if (i > 0)
                          Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                            color: zen.outlineSoft,
                          ),
                        _ScheduleRow(
                          at: schedule[i].$1,
                          cook: schedule[i].$2.address == me
                              ? t('Ty')
                              : schedule[i].$2.name,
                          mine: schedule[i].$2.address == me,
                          first: i == 0,
                          tone: tone,
                          onSwap: schedule[i].$2.address != me
                              ? () => unawaited(
                                  circles.askSwap(c.id, schedule[i].$2.address),
                                )
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
              if (next != null) ...<Widget>[
                ZenSection(
                  t('Kto co przynosi · {date}', {
                    'date': eventDate(next.millisecondsSinceEpoch),
                  }),
                  action: t('Dodaj'),
                  onAction: () async {
                    final String? item = await _ask(
                      context,
                      t('Co trzeba przynieść?'),
                    );
                    if (item != null) {
                      await circles.addItem(c.id, next, item);
                    }
                  },
                ),
                if (items.isEmpty)
                  ZenInfo(
                    icon: Icons.shopping_basket_rounded,
                    tone: tone,
                    text: t(
                      'Lista jest pusta. Dodaj, co trzeba przynieść — '
                      'np. deser, wino, chleb.',
                    ),
                  )
                else
                  ZenGroup(
                    children: <Widget>[
                      for (final MapEntry<String, String> i in items.entries)
                        CheckboxListTile(
                          value: i.value.isNotEmpty,
                          title: Text(i.key),
                          subtitle: Text(
                            i.value.isEmpty
                                ? t('nikt jeszcze')
                                : i.value == me
                                ? t('Ty')
                                : nameOf(i.value),
                          ),
                          onChanged: i.value.isEmpty || i.value == me
                              ? (_) => unawaited(
                                  circles.claimItem(c.id, next, i.key),
                                )
                              : null,
                        ),
                    ],
                  ),
              ],
              ZenSection(t('Kółko otwarte')),
              ZenGroup(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('circle-open'),
                    value: c.open,
                    title: Text(t('Raz w miesiącu +1')),
                    subtitle: Text(
                      t(
                        'Każdy może raz w miesiącu przyprowadzić jedną osobę '
                        'spoza kółka — tak poznajecie nowych ludzi.',
                      ),
                    ),
                    onChanged: (bool v) => unawaited(circles.setOpen(c.id, v)),
                  ),
                ],
              ),
              if (c.open && next != null) ...<Widget>[
                const SizedBox(height: 6),
                for (final (String by, CircleGuest g) in guestsNext)
                  ZenTile(
                    icon: Icons.person_add_alt_1_rounded,
                    tone: tone,
                    title: g.name,
                    subtitle: t('Gość na {date} · przyprowadza {name}', {
                      'date': eventDate(next.millisecondsSinceEpoch),
                      'name': by == me ? t('Ty') : nameOf(by),
                    }),
                  ),
                if (myGuest != null)
                  ZenCard(
                    tone: tone,
                    child: Row(
                      children: <Widget>[
                        ZenIconBadge(
                          icon: Icons.event_seat_rounded,
                          tone: tone,
                          size: 38,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            t(
                              'W tym miesiącu przyprowadzasz: {name} ({date})',
                              {
                                'name': myGuest.name,
                                'date': myGuest.day
                                    .split('-')
                                    .reversed
                                    .join('.'),
                              },
                            ),
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 14,
                              height: 1.35,
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () =>
                              unawaited(circles.cancelGuest(c.id, next)),
                          child: Text(t('Odwołaj')),
                        ),
                      ],
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.tonalIcon(
                        key: const Key('circle-bring-guest'),
                        onPressed: () =>
                            unawaited(_bringGuest(context, ref, c, next)),
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: Text(
                          t('Przyprowadzę kogoś · {date}', {
                            'date': eventDate(next.millisecondsSinceEpoch),
                          }),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
              ],
              ZenSection(t('Preferencje i alergie')),
              ZenGroup(
                children: <Widget>[
                  for (final CircleMember m in c.members)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: tone.withValues(alpha: 0.18),
                        foregroundColor: tone,
                        child: Text(
                          _initial(m.address == me ? t('Ty') : m.name),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      title: Text(
                        m.address == me ? t('Ty') : m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(c.prefs[m.address] ?? '—'),
                      trailing: m.address == me
                          ? IconButton(
                              tooltip: t('Edytuj'),
                              icon: const Icon(Icons.edit_rounded),
                              onPressed: () async {
                                final String? prefs = await _ask(
                                  context,
                                  t('Twoje preferencje i alergie'),
                                  initial: c.prefs[me] ?? '',
                                );
                                if (prefs != null) {
                                  await circles.setMyPrefs(c.id, prefs);
                                }
                              },
                            )
                          : null,
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

String _initial(String name) {
  final String t = name.trim();
  return t.isEmpty ? '?' : t.characters.first.toUpperCase();
}

/// One dinner in the queue: date, who cooks, "swap" button.
class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({
    required this.at,
    required this.cook,
    required this.mine,
    required this.first,
    required this.tone,
    this.onSwap,
  });

  final DateTime at;
  final String cook;
  final bool mine;
  final bool first;
  final Color tone;
  final VoidCallback? onSwap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      child: Row(
        children: <Widget>[
          ZenIconBadge(
            icon: Icons.restaurant_rounded,
            tone: mine ? zen.accent : tone,
            size: 36,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  eventDate(at.millisecondsSinceEpoch),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: first ? FontWeight.w800 : FontWeight.w600,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t('gotuje {name}', {'name': cook}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: mine ? zen.accent : zen.textSecondary,
                    fontSize: 13,
                    fontWeight: mine ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
          if (onSwap != null)
            TextButton(
              onPressed: onSwap,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              child: Text(t('Zamień')),
            ),
        ],
      ),
    );
  }
}
