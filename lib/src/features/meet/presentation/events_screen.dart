import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart'
    show pickImageBytes;
import 'package:zen/src/features/feed/thanks_model.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/presentation/met_level_prompt.dart';
import 'package:zen/src/features/meet/presentation/safe_photo.dart';
import 'package:zen/src/features/meet/presentation/table_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart'
    show confirmPayment, parseMoney;
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

String eventDate(int millis) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(millis);
  return t('{weekday} {date} o {time}', {
    'weekday': ZenFormat.weekdayShort(d),
    'date': ZenFormat.dayMonth(d, padDay: false),
    'time': ZenFormat.time(d),
  });
}

/// "Wydarzenia": mine and the ones I am invited to.
class EventsScreen extends ConsumerStatefulWidget {
  const EventsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const EventsScreen(),
    ),
  );

  @override
  ConsumerState<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends ConsumerState<EventsScreen> {
  @override
  void initState() {
    super.initState();
    // What the background service took in while the app was away.
    unawaited(ref.read(eventServiceProvider).load());
  }

  @override
  Widget build(BuildContext context) {
    final EventService events = ref.watch(eventServiceProvider);
    return Scaffold(
      key: const Key('events-screen'),
      appBar: AppBar(title: Text(t('Wydarzenia'))),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('events-new'),
        onPressed: () => unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => const CreateEventScreen(),
            ),
          ),
        ),
        icon: const Icon(Icons.add_rounded),
        label: Text(t('Nowe')),
      ),
      body: ListenableBuilder(
        listenable: events,
        builder: (BuildContext context, Widget? _) {
          final int now = events.now;
          final List<MeetEvent> list = events.events
              .where((MeetEvent e) => e.startsAt > now - 12 * 3600 * 1000)
              .toList();
          // Past ones stay a month: their shared album and thank-you cards.
          final List<MeetEvent> past = events.events.reversed
              .where(
                (MeetEvent e) =>
                    e.startsAt <= now - 12 * 3600 * 1000 && !e.cancelled,
              )
              .toList();
          if (list.isEmpty && past.isEmpty) {
            return ListView(
              children: <Widget>[
                ZenEmpty(
                  icon: Icons.celebration_rounded,
                  title: t('Nie ma jeszcze wydarzeń'),
                  text: t(
                    'Zorganizuj coś — zaproszenie trafi tylko do ludzi '
                    'połączonych z Tobą przez znajomych.',
                  ),
                ),
              ],
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
            children: <Widget>[
              for (final MeetEvent e in list)
                _EventCard(
                  key: Key('event-${e.id}'),
                  event: e,
                  status: e.isMine
                      ? t('Organizujesz · gości: {count}', {
                          'count': e.goingCount,
                        })
                      : events.myGuest(e)?.status.label ?? t('Zaproszenie'),
                  onTap: () => unawaited(EventScreen.open(context, e.id)),
                ),
              if (past.isNotEmpty) ...<Widget>[
                ZenSection(t('Minione'), top: list.isEmpty ? 4 : 20),
                for (final MeetEvent e in past)
                  _EventCard(
                    key: Key('event-${e.id}'),
                    event: e,
                    status: events.photos(e.id).isEmpty
                        ? t('Już było')
                        : t('Już było · zdjęcia: {count}', {
                            'count': events.photos(e.id).length,
                          }),
                    onTap: () => unawaited(EventScreen.open(context, e.id)),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// An event in a list: a date block, the title, where and my status.
class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.status,
    required this.onTap,
    super.key,
  });

  final MeetEvent event;
  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final DateTime d = DateTime.fromMillisecondsSinceEpoch(event.startsAt);
    final Color tone = event.cancelled
        ? zen.textMuted
        : zenTone(zen, event.kind.index + 1);
    return ZenCard(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: <Widget>[
          Container(
            width: 58,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.16),
              borderRadius: context.zenRadius(16),
            ),
            child: Column(
              children: <Widget>[
                Text('${d.day}', style: zen.display(color: tone, size: 24)),
                Text(
                  ZenFormat.monthShort(d),
                  style: TextStyle(
                    color: tone,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(eventKindIcon(event.kind), size: 16, color: tone),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        event.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          decoration: event.cancelled
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  <String>[
                    eventDate(event.startsAt),
                    if (event.place.isNotEmpty) event.place,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 6),
                ZenPill(
                  text: event.cancelled ? t('Odwołane') : status,
                  tone: event.cancelled ? zen.danger : tone,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: zen.textMuted),
        ],
      ),
    );
  }
}

/// Organizing an event.
class CreateEventScreen extends ConsumerStatefulWidget {
  const CreateEventScreen({super.key, this.kind = EventKind.party});

  final EventKind kind;

  @override
  ConsumerState<CreateEventScreen> createState() => _CreateEventScreenState();
}

class _CreateEventScreenState extends ConsumerState<CreateEventScreen> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _place = TextEditingController();
  final TextEditingController _desc = TextEditingController();
  final TextEditingController _capacity = TextEditingController();
  late EventKind _kind = widget.kind;
  EventReach _reach = EventReach.selected;
  bool _plusOne = true;
  DateTime _at = DateTime.now().add(const Duration(days: 1));
  final Set<String> _invite = <String>{};
  bool _busy = false;

  @override
  void dispose() {
    _title.dispose();
    _place.dispose();
    _desc.dispose();
    _capacity.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (d == null || !mounted) {
      return;
    }
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    setState(() {
      _at = DateTime(
        d.year,
        d.month,
        d.day,
        t?.hour ?? _at.hour,
        t?.minute ?? _at.minute,
      );
    });
  }

  Future<void> _create() async {
    if (_title.text.trim().isEmpty) {
      return;
    }
    setState(() => _busy = true);
    final MeetEvent e = await ref
        .read(eventServiceProvider)
        .create(
          title: _title.text.trim(),
          kind: _kind,
          startsAt: _at.millisecondsSinceEpoch,
          place: _place.text.trim(),
          description: _desc.text.trim(),
          reach: _reach,
          capacity: int.tryParse(_capacity.text.trim()) ?? 0,
          askForPlusOne: _plusOne,
          invite: _reach == EventReach.close
              ? ref.read(meetServiceProvider).host.closeFriends()
              : _invite.toList(),
        );
    if (!mounted) {
      return;
    }
    Navigator.of(context).pop();
    unawaited(EventScreen.open(context, e.id));
  }

  @override
  Widget build(BuildContext context) {
    final SocialHubState social = watchSocialPeople(ref);
    final List<FriendProfile> friends = social.acceptedFriends;
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t('Nowe wydarzenie'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          TextField(
            key: const Key('event-title'),
            controller: _title,
            maxLength: 100,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: t('Nazwa'),
              hintText: t('np. Grill u mnie w sobotę'),
            ),
          ),
          ZenSection(t('Rodzaj'), top: 4),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final EventKind k in EventKind.values)
                if (k != EventKind.table || _kind == EventKind.table)
                  ChoiceChip(
                    key: Key('event-kind-${k.name}'),
                    avatar: Icon(eventKindIcon(k), size: 18),
                    label: Text(k.label),
                    selected: _kind == k,
                    onSelected: (_) => setState(() => _kind = k),
                  ),
            ],
          ),
          if (_kind != EventKind.table)
            ZenInfo(
              title: t('Chcesz poznać nowych ludzi?'),
              icon: Icons.dinner_dining_rounded,
              text: t(
                'Stół na sześć to kolacja, na którą aplikacja sama zaprasza '
                '5 osób: znajomych Twoich znajomych, którzy też chcą tak '
                'poznawać ludzi. Każdy przy stole jest połączony z Tobą przez '
                'kogoś, kogo znasz — nikt nie jest zupełnie obcy.',
              ),
              tone: zenTone(zen, 3),
            )
          else
            ZenInfo(
              title: t('Stół na sześć'),
              icon: Icons.dinner_dining_rounded,
              text: t(
                'Kolacja dla 6 osób: Ty i 5 gości, których aplikacja dobiera '
                'sama spośród znajomych Twoich znajomych.',
              ),
            ),
          if (_kind != EventKind.table)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('event-open-table'),
                onPressed: () => unawaited(TableScreen.open(context)),
                icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                label: Text(t('Załóż Stół na sześć')),
              ),
            ),
          ZenSection(t('Kiedy i gdzie'), top: 12),
          ZenGroup(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.schedule_rounded),
                title: Text(eventDate(_at.millisecondsSinceEpoch)),
                trailing: const Icon(Icons.edit_calendar_rounded),
                onTap: () => unawaited(_pickDate()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _place,
            maxLength: 200,
            decoration: InputDecoration(
              labelText: t('Gdzie'),
              prefixIcon: const Icon(Icons.place_outlined),
            ),
          ),
          TextField(
            controller: _desc,
            minLines: 2,
            maxLines: 5,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(labelText: t('Opis (nie trzeba)')),
          ),
          ZenSection(t('Kto może przyjść'), top: 4),
          Wrap(
            key: const Key('event-reach'),
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final EventReach r in EventReach.values)
                ChoiceChip(
                  key: Key('event-reach-${r.name}'),
                  label: Text(r.label),
                  selected: _reach == r,
                  onSelected: (_) => setState(() => _reach = r),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            switch (_reach) {
              EventReach.selected => t('Tylko osoby, które zaznaczysz niżej.'),
              EventReach.close => t('Tylko Twoi przyjaciele.'),
              EventReach.friends => t('Wszyscy Twoi znajomi.'),
              EventReach.friendsOfFriends => t(
                'Twoi znajomi i ich znajomi. Na liście gości zobaczysz, kto '
                'kogo przyprowadził. Znajomi znajomych widzą tylko imiona '
                'gości, adresy dopiero z biletem.',
              ),
              EventReach.twoSteps => t(
                'Znajomi, ich znajomi i znajomi tamtych. Każdy gość jest '
                'połączony z Tobą łańcuchem znajomych.',
              ),
            },
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _capacity,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: t('Ile osób najwyżej'),
              helperText: t('Razem z Tobą. Puste = bez limitu.'),
              prefixIcon: const Icon(Icons.groups_2_outlined),
            ),
          ),
          const SizedBox(height: 8),
          ZenGroup(
            children: <Widget>[
              SwitchListTile(
                value: _plusOne,
                title: Text(t('Goście mogą prosić o „+1”')),
                subtitle: Text(t('O każdej osobie decydujesz Ty.')),
                onChanged: (bool v) => setState(() => _plusOne = v),
              ),
            ],
          ),
          if (_reach == EventReach.selected) ...<Widget>[
            ZenSection(
              t('Kogo zapraszasz ({count})', {'count': _invite.length}),
              top: 16,
            ),
            if (friends.isEmpty)
              Text(
                t('Nie masz jeszcze znajomych w aplikacji.'),
                style: TextStyle(color: zen.textSecondary),
              )
            else
              ZenGroup(
                children: <Widget>[
                  for (final FriendProfile f in friends)
                    CheckboxListTile(
                      value: _invite.contains(f.address),
                      title: Text(social.nameFor(f)),
                      onChanged: (bool? v) => setState(() {
                        if (v ?? false) {
                          _invite.add(f.address);
                        } else {
                          _invite.remove(f.address);
                        }
                      }),
                    ),
                ],
              ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            key: const Key('event-create'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed:
                _busy ||
                    (_reach == EventReach.selected && _invite.isEmpty) ||
                    (_reach == EventReach.close &&
                        ref
                            .read(meetServiceProvider)
                            .host
                            .closeFriends()
                            .isEmpty)
                ? null
                : () => unawaited(_create()),
            icon: const Icon(Icons.send_rounded),
            label: Text(t('Zaproś')),
          ),
        ],
      ),
    );
  }
}

