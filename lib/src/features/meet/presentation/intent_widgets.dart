import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// When a status set now goes out: in an hour, at midnight, or never.
enum IntentDuration {
  hour,
  today,
  open;

  String get label => switch (this) {
    IntentDuration.hour => t('1 godzina'),
    IntentDuration.today => t('Do końca dnia'),
    IntentDuration.open => t('Do odwołania'),
  };

  int untilFrom(int now) {
    switch (this) {
      case IntentDuration.hour:
        return now + 3600 * 1000;
      case IntentDuration.today:
        final DateTime d = DateTime.fromMillisecondsSinceEpoch(now);
        return DateTime(d.year, d.month, d.day + 1).millisecondsSinceEpoch;
      case IntentDuration.open:
        return 0;
    }
  }
}

/// "jeszcze 40 min", "do 18:00", "do odwołania".
String intentTimeLeft(IntentStatus s, int now) {
  if (s.until == 0) {
    return t('do odwołania');
  }
  final int minutes = ((s.until - now) / 60000).ceil();
  if (minutes < 60) {
    return t('jeszcze {minutes} min', {'minutes': minutes < 1 ? 1 : minutes});
  }
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(s.until);
  return t('do {time}', {'time': ZenFormat.time(d)});
}

/// How much of a status's time is left (1 = just set), or `null` for one
/// that lasts until switched off.
double? intentTimeShare(IntentStatus s, int now) {
  if (s.until == 0 || s.until <= s.setAt) {
    return null;
  }
  return ((s.until - now) / (s.until - s.setAt)).clamp(0.0, 1.0);
}

/// The colour of a status everywhere (panel, graph, lists).
Color intentTone(ZenColors zen, IntentKind k) => switch (k) {
  IntentKind.urgent => zen.danger,
  IntentKind.help => zenTone(zen, 5),
  IntentKind.canHelp => zen.success,
  IntentKind.talk => zenTone(zen, 0),
  IntentKind.out => zenTone(zen, 2),
  IntentKind.walk => zenTone(zen, 3),
  IntentKind.eat => zenTone(zen, 1),
  IntentKind.play => zenTone(zen, 6),
  IntentKind.dnd => zen.textMuted,
  IntentKind.dating => zenTone(zen, 4),
  IntentKind.custom => zenTone(zen, 7),
};

/// Friends' statuses on the panel, in this order ("Nie przeszkadzać" is not
/// an invitation, so it is not listed).
const List<IntentKind> kFriendIntentOrder = <IntentKind>[
  IntentKind.urgent,
  IntentKind.help,
  IntentKind.canHelp,
  IntentKind.talk,
  IntentKind.out,
  IntentKind.walk,
  IntentKind.eat,
  IntentKind.play,
  IntentKind.dating,
  IntentKind.custom,
];

/// "Na teraz": this person's own status on top (or the question
/// what they are up for), then which friends are up for something now,
/// grouped by kind.
/// "Tylko przyjaciele": the friends' statuses shown (for this run of the
/// app).
final ValueNotifier<bool> _onlyClose = ValueNotifier<bool>(false);

