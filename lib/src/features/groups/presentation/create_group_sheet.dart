import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

class CreateGroupSheet extends ConsumerStatefulWidget {
  const CreateGroupSheet({super.key});

  static Future<GroupProfile?> show(BuildContext context) {
    return showModalBottomSheet<GroupProfile?>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) => const CreateGroupSheet(),
    );
  }

  @override
  ConsumerState<CreateGroupSheet> createState() => _CreateGroupSheetState();
}

class _CreateGroupSheetState extends ConsumerState<CreateGroupSheet> {
  final TextEditingController _nameController = TextEditingController();
  final Set<String> _selectedMembers = <String>{};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final String name = _nameController.text.trim();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    if (name.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Nadaj grupie nazwę.')),
      );
      return;
    }
    if (_selectedMembers.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Wybierz co najmniej jedną osobę.')),
      );
      return;
    }

    try {
      final GroupProfile created = await ref
          .read(socialHubControllerProvider.notifier)
          .createGroup(
            name: name,
            description: '',
            avatarPreset: 'group_default',
            memberAddresses: _selectedMembers.toList(),
          );

      if (mounted) {
        Navigator.of(context).pop(created);
        messenger.showSnackBar(
          SnackBar(content: Text('Utworzono grupę "${created.name}".')),
        );
      }
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Błąd tworzenia grupy: $error')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<FriendProfile> acceptedFriends = watchSocialPeople(
      ref,
    ).acceptedFriends;
    final double bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return ZenFadeSlide(
      duration: const Duration(milliseconds: 240),
      offset: const Offset(0, 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: zen.surface,
          gradient: LinearGradient(
            colors: <Color>[
              Color.alphaBlend(zen.accent.withValues(alpha: 0.10), zen.surface),
              zen.surface,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const <double>[0, 0.4],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: zen.outlineSoft)),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 10, 16, 24 + bottomInset),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: zen.outlineStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    const ZenIconBadge(icon: Icons.group_add_rounded, size: 42),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            'Nowa grupa',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: zen.display(
                              color: zen.textPrimary,
                              size: 22,
                              weight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Nazwij grupę i wybierz, kogo zaprosić.',
                            style: TextStyle(
                              color: zen.textSecondary,
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Zamknij',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  key: const Key('create-group-name-field'),
                  controller: _nameController,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Nazwa grupy',
                    hintText: 'np. Ekipa z pracy',
                    prefixIcon: Icon(Icons.groups_rounded),
                  ),
                ),
                ZenSection(
                  'Dodaj znajomych (${_selectedMembers.length})',
                  top: 18,
                ),
                if (acceptedFriends.isEmpty)
                  const ZenInfo(
                    icon: Icons.person_search_rounded,
                    text:
                        'Nie masz jeszcze dodanych znajomych. Możesz utworzyć grupę i dodać ich później.',
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: Material(
                      color: zen.surfaceRaised,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                        side: BorderSide(color: zen.outlineSoft),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: acceptedFriends.length,
                          itemBuilder: (BuildContext context, int index) {
                            final FriendProfile friend = acceptedFriends[index];
                            final bool selected = _selectedMembers.contains(
                              friend.address,
                            );
                            final Color tone = zenTone(zen, index % 8);
                            final String label = friend.displayLabel.trim();

                            return CheckboxListTile(
                              dense: true,
                              controlAffinity: ListTileControlAffinity.trailing,
                              secondary: CircleAvatar(
                                radius: 17,
                                backgroundColor: tone.withValues(alpha: 0.18),
                                child: Text(
                                  label.isEmpty
                                      ? '?'
                                      : label.characters.first.toUpperCase(),
                                  style: TextStyle(
                                    color: tone,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              title: Text(
                                friend.displayLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: zen.textPrimary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14.5,
                                ),
                              ),
                              value: selected,
                              onChanged: (bool? val) {
                                setState(() {
                                  if (val == true) {
                                    _selectedMembers.add(friend.address);
                                  } else {
                                    _selectedMembers.remove(friend.address);
                                  }
                                });
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  key: const Key('create-group-submit-button'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _createGroup,
                  icon: const Icon(Icons.check_rounded),
                  label: const Text('Utwórz grupę'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
