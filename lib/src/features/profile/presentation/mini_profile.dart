import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/feed/rich_text.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/profile/follows.dart';
import 'package:zen/src/features/profile/presentation/ledger_picture.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The mini-profile: a compact card made from someone's profile —
/// photo, name, status, badges and numbers — with what can be done right
/// away: open the whole profile, write ("Wiadomość") or invite ("Dodaj"),
/// follow. Opened from the graph, people nearby, lists of likes and
/// followers, and a conversation's header.
Future<void> showMiniProfile(BuildContext context, String address) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => MiniProfileSheet(address: address),
    );

/// Opens the conversation with friend [address].
Future<void> openConversationWith(
  BuildContext context,
  String address,
  String title,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (BuildContext context) =>
        ConversationScreen(peerAddress: address, title: title),
  ),
);

/// "Dodaj": invites [address] to be friends. Returns true when sent.
Future<bool> inviteAsFriend(
  BuildContext context,
  WidgetRef ref,
  String address, {
  String knownName = '',
}) async {
  final UserProfile me = ref.read(userProfileControllerProvider);
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await ref
        .read(socialHubControllerProvider.notifier)
        .sendFriendRequest(
          peerAddress: address,
          knownName: knownName,
          senderDisplayName: me.displayName,
        );
    messenger?.showSnackBar(SnackBar(content: Text(t('Zaproszenie wysłane.'))));
    return true;
  } on Object catch (error, stackTrace) {
    logZenError('Sending a friend request failed', error, stackTrace);
    messenger?.showSnackBar(
      SnackBar(content: Text(t('Nie udało się: {error}', {'error': error}))),
    );
    return false;
  }
}

/// "{n} znajomych".
String friendCountLabel(int n) =>
    tn(n, one: '{n} znajomy', few: '{n} znajomych', many: '{n} znajomych');

/// "{n} obserwujących".
String followerCountLabel(int n) => tn(
  n,
  one: '{n} obserwujący',
  few: '{n} obserwujących',
  many: '{n} obserwujących',
);

class MiniProfileSheet extends ConsumerStatefulWidget {
  const MiniProfileSheet({required this.address, super.key});

  final String address;

  @override
  ConsumerState<MiniProfileSheet> createState() => _MiniProfileSheetState();
}