class IntentPanel extends ConsumerWidget {
  const IntentPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MeetService service = ref.watch(meetServiceProvider);
    final DatingService dating = ref.watch(datingServiceProvider);
    // Rebuilt now and then too, so the time left stays true.
    return _Ticking(
      builder: (BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[service, dating]),
        builder: (BuildContext context, Widget? _) {
          // „Randkuję” only while dating is on.
          final bool datingOn = dating.active;
          final int now = service.now;
          final IntentStatus? stored = service.book.myIntent;
          final IntentStatus? mine = stored != null && stored.activeAt(now)
              ? stored
              : null;
          void open(IntentKind k, {IntentStatus? initial}) => unawaited(
            showIntentSheet(
              context,
              service,
              k,
              // Used only for „Randkuję”.
              hideFrom: dating.hiddenAddresses(),
              initial: initial,
              kinds: initial == null
                  ? const <IntentKind>[]
                  : <IntentKind>[
                      for (final IntentKind other in IntentKind.values)
                        if (other != IntentKind.dating || datingOn) other,
                    ],
            ),
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (mine != null)
                MyIntentCard(
                  key: const Key('intent-mine'),
                  status: mine,
                  now: now,
                  onEdit: () => open(mine.kind, initial: mine),
                  onClear: () => unawaited(service.setMyIntent(null)),
                )
              else
                IntentPicker(
                  key: const Key('intent-mine'),
                  datingOn: datingOn,
                  onPick: open,
                ),
              ValueListenableBuilder<bool>(
                valueListenable: _onlyClose,
                builder: (BuildContext context, bool onlyClose, Widget? _) {
                  final Set<String> close = <String>{
                    for (final String f in service.host.closeFriends())
                      PeerShareCodec.normalizeAddress(f),
                  };
                  final Map<IntentKind, List<(String, IntentStatus)>> all =
                      <IntentKind, List<(String, IntentStatus)>>{
                        for (final IntentKind k in kFriendIntentOrder)
                          k: service.friendsWith(k),
                      };
                  final bool any = all.values.any(
                    (List<(String, IntentStatus)> l) => l.isNotEmpty,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      if (any && close.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: <Widget>[
                              ChoiceChip(
                                key: const Key('intent-filter-all'),
                                label: Text(t('Wszyscy')),
                                selected: !onlyClose,
                                onSelected: (_) => _onlyClose.value = false,
                              ),
                              ChoiceChip(
                                key: const Key('intent-filter-close'),
                                label: Text(t('Tylko przyjaciele')),
                                selected: onlyClose,
                                onSelected: (_) => _onlyClose.value = true,
                              ),
                            ],
                          ),
                        ),
                      FriendIntents(
                        byKind: <IntentKind, List<(String, IntentStatus)>>{
                          for (final MapEntry<
                                IntentKind,
                                List<(String, IntentStatus)>
                              >
                              e
                              in all.entries)
                            e.key: <(String, IntentStatus)>[
                              for (final (String, IntentStatus) f in e.value)
                                if (!onlyClose ||
                                    close.contains(
                                      PeerShareCodec.normalizeAddress(f.$1),
                                    ))
                                  f,
                            ],
                        },
                        now: now,
                        ownSet: mine != null,
                        nameOf: service.host.nameOf,
                        avatar: (String address, String name, double size) =>
                            _StatusAvatar(
                              address: address,
                              name: name,
                              size: size,
                            ),
                        onOpen: (String address) => unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (BuildContext context) =>
                                  ConversationScreen(
                                    peerAddress: address,
                                    title: service.host.nameOf(address),
                                  ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Calls [builder] again every half a minute.
class _Ticking extends StatefulWidget {
  const _Ticking({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_Ticking> createState() => _TickingState();
}

class _TickingState extends State<_Ticking> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// A friend's photo (or initial) without the online dot.
class _StatusAvatar extends ConsumerWidget {
  const _StatusAvatar({
    required this.address,
    required this.name,
    required this.size,
  });

  final String address;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? path = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.peerProfileOf(address)?.avatarPath,
      ),
    );
    return ZenBlobAvatar(
      name: name,
      size: size,
      showStatus: false,
      image: peerAvatarImage(path),
    );
  }
}

/// No status yet: "Na co masz teraz ochotę?" with the statuses to pick.
class IntentPicker extends StatelessWidget {
  const IntentPicker({required this.datingOn, required this.onPick, super.key});

  /// „Randkuję” is offered only while dating is on.
  final bool datingOn;
  final void Function(IntentKind kind) onPick;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      decoration: BoxDecoration(
        borderRadius: context.zenRadius(24),
        gradient: zen.panelGradient(tone: zen.accent, alpha: 0.10),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(t('TWÓJ STATUS'), style: zen.label(color: zen.textMuted)),
          const SizedBox(height: 6),
          Text(
            t('Na co masz teraz ochotę?'),
            style: zen.display(
              color: zen.textPrimary,
              size: 20,
              weight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t('Daj znać znajomym — zobaczą to od razu.'),
            style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
          ),
          const SizedBox(height: 14),
          // The urgent one stands apart (full width, red); the rest are
          // compact pills that flow with the width.
          _IntentChoice(
            key: const Key('intent-set-urgent'),
            kind: IntentKind.urgent,
            tone: intentTone(zen, IntentKind.urgent),
            wide: true,
            onTap: () => onPick(IntentKind.urgent),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              // The everyday ones on the panel; the rest one tap away.
              for (final IntentKind k in _mainIntents)
                _IntentChoice(
                  key: Key('intent-set-${k.name}'),
                  kind: k,
                  tone: intentTone(zen, k),
                  onTap: () => onPick(k),
                ),
              // The sheet ends with "Własny status", set apart from the
              // ready-made ones.
              _MoreIntents(
                key: const Key('intent-more'),
                kinds: <IntentKind>[
                  for (final IntentKind k in IntentKind.values)
                    if (k != IntentKind.urgent &&
                        k != IntentKind.custom &&
                        !_mainIntents.contains(k) &&
                        (k != IntentKind.dating || datingOn))
                      k,
                ],
                onPick: onPick,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One status to pick: an emoji and its name in a tinted pill (or a
/// full-width card for the urgent one).
class _IntentChoice extends StatelessWidget {
  const _IntentChoice({
    required this.kind,
    required this.tone,
    required this.onTap,
    this.wide = false,
    super.key,
  });

  final IntentKind kind;
  final Color tone;
  final VoidCallback onTap;

  /// A full-width card (the urgent one) instead of a compact pill.
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final BorderRadius r = context.zenRadius(wide ? 18 : 999);
    final Text label = Text(
      kind.label,
      maxLines: wide ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: wide ? tone : zen.textPrimary,
        fontSize: wide ? 15 : 13.5,
        fontWeight: wide ? FontWeight.w800 : FontWeight.w700,
        height: 1.2,
      ),
    );
    return Material(
      color: Color.alphaBlend(
        tone.withValues(alpha: wide ? 0.14 : 0.10),
        zen.surface,
      ),
      borderRadius: r,
      child: InkWell(
        borderRadius: r,
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: r,
            border: Border.all(
              color: tone.withValues(alpha: wide ? 0.55 : 0.30),
            ),
          ),
          padding: wide
              ? const EdgeInsets.fromLTRB(14, 12, 12, 12)
              : const EdgeInsets.fromLTRB(10, 8, 14, 8),
          child: Row(
            mainAxisSize: wide ? MainAxisSize.max : MainAxisSize.min,
            children: <Widget>[
              Text(kind.emoji, style: TextStyle(fontSize: wide ? 24 : 17)),
              SizedBox(width: wide ? 10 : 6),
              if (wide) Expanded(child: label) else Flexible(child: label),
              if (wide) Icon(Icons.chevron_right_rounded, color: tone),
            ],
          ),
        ),
      ),
    );
  }
}

/// The statuses shown on the panel itself.
const List<IntentKind> _mainIntents = <IntentKind>[
  IntentKind.help,
  IntentKind.canHelp,
  IntentKind.talk,
  IntentKind.out,
];

/// "Więcej…": the other statuses in a sheet.
class _MoreIntents extends StatelessWidget {
  const _MoreIntents({required this.kinds, required this.onPick, super.key});

  final List<IntentKind> kinds;
  final void Function(IntentKind kind) onPick;

  Future<void> _show(BuildContext context) async {
    final IntentKind? picked = await showModalBottomSheet<IntentKind>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) {
        final ZenColors zen = ZenColors.of(context);
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  t('Więcej statusów'),
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 20,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                ZenGroup(
                  children: <Widget>[
                    for (final IntentKind k in kinds)
                      ListTile(
                        key: Key('intent-set-${k.name}'),
                        leading: Text(
                          k.emoji,
                          style: const TextStyle(fontSize: 22),
                        ),
                        title: Text(k.label),
                        trailing: Icon(
                          Icons.chevron_right_rounded,
                          color: intentTone(zen, k),
                        ),
                        onTap: () => Navigator.of(context).pop(k),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                ZenCard(
                  key: const Key('intent-set-custom'),
                  tone: intentTone(zen, IntentKind.custom),
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  onTap: () => Navigator.of(context).pop(IntentKind.custom),
                  child: Row(
                    children: <Widget>[
                      Text(
                        IntentKind.custom.emoji,
                        style: const TextStyle(fontSize: 22),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              IntentKind.custom.label,
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
                              t('Napisz po swojemu i wybierz emoji'),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: zen.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: intentTone(zen, IntentKind.custom),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (picked != null && context.mounted) {
      onPick(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final BorderRadius r = context.zenRadius(999);
    return Material(
      color: zen.surfaceRaised,
      borderRadius: r,
      child: InkWell(
        borderRadius: r,
        onTap: () => _show(context),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: r,
            border: Border.all(color: zen.outline),
          ),
          padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.more_horiz_rounded,
                size: 18,
                color: zen.textSecondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  t('Więcej'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Twój status": the status this person has set, set apart from friends'
/// ones — what, the note, who sees it, how long it still lasts, and
/// changing or switching it off.
class MyIntentCard extends StatelessWidget {
  const MyIntentCard({
    required this.status,
    required this.now,
    required this.onEdit,
    required this.onClear,
    super.key,
  });

  final IntentStatus status;
  final int now;
  final VoidCallback onEdit;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = intentTone(zen, status.kind);
    final double? share = intentTimeShare(status, now);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: BoxDecoration(
        borderRadius: context.zenRadius(24),
        gradient: LinearGradient(
          colors: <Color>[
            Color.alphaBlend(tone.withValues(alpha: 0.26), zen.surface),
            Color.alphaBlend(tone.withValues(alpha: 0.06), zen.surface),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: tone.withValues(alpha: 0.55), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                status.isCustom ? t('TWÓJ WŁASNY STATUS') : t('TWÓJ STATUS'),
                style: zen.label(color: tone),
              ),
              ZenPill(
                text: status.onlyClose
                    ? t('widzą przyjaciele')
                    : t('widzą znajomi'),
                tone: zen.textSecondary,
                icon: status.onlyClose
                    ? Icons.favorite_rounded
                    : Icons.group_rounded,
              ),
              if (status.isCustom)
                ZenPill(
                  text: t('Własny'),
                  tone: tone,
                  icon: Icons.auto_awesome_rounded,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                  border: Border.all(color: tone.withValues(alpha: 0.45)),
                ),
                child: Text(
                  status.shownEmoji,
                  style: const TextStyle(fontSize: 28),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  status.shownLabel,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 21,
                    weight: FontWeight.w600,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
          if (status.shownNote.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              status.shownNote,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 14.5,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Icon(Icons.schedule_rounded, size: 16, color: tone),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  share == null
                      ? t('Do odwołania')
                      : t('Zgaśnie sam: {left}', {
                          'left': intentTimeLeft(status, now),
                        }),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          if (share != null) ...<Widget>[
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: context.zenRadius(99),
              child: LinearProgressIndicator(
                key: const Key('intent-mine-time'),
                value: share,
                minHeight: 6,
                color: tone,
                backgroundColor: tone.withValues(alpha: 0.16),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  key: const Key('intent-edit'),
                  style: FilledButton.styleFrom(
                    backgroundColor: tone,
                    foregroundColor: ZenColors.foregroundFor(tone),
                  ),
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: Text(
                    t('Zmień'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('intent-clear'),
                  onPressed: onClear,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  label: Text(
                    t('Wyłącz'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// Builds a friend's avatar of [size].
typedef IntentAvatarBuilder =
    Widget Function(String address, String name, double size);

/// Friends who are up for something now, grouped by kind (in
/// [kFriendIntentOrder]); a friendly line when nobody is.
class FriendIntents extends StatelessWidget {
  const FriendIntents({
    required this.byKind,
    required this.now,
    required this.nameOf,
    required this.onOpen,
    this.avatar,
    this.ownSet = false,
    super.key,
  });

  final Map<IntentKind, List<(String, IntentStatus)>> byKind;
  final int now;
  final String Function(String address) nameOf;
  final void Function(String address) onOpen;

  /// The avatar of a friend (initials when `null`).
  final IntentAvatarBuilder? avatar;

  /// This person has a status of their own.
  final bool ownSet;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<IntentKind> kinds = <IntentKind>[
      for (final IntentKind k in kFriendIntentOrder)
        if (byKind[k]?.isNotEmpty ?? false) k,
    ];
    final int total = kinds.fold<int>(
      0,
      (int sum, IntentKind k) => sum + byKind[k]!.length,
    );
    if (total == 0) {
      return Container(
        key: const Key('intent-friends-empty'),
        margin: const EdgeInsets.only(top: 10, bottom: 5),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: zen.surfaceSunk,
          borderRadius: context.zenRadius(20),
          border: Border.all(color: zen.outlineSoft),
        ),
        child: Row(
          children: <Widget>[
            Icon(Icons.people_alt_outlined, color: zen.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t('Nikt ze znajomych nie ma teraz statusu'),
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    ownSet
                        ? t('Twój już widzą — może ktoś się odezwie.')
                        : t('Ustaw swój, a może ktoś dołączy.'),
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
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenSection(t('Znajomi teraz · {count}', {'count': total}), top: 14),
        for (final IntentKind k in kinds)
          _IntentGroup(
            key: Key('intent-friends-${k.name}'),
            kind: k,
            friends: byKind[k]!,
            now: now,
            nameOf: nameOf,
            onOpen: onOpen,
            avatar: avatar,
          ),
      ],
    );
  }
}

/// Friends with statuses of one kind, in a card of its colour.
class _IntentGroup extends StatelessWidget {
  const _IntentGroup({
    required this.kind,
    required this.friends,
    required this.now,
    required this.nameOf,
    required this.onOpen,
    this.avatar,
    super.key,
  });

  final IntentKind kind;
  final List<(String, IntentStatus)> friends;
  final int now;
  final String Function(String address) nameOf;
  final void Function(String address) onOpen;
  final IntentAvatarBuilder? avatar;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = intentTone(zen, kind);
    final bool urgent = kind == IntentKind.urgent;
    final BorderRadius r = context.zenRadius(22);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: Color.alphaBlend(
          tone.withValues(alpha: urgent ? 0.14 : 0.06),
          zen.surface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: r,
          side: BorderSide(
            color: tone.withValues(alpha: urgent ? 0.6 : 0.28),
            width: urgent ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      kind.emoji,
                      style: const TextStyle(fontSize: 16),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      kind == IntentKind.custom
                          ? t('Własne statusy')
                          : kind.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: urgent ? tone : zen.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ZenPill(text: '${friends.length}', tone: tone, filled: true),
                ],
              ),
            ),
            for (final (String address, IntentStatus s) in friends)
              _FriendIntentRow(
                key: Key('intent-friend-$address'),
                address: address,
                name: nameOf(address),
                status: s,
                tone: tone,
                now: now,
                avatar: avatar,
                onOpen: () => onOpen(address),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// A friend with their status: avatar with the status's emoji, name, the
/// short text, and how long it still lasts.
class _FriendIntentRow extends StatelessWidget {
  const _FriendIntentRow({
    required this.address,
    required this.name,
    required this.status,
    required this.tone,
    required this.now,
    required this.onOpen,
    this.avatar,
    super.key,
  });

  final String address;
  final String name;
  final IntentStatus status;
  final Color tone;
  final int now;
  final VoidCallback onOpen;
  final IntentAvatarBuilder? avatar;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String text = status.isCustom ? status.shownLabel : status.shownNote;
    final double? share = intentTimeShare(status, now);
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
        child: Row(
          children: <Widget>[
            Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                avatar?.call(address, name, 44) ??
                    ZenBlobAvatar(name: name, size: 44, showStatus: false),
                Positioned(
                  right: -5,
                  bottom: -5,
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Color.alphaBlend(
                        tone.withValues(alpha: 0.22),
                        zen.surface,
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(color: zen.surface, width: 2),
                    ),
                    child: Text(
                      status.shownEmoji,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
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
                  if (text.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 13.5,
                        height: 1.3,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Row(
                    children: <Widget>[
                      Icon(Icons.schedule_rounded, size: 13, color: tone),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          intentTimeLeft(status, now),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tone,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (share != null) ...<Widget>[
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 44,
                          child: ClipRRect(
                            borderRadius: context.zenRadius(99),
                            child: LinearProgressIndicator(
                              value: share,
                              minHeight: 4,
                              color: tone,
                              backgroundColor: tone.withValues(alpha: 0.16),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: t('Napisz'),
              color: tone,
              icon: const Icon(Icons.chat_bubble_outline_rounded),
              onPressed: onOpen,
            ),
          ],
        ),
      ),
    );
  }
}

/// Sets a status of [kind]: how long, a short note, who sees it. With
/// [initial] it changes the status already set (prefilled; with [kinds],
/// its kind can be changed too). [hideFrom] is used only for „Randkuję”:
/// those people are told there is no status.
Future<void> showIntentSheet(
  BuildContext context,
  MeetService service,
  IntentKind kind, {
  Set<String> hideFrom = const <String>{},
  IntentStatus? initial,
  List<IntentKind> kinds = const <IntentKind>[],
}) {
  final TextEditingController note = TextEditingController(
    text: initial?.note ?? '',
  );
  IntentKind current = kind;
  // Changing a status keeps its time unless another one is picked.
  IntentDuration? duration = initial != null
      ? null
      : kind == IntentKind.dnd || kind == IntentKind.custom
      // A custom status ("W pracy", "Choruję") usually lasts the day.
      ? IntentDuration.today
      : IntentDuration.hour;
  bool onlyClose = initial?.onlyClose ?? false;
  String emoji = initial != null && initial.emoji.isNotEmpty
      ? initial.emoji
      : kCustomStatusEmoji.first;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter setSheet) {
        final ZenColors zen = ZenColors.of(context);
        final Color tone = intentTone(zen, current);
        final bool custom = current == IntentKind.custom;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: tone.withValues(alpha: 0.16),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      custom ? emoji : current.emoji,
                      style: const TextStyle(fontSize: 24),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      initial == null ? current.label : t('Zmień status'),
                      style: zen.display(
                        color: zen.textPrimary,
                        size: 22,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              if (kinds.isNotEmpty) ...<Widget>[
                ZenSection(t('Rodzaj'), top: 16),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      for (final IntentKind k in kinds)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            key: Key('intent-kind-${k.name}'),
                            showCheckmark: false,
                            avatar: Text(k.emoji),
                            label: Text(k.label),
                            selected: current == k,
                            onSelected: (_) => setSheet(() {
                              // A custom status's words are its name, the
                              // others' a note: they do not carry over.
                              if ((k == IntentKind.custom) !=
                                  (current == IntentKind.custom)) {
                                note.clear();
                              }
                              current = k;
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (custom) ...<Widget>[
                const SizedBox(height: 18),
                TextField(
                  key: const Key('intent-custom-text'),
                  controller: note,
                  autofocus: initial == null,
                  maxLength: IntentStatus.maxCustomChars,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (_) => setSheet(() {}),
                  decoration: InputDecoration(
                    labelText: t('Twój status'),
                    hintText: t('np. Na siłowni do 18'),
                    helperText: t('Krótko — znajomi zobaczą to razem z emoji.'),
                    prefixIcon: const Icon(Icons.edit_rounded),
                  ),
                ),
                ZenSection(t('Emoji'), top: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final String e in kCustomStatusEmoji)
                      ChoiceChip(
                        key: Key('intent-emoji-$e'),
                        showCheckmark: false,
                        label: Text(e, style: const TextStyle(fontSize: 20)),
                        selected: emoji == e,
                        onSelected: (_) => setSheet(() => emoji = e),
                      ),
                  ],
                ),
              ],
              ZenSection(t('Na jak długo'), top: custom ? 20 : 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (initial != null)
                    ChoiceChip(
                      key: const Key('intent-duration-keep'),
                      label: Text(
                        t('Bez zmian ({left})', {
                          'left': intentTimeLeft(initial, service.now),
                        }),
                      ),
                      selected: duration == null,
                      onSelected: (_) => setSheet(() => duration = null),
                    ),
                  for (final IntentDuration d in IntentDuration.values)
                    ChoiceChip(
                      key: Key('intent-duration-${d.name}'),
                      label: Text(d.label),
                      selected: duration == d,
                      onSelected: (_) => setSheet(() => duration = d),
                    ),
                ],
              ),
              // A custom status's words are above; the others take a note.
              if (custom)
                const SizedBox(height: 12)
              else ...<Widget>[
                const SizedBox(height: 16),
                TextField(
                  key: const Key('intent-note'),
                  controller: note,
                  maxLength: 140,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: switch (current) {
                      IntentKind.urgent => t(
                        'Co się stało? (np. zepsuty samochód, potrzebuję '
                        'transportu)',
                      ),
                      IntentKind.help => t(
                        'W czym? (np. przeprowadzka w sobotę)',
                      ),
                      IntentKind.canHelp => t(
                        'W czym? (np. mam auto, znam się na komputerach)',
                      ),
                      IntentKind.out => t('Gdzie, kiedy? (nie trzeba)'),
                      IntentKind.walk => t('Gdzie? (np. park, nad rzekę)'),
                      IntentKind.eat => t('Co, gdzie? (np. pizza o 19)'),
                      IntentKind.play => t('W co? (np. planszówki, piłka)'),
                      _ => t('Dopisek (nie trzeba)'),
                    },
                    prefixIcon: const Icon(Icons.edit_note_rounded),
                  ),
                ),
              ],
              if (current == IntentKind.urgent) ...<Widget>[
                ZenInfo(
                  icon: Icons.priority_high_rounded,
                  tone: tone,
                  text: t(
                    'Znajomi dostaną głośniejsze powiadomienie. Gdy grozi Ci '
                    'niebezpieczeństwo, użyj Alarmu — wysyła też położenie.',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (current == IntentKind.dating) ...<Widget>[
                ZenInfo(
                  icon: Icons.visibility_off_rounded,
                  tone: tone,
                  text: t(
                    'Osoby, przed którymi ukrywasz profil randkowy, '
                    'nie zobaczą tego statusu.',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              ZenGroup(
                children: <Widget>[
                  SwitchListTile(
                    value: onlyClose,
                    title: Text(t('Tylko przyjaciele')),
                    subtitle: Text(t('Inaczej widzą wszyscy znajomi.')),
                    onChanged: (bool v) => setSheet(() => onlyClose = v),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('intent-save'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                // A custom status is its words: none, nothing to set.
                onPressed: custom && note.text.trim().isEmpty
                    ? null
                    : () {
                        final int now = service.now;
                        final String text = note.text.trim();
                        final IntentDuration? d = duration;
                        // "Bez zmian" keeps the old end (or none).
                        final int until = d != null
                            ? d.untilFrom(now)
                            : initial?.until ?? 0;
                        unawaited(
                          service.setMyIntent(
                            IntentStatus(
                              kind: current,
                              setAt: now,
                              until: until,
                              note: custom
                                  ? IntentStatus.cutCustom(text)
                                  : text,
                              onlyClose: onlyClose,
                              emoji: custom ? emoji : '',
                            ),
                            except: current == IntentKind.dating
                                ? hideFrom
                                : const <String>{},
                          ),
                        );
                        Navigator.of(context).pop();
                      },
                icon: const Icon(Icons.check_rounded),
                label: Text(initial == null ? t('Ustaw') : t('Zapisz')),
              ),
            ],
          ),
        );
      },
    ),
  ).whenComplete(() => disposeLater(note));
}
