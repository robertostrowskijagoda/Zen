import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/follows.dart';
import 'package:zen/src/features/profile/presentation/mini_profile.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Who follows you: friends automatically, and everyone else who
/// chose to. A follower can be blocked: they leave the list and their
/// likes and comments disappear from your posts (they can still read what
/// is public).
Future<void> showFollowersSheet(BuildContext context, LedgerNode node) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => FollowersSheet(node: node),
    );

class FollowersSheet extends ConsumerStatefulWidget {
  const FollowersSheet({required this.node, super.key});

  final LedgerNode node;

  @override
  ConsumerState<FollowersSheet> createState() => _FollowersSheetState();
}

class _FollowersSheetState extends ConsumerState<FollowersSheet> {
  late final FollowLedger _follows = FollowLedger.of(widget.node);
  StreamSubscription<void>? _changes;

  @override
  void initState() {
    super.initState();
    _changes = _follows.changes.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    unawaited(
      _follows.ready.then((_) {
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    super.dispose();
  }

  Future<void> _block(Follower f) async {
    final String name = f.name.isEmpty ? t('Ta osoba') : f.name;
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        scrollable: true,
        title: Text(t('Zablokować: {name}?', {'name': name})),
        content: Text(
          t(
            'Zniknie z listy obserwujących, a jej polubienia i komentarze '
            'znikną spod Twoich postów. Posty publiczne nadal może czytać.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('followers-block-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Zablokuj')),
          ),
        ],
      ),
    );
    if (sure ?? false) {
      await _follows.block(f.account, name: f.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<Follower> followers = _follows.followers;
    final SocialHubState social = ref.watch(socialHubControllerProvider);
    final List<FriendProfile> friendList = social.acceptedFriends;
    final int friends = friendList.length;
    final Map<String, String> blocked = _follows.blocked;
    return SafeArea(
      child: ListView(
        key: const Key('followers-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: <Widget>[
          Text(
            t('Obserwujący ({count})', {'count': friends + followers.length}),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          ZenInfo(
            icon: Icons.people_alt_outlined,
            text: friends == 0
                ? t(
                    'Obserwować może każdy, bez Twojej zgody — widzi tylko '
                    'Twoje posty publiczne.',
                  )
                : tn(
                    friends,
                    one:
                        'Twój {n} znajomy obserwuje Cię automatycznie. '
                        'Poza znajomymi obserwować może każdy — widzi tylko '
                        'posty publiczne.',
                    few:
                        'Twoi {n} znajomi obserwują Cię automatycznie. '
                        'Poza znajomymi obserwować może każdy — widzi tylko '
                        'posty publiczne.',
                    many:
                        'Twoich {n} znajomych obserwuje Cię automatycznie. '
                        'Poza znajomymi obserwować może każdy — widzi tylko '
                        'posty publiczne.',
                  ),
          ),
          const SizedBox(height: 8),
          // Friends follow automatically: they are part of the count, so
          // they are on the list too.
          for (final FriendProfile friend in friendList)
            ListTile(
              key: Key('follower-friend-${friend.address}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: PeerAvatar(
                address: friend.address,
                name: social.nameFor(friend),
                size: 38,
                showStatus: false,
              ),
              title: Text(
                social.nameFor(friend),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                t('Znajomy'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: zen.textMuted, fontSize: 12),
              ),
              onTap: () => unawaited(showMiniProfile(context, friend.address)),
            ),
          if (followers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                t('Poza znajomymi nikt Cię jeszcze nie obserwuje.'),
                key: const Key('followers-empty'),
                style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
              ),
            ),
          for (final Follower f in followers)
            ListTile(
              key: Key('follower-${f.account}'),
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: ZenBlobAvatar(
                name: f.name.isEmpty ? '?' : f.name,
                size: 38,
                showStatus: false,
              ),
              title: Text(
                f.name.isEmpty ? t('Bez nazwy') : f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                f.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: zen.textMuted, fontSize: 12),
              ),
              onTap: () => unawaited(showMiniProfile(context, f.address)),
              trailing: IconButton(
                key: Key('follower-block-${f.account}'),
                tooltip: t('Zablokuj'),
                icon: Icon(Icons.block_rounded, color: zen.danger),
                onPressed: () => unawaited(_block(f)),
              ),
            ),
          if (blocked.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              t('Zablokowani'),
              style: TextStyle(
                color: zen.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            for (final MapEntry<String, String> b in blocked.entries)
              ListTile(
                key: Key('follower-blocked-${b.key}'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(Icons.block_rounded, color: zen.textMuted),
                title: Text(
                  b.value.isEmpty ? t('Bez nazwy') : b.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  key: Key('follower-unblock-${b.key}'),
                  onPressed: () => unawaited(_follows.unblock(b.key)),
                  child: Text(t('Odblokuj')),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
