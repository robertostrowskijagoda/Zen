part of 'app_shell_screen.dart';

/// Carries the enclosing panel's accent hue down the tree, so nested
/// decorations (section headings, hairlines) match the panel they sit in
/// instead of always falling back to the primary accent.
class _PanelTone extends InheritedWidget {
  const _PanelTone({required this.tone, required super.child});

  final Color tone;

  static Color of(BuildContext context, Color fallback) {
    return context.dependOnInheritedWidgetOfExactType<_PanelTone>()?.tone ??
        fallback;
  }

  @override
  bool updateShouldNotify(_PanelTone oldWidget) => oldWidget.tone != tone;
}

class _Panel extends StatelessWidget {
  const _Panel({
    super.key,
    required this.child,
    this.onTap,
    // ignore: unused_element_parameter
    this.glow = false,
    // ignore: unused_element_parameter
    this.borderColor,
    this.accentTone,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// Lifts the panel a little (raised fill and a soft accent glow) —
  /// reserved for the single most important surface on a page.
  final bool glow;

  /// Overrides the default soft outline (e.g. an accent tint for cards
  /// that need attention).
  final Color? borderColor;

  /// Hue this panel is tinted with - a faint wash in the corner and the
  /// outline derive from it. Defaults to a neutral card.
  final Color? accentTone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = accentTone ?? zen.accent;
    final BorderRadius radius = context.zenRadius(22);
    final Color base = glow ? zen.surfaceRaised : zen.surface;
    final Widget content = _PanelTone(
      tone: tone,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          colors: <Color>[
            Color.alphaBlend(
              tone.withValues(alpha: accentTone == null ? 0.03 : 0.08),
              base,
            ),
            base,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: const <double>[0, 0.7],
        ),
        border: Border.all(
          color:
              borderColor ??
              (accentTone == null
                  ? zen.outlineSoft
                  : tone.withValues(alpha: 0.26)),
        ),
        boxShadow: glow
            ? ZenLook.of(context).tinted(
                zen,
                tone,
                radius: 24,
                alpha: 0.14,
                offset: const Offset(0, 8),
              )
            : null,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: onTap == null
              ? content
              : InkWell(
                  onTap: onTap,
                  splashColor: tone.withValues(alpha: 0.08),
                  highlightColor: tone.withValues(alpha: 0.04),
                  child: content,
                ),
        ),
      ),
    );
  }
}

/// The head of a panel: a tinted icon badge, a title and a line or two of
/// explanation, with an optional status pill under the title.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.icon,
    required this.title,
    this.caption,
    this.tone,
    this.pill,
    // ignore: unused_element_parameter
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String? caption;
  final Color? tone;
  final Widget? pill;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color t = tone ?? _PanelTone.of(context, zen.accent);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ZenIconBadge(icon: icon, tone: t, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
              if (pill != null) ...<Widget>[const SizedBox(height: 6), pill!],
              if (caption != null && caption!.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  caption!,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...<Widget>[const SizedBox(width: 4), trailing!],
      ],
    );
  }
}

class _SectionIntro extends StatelessWidget {
  const _SectionIntro({required this.title, this.caption = ''});

  final String title;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = _PanelTone.of(context, zen.textMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ZenLabel(title, color: tone),
        if (caption.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            caption,
            style: TextStyle(
              color: zen.textSecondary,
              height: 1.4,
              fontSize: 13.5,
            ),
          ),
        ],
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return ZenPill(text: label, tone: tone);
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    this.toneIndex = 0,
  });

  final String label;
  final String value;

  /// Which tone of the palette this tile wears, so a row of metrics reads
  /// as a set of distinct values.
  final int toneIndex;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, toneIndex);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.08), zen.surface),
        borderRadius: context.zenRadius(18),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                value,
                maxLines: 1,
                style: zen.display(
                  color: tone,
                  size: 22,
                  weight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuntimeErrorNotice extends StatelessWidget {
  const _RuntimeErrorNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    // The details can be selected and copied (for a bug report).
    return SelectionArea(
      child: ZenInfo(
        text: message,
        title: t('Coś poszło nie tak'),
        icon: Icons.error_outline_rounded,
        tone: zen.danger,
      ),
    );
  }
}

