import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/chat/stranger_chats.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/profile/presentation/mini_profile.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Whether the conversation with [address] is one with someone who is not
/// a friend ([friend] is what the app knows about them): text only, within
/// the limits of `stranger_chats.dart`.
bool isStrangerConversation(FriendProfile? friend, String address) =>
    friend?.status != FriendRelationshipStatus.accepted &&
    friend?.status != FriendRelationshipStatus.blocked &&
    isRoutablePeerAddress(address);

/// The strip above a conversation with someone who is not a friend:
/// who it is (their mini-profile), the limits, and what can be done
/// with a message request: answer by writing, invite, ignore or block.
class StrangerChatBanner extends ConsumerStatefulWidget {
  const StrangerChatBanner({
    required this.address,
    required this.friend,
    super.key,
  });

  final String address;
  final FriendProfile? friend;

  @override
  ConsumerState<StrangerChatBanner> createState() => _StrangerChatBannerState();
}

class _StrangerChatBannerState extends ConsumerState<StrangerChatBanner> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(strangerChatsProvider).markRead(widget.address));
  }

  Future<void> _ignore() async {
    final NavigatorState nav = Navigator.of(context);
    await ref.read(strangerChatsProvider).forget(widget.address);
    await ref
        .read(socialHubControllerProvider.notifier)
        .clearConversationHistory(peerAddress: widget.address);
    if (mounted) {
      unawaited(nav.maybePop());
    }
  }

  Future<void> _block() async {
    final NavigatorState nav = Navigator.of(context);
    await ref
        .read(socialHubControllerProvider.notifier)
        .blockFriend(peerAddress: widget.address);
    await ref.read(strangerChatsProvider).forget(widget.address);
    if (mounted) {
      unawaited(nav.maybePop());
    }
  }

  @override
  Widget build(BuildContext context) {
    final StrangerChatBook book = ref.watch(strangerChatsProvider);
    return ListenableBuilder(
      listenable: book,
      builder: (BuildContext context, Widget? _) => _strip(context, book),
    );
  }

  Widget _strip(BuildContext context, StrangerChatBook book) {
    final ZenColors zen = ZenColors.of(context);
    final StrangerChat? chat = book.chatWith(widget.address);
    final String name = chat?.shownName ?? t('Ta osoba');
    final int mutual = ref
        .read(meetServiceProvider)
        .mutualFriends(widget.address)
        .length;
    final String? mutualText = mutualFriendsText(mutual);
    final String text = chat?.isRequest == true
        ? t(
            '{name} pisze do Ciebie spoza znajomych. Odpisz, żeby rozmawiać '
            'dalej, albo zignoruj — nie dowie się o tym.',
            <String, Object?>{'name': name},
          )
        : chat?.open == true
        ? t('Nie jesteście znajomymi: rozmawiacie tylko tekstem.')
        : t(
            'Nie jesteście znajomymi. Zanim odpisze, wyślesz najwyżej {n} '
            'wiadomości (tylko tekst); dołączysz do nich swój mini-profil.',
            <String, Object?>{'n': kStrangerMessagesBeforeReply},
          );
    final bool canInvite =
        widget.friend == null ||
        widget.friend!.status == FriendRelationshipStatus.none;
    return Container(
      key: const Key('stranger-chat-banner'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: zen.surfaceRaised,
        border: Border(bottom: BorderSide(color: zen.outlineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              PeerAvatar(address: widget.address, name: name, size: 36),
              const SizedBox(width: 10),
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
                      ),
                    ),
                    Text(
                      mutualText ?? t('Brak wspólnych znajomych'),
                      style: TextStyle(color: zen.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            text,
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 12.5,
              height: 1.35,
            ),
          ),
          Wrap(
            spacing: 4,
            children: <Widget>[
              if (canInvite)
                TextButton.icon(
                  key: const Key('stranger-chat-invite'),
                  onPressed: () => unawaited(
                    inviteAsFriend(
                      context,
                      ref,
                      widget.address,
                      knownName: chat?.name ?? '',
                    ),
                  ),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: Text(t('Zaproś do znajomych')),
                ),
              if (chat?.isRequest == true)
                TextButton(
                  key: const Key('stranger-chat-ignore'),
                  onPressed: () => unawaited(_ignore()),
                  child: Text(t('Zignoruj')),
                ),
              TextButton(
                key: const Key('stranger-chat-block'),
                onPressed: () => unawaited(_block()),
                child: Text(t('Zablokuj'), style: TextStyle(color: zen.danger)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The chat list's part for people who are not friends:
/// message requests first, then conversations this person started or
/// answered. Nothing when there are none.
class StrangerChatsSection extends ConsumerWidget {
  const StrangerChatsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final StrangerChatBook book = ref.watch(strangerChatsProvider);
    // Who became a friend (or was blocked) meanwhile is no longer here.
    final SocialHubState hub = ref.watch(socialHubControllerProvider);
    return ListenableBuilder(
      listenable: book,
      builder: (BuildContext context, Widget? _) {
        bool stillStranger(StrangerChat c) => isStrangerConversation(
          hub.friendByAddress(c.address),
          PeerShareCodec.normalizeAddress(c.address),
        );
        final List<StrangerChat> requests = book.requests
            .where(stillStranger)
            .toList();
        final List<StrangerChat> others = book.conversations
            .where(stillStranger)
            .toList();
        if (requests.isEmpty && others.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          key: const Key('stranger-chats-section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (requests.isNotEmpty) ...<Widget>[
              ZenSection(t('Prośby o rozmowę')),
              for (final StrangerChat c in requests) _row(context, c),
            ],
            if (others.isNotEmpty) ...<Widget>[
              ZenSection(t('Spoza znajomych')),
              for (final StrangerChat c in others) _row(context, c),
            ],
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, StrangerChat c) {
    final ZenColors zen = ZenColors.of(context);
    return ListTile(
      key: Key('stranger-chat-${c.address}'),
      leading: PeerAvatar(address: c.address, name: c.shownName, size: 40),
      title: Text(
        c.shownName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: zen.textPrimary,
          fontWeight: c.unread > 0 ? FontWeight.w700 : FontWeight.w600,
        ),
      ),
      subtitle: Text(
        c.preview,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: zen.textSecondary),
      ),
      trailing: c.unread > 0
          ? ZenPill(text: '${c.unread}', filled: true)
          : null,
      onTap: () => unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                ConversationScreen(peerAddress: c.address, title: c.shownName),
          ),
        ),
      ),
    );
  }
}

/// "Kto może napisać do mnie spoza znajomych" and what a first message
/// costs: a first message from anyone else does not come in at all, and
/// one that is not paid (when there is a price) neither. Someone a friend
/// opened a gate for comes in whatever these say.
class StrangerMessagesFromTile extends ConsumerWidget {
  const StrangerMessagesFromTile({super.key});

  static Future<void> _editPrice(
    BuildContext context,
    StrangerChatBook book,
  ) async {
    final TextEditingController field = TextEditingController(
      text: book.price == 0 ? '' : formatMoney(book.price),
    );
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Cena wiadomości od osób spoza znajomych')),
        content: TextField(
          key: const Key('stranger-price-field'),
          controller: field,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: t('Punkty (puste albo 0 = za darmo)'),
            prefixIcon: const Icon(Icons.toll_outlined),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('stranger-price-save'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Zapisz')),
          ),
        ],
      ),
    );
    final int value = parseMoney(field.text) ?? 0;
    disposeLater(field);
    if (ok == true) {
      await book.setPrice(value);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final StrangerChatBook book = ref.watch(strangerChatsProvider);
    // Prices are paid in the pyramid's points: only between members.
    final bool member =
        ref.watch(featureFlagsProvider).isEnabled(ZenFeature.pyramid) &&
        ref.exists(pyramidServiceProvider) &&
        ref.read(pyramidServiceProvider).isMember;
    return ListenableBuilder(
      listenable: book,
      builder: (BuildContext context, Widget? _) => Padding(
        key: const Key('stranger-messages-from'),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              t('Kto może napisać do mnie spoza znajomych'),
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              t(
                'Pierwsza wiadomość od kogoś spoza wybranych nie dociera. Ci, '
                'którzy mogą, wyślą najwyżej {n} wiadomości (tylko tekst, ze '
                'swoim mini-profilem), zanim odpiszesz.',
                <String, Object?>{'n': kStrangerMessagesBeforeReply},
              ),
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final StrangerMessagesFrom f
                    in StrangerMessagesFrom.values)
                  ChoiceChip(
                    key: Key('stranger-messages-from-${f.name}'),
                    showCheckmark: false,
                    label: Text(f.label),
                    selected: book.from == f,
                    onSelected: (_) => unawaited(book.setFrom(f)),
                  ),
              ],
            ),
            if (book.from != StrangerMessagesFrom.nobody) ...<Widget>[
              const SizedBox(height: 12),
              ListTile(
                key: const Key('stranger-price'),
                contentPadding: EdgeInsets.zero,
                title: Text(t('Cena wiadomości od osób spoza znajomych')),
                subtitle: Text(
                  book.price == 0 ? t('za darmo') : formatPoints(book.price),
                ),
                trailing: TextButton(
                  key: const Key('stranger-price-edit'),
                  onPressed: () => unawaited(_editPrice(context, book)),
                  child: Text(t('Zmień')),
                ),
              ),
              Text(
                t(
                  'Płaci się raz, za pierwszy kontakt — potem jak zawsze do {n} '
                  'wiadomości przed Twoją odpowiedzią, a odpowiedź otwiera '
                  'rozmowę. Kogoś, komu znajomy otworzył do Ciebie bramę '
                  '(przedstawienie), cena nie dotyczy.',
                  <String, Object?>{'n': kStrangerMessagesBeforeReply},
                ),
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              if (book.price > 0 && !member) ...<Widget>[
                const SizedBox(height: 8),
                ZenInfo(
                  key: const Key('stranger-price-member'),
                  icon: Icons.info_outline_rounded,
                  text: t(
                    'Cena działa tylko między członkami piramidy (punkty z '
                    'portfela). Poza piramidą nikt jej nie zapłaci, więc '
                    'pierwsze wiadomości dotrą tylko przez bramy znajomych.',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
