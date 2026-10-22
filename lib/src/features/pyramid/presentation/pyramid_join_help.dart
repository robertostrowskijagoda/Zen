import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The friends (as `address → name`) who are members of the pyramid, as
/// far as [members] tell: a member's device addresses are public in the
/// pyramid. Sorted by name.
List<String> friendsInPyramid(
  Iterable<PyrMember> members,
  Map<String, String> friends,
) {
  final Map<String, String> byAddress = <String, String>{
    for (final MapEntry<String, String> f in friends.entries)
      PeerShareCodec.normalizeAddress(f.key): f.value,
  };
  final Set<String> names = <String>{};
  for (final PyrMember m in members) {
    if (!m.active) {
      continue;
    }
    for (final String a in <String>{m.addr, ...m.addrs}) {
      final String? name = byAddress[PeerShareCodec.normalizeAddress(a)];
      if (name != null) {
        names.add(name);
        break;
      }
    }
  }
  return names.toList()..sort();
}

/// "Jak dołączyć": the pyramid is entered only through a friend who is a
/// member; this says how, and who of the person's friends is one (when the
/// pyramid's records are known here), so the screen is no dead end.
class PyramidJoinHelp extends ConsumerWidget {
  const PyramidJoinHelp({super.key, required this.state});

  /// The pyramid as known on this device; `null` when nothing is known.
  final PyramidState? state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final SocialHubState social = watchSocialPeople(ref);
    final PyramidState? s = state;
    final List<String> inPyramid = s == null || s.members.isEmpty
        ? const <String>[]
        : friendsInPyramid(s.members.values, <String, String>{
            for (final FriendProfile f in social.acceptedFriends)
              f.address: social.nameFor(f),
          });
    return Column(
      key: const Key('pyr-join-help'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenInfo(
          icon: Icons.handshake_outlined,
          title: t('Jak dołączyć'),
          text: t(
            'Do piramidy wchodzi się tylko przez znajomego, który już w niej '
            'jest. Spotkajcie się: on otwiera Piramida → „Zaproś do '
            'piramidy” i pokazuje kod, a Ty skanujesz go przyciskiem niżej. '
            'Za dołączenie nikt nic nie płaci.',
          ),
        ),
        if (inPyramid.isNotEmpty)
          ZenInfo(
            key: const Key('pyr-friends-in'),
            icon: Icons.groups_rounded,
            tone: zen.success,
            title: t('Twoi znajomi w piramidzie'),
            text: t(
              '{names} — poproś kogoś z nich o zaproszenie.',
              <String, Object?>{'names': inPyramid.join(', ')},
            ),
          )
        else
          ZenInfo(
            key: const Key('pyr-friends-none'),
            icon: Icons.group_off_outlined,
            tone: zen.textMuted,
            text: s == null || s.members.isEmpty
                ? t(
                    'Zen nie wie jeszcze, kto ze znajomych jest w piramidzie. '
                    'Zapytaj ich — wystarczy jedna osoba, która już jest.',
                  )
                : t(
                    'Nikt z Twoich znajomych nie jest jeszcze w piramidzie. '
                    'Gdy ktoś dołączy, zobaczysz go tutaj.',
                  ),
          ),
      ],
    );
  }
}