/// A tile like [ZenTile] whose title and subtitle wrap instead of being
/// cut (settings pages: some languages are much longer than Polish).
class _WrapTile extends StatelessWidget {
  const _WrapTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tone,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      onTap: onTap,
      padding: const EdgeInsetsDirectional.fromSTEB(14, 14, 12, 14),
      child: Row(
        children: <Widget>[
          ZenIconBadge(icon: icon, tone: tone),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontSize: 13.5,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right_rounded, color: zen.textMuted),
        ],
      ),
    );
  }
}

class _ServiceActions extends ConsumerWidget {
  const _ServiceActions({required this.state});

  final AppShellState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppShellController controller = ref.read(
      appShellControllerProvider.notifier,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _ServiceButton(
          key: const Key('service-reset-button'),
          icon: Icons.restart_alt_rounded,
          title: t('Resetuj sieć'),
          onPressed: controller.resetService,
        ),
        const SizedBox(height: 8),
        _ServiceButton(
          key: const Key('service-toggle-button'),
          icon: state.serviceRunning
              ? Icons.stop_circle_outlined
              : Icons.play_circle_outline_rounded,
          title: state.toggleLabel,
          onPressed: controller.toggleService,
          isDestructive: state.serviceRunning,
        ),
      ],
    );
  }
}

class _ServiceButton extends StatelessWidget {
  const _ServiceButton({
    super.key,
    required this.icon,
    required this.title,
    required this.onPressed,
    this.isDestructive = false,
  });

  final IconData icon;
  final String title;
  final VoidCallback onPressed;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = isDestructive ? zen.danger : zen.accent;
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: tone,
        backgroundColor: tone.withValues(alpha: 0.06),
        side: BorderSide(color: tone.withValues(alpha: 0.4)),
        minimumSize: const Size.fromHeight(48),
      ),
      icon: Icon(icon, size: 20),
      label: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// The unread count of a chat (the look's count badge).
class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) => ZenCountBadge(count);
}

