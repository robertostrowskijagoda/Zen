import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/social/friend_display_name.dart';

/// Asks for the nickname of [friend]: their own name (from their profile)
/// is shown and cannot be changed; the nickname appears under it, only
/// here. Returns the nickname ('' removes it) or null when cancelled.
Future<String?> promptForFriendNickname({
  required BuildContext context,
  required FriendProfile friend,
  Key fieldKey = const Key('friend-nickname-field'),
  Key confirmKey = const Key('friend-nickname-save'),
}) {
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => _FriendNicknameDialog(
      friend: friend,
      fieldKey: fieldKey,
      confirmKey: confirmKey,
    ),
  );
}

class _FriendNicknameDialog extends StatefulWidget {
  const _FriendNicknameDialog({
    required this.friend,
    required this.fieldKey,
    required this.confirmKey,
  });

  final FriendProfile friend;
  final Key fieldKey;
  final Key confirmKey;

  @override
  State<_FriendNicknameDialog> createState() => _FriendNicknameDialogState();
}

class _FriendNicknameDialogState extends State<_FriendNicknameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.friend.nickname,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(sanitizeFriendNickname(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool hadNickname = widget.friend.hasNickname;
    return AlertDialog(
      icon: ZenIconBadge(icon: Icons.badge_rounded, tone: zenTone(zen, 1)),
      title: Text(t('Pseudonim'), textAlign: TextAlign.center),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                key: const Key('friend-nickname-profile-name'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: zen.surfaceMuted,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.lock_outline_rounded,
                      size: 18,
                      color: zen.textMuted,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            t('Nazwa z profilu'),
                            style: TextStyle(
                              color: zen.textMuted,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            widget.friend.displayLabel,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: widget.fieldKey,
                controller: _controller,
                autofocus: true,
                maxLength: kMaxFriendNickname,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('Pseudonim (opcjonalnie)'),
                  hintText: t('np. Kasia z pracy'),
                  prefixIcon: const Icon(Icons.edit_note_rounded),
                  helperText: t(
                    'Widzisz go tylko Ty, pod nazwą tej osoby. '
                    'Nazwę zmienia ona sama w swoim profilu.',
                  ),
                  helperMaxLines: 3,
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        if (hadNickname)
          TextButton(
            key: const Key('friend-nickname-clear'),
            onPressed: () => Navigator.of(context).pop(''),
            child: Text(t('Usuń')),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: widget.confirmKey,
          onPressed: _submit,
          child: Text(t('Zapisz')),
        ),
      ],
    );
  }
}
