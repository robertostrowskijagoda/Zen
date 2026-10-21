import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// People this person reached through an opened gate (an introduction that
/// came through), and people who reached this person through one (and were
/// not turned down): Dating's lanterns and the graph's "open to meet" go to
/// them as to friends, marked as having crossed a gate.
Set<String> datingGateContacts(Ref ref) {
  try {
    final IntroService intro = ref.read(introServiceProvider);
    return <String>{
      for (final IntroCase c in intro.mine)
        if (c.kind == IntroKind.intro &&
            c.target.isNotEmpty &&
            (c.reached || c.status == IntroStatus.accepted))
          PeerShareCodec.normalizeAddress(c.target),
      for (final IntroCase c in <IntroCase>[...intro.needsMe, ...intro.handled])
        if (c.role == IntroRole.target &&
            c.kind == IntroKind.intro &&
            c.asker.isNotEmpty &&
            (c.status == IntroStatus.open || c.status == IntroStatus.accepted))
          PeerShareCodec.normalizeAddress(c.asker),
    };
  } on Object catch (error, stack) {
    logZenError('Randki: bramy', error, stack);
    return const <String>{};
  }
}

/// "Randki przez znajomych".
final Provider<DatingService> datingServiceProvider = Provider<DatingService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final DatingService dating = DatingService(
    host: appEventHost(ref, meet),
    disk: ref.read(ledgerDiskProvider),
    groupMembers: (String id) {
      final GroupProfile? g = ref.read(socialHubControllerProvider).groups[id];
      return g?.memberAddresses ?? const <String>[];
    },
    // The people of this person's groups get the dating key too, so hiding
    // from a group holds for members who are not friends.
    groupPeers: () {
      final SocialHubState social = ref.read(socialHubControllerProvider);
      return <String>{
        for (final GroupProfile g in social.groups.values)
          ...g.memberAddresses.map(PeerShareCodec.normalizeAddress),
      };
    },
    gateContacts: () => datingGateContacts(ref),
    // "Wspólni znajomi" with a match: friends, not weak acquaintances.
    trustedFriends: () => <String>[
      for (final String f in meet.host.friends())
        if (!meet.isWeak(f)) f,
    ],
    isBanned: (String key) {
      final PyramidState? st = ref.read(pyramidServiceProvider).state;
      return st != null &&
          st
              .bannedDatingKeys(DateTime.now().millisecondsSinceEpoch)
              .contains(key);
    },
    // Profiles this person reported are hidden from them.
    isHiddenByMe: (String key) =>
        ref.read(hiddenByMeProvider).hides(datingKey: key),
    // "Podziękuj swatowi": only inside one pyramid.
    pyramidKey: () {
      final PyramidService pyramid = ref.read(pyramidServiceProvider);
      final String? mine = pyramid.myKey;
      final PyramidState? st = pyramid.state;
      return mine != null && st != null && st.isMember(mine) ? mine : null;
    },
    canPay: (String to) {
      final PyramidService pyramid = ref.read(pyramidServiceProvider);
      final String? mine = pyramid.myKey;
      final PyramidState? st = pyramid.state;
      return mine != null &&
          st != null &&
          mine != to &&
          st.isMember(mine) &&
          st.isMember(to);
    },
    pay: (String to, int amount, String memo) async =>
        await ref.read(pyramidServiceProvider).pay(to, amount, memo: memo) !=
        null,
    // A friend's request for the location of a date, when the person agreed
    // beforehand.
    currentPosition: () async {
      final GeoFix? fix = await currentFix();
      return fix == null ? null : (fix.lat, fix.lon);
    },
    raiseAlarm: (String note) async {
      final GeoFix? fix = await currentFix();
      await meet.raiseAlarm(
        note: note,
        lat: fix?.lat,
        lon: fix?.lon,
        accuracy: fix?.accuracy,
      );
    },
  );
  unawaitedLogged(
    dating.load().then((_) => dating.tick()),
    context: 'Odczyt randek',
  );
  listenFrames(ref, dating.handle, 'Randki');
  ref.onDispose(dating.dispose);
  return dating;
});

/// One minute of dating housekeeping (`ZenCore`'s minute, so it stops
/// with the app): deadlines of "Idę na randkę" every minute; the
/// weekly lantern and the position of a running date every 10 minutes
/// (the lantern not right at start, so it does not mark when the app was
/// opened).
void datingMinute(DatingService dating, int minute) {
  unawaitedLogged(dating.tick(), context: 'Randki: terminy');
  if (minute % 10 != 0) {
    return;
  }
  unawaitedLogged(dating.maybePublish(), context: 'Randki: latarnia');
  if (dating.mySafeDate != null) {
    unawaitedLogged(
      currentFix().then((GeoFix? fix) async {
        if (fix != null) {
          await dating.updateSafeLocation(fix.lat, fix.lon);
        }
      }),
      context: 'Randki: położenie',
    );
  }
}