/// A row of a chat list: avatar, name and time on top, last message and the
/// unread count below.
class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.avatar,
    required this.name,
    required this.preview,
    required this.highlight,
    this.nameBadge,
    this.meta,
    this.unreadBadge,
    this.nickname = '',
  });

  final Widget avatar;
  final String name;

  /// What the user calls them, a small line under [name] ('' for none).
  final String nickname;
  final Widget preview;
  final bool highlight;
  final Widget? nameBadge;
  final String? meta;
  final Widget? unreadBadge;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Row(
      children: <Widget>[
        avatar,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 15.5,
                              fontWeight: highlight
                                  ? FontWeight.w800
                                  : FontWeight.w700,
                              height: 1.2,
                            ),
                          ),
                        ),
                        if (nameBadge != null) ...<Widget>[
                          const SizedBox(width: 6),
                          nameBadge!,
                        ],
                      ],
                    ),
                  ),
                  if (meta != null) ...<Widget>[
                    const SizedBox(width: 8),
                    Text(
                      meta!,
                      maxLines: 1,
                      style: TextStyle(
                        color: highlight ? zen.accent : zen.textMuted,
                        fontSize: 12,
                        fontWeight: highlight
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ],
                ],
              ),
              if (nickname.isNotEmpty)
                Text(
                  nickname,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textMuted,
                    fontSize: 12,
                    fontStyle: FontStyle.italic,
                    height: 1.3,
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                children: <Widget>[
                  Expanded(child: preview),
                  if (unreadBadge != null) ...<Widget>[
                    const SizedBox(width: 8),
                    unreadBadge!,
                  ],
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ConversationCard extends ConsumerStatefulWidget {
  const _ConversationCard({required this.conversation});

  final ConversationPreview conversation;

  @override
  ConsumerState<_ConversationCard> createState() => _ConversationCardState();
}

class _ConversationCardState extends ConsumerState<_ConversationCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ConversationPreview conversation = widget.conversation;
    final bool hasUnread =
        conversation.status == FriendRelationshipStatus.accepted &&
        conversation.unreadCount > 0;
    final bool pending =
        conversation.status == FriendRelationshipStatus.pendingOutgoing;
    final BorderRadius radius = context.zenRadius(20);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: Key('conversation-card-${conversation.address}'),
          borderRadius: radius,
          onTap: () {
            _openConversationScreen(
              context,
              peerAddress: conversation.address,
              title: conversation.name,
            );
          },
          onHover: (bool hovering) => setState(() => _isHovered = hovering),
          onLongPress: () {
            _showConversationActionSheet(context, ref, conversation);
          },
          onSecondaryTap: () {
            _showConversationActionSheet(context, ref, conversation);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: radius,
              color: _isHovered
                  ? zen.surface
                  : (hasUnread
                        ? zen.accent.withValues(alpha: 0.06)
                        : Colors.transparent),
              border: Border.all(
                color: _isHovered ? zen.outlineSoft : Colors.transparent,
              ),
            ),
            child: _ChatRow(
              highlight: hasUnread,
              avatar: Semantics(
                label: pending ? null : _presenceSemantics(conversation),
                child: ZenBlobAvatar(
                  name: conversation.name,
                  size: 50,
                  online: conversation.isOnline && !pending,
                  away:
                      conversation.presence == PeerPresence.background &&
                      !pending,
                  // A friend who does not show presence gets no dot.
                  showStatus:
                      pending || conversation.presence != PeerPresence.hidden,
                  image: peerAvatarImage(conversation.avatarPath),
                ),
              ),
              name: conversation.name,
              nickname: conversation.nickname,
              nameBadge: pending
                  ? _StatusPill(label: t('Oczekuje'), tone: zen.warning)
                  : null,
              meta: conversation.timeLabel,
              preview: conversation.isTyping
                  ? Row(
                      children: <Widget>[
                        Text(
                          t('Pisze...'),
                          style: TextStyle(
                            color: zen.accent,
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        ZenAnimatedDots(color: zen.accent, size: 3),
                      ],
                    )
                  : Text(
                      conversation.lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: hasUnread ? zen.textPrimary : zen.textSecondary,
                        fontSize: 13.5,
                        fontWeight: hasUnread
                            ? FontWeight.w600
                            : FontWeight.w400,
                        fontStyle: pending
                            ? FontStyle.italic
                            : FontStyle.normal,
                      ),
                    ),
              unreadBadge: hasUnread
                  ? _UnreadBadge(
                      conversation.unreadCount,
                      key: Key('conversation-unread-${conversation.address}'),
                    )
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// The grab handle on top of a bottom sheet.
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: zen.outlineStrong,
          borderRadius: context.zenRadius(2),
        ),
      ),
    );
  }
}

/// One action of a bottom sheet: a tinted icon badge and a label.
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.tone,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ListTile(
      leading: ZenIconBadge(icon: icon, tone: tone, size: 38),
      title: Text(
        label,
        style: TextStyle(
          color: danger ? tone : zen.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: context.zenRadius(16)),
      onTap: onTap,
    );
  }
}