class _MiniProfileSheetState extends ConsumerState<MiniProfileSheet> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final SocialHubState state = watchSocialPeople(ref);
    final String address = widget.address;
    final FriendProfile? friend = state.friendByAddress(address);
    final PeerPublicProfile? peer = state.peerProfileOf(address);
    final LedgerNode? node = ref.watch(ledgerNodeProvider);
    final String? account = node != null && node.isReady
        ? node.knownAccountOf(address)
        : null;
    final ProfileView? view = node != null && account != null
        ? readProfile(node, account)
        : null;
    final bool isFriend = friend?.status == FriendRelationshipStatus.accepted;
    final String ownName = peer?.name.trim().isNotEmpty == true
        ? peer!.name.trim()
        : (view?.name ?? '');
    final String shownName = friend != null && isFriend
        ? state.nameFor(friend)
        : (ownName.isNotEmpty ? ownName : t('Kontakt'));
    final String status = (view?.status.isNotEmpty ?? false)
        ? view!.status
        : (peer?.status ?? '');
    final String bio = (view?.bio.isNotEmpty ?? false)
        ? view!.bio
        : (peer?.bio ?? '');
    final bool following = node != null && node.isFollowing(address);
    final bool followsMe =
        node != null &&
        account != null &&
        FollowLedger.of(
          node,
        ).followers.any((Follower f) => f.account == account);

    final Widget avatar;
    if (peer?.avatarPath != null) {
      avatar = PeerAvatar(address: address, name: shownName, size: 76);
    } else if (view?.avatar != null && node != null) {
      avatar = LedgerAvatar(
        node: node,
        media: view!.avatar!,
        name: shownName,
        size: 76,
      );
    } else {
      avatar = ZenBlobAvatar(name: shownName, size: 76, showStatus: false);
    }

    final List<Widget> badges = <Widget>[
      if (isFriend && node != null)
        ZenPill(
          key: const Key('mini-profile-level'),
          icon: Icons.people_alt_rounded,
          text: kFriendLevelLabels[node.levelOf(address)]!,
          tone: zen.accent,
        ),
      if (friend?.status == FriendRelationshipStatus.pendingOutgoing)
        ZenPill(
          icon: Icons.hourglass_top_rounded,
          text: t('Zaproszono'),
          tone: zen.textSecondary,
        ),
      if (following)
        ZenPill(
          icon: Icons.visibility_rounded,
          text: t('Obserwujesz'),
          tone: zenTone(zen, 3),
        ),
      if (followsMe)
        ZenPill(
          key: const Key('mini-profile-follows-me'),
          icon: Icons.how_to_reg_rounded,
          text: t('Obserwuje Cię'),
          tone: zenTone(zen, 2),
        ),
      for (final String code in view?.nationalities ?? const <String>[])
        ZenPill(text: nationalityLabel(code)),
    ];
    final List<String> numbers = <String>[
      if (view?.friendCount != null) friendCountLabel(view!.friendCount!),
      if (view?.followerCount != null) followerCountLabel(view!.followerCount!),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('peer-profile-sheet'),
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            avatar,
            const SizedBox(height: 12),
            Text(
              shownName,
              key: const Key('mini-profile-name'),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: zen.display(
                color: zen.textPrimary,
                size: 21,
                weight: FontWeight.w800,
              ),
            ),
            if (ownName.isNotEmpty && ownName != shownName) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                t('Przedstawia się jako: {name}', {'name': ownName}),
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textSecondary, fontSize: 13),
              ),
            ],
            if (status.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                status,
                key: const Key('mini-profile-status'),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (badges.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: badges,
              ),
            ],
            if (numbers.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                numbers.join(' · '),
                key: const Key('mini-profile-numbers'),
                style: TextStyle(color: zen.textSecondary, fontSize: 13),
              ),
            ],
            if (bio.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                plainText(bio),
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
              ),
            ],
            if (peer == null && view == null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                t('Ta osoba nie udostępniła jeszcze swojego profilu.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textMuted, fontSize: 13),
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  key: const Key('mini-profile-open'),
                  onPressed: () {
                    final NavigatorState nav = Navigator.of(context)..pop();
                    unawaited(
                      nav.push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) =>
                              ProfileScreen(address: address),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.person_rounded, size: 18),
                  label: Text(t('Profil')),
                ),
                // Someone who is not a friend can be written to as well:
                // text only, within limits, with this
                // person's mini-profile.
                if (!isFriend &&
                    friend?.status != FriendRelationshipStatus.blocked &&
                    isRoutablePeerAddress(address))
                  OutlinedButton.icon(
                    key: const Key('mini-profile-message-stranger'),
                    onPressed: () {
                      final NavigatorState nav = Navigator.of(context)..pop();
                      unawaited(
                        nav.push(
                          MaterialPageRoute<void>(
                            builder: (BuildContext context) =>
                                ConversationScreen(
                                  peerAddress: address,
                                  title: shownName,
                                ),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 18,
                    ),
                    label: Text(t('Napisz')),
                  ),
                if (isFriend)
                  FilledButton.icon(
                    key: const Key('mini-profile-message'),
                    onPressed: () {
                      final NavigatorState nav = Navigator.of(context)..pop();
                      unawaited(
                        nav.push(
                          MaterialPageRoute<void>(
                            builder: (BuildContext context) =>
                                ConversationScreen(
                                  peerAddress: address,
                                  title: shownName,
                                ),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.chat_bubble_rounded, size: 18),
                    label: Text(t('Wiadomość')),
                  )
                else if (friend?.status != FriendRelationshipStatus.blocked &&
                    friend?.status != FriendRelationshipStatus.pendingOutgoing)
                  FilledButton.icon(
                    key: const Key('mini-profile-add'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(
                            _run(() async {
                              await inviteAsFriend(
                                context,
                                ref,
                                address,
                                knownName: ownName,
                              );
                            }),
                          ),
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                    label: Text(t('Dodaj')),
                  ),
                if (!isFriend && node != null)
                  OutlinedButton.icon(
                    key: const Key('mini-profile-follow'),
                    onPressed: _busy
                        ? null
                        : () => unawaited(
                            _run(() async {
                              final FollowLedger follows = FollowLedger.of(
                                node,
                              );
                              if (following) {
                                await follows.unfollow(address);
                              } else {
                                await follows.follow(address);
                              }
                            }),
                          ),
                    icon: Icon(
                      following
                          ? Icons.check_rounded
                          : Icons.visibility_outlined,
                      size: 18,
                    ),
                    label: Text(following ? t('Obserwujesz') : t('Obserwuj')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