IconData eventKindIcon(EventKind k) => switch (k) {
  EventKind.party => Icons.celebration_rounded,
  EventKind.dinner => Icons.restaurant_rounded,
  EventKind.table => Icons.dinner_dining_rounded,
  EventKind.meeting => Icons.groups_rounded,
  EventKind.other => Icons.event_rounded,
};

/// One event: details, guests ("znasz 5"), answering, the ticket, and the
/// organizer's tools.
class EventScreen extends ConsumerWidget {
  const EventScreen({required this.eventId, super.key});

  final String eventId;

  static Future<void> open(BuildContext context, String id) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => EventScreen(eventId: id),
        ),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final EventService events = ref.watch(eventServiceProvider);
    final MeetService meet = ref.watch(meetServiceProvider);
    return ListenableBuilder(
      listenable: events,
      builder: (BuildContext context, Widget? _) {
        final MeetEvent? e = events.event(eventId);
        if (e == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: ZenEmpty(
                icon: Icons.event_busy_rounded,
                title: t('Nie ma tego wydarzenia.'),
              ),
            ),
          );
        }
        final String me = PeerShareCodec.normalizeAddress(
          events.host.ownAddress(),
        );
        final Set<String> myFriends = meet.host
            .friends()
            .map(PeerShareCodec.normalizeAddress)
            .toSet();
        final List<EventGuest> going = e.guests.values
            .where((EventGuest g) => g.status == GuestStatus.going)
            .toList();
        final int known = e.knownGoing(myFriends);
        final EventGuest? mine = events.myGuest(e);
        final EventTicket? ticket = events.ticket(e.id);
        final bool past = e.startsAt < events.now;
        // On a list without addresses, friends are found by their hash.
        String? friendOf(EventGuest g) => e.friendIn(g, myFriends);
        String nameOf(String a) {
          final EventGuest? g = e.guests[a] ?? e.guest(a);
          final String? friend = g == null ? null : friendOf(g);
          if (a == me || (g != null && e.guest(me) == g)) {
            return t('Ty');
          }
          if (myFriends.contains(a) || friend != null) {
            return meet.host.nameOf(friend ?? a);
          }
          return (g?.name.isNotEmpty ?? false) ? g!.name : t('ktoś');
        }

        final ZenColors zen = ZenColors.of(context);
        final Color tone = e.cancelled
            ? zen.textMuted
            : zenTone(zen, e.kind.index + 1);
        final int knownTotal =
            known + (e.isMine || myFriends.contains(e.organizer) ? 1 : 0);
        String chain(EventGuest g) {
          final List<String> c = e
              .chainOf(g.address)
              .skip(1)
              .map(nameOf)
              .toList();
          return c.isEmpty ? '' : t('przez {chain}', {'chain': c.join(' ← ')});
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(e.title),
            actions: <Widget>[
              if (e.isMine && !e.cancelled)
                PopupMenuButton<String>(
                  onSelected: (String v) {
                    if (v == 'cancel') {
                      unawaited(events.cancel(e.id));
                    } else if (v == 'scan') {
                      unawaited(_scan(context, ref, e));
                    }
                  },
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'scan',
                          child: Text(t('Sprawdzaj bilety')),
                        ),
                        PopupMenuItem<String>(
                          value: 'cancel',
                          child: Text(t('Odwołaj wydarzenie')),
                        ),
                      ],
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              if (e.cancelled)
                ZenInfo(
                  icon: Icons.event_busy_rounded,
                  tone: zen.danger,
                  title: t('Wydarzenie odwołane'),
                  text: t('Organizator odwołał to spotkanie.'),
                ),
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: context.zenRadius(26),
                  gradient: LinearGradient(
                    colors: <Color>[
                      Color.alphaBlend(
                        tone.withValues(alpha: 0.26),
                        zen.surface,
                      ),
                      Color.alphaBlend(
                        zen.accentSecondary.withValues(alpha: 0.08),
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
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ZenIconBadge(
                          icon: eventKindIcon(e.kind),
                          tone: tone,
                          size: 48,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            e.title,
                            style: zen.display(
                              color: zen.textPrimary,
                              size: 22,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        ZenPill(text: e.kind.label, tone: tone),
                        ZenPill(
                          text: e.reach.label,
                          tone: zen.textSecondary,
                          icon: Icons.share_rounded,
                        ),
                        if (past && !e.cancelled)
                          ZenPill(
                            text: t('Już było'),
                            tone: zen.textMuted,
                            icon: Icons.history_rounded,
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    _EventFact(
                      icon: Icons.schedule_rounded,
                      text: eventDate(e.startsAt),
                    ),
                    if (e.place.isNotEmpty)
                      _EventFact(icon: Icons.place_outlined, text: e.place),
                    _EventFact(
                      icon: Icons.person_outline_rounded,
                      text: t('organizuje {name}', {
                        'name': e.isMine ? t('Ty') : e.organizerName,
                      }),
                    ),
                  ],
                ),
              ),
              if (e.description.isNotEmpty)
                ZenCard(
                  child: Text(
                    e.description,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 14.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ZenCard(
                child: Row(
                  children: <Widget>[
                    Column(
                      children: <Widget>[
                        Text(
                          '$knownTotal',
                          style: zen.display(color: tone, size: 32),
                        ),
                        Text(
                          t('znasz'),
                          style: zen.label(color: zen.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        e.capacity > 0
                            ? t(
                                'Będzie {count} z {capacity} osób, znasz {known}.',
                                {
                                  'count': going.length + 1,
                                  'capacity': e.capacity,
                                  'known': knownTotal,
                                },
                              )
                            : tn(
                                going.length + 1,
                                one: 'Będzie {n} osoba, znasz {known}.',
                                few: 'Będą {n} osoby, znasz {known}.',
                                many: 'Będzie {n} osób, znasz {known}.',
                                args: {'known': knownTotal},
                              ),
                        key: const Key('event-known'),
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!e.isMine && !e.cancelled && !past) ...<Widget>[
                ZenSection(t('Twoja odpowiedź')),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final (GuestStatus s, IconData icon)
                        in <(GuestStatus, IconData)>[
                          (
                            GuestStatus.going,
                            Icons.check_circle_outline_rounded,
                          ),
                          (GuestStatus.maybe, Icons.help_outline_rounded),
                          (GuestStatus.declined, Icons.cancel_outlined),
                        ])
                      ChoiceChip(
                        key: Key('event-rsvp-${s.name}'),
                        showCheckmark: false,
                        avatar: Icon(icon, size: 18),
                        label: Text(s.label),
                        selected: mine?.status == s,
                        onSelected: (_) => unawaited(events.rsvp(e.id, s)),
                      ),
                  ],
                ),
                if (e.isFull && mine?.status != GuestStatus.going) ...<Widget>[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ZenPill(
                      text: t('Brak miejsc.'),
                      tone: zen.warning,
                      icon: Icons.event_seat_rounded,
                    ),
                  ),
                ],
                if (e.askForPlusOne &&
                    mine?.status == GuestStatus.going) ...<Widget>[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('event-plus1'),
                      onPressed: () => unawaited(_askPlusOne(context, ref, e)),
                      icon: const Icon(Icons.person_add_alt_1_rounded),
                      label: Text(t('Chcę kogoś przyprowadzić')),
                    ),
                  ),
                ],
              ],
              if (ticket != null &&
                  mine?.status == GuestStatus.going &&
                  !e.cancelled) ...<Widget>[
                ZenSection(t('Twój bilet')),
                ZenCard(
                  tone: tone,
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    children: <Widget>[
                      Text(
                        t('Pokaż przy wejściu'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _LiveTicketCode(
                        // A new ticket (e.g. just pinned) starts afresh.
                        key: ValueKey<String>('ticket-${ticket.signature}'),
                        events: events,
                        eventId: e.id,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        ticket.name,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (events.ticketPinned(e.id)) ...<Widget>[
                        ZenPill(
                          key: const Key('event-ticket-pinned'),
                          text: t('Przypięty do tego telefonu'),
                          tone: zen.success,
                          icon: Icons.lock_rounded,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          t(
                            'Kod zmienia się co 20 s — zrzut ekranu nikogo '
                            'innego nie wpuści.',
                          ),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ] else ...<Widget>[
                        ZenPill(
                          text: t('Bilet bez przypięcia'),
                          tone: zen.warning,
                          icon: Icons.lock_open_rounded,
                        ),
                        const SizedBox(height: 4),
                        TextButton.icon(
                          key: const Key('event-ticket-pin'),
                          onPressed: () =>
                              unawaited(events.rsvp(e.id, GuestStatus.going)),
                          icon: const Icon(Icons.push_pin_outlined),
                          label: Text(t('Przypnij do tego telefonu')),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              _AfterEvent(events: events, event: e, tone: tone),
              ZenSection(t('Goście ({count})', {'count': e.guests.length})),
              if (e.guests.isEmpty)
                ZenCard(
                  child: Text(
                    t('Jeszcze nikt nie odpowiedział.'),
                    style: TextStyle(color: zen.textSecondary),
                  ),
                )
              else
                ZenCard(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: <Widget>[
                      for (final (int i, EventGuest g)
                          in e.guests.values.indexed) ...<Widget>[
                        if (i > 0)
                          Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16,
                            color: zen.outlineSoft,
                          ),
                        _GuestRow(
                          icon: g.checkedIn
                              ? Icons.how_to_reg_rounded
                              : friendOf(g) != null
                              ? Icons.person_rounded
                              : Icons.person_outline_rounded,
                          tone: g.checkedIn
                              ? zen.success
                              : switch (g.status) {
                                  GuestStatus.going => tone,
                                  GuestStatus.requested => zen.warning,
                                  GuestStatus.declined => zen.textMuted,
                                  _ => zen.textSecondary,
                                },
                          name: nameOf(g.address),
                          details: <String>[
                            g.status.label,
                            if (chain(g).isNotEmpty) chain(g),
                            if (g.plusOnes > 0)
                              t('+{count} bez pytania', {'count': g.plusOnes}),
                          ].join(' · '),
                          trailing: e.isMine
                              ? _organizerActions(context, events, e, g)
                              : null,
                          below:
                              !e.isMine &&
                                  past &&
                                  g.address != me &&
                                  !g.address.startsWith('#') &&
                                  !myFriends.contains(g.address) &&
                                  g.status == GuestStatus.going
                              ? FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(0, 36),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                  ),
                                  onPressed: () =>
                                      unawaited(_metAt(context, ref, g, e)),
                                  icon: const Icon(
                                    Icons.handshake_outlined,
                                    size: 18,
                                  ),
                                  label: Text(t('Poznaliśmy się')),
                                )
                              : null,
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget? _organizerActions(
    BuildContext context,
    EventService events,
    MeetEvent e,
    EventGuest g,
  ) {
    if (g.status == GuestStatus.requested) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton.filledTonal(
            tooltip: t('Zgoda'),
            icon: const Icon(Icons.check_rounded),
            onPressed: () =>
                unawaited(events.decidePlusOne(e.id, g.address, true)),
          ),
          IconButton(
            tooltip: t('Nie'),
            icon: const Icon(Icons.close_rounded),
            onPressed: () =>
                unawaited(events.decidePlusOne(e.id, g.address, false)),
          ),
        ],
      );
    }
    return PopupMenuButton<int>(
      tooltip: t('„+1” bez pytania'),
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (int v) {
        if (v < 0) {
          unawaited(events.removeGuest(e.id, g.address));
        } else {
          unawaited(events.allowPlusOnes(e.id, g.address, v));
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        for (final int n in <int>[0, 1, 2])
          PopupMenuItem<int>(
            value: n,
            child: Text(t('„+{count}” bez pytania', {'count': n})),
          ),
        PopupMenuItem<int>(value: -1, child: Text(t('Usuń z listy'))),
      ],
    );
  }

  Future<void> _askPlusOne(
    BuildContext context,
    WidgetRef ref,
    MeetEvent e,
  ) async {
    final SocialHubState social = ref.read(socialHubControllerProvider);
    final FriendProfile? picked = await showDialog<FriendProfile>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(t('Kogo chcesz przyprowadzić?')),
        children: <Widget>[
          for (final FriendProfile f in social.acceptedFriends)
            if (e.guest(f.address) == null)
              SimpleDialogOption(
                onPressed: () => Navigator.of(context).pop(f),
                child: Text(social.nameFor(f)),
              ),
        ],
      ),
    );
    if (picked != null) {
      await ref.read(eventServiceProvider).askPlusOne(e.id, picked.address);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('Zapytano organizatora.'))));
      }
    }
  }

  Future<void> _metAt(
    BuildContext context,
    WidgetRef ref,
    EventGuest g,
    MeetEvent e,
  ) async {
    await ref
        .read(socialHubControllerProvider.notifier)
        .sendFriendRequest(
          peerAddress: g.address,
          knownName: g.name,
          message: t('Poznaliśmy się na: {title}', {'title': e.title}),
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Zaproszenie do {name} wysłane.', {'name': g.name})),
        ),
      );
      // Met in person: how close are you?
      await showMetLevelPrompt(context, address: g.address, name: g.name);
    }
  }

  Future<void> _scan(BuildContext context, WidgetRef ref, MeetEvent e) async {
    final String? qr = await ref.read(peerQrScannerProvider).scan(context);
    if (qr == null || !context.mounted) {
      return;
    }
    final EventService events = ref.read(eventServiceProvider);
    final (CheckIn result, EventGuest? g) = await events.checkIn(e.id, qr);
    if (!context.mounted) {
      return;
    }
    final String text = switch (result) {
      CheckIn.ok => '✓ ${g!.name}',
      CheckIn.already => t('{name} już wszedł(-ła) — bilet użyty', {
        'name': g!.name,
      }),
      CheckIn.notGoing => t('Ta osoba nie potwierdziła udziału'),
      CheckIn.otherEvent => t('Bilet na inne wydarzenie'),
      CheckIn.invalid => t('✗ Nieważny bilet'),
      CheckIn.expired => t(
        '✗ Kod nieaktualny — to zrzut ekranu albo stara kopia',
      ),
      CheckIn.replayed => t('✗ Ten kod już był użyty'),
    };
    final List<String> notes = <String>[
      if (g != null && g.broughtBy != null)
        t('Przyprowadzona przez: {name}', {
          'name': e.guest(g.broughtBy!)?.name ?? '?',
        }),
      if (result == CheckIn.expired)
        t(
          'Poproś o pokazanie biletu na żywo w aplikacji: kod na telefonie '
          'gościa zmienia się co 20 s.',
        ),
    ];
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(text),
        content: notes.isEmpty ? null : Text(notes.join('\n\n')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('OK')),
          ),
        ],
      ),
    );
  }
}

/// The ticket QR shown at the door: renewed every 20 s and signed
/// by this phone's own key, so a screenshot passed on to someone else stops
/// working after about a minute and a half.
class _LiveTicketCode extends StatefulWidget {
  const _LiveTicketCode({
    required this.events,
    required this.eventId,
    super.key,
  });

  final EventService events;
  final String eventId;

  @override
  State<_LiveTicketCode> createState() => _LiveTicketCodeState();
}

class _LiveTicketCodeState extends State<_LiveTicketCode> {
  String? _code;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    unawaited(_renew());
    _timer = Timer.periodic(
      EventTicket.liveRefresh,
      (Timer _) => unawaited(_renew()),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _renew() async {
    final String? code;
    try {
      code = await widget.events.ticketQr(widget.eventId);
    } on Object {
      return;
    }
    if (mounted && code != _code) {
      setState(() => _code = code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? code = _code;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: context.zenRadius(18),
      ),
      child: code == null
          ? const SizedBox(
              width: 200,
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            )
          : QrImageView(
              key: const Key('event-ticket'),
              data: code,
              size: 200,
              backgroundColor: Colors.white,
            ),
    );
  }
}

/// A line of the event header: icon and text.
class _EventFact extends StatelessWidget {
  const _EventFact({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: zen.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 14.5,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One guest on the list: who, how they are connected to you, and the
/// organizer's (or your) actions.
class _GuestRow extends StatelessWidget {
  const _GuestRow({
    required this.icon,
    required this.tone,
    required this.name,
    required this.details,
    this.trailing,
    this.below,
  });

  final IconData icon;
  final Color tone;
  final String name;
  final String details;
  final Widget? trailing;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ZenIconBadge(icon: icon, tone: tone, size: 36),
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
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
                if (below != null) ...<Widget>[
                  const SizedBox(height: 8),
                  below!,
                ],
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// The pyramid key of the member reachable at [address], or `null`.
String? pyramidKeyOfAddress(PyramidState s, String address) {
  final String a = PeerShareCodec.normalizeAddress(address);
  for (final MapEntry<String, PyrMember> m in s.members.entries) {
    if (m.value.addr.isNotEmpty &&
        PeerShareCodec.normalizeAddress(m.value.addr) == a &&
        s.isMember(m.key)) {
      return m.key;
    }
  }
  return null;
}

/// After the event: the shared album, gratitude cards for the host
/// and a tip in the pyramid's currency.
class _AfterEvent extends ConsumerWidget {
  const _AfterEvent({
    required this.events,
    required this.event,
    required this.tone,
  });

  final EventService events;
  final MeetEvent event;
  final Color tone;

  Future<void> _addPhotos(BuildContext context) async {
    final int room =
        EventService.maxPhotosPerGuest -
        events
            .photos(event.id)
            .where(
              (EventPhoto p) =>
                  p.by ==
                  PeerShareCodec.normalizeAddress(events.host.ownAddress()),
            )
            .length;
    if (room <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Dodano już wszystkie Twoje zdjęcia (20).'))),
      );
      return;
    }
    final List<Uint8List> picked;
    try {
      picked = await pickImageBytes(limit: room > 1 ? room : null);
    } on Object {
      return;
    }
    int added = 0;
    int bad = 0;
    for (final Uint8List raw in picked.take(room)) {
      final Uint8List? jpeg = await compute(compressEventPhoto, raw);
      if (jpeg == null || await events.addPhoto(event.id, jpeg) == null) {
        bad++;
      } else {
        added++;
      }
    }
    if (context.mounted && picked.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            bad == 0
                ? t(
                    'Dodano zdjęcia: {count}. Zobaczą je goście, którzy byli.',
                    {'count': added},
                  )
                : t(
                    'Dodano: {added}, nie udało się: {failed} '
                    '(nieobsługiwany format?).',
                    {'added': added, 'failed': bad},
                  ),
          ),
        ),
      );
    }
  }

  void _show(BuildContext context, List<EventPhoto> photos, int index) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (BuildContext dialog) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: _PhotoViewer(photos: photos, initial: index),
        ),
      ),
    );
  }

  Future<void> _thank(BuildContext context, WidgetRef ref) async {
    final TextEditingController field = TextEditingController(
      text: events.myThanks(event.id)?.text ?? '',
    );
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(t('Karta wdzięczności')),
        content: TextField(
          key: const Key('event-thanks-field'),
          controller: field,
          autofocus: true,
          maxLength: EventThanks.maxChars,
          minLines: 2,
          maxLines: 4,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: t('Za co dziękujesz?'),
            hintText: t('Np. „Najlepsza kolacja w tym roku!”'),
            helperText: t('Dostanie ją {name}.', {'name': event.organizerName}),
            prefixIcon: const Icon(Icons.volunteer_activism_outlined),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('event-thanks-send'),
            onPressed: () => Navigator.of(dialog).pop(field.text),
            child: Text(t('Wyślij')),
          ),
        ],
      ),
    );
    disposeLater(field);
    if (text == null || text.trim().isEmpty) {
      return;
    }
    final bool sent = await events.sendThanks(event.id, text);
    // It also counts on the host's profile ("Podziękowania"), when
    // their account is known and the monthly limit allows.
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    final String? account = node == null || !node.isReady
        ? null
        : node.knownAccountOf(event.organizer);
    if (sent && node != null && account != null) {
      try {
        if (thanksLeft(
              node,
              account,
              nowMillis: DateTime.now().millisecondsSinceEpoch,
            ) >
            0) {
          final String card = t('Za „{title}”: {text}', {
            'title': event.title,
            'text': text.trim(),
          });
          await node.publish(
            kThanksKind,
            thanksBody(
              account,
              card.length > kMaxThanksChars
                  ? card.substring(0, kMaxThanksChars)
                  : card,
            ),
            spaceKind: 'acts',
          );
        }
      } on Object {
        // The card for the event went anyway.
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sent
                ? t('Karta wysłana do {name}.', {'name': event.organizerName})
                : t('Nie udało się wysłać.'),
          ),
        ),
      );
    }
  }

  Future<void> _tip(
    BuildContext context,
    PyramidService pyr,
    PyramidState s,
    String to,
    String me,
  ) async {
    final TextEditingController amount = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(t('Napiwek dla gospodarza')),
        content: TextField(
          key: const Key('event-tip-amount'),
          controller: amount,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: t('Kwota'),
            hintText: '0,00',
            helperText: t('Na koncie: {amount}', {
              'amount': formatMoney(pyr.balance),
            }),
            prefixIcon: const Icon(Icons.payments_outlined),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('event-tip-send'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Daj napiwek')),
          ),
        ],
      ),
    );
    final int? value = parseMoney(amount.text);
    disposeLater(amount);
    if (ok != true || value == null || value <= 0) {
      return;
    }
    if (value > pyr.balance) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('Za mało na koncie.'))));
      }
      return;
    }
    if (!context.mounted || !await confirmPayment(context)) {
      return;
    }
    final PyramidRecord? order = await pyr.pay(
      to,
      value,
      memo: t('Napiwek: {title}', {'title': event.title}),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            order == null
                ? t('Nie można teraz (poprzedni przelew jeszcze czeka?).')
                : t('Napiwek {amount} poszedł do skarbników piramidy.', {
                    'amount': formatMoney(value),
                  }),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final MeetEvent e = event;
    final List<EventPhoto> photos = events.photos(e.id);
    final bool canAdd = events.canAddPhotos(e);
    final bool canThank = events.canThank(e);
    final EventThanks? mine = events.myThanks(e.id);
    final List<EventThanks> cards = e.isMine
        ? events.thanksFor(e.id)
        : const <EventThanks>[];
    // A tip only when both are in the same pyramid; hidden otherwise.
    final PyramidService pyr = ref.watch(pyramidServiceProvider);
    final PyramidState? ps = pyr.state;
    final String? me = pyr.myKey;
    final String? host = canThank && ps != null && me != null && ps.isMember(me)
        ? pyramidKeyOfAddress(ps, e.organizer)
        : null;
    final bool canTip = host != null && host != me;
    final bool askHow = events.howDue(e);
    // "Powtórzymy za miesiąc?": the organizer, once it is over.
    final bool canRepeat =
        e.isMine &&
        !e.cancelled &&
        events.now - e.startsAt >= EventService.howAfter.inMilliseconds;
    if (photos.isEmpty &&
        !canAdd &&
        !canThank &&
        cards.isEmpty &&
        !askHow &&
        !canRepeat) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (askHow)
          ZenCard(
            key: const Key('event-how'),
            tone: tone,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t('Jak było?'),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final (String code, String label)
                        in <(String, String)>[
                          ('g', t('Super')),
                          ('o', t('Dobrze')),
                          ('m', t('Tak sobie')),
                        ])
                      ActionChip(
                        key: Key('event-how-$code'),
                        label: Text(label),
                        onPressed: () => unawaited(events.rate(e.id, code)),
                      ),
                  ],
                ),
                if (!e.isMine) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    t(
                      'Poznaliście kogoś nowego? Przy gościach jest '
                      '„Spotkani?”. Gospodarzowi możesz podziękować niżej.',
                    ),
                    style: TextStyle(color: zen.textSecondary, fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        if (canRepeat)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: FilledButton.tonalIcon(
              key: const Key('event-repeat'),
              onPressed: () async {
                final MeetEvent? again = await events.repeat(e.id);
                if (!context.mounted) {
                  return;
                }
                if (again == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(t('Nikt nie przyszedł.'))),
                  );
                  return;
                }
                unawaited(EventScreen.open(context, again.id));
              },
              icon: const Icon(Icons.replay_rounded),
              label: Text(t('Powtórzymy za miesiąc?')),
            ),
          ),
        if (photos.isNotEmpty || canAdd) ...<Widget>[
          ZenSection(
            t('Wspólny album ({count})', {'count': photos.length}),
            action: canAdd ? t('Dodaj') : null,
            onAction: canAdd ? () => unawaited(_addPhotos(context)) : null,
          ),
          if (photos.isEmpty)
            ZenInfo(
              icon: Icons.photo_library_rounded,
              tone: tone,
              title: t('Album tylko dla gości'),
              text: t(
                'Dodajcie zdjęcia z wydarzenia. Zobaczą je tylko ci, '
                'którzy byli — nikt spoza listy gości.',
              ),
            )
          else
            GridView.count(
              key: const Key('event-album'),
              crossAxisCount: 3,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: <Widget>[
                for (final (int i, EventPhoto p) in photos.indexed)
                  ClipRRect(
                    borderRadius: context.zenRadius(12),
                    child: Material(
                      color: zen.surfaceMuted,
                      child: InkWell(
                        onTap: () => _show(context, photos, i),
                        child: SafePhoto(data: p.data),
                      ),
                    ),
                  ),
              ],
            ),
        ],
        if (canThank || canTip) ...<Widget>[
          ZenSection(t('Dla gospodarza')),
          if (mine != null)
            ZenCard(
              tone: zen.success,
              child: Row(
                children: <Widget>[
                  ZenIconBadge(
                    icon: Icons.volunteer_activism_rounded,
                    tone: zen.success,
                    size: 38,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '„${mine.text}”',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 14,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (canThank)
                FilledButton.tonalIcon(
                  key: const Key('event-thanks'),
                  onPressed: () => unawaited(_thank(context, ref)),
                  icon: const Icon(Icons.volunteer_activism_outlined),
                  label: Text(
                    mine == null ? t('Karta wdzięczności') : t('Zmień kartę'),
                  ),
                ),
              if (canTip)
                OutlinedButton.icon(
                  key: const Key('event-tip'),
                  onPressed: () =>
                      unawaited(_tip(context, pyr, ps!, host, me!)),
                  icon: const Icon(Icons.payments_outlined),
                  label: Text(t('Napiwek dla gospodarza')),
                ),
            ],
          ),
        ],
        if (cards.isNotEmpty) ...<Widget>[
          ZenSection(
            t('Karty wdzięczności ({count})', {'count': cards.length}),
          ),
          for (final EventThanks c in cards)
            ZenCard(
              tone: zen.success,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  ZenIconBadge(
                    icon: Icons.volunteer_activism_rounded,
                    tone: zen.success,
                    size: 38,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          c.byName.isEmpty ? t('Gość') : c.byName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 14.5,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          c.text,
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 14,
                            height: 1.35,
                          ),
                        ),
                      ],
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

/// Album photos one by one, full screen.
class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({required this.photos, required this.initial});

  final List<EventPhoto> photos;
  final int initial;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initial,
  );
  late int _at = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final EventPhoto p = widget.photos[_at];
    final String by = p.byName.isEmpty ? t('Gość') : p.byName;
    return Stack(
      children: <Widget>[
        PageView.builder(
          controller: _pages,
          itemCount: widget.photos.length,
          onPageChanged: (int i) => setState(() => _at = i),
          itemBuilder: (BuildContext context, int i) => InteractiveViewer(
            child: Center(
              child: SafePhoto(
                data: widget.photos[i].data,
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                IconButton(
                  tooltip: t('Zamknij'),
                  color: Colors.white,
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '$by · ${_at + 1}/${widget.photos.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