void _showConversationActionSheet(
  BuildContext context,
  WidgetRef ref,
  ConversationPreview conversation,
) {
  final ZenColors zen = ZenColors.of(context);
  final bool pending =
      conversation.status == FriendRelationshipStatus.pendingOutgoing;
  final bool online = conversation.isOnline && !pending;
  final bool away =
      conversation.presence == PeerPresence.background && !pending;
  final String? presence = pending ? null : _presenceSemantics(conversation);

  showModalBottomSheet<void>(
    context: context,
    backgroundColor: zen.surfaceRaised,
    shape: context.zenSheetShape(),
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _SheetHandle(),
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  ZenBlobAvatar(
                    name: conversation.name,
                    size: 52,
                    online: online,
                    away: away,
                    showStatus:
                        pending || conversation.presence != PeerPresence.hidden,
                    image: peerAvatarImage(conversation.avatarPath),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          conversation.name,
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 20,
                            weight: FontWeight.w600,
                            height: 1.15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (pending || presence != null) ...<Widget>[
                          const SizedBox(height: 6),
                          ZenPill(
                            text: pending
                                ? t('Zaproszenie wysłane')
                                : presence!,
                            tone: pending
                                ? zen.warning
                                : online
                                ? zen.success
                                : away
                                ? zen.warning
                                : zen.textMuted,
                            icon: pending
                                ? Icons.schedule_rounded
                                : Icons.circle,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: zen.outlineSoft),
              const SizedBox(height: 8),
              if (pending) ...<Widget>[
                _SheetAction(
                  icon: Icons.cancel_outlined,
                  label: t('Anuluj zaproszenie'),
                  tone: zen.danger,
                  danger: true,
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await ref
                        .read(socialHubControllerProvider.notifier)
                        .cancelOutgoingRequest(
                          peerAddress: conversation.address,
                        );
                  },
                ),
                _SheetAction(
                  icon: Icons.block_rounded,
                  label: t('Zablokuj użytkownika'),
                  tone: zen.danger,
                  danger: true,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _confirmAndBlockFriend(context, ref, conversation);
                  },
                ),
              ] else ...<Widget>[
                _SheetAction(
                  icon: Icons.chat_bubble_outline_rounded,
                  label: t('Otwórz rozmowę'),
                  tone: zen.accent,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _openConversationScreen(
                      context,
                      peerAddress: conversation.address,
                      title: conversation.name,
                    );
                  },
                ),
                _SheetAction(
                  icon: Icons.edit_outlined,
                  label: t('Pseudonim'),
                  tone: zen.tone(ZenTone.people),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _promptFriendNickname(context, ref, conversation);
                  },
                ),
                _SheetAction(
                  icon: Icons.cleaning_services_outlined,
                  label: t('Wyczyść historię'),
                  tone: zen.warning,
                  danger: true,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _confirmAndClearHistory(context, ref, conversation);
                  },
                ),
                _SheetAction(
                  icon: Icons.person_remove_outlined,
                  label: t('Usuń znajomego'),
                  tone: zen.danger,
                  danger: true,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _confirmAndRemoveFriend(context, ref, conversation);
                  },
                ),
                _SheetAction(
                  icon: Icons.block_rounded,
                  label: t('Zablokuj użytkownika'),
                  tone: zen.danger,
                  danger: true,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _confirmAndBlockFriend(context, ref, conversation);
                  },
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _confirmAndRemoveFriend(
  BuildContext context,
  WidgetRef ref,
  ConversationPreview conversation,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ZenColors zen = ZenColors.of(dialogContext);
      return AlertDialog(
        scrollable: true,
        icon: Icon(Icons.person_remove_outlined, color: zen.danger, size: 30),
        title: Text(t('Usunąć znajomego?')),
        content: Text(
          t('Czy na pewno chcesz usunąć {name} z listy kontaktów?', {
            'name': conversation.name,
          }),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: zen.danger,
              foregroundColor: ZenColors.foregroundFor(zen.danger),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t('Usuń')),
          ),
        ],
      );
    },
  );

  if (confirmed == true) {
    await ref
        .read(socialHubControllerProvider.notifier)
        .removeFriend(peerAddress: conversation.address);
  }
}

Future<void> _confirmAndBlockFriend(
  BuildContext context,
  WidgetRef ref,
  ConversationPreview conversation,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ZenColors zen = ZenColors.of(dialogContext);
      return AlertDialog(
        scrollable: true,
        icon: Icon(Icons.block_rounded, color: zen.danger, size: 30),
        title: Text(t('Zablokować użytkownika?')),
        content: Text(
          t(
            'Czy na pewno chcesz zablokować {name}? Nie będziesz otrzymywać '
            'wiadomości ani połączeń od tego kontaktu.',
            {'name': conversation.name},
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: zen.danger,
              foregroundColor: ZenColors.foregroundFor(zen.danger),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t('Zablokuj')),
          ),
        ],
      );
    },
  );

  if (confirmed == true) {
    await ref
        .read(socialHubControllerProvider.notifier)
        .blockFriend(peerAddress: conversation.address);
  }
}

