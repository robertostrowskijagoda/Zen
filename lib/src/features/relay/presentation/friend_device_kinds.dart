import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/relay/mailbox_quiet_notice.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The kinds of a friend's devices ("Android · komputer"), as their devices
/// announced them; `null` while none did (or without mailboxes).
String? friendDeviceKindsLabel(List<RelayDeviceClass> kinds) {
  final List<String> labels = <String>[
    for (final RelayDeviceClass kind in kinds) relayDeviceKindLabel(kind),
  ].where((String label) => label.isNotEmpty).toList(growable: false);
  return labels.isEmpty ? null : labels.join(' · ');
}

/// A small icon for [kind].
IconData relayDeviceKindIcon(RelayDeviceClass kind) => switch (kind) {
  RelayDeviceClass.desktop => Icons.computer_rounded,
  RelayDeviceClass.android => Icons.android_rounded,
  RelayDeviceClass.iphone ||
  RelayDeviceClass.iphoneKeepAlive => Icons.phone_iphone_rounded,
  RelayDeviceClass.unknown => Icons.devices_other_rounded,
};

/// The devices' kinds of the friend at [address], by what their devices
/// announced.
final friendDeviceKindsProvider = Provider.autoDispose
    .family<List<RelayDeviceClass>, String>((Ref ref, String address) {
      final RelayEngine? engine = ref.watch(relayEngineProvider);
      if (engine == null) {
        return const <RelayDeviceClass>[];
      }
      void changed() => ref.invalidateSelf();
      engine.overview.addListener(changed);
      ref.onDispose(() => engine.overview.removeListener(changed));
      return engine
              .overview
              .value
              .candidates[PeerShareCodec.normalizeAddress(address)]
              ?.deviceClasses ??
          const <RelayDeviceClass>[];
    });

/// What the friend at [address] uses: a small icon per system and its name
/// ("Android · komputer"); nothing until it is known.
class FriendDeviceKinds extends ConsumerWidget {
  const FriendDeviceKinds({
    required this.address,
    this.color,
    this.fontSize = 12.5,
    super.key,
  });

  final String address;
  final Color? color;
  final double fontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<RelayDeviceClass> kinds = ref.watch(
      friendDeviceKindsProvider(address),
    );
    final String? label = friendDeviceKindsLabel(kinds);
    if (label == null) {
      return const SizedBox.shrink();
    }
    final Color tone = color ?? ZenColors.of(context).textSecondary;
    final Set<IconData> icons = <IconData>{
      for (final RelayDeviceClass kind in kinds) relayDeviceKindIcon(kind),
    };
    return Row(
      key: const Key('friend-device-kinds'),
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final IconData icon in icons) ...<Widget>[
          Icon(icon, size: fontSize + 1, color: tone),
          const SizedBox(width: 3),
        ],
        const SizedBox(width: 1),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tone, fontSize: fontSize),
          ),
        ),
      ],
    );
  }
}
