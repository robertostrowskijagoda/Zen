import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// A neighbour's flat: their invitations, offers and needs, and messages
/// between the two flats.
class NeighborScreen extends ConsumerStatefulWidget {
  const NeighborScreen({required this.flatKey, super.key});

  final String flatKey;

  static Future<void> open(BuildContext context, String key) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => NeighborScreen(flatKey: key),
        ),
      );

  @override
  ConsumerState<NeighborScreen> createState() => _NeighborScreenState();
}

class _NeighborScreenState extends ConsumerState<NeighborScreen> {
  late final NeighborsService _service = ref.read(neighborsServiceProvider);
  final TextEditingController _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_service.markRead(widget.flatKey));
    unawaited(_service.refresh(widget.flatKey));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final String t = _text.text;
    if (t.trim().isEmpty) {
      return;
    }
    _text.clear();
    await _service.sendMessage(widget.flatKey, t);
  }

  /// The small chat about one invitation: a thread with the flat,
  /// answered by any of the residents.
  Future<void> _askAbout(FlatItem item) async {
    final TextEditingController input = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: ListenableBuilder(
          listenable: _service,
          builder: (BuildContext context, Widget? _) {
            final List<FlatMessage> thread = _service.threadAbout(
              widget.flatKey,
              item.id,
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(item.text, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (thread.isEmpty)
                  Text(t('Zapytajcie o szczegóły — odpisze ktoś z domowników.'))
                else
                  // Newest at the bottom, next to the field; the thread
                  // scrolls when it no longer fits above the keyboard.
                  Flexible(
                    child: ListView(
                      key: const Key('flat-invite-chat-thread'),
                      reverse: true,
                      shrinkWrap: true,
                      children: <Widget>[
                        for (final FlatMessage m in thread.reversed)
                          Align(
                            alignment: m.mine
                                ? AlignmentDirectional.centerEnd
                                : AlignmentDirectional.centerStart,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text(
                                m.by.isEmpty ? m.text : '${m.by}: ${m.text}',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('flat-invite-chat-input'),
                  controller: input,
                  maxLength: 500,
                  decoration: InputDecoration(
                    hintText: t('Napisz o zaproszeniu…'),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.send_rounded),
                      onPressed: () {
                        final String text = input.text;
                        if (text.trim().isEmpty) {
                          return;
                        }
                        input.clear();
                        unawaited(
                          _service.sendMessage(
                            widget.flatKey,
                            text,
                            itemId: item.id,
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    input.dispose();
  }

  Future<void> _signUp(FlatItem item, int current) async {
    int count = current > 0 ? current : 1;
    final int? chosen = await showDialog<int>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ZenColors zen = ZenColors.of(context);
          final Color tone = neighborsTone(zen);
          return AlertDialog(
            scrollable: true,
            title: Text(item.text),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t('Ile osób przyjdzie?'),
                  style: TextStyle(color: zen.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    IconButton.filledTonal(
                      tooltip: t('Mniej'),
                      onPressed: count > 1 ? () => set(() => count--) : null,
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    Flexible(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              '$count',
                              style: zen.display(color: tone, size: 34),
                            ),
                            Text(
                              tn(
                                count,
                                one: 'osoba',
                                few: 'osoby',
                                many: 'osób',
                              ),
                              style: TextStyle(
                                color: zen.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton.filledTonal(
                      tooltip: t('Więcej'),
                      onPressed: count < 20 ? () => set(() => count++) : null,
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
              ],
            ),
            actions: <Widget>[
              if (current > 0)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(0),
                  child: Text(t('Nie przyjdziemy')),
                ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t('Anuluj')),
              ),
              FilledButton(
                key: const Key('flat-signup-ok'),
                onPressed: () => Navigator.of(context).pop(count),
                child: Text(t('Przyjdziemy')),
              ),
            ],
          );
        },
      ),
    );
    if (chosen != null) {
      await _service.signUp(widget.flatKey, item.id, chosen);
    }
  }

  /// "Pokaż mój profil": this resident's own account goes to the
  /// neighbour flat (only this person, never the housemates).
  Future<void> _reveal(NeighborFlat f) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.badge_rounded),
        title: Text(
          t('Pokazać Twój profil „{name}”?', {'name': f.profile.name}),
        ),
        content: Text(
          t(
            'Zobaczą Twoje imię z Zen i będą mogli zaprosić Cię do znajomych. '
            'Pozostali domownicy pozostaną ukryci — każdy decyduje sam za '
            'siebie.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('flat-reveal-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Pokaż')),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    final bool sent = await _service.revealMyProfile(f.key);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sent
                ? t('Wysłane. „{name}” zobaczą Twój profil.', {
                    'name': f.profile.name,
                  })
                : t('Nie udało się.'),
          ),
        ),
      );
    }
  }

  /// Two different new keys came for this household: the one whose door
  /// code is scanned stays.
  Future<void> _scanTheirDoor() async {
    final String? text = await scanOrPaste(
      context,
      ref,
      title: t('Nowy kod z ich drzwi'),
      accepts: isFlatDoorText,
    );
    if (text == null || !mounted) {
      return;
    }
    final FlatDoorCode? code = FlatDoorCode.parse(text);
    if (code == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            FlatDoorCode.isNewer(text)
                ? t('Ten kod jest z nowszej wersji Zen. Zaktualizuj aplikację.')
                : t('To nie jest kod mieszkania.'),
          ),
        ),
      );
      return;
    }
    await _service.scanDoor(code);
    if (!mounted) {
      return;
    }
    if (code.key != widget.flatKey && _service.neighbor(code.key) != null) {
      // They live under the other key: show that one.
      unawaited(
        Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                NeighborScreen(flatKey: code.key),
          ),
        ),
      );
    }
  }

  Future<void> _invite(NeighborFlat f, FlatReveal r) async {
    await ref
        .read(socialHubControllerProvider.notifier)
        .sendFriendRequest(
          peerAddress: r.address,
          knownName: r.name,
          message: t('Sąsiedzi: {name}', {'name': f.profile.label}),
        );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Zaproszenie do {name} wysłane.', {'name': r.name})),
        ),
      );
    }
  }

  Future<void> _menu(String action, NeighborFlat f) async {
    switch (action) {
      case 'reveal':
        await _reveal(f);
      case 'mute':
        await _service.setFollowing(f.key, !f.following);
      case 'remove':
        final bool? ok = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            scrollable: true,
            icon: Icon(
              Icons.person_remove_rounded,
              color: ZenColors.of(context).danger,
            ),
            title: Text(t('Usunąć „{name}”?', {'name': f.profile.label})),
            content: Text(
              t('Znikną z Waszej listy sąsiadów razem z wiadomościami.'),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(t('Anuluj')),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: ZenColors.of(context).danger,
                  foregroundColor: ZenColors.foregroundFor(
                    ZenColors.of(context).danger,
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(t('Usuń')),
              ),
            ],
          ),
        );
        if (ok == true) {
          await _service.removeNeighbor(f.key);
          if (mounted) {
            Navigator.of(context).pop();
          }
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _service,
      builder: (BuildContext context, Widget? _) {
        final NeighborFlat? f = _service.neighbor(widget.flatKey);
        if (f == null) {
          return Scaffold(appBar: AppBar());
        }
        final FlatProfile p = f.profile;
        final ZenColors zen = ZenColors.of(context);
        final ZenLook look = ZenLook.of(context);
        final Color tone = neighborsTone(zen);
        final Color onTone = ZenColors.foregroundFor(tone);
        final List<FlatMessage> messages = _service.messagesWith(f.key);
        final List<FlatItem> invites = p.of(FlatItemKind.invite).toList();
        final List<FlatItem> offers = p.of(FlatItemKind.offer).toList();
        final List<FlatItem> needs = p.of(FlatItemKind.need).toList();
        final FlatProfile? rival = _service.keyRival(f.key);
        if (_service.unread(f.key) > 0) {
          unawaited(_service.markRead(f.key));
        }
        return Scaffold(
          key: const Key('neighbor-screen'),
          appBar: AppBar(
            title: Text(p.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: <Widget>[
              PopupMenuButton<String>(
                onSelected: (String a) => unawaited(_menu(a, f)),
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    key: const Key('flat-reveal'),
                    value: 'reveal',
                    child: ListTile(
                      leading: const Icon(Icons.badge_rounded),
                      title: Text(
                        _service.revealedTo(f.key)
                            ? t('Pokaż mój profil jeszcze raz')
                            : t('Pokaż mój profil'),
                      ),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'mute',
                    child: ListTile(
                      leading: Icon(
                        f.following
                            ? Icons.notifications_off_rounded
                            : Icons.notifications_active_rounded,
                      ),
                      title: Text(
                        f.following
                            ? t('Wycisz nowości')
                            : t('Powiadamiaj o nowościach'),
                      ),
                    ),
                  ),
                  PopupMenuItem<String>(
                    value: 'remove',
                    child: ListTile(
                      leading: const Icon(Icons.person_remove_rounded),
                      title: Text(t('Usuń z sąsiadów')),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: SelectionArea(
            child: Column(
              children: <Widget>[
                Expanded(
                  child: SelectionArea(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      children: <Widget>[
                        ZenCard(
                          tone: tone,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  FlatAvatar(
                                    profile: p,
                                    size: 48,
                                    icon: Icons.door_front_door_rounded,
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          p.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: zen.display(
                                            color: zen.textPrimary,
                                            size: 21,
                                            weight: FontWeight.w600,
                                          ),
                                        ),
                                        if (p.place.isNotEmpty) ...<Widget>[
                                          const SizedBox(height: 3),
                                          Text(
                                            p.place,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: zen.textSecondary,
                                              fontSize: 13.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              if (p.about.isNotEmpty) ...<Widget>[
                                const SizedBox(height: 10),
                                Text(
                                  p.about,
                                  style: TextStyle(
                                    color: zen.textSecondary,
                                    fontSize: 14,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                              if (!f.following) ...<Widget>[
                                const SizedBox(height: 10),
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: ZenPill(
                                    text: t('Wyciszeni'),
                                    tone: zen.textMuted,
                                    icon: Icons.notifications_off_rounded,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (rival != null)
                          ZenCard(
                            key: const Key('flat-key-conflict'),
                            tone: zen.warning,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    ZenIconBadge(
                                      icon: Icons.warning_amber_rounded,
                                      tone: zen.warning,
                                      size: 40,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          Text(
                                            kFlatKeyConflict,
                                            style: TextStyle(
                                              color: zen.textPrimary,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              height: 1.3,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            t(
                                              'Odłączyli jeden telefon, ale przyszły '
                                              'dwie różne wersje (domowników: '
                                              '{count} i {otherCount}). Zapytajcie '
                                              'ich osobiście i zeskanujcie nowy kod '
                                              'z ich drzwi — zostanie ten właściwy.',
                                              <String, Object?>{
                                                'count': p.members.length,
                                                'otherCount':
                                                    rival.members.length,
                                              },
                                            ),
                                            style: TextStyle(
                                              color: zen.textSecondary,
                                              fontSize: 13.5,
                                              height: 1.4,
                                            ),
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
                                  alignment: WrapAlignment.end,
                                  children: <Widget>[
                                    TextButton(
                                      key: const Key('flat-key-keep'),
                                      onPressed: () => unawaited(
                                        _service.keepCurrentKey(f.key),
                                      ),
                                      child: Text(t('Zostaw tę wersję')),
                                    ),
                                    FilledButton.tonalIcon(
                                      key: const Key('flat-key-scan'),
                                      onPressed: () =>
                                          unawaited(_scanTheirDoor()),
                                      icon: const Icon(
                                        Icons.qr_code_scanner_rounded,
                                        size: 18,
                                      ),
                                      label: Text(t('Zeskanuj ich kod')),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        if (_service.revealsFrom(f.key).isNotEmpty) ...<Widget>[
                          ZenSection(t('Pokazali swoje profile')),
                          for (final FlatReveal r in _service.revealsFrom(
                            f.key,
                          ))
                            ZenTile(
                              key: Key('flat-reveal-${r.name}'),
                              icon: Icons.badge_rounded,
                              tone: tone,
                              title: r.name,
                              subtitle: t(
                                'Mieszka tu — możesz zaprosić do znajomych.',
                              ),
                              onTap: () => unawaited(_invite(f, r)),
                              trailing: Icon(
                                Icons.person_add_alt_1_rounded,
                                color: tone,
                              ),
                            ),
                        ],
                        if (invites.isNotEmpty) ...<Widget>[
                          ZenSection(t('Zapraszają')),
                          for (final FlatItem i in invites)
                            Builder(
                              builder: (BuildContext context) {
                                final int mine = _service.mySignup(f.key, i.id);
                                return FlatItemCard(
                                  kind: FlatItemKind.invite,
                                  text: i.text,
                                  meta: <String>[
                                    if (i.at != null) flatDate(i.at!),
                                    if (i.seats > 0)
                                      t('miejsca: {taken}/{seats}', {
                                        'taken': i.taken,
                                        'seats': i.seats,
                                      }),
                                  ].join(' · '),
                                  below: Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    alignment: WrapAlignment.end,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: <Widget>[
                                      if (mine > 0)
                                        ZenPill(
                                          text: t('Wy: {count}', {
                                            'count': mine,
                                          }),
                                          tone: zen.success,
                                          icon: Icons.check_rounded,
                                        ),
                                      TextButton.icon(
                                        onPressed: () =>
                                            unawaited(_askAbout(i)),
                                        icon: const Icon(Icons.forum_rounded),
                                        label: Text(t('Zapytaj')),
                                      ),
                                      FilledButton.tonal(
                                        onPressed: i.isFull && mine == 0
                                            ? null
                                            : () => unawaited(_signUp(i, mine)),
                                        child: Text(
                                          mine > 0
                                              ? t('Zmień')
                                              : i.isFull
                                              ? t('Brak miejsc')
                                              : t('Przyjdziemy'),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                        ],
                        if (offers.isNotEmpty) ...<Widget>[
                          ZenSection(t('Oferują')),
                          for (final FlatItem i in offers)
                            FlatItemCard(
                              kind: FlatItemKind.offer,
                              text: i.text,
                            ),
                        ],
                        if (needs.isNotEmpty) ...<Widget>[
                          ZenSection(t('Potrzebują')),
                          for (final FlatItem i in needs)
                            FlatItemCard(kind: FlatItemKind.need, text: i.text),
                        ],
                        ZenSection(t('Wiadomości')),
                        if (messages.isEmpty)
                          ZenInfo(
                            icon: Icons.forum_rounded,
                            tone: tone,
                            text: t(
                              'Napiszcie coś do siebie — odpisze ktokolwiek z '
                              'domowników.',
                            ),
                          ),
                        for (final FlatMessage m in messages)
                          Builder(
                            builder: (BuildContext context) {
                              // The look's own bubbles; the filled looks keep
                              // the tone fill with the look's corners.
                              final BoxDecoration? themed = look.bubble(
                                zen,
                                outgoing: m.mine,
                              );
                              final bool onFill = m.mine && themed == null;
                              return Align(
                                alignment: m.mine
                                    ? AlignmentDirectional.centerEnd
                                    : AlignmentDirectional.centerStart,
                                child: Container(
                                  margin: EdgeInsetsDirectional.only(
                                    top: 3,
                                    bottom: 3,
                                    start: m.mine ? 48 : 0,
                                    end: m.mine ? 0 : 48,
                                  ),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  constraints: const BoxConstraints(
                                    maxWidth: 480,
                                  ),
                                  decoration:
                                      themed ??
                                      BoxDecoration(
                                        color: m.mine
                                            ? tone
                                            : zen.surfaceRaised,
                                        borderRadius:
                                            BorderRadiusDirectional.only(
                                              topStart: Radius.circular(
                                                look.radius(18),
                                              ),
                                              topEnd: Radius.circular(
                                                look.radius(18),
                                              ),
                                              bottomStart: Radius.circular(
                                                look.radius(m.mine ? 18 : 6),
                                              ),
                                              bottomEnd: Radius.circular(
                                                look.radius(m.mine ? 6 : 18),
                                              ),
                                            ),
                                        border: m.mine
                                            ? null
                                            : Border.all(
                                                color: zen.outlineSoft,
                                              ),
                                      ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      if (m.by.isNotEmpty) ...<Widget>[
                                        Text(
                                          m.by,
                                          style: TextStyle(
                                            color: onFill
                                                ? onTone.withValues(alpha: 0.8)
                                                : tone,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                      ],
                                      Text(
                                        m.text,
                                        style: TextStyle(
                                          color: onFill
                                              ? onTone
                                              : zen.textPrimary,
                                          fontSize: 15,
                                          height: 1.35,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: zen.surface,
                    border: Border(top: BorderSide(color: zen.outlineSoft)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(
                        12,
                        8,
                        8,
                        8,
                      ),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              key: const Key('neighbor-text'),
                              controller: _text,
                              minLines: 1,
                              maxLines: 4,
                              textCapitalization: TextCapitalization.sentences,
                              decoration: InputDecoration(
                                hintText: t('Napisz do „{name}”', {
                                  'name': p.name,
                                }),
                              ),
                              onSubmitted: (_) => unawaited(_send()),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton.filled(
                            key: const Key('neighbor-send'),
                            tooltip: t('Wyślij'),
                            style: IconButton.styleFrom(
                              backgroundColor: tone,
                              foregroundColor: onTone,
                            ),
                            onPressed: () => unawaited(_send()),
                            icon: const Icon(Icons.send_rounded),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