Future<void> _confirmAndClearHistory(
  BuildContext context,
  WidgetRef ref,
  ConversationPreview conversation,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ZenColors zen = ZenColors.of(dialogContext);
      return AlertDialog(
        scrollable: true,
        icon: Icon(
          Icons.cleaning_services_outlined,
          color: zen.warning,
          size: 30,
        ),
        title: Text(t('Wyczyścić historię?')),
        content: Text(
          t(
            'Czy na pewno chcesz usunąć całą historię rozmowy z {name}? '
            'Tej operacji nie można cofnąć.',
            {'name': conversation.name},
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: zen.warning,
              foregroundColor: ZenColors.foregroundFor(zen.warning),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(t('Wyczyść')),
          ),
        ],
      );
    },
  );

  if (confirmed == true) {
    await ref
        .read(socialHubControllerProvider.notifier)
        .clearConversationHistory(peerAddress: conversation.address);
  }
}

Future<void> _promptFriendNickname(
  BuildContext context,
  WidgetRef ref,
  ConversationPreview conversation,
) async {
  final FriendProfile? friend = ref
      .read(socialHubControllerProvider)
      .friendByAddress(conversation.address);
  if (friend == null) {
    return;
  }
  final String? nickname = await promptForFriendNickname(
    context: context,
    friend: friend.copyWith(displayName: conversation.name),
  );
  if (nickname == null || !context.mounted) {
    return;
  }
  try {
    await ref
        .read(socialHubControllerProvider.notifier)
        .setFriendNickname(
          peerAddress: conversation.address,
          nickname: nickname,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            nickname.isEmpty
                ? t('Usunięto pseudonim')
                : t('Zapisano pseudonim'),
          ),
        ),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('Nie udało się zapisać pseudonimu: {error}', {'error': error}),
          ),
        ),
      );
    }
  }
}

(String groupId, String groupName) _resolveGroupInvite(
  InboxEntry item,
  Map<String, GroupProfile> groups,
) {
  if (item.routeKey != null) {
    final Uri? uri = Uri.tryParse(item.routeKey!);
    if (uri != null &&
        uri.scheme == 'zen' &&
        uri.host == 'group' &&
        uri.pathSegments.isNotEmpty) {
      final String id = uri.pathSegments.first;
      final String name =
          uri.queryParameters['title']?.trim().isNotEmpty == true
          ? uri.queryParameters['title']!.trim()
          : (groups[id]?.name ?? t('Grupa'));
      return (id, name);
    }
  }
  String name = item.title;
  const String prefix = 'Zaproszenie do grupy: ';
  if (name.startsWith(prefix)) {
    name = name.substring(prefix.length).trim();
  }
  for (final GroupProfile group in groups.values) {
    if (name.isNotEmpty && group.name == name) {
      return (group.id, group.name);
    }
    if (item.peerAddress != null &&
        PeerShareCodec.addressesEqual(group.createdById, item.peerAddress!)) {
      return (group.id, group.name);
    }
  }
  final String fallbackId = 'grp-${item.peerAddress ?? item.id}';
  final String fallbackName = name.isNotEmpty ? name : t('Grupa');
  return (fallbackId, fallbackName);
}

class _InboxCard extends ConsumerWidget {
  const _InboxCard({required this.item});

  final InboxEntry item;

  /// Joins the group from its invitation. The user stays where they are: the
  /// group simply shows up in their list, no screen is pushed on them.
  Future<void> _joinGroup(
    BuildContext context,
    WidgetRef ref,
    String groupId,
    String groupName,
  ) async {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    try {
      await ref
          .read(socialHubControllerProvider.notifier)
          .acceptGroupInvite(
            groupId: groupId,
            groupName: groupName,
            senderAddress: item.peerAddress,
            inboxEntryId: item.id,
          );
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            t('Dołączono do grupy „{group}”.', {'group': groupName}),
          ),
        ),
      );
    } catch (error) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(t('Nie udało się dołączyć: {error}', {'error': error})),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final RuntimeRouteIntent? launchIntent = runtimeRouteIntentFromRouteKey(
      id: item.id,
      routeKey: item.routeKey,
    );
    final String? peerAddress = item.peerAddress;
    final bool canRespondToRequest =
        item.type == InboxEntryType.friendRequest && peerAddress != null;
    final bool isGroupInvite = item.type == InboxEntryType.groupInvite;
    final Color tone = _inboxTone(zen, item.type);
    return _Panel(
      key: Key('inbox-card-${item.id}'),
      accentTone: tone,
      // An invitation is answered with its buttons; the card itself leads
      // nowhere until the user has joined.
      onTap: canRespondToRequest || isGroupInvite
          ? null
          : () {
              if (item.routeKey != null) {
                ref
                    .read(socialHubControllerProvider.notifier)
                    .requestLaunchFromRouteKey(item.routeKey);
              }
            },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ZenIconBadge(icon: _inboxIcon(item.type), tone: tone, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        item.displayTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.25,
                        ),
                      ),
                    ),
                    if (item.displayBody.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        item.displayBody,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  key: Key('inbox-dismiss-${item.id}'),
                  tooltip: t('Usuń powiadomienie'),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  color: zen.textMuted,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    ref
                        .read(socialHubControllerProvider.notifier)
                        .dismissInboxEntry(item.id);
                  },
                ),
              ),
            ],
          ),
          if (canRespondToRequest) ...<Widget>[
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    key: Key('inbox-reject-$peerAddress'),
                    onPressed: () async {
                      try {
                        await ref
                            .read(socialHubControllerProvider.notifier)
                            .rejectFriendRequest(peerAddress: peerAddress);
                      } catch (error) {
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              t('Nie udało się odrzucić: {error}', {
                                'error': error,
                              }),
                            ),
                          ),
                        );
                      }
                    },
                    child: Text(
                      t('Odrzuć'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: Key('inbox-accept-$peerAddress'),
                    onPressed: () async {
                      try {
                        // They keep the name from their profile.
                        await ref
                            .read(socialHubControllerProvider.notifier)
                            .acceptFriendRequest(
                              peerAddress: peerAddress,
                              senderDisplayName: _localSenderDisplayName(ref),
                            );
                      } catch (error) {
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              t('Nie udało się zaakceptować: {error}', {
                                'error': error,
                              }),
                            ),
                          ),
                        );
                      }
                    },
                    child: Text(
                      t('Akceptuj'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (isGroupInvite) ...<Widget>[
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    key: Key('inbox-reject-${item.id}'),
                    onPressed: () async {
                      final (String groupId, _) = _resolveGroupInvite(
                        item,
                        ref.read(socialHubControllerProvider).groups,
                      );
                      await ref
                          .read(socialHubControllerProvider.notifier)
                          .rejectGroupInvite(
                            groupId: groupId,
                            inboxEntryId: item.id,
                            senderAddress: item.peerAddress,
                          );
                    },
                    child: Text(
                      t('Odrzuć'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: Key('inbox-accept-${item.id}'),
                    onPressed: () {
                      final (
                        String groupId,
                        String groupName,
                      ) = _resolveGroupInvite(
                        item,
                        ref.read(socialHubControllerProvider).groups,
                      );
                      unawaited(_joinGroup(context, ref, groupId, groupName));
                    },
                    child: Text(
                      t('Dołącz'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ] else if (launchIntent != null) ...<Widget>[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 54),
              child: Row(
                children: <Widget>[
                  Flexible(
                    child: Text(
                      launchIntent.actionLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tone,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, size: 16, color: tone),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

ConversationPreview _conversationFromFriend(
  FriendProfile friend, [
  PeerPublicProfile? peer,
]) {
  final String peerName = peer?.name.trim() ?? '';
  final String preview = switch (friend.status) {
    FriendRelationshipStatus.pendingOutgoing =>
      friend.requestMessage?.trim().isNotEmpty == true
          ? friend.requestMessage!.trim()
          : t('Zaproszenie oczekuje na akceptacje.'),
    FriendRelationshipStatus.pendingIncoming =>
      friend.requestMessage?.trim().isNotEmpty == true
          ? friend.requestMessage!.trim()
          : t('Oczekujące zaproszenie.'),
    FriendRelationshipStatus.accepted =>
      friend.lastMessagePreview.isEmpty
          ? t('Brak wiadomości.')
          : friend.lastMessagePreview,
    FriendRelationshipStatus.blocked => t('Kontakt zablokowany.'),
    FriendRelationshipStatus.none => t('Brak relacji.'),
  };
  return ConversationPreview(
    address: friend.address,
    // Their own name (the newest profile wins); the nickname goes under it.
    name: peerName.isEmpty ? friend.displayLabel : peerName,
    nickname: friend.nickname.trim(),
    avatarPath: peer?.avatarPath,
    status: friend.status,
    lastMessage: preview,
    timeLabel: friend.lastActivityLabel.isEmpty
        ? t('Teraz')
        : friend.lastActivityLabel,
    unreadCount: friend.unreadCount,
    presence: friend.status == FriendRelationshipStatus.accepted
        ? friend.presence
        : PeerPresence.hidden,
    lastOpenedAtMillis: friend.lastOpenedAtMillis,
    isTyping: friend.isTyping,
  );
}

/// What a chat's presence dot says, in words: "online", "w tle · ostatnio
/// otwierał(a) 5 min temu", …; `null` for a friend who does not show it.
String? _presenceSemantics(ConversationPreview conversation) =>
    friendPresenceLine(
      FriendProfile(
        address: conversation.address,
        presence: conversation.presence,
        lastOpenedAtMillis: conversation.lastOpenedAtMillis,
      ),
      DateTime.now().millisecondsSinceEpoch,
    );

Color _shellStatusAccent(ZenColors zen, AppShellState state) {
  if (state.health == ServiceHealth.failed ||
      state.health == ServiceHealth.stopped) {
    return zen.danger;
  }
  if (state.isConnected) {
    return zen.tone(ZenTone.network);
  }
  return zen.warning;
}

IconData _inboxIcon(InboxEntryType type) {
  return switch (type) {
    InboxEntryType.friendAccepted => Icons.check_circle_outline_rounded,
    InboxEntryType.friendRequest => Icons.person_add_alt_1_rounded,
    InboxEntryType.friendRemoved => Icons.person_remove_alt_1_rounded,
    InboxEntryType.transferCancelled => Icons.file_present_rounded,
    InboxEntryType.message => Icons.chat_bubble_outline_rounded,
    InboxEntryType.callInvite => Icons.call_outlined,
    InboxEntryType.friendRejected => Icons.person_off_outlined,
    InboxEntryType.friendCancelled => Icons.event_busy_outlined,
    InboxEntryType.groupInvite => Icons.group_add_outlined,
    InboxEntryType.post => Icons.article_outlined,
    InboxEntryType.mention => Icons.alternate_email_rounded,
  };
}

Color _inboxTone(ZenColors zen, InboxEntryType type) {
  return switch (type) {
    InboxEntryType.friendAccepted => zen.tone(ZenTone.people),
    InboxEntryType.friendRequest => zen.tone(ZenTone.people),
    InboxEntryType.friendRemoved => zen.warning,
    InboxEntryType.transferCancelled => zen.warning,
    InboxEntryType.message => zen.tone(ZenTone.communication),
    InboxEntryType.callInvite => zen.tone(ZenTone.communication),
    InboxEntryType.friendRejected => zen.warning,
    InboxEntryType.friendCancelled => zen.textMuted,
    InboxEntryType.groupInvite => zen.tone(ZenTone.people),
    InboxEntryType.post => zen.tone(ZenTone.people),
    InboxEntryType.mention => zen.tone(ZenTone.communication),
  };
}

String? _localSenderDisplayName(WidgetRef ref) {
  final String localAddress = ref.read(appShellControllerProvider).localAddress;
  final String profileName = ref.read(userProfileControllerProvider).publicName;
  return PeerShareCodec.buildLocalProfile(
        address: localAddress,
        displayName: profileName,
      )?.displayName ??
      (profileName.trim().isNotEmpty ? profileName.trim() : null);
}
