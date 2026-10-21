import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/graph/graph_notes.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// "Otwarty(-a) na poznanie" on the graph (see [OpenToMeetService]).
final Provider<OpenToMeetService> openToMeetServiceProvider =
    Provider<OpenToMeetService>((Ref ref) {
      final MeetService meet = ref.watch(meetServiceProvider);
      final OpenToMeetService open = OpenToMeetService(
        host: AppMeetHost(ref),
        disk: ref.read(ledgerDiskProvider),
        // Friends' flags go only with the friend list (who does not see it
        // does not see those people either).
        listVisibleTo: meet.friendListVisibleTo,
        isWeak: meet.isWeak,
        // Read only while this person's own flag is on: the dating
        // profile's "Ukryj przed" as it is now.
        hiddenFrom: () =>
            ref.read(featureFlagsProvider).isEnabled(ZenFeature.dating)
            ? ref.read(datingServiceProvider).hiddenAddresses()
            : const <String>{},
        // People across opened gates: they see the flag, theirs shows here.
        gateContacts: () => datingGateContacts(ref),
      );
      unawaitedLogged(open.load(), context: 'Graf: otwarci na poznanie');
      listenFrames(ref, open.handle, 'Graf: otwarci na poznanie');
      // New or gone friends, a changed level or friend-list audience: each
      // friend gets what changed for them (digest-checked, so mostly
      // nothing), a little later so a burst of changes is one pass.
      Timer? soon;
      void later() {
        soon?.cancel();
        soon = Timer(
          const Duration(seconds: 3),
          () => unawaitedLogged(
            open.shareAll(),
            context: 'Graf: otwarci na poznanie',
          ),
        );
      }

      ref.listen<String>(
        socialHubControllerProvider.select(
          (SocialHubState s) => (acceptedFriendAddresses(s)..sort()).join(','),
        ),
        (String? previous, String next) => later(),
      );
      // What decides who gets what: the list audience and who is a weak
      // acquaintance (a level change sends the list again, so it shows here).
      String signature() => <String>[
        meet.book.friendListAudience.name,
        '${meet.book.friendListAllowed.length}',
        for (final String f in meet.host.friends())
          if (meet.isWeak(f)) f,
      ].join('|');
      String last = signature();
      void onMeet() {
        final String now = signature();
        if (now != last) {
          last = now;
          later();
        }
      }

      meet.addListener(onMeet);
      ref.onDispose(() {
        soon?.cancel();
        meet.removeListener(onMeet);
        open.dispose();
      });
      return open;
    });

/// What the graph keeps for this person only (dates, private circle names,
/// reminders). Friends are noted as they come and go while it lives.
final Provider<GraphNotesService> graphNotesProvider =
    Provider<GraphNotesService>((Ref ref) {
      final GraphNotesService notes = GraphNotesService(
        disk: ref.read(ledgerDiskProvider),
      );
      unawaitedLogged(notes.load(), context: 'Graf: notatki');
      ref.listen<String>(
        socialHubControllerProvider.select(
          (SocialHubState s) => (acceptedFriendAddresses(s)..sort()).join(','),
        ),
        (String? previous, String next) {
          if (next.isEmpty) {
            return;
          }
          unawaitedLogged(
            notes.observe(friends: next.split(',')),
            context: 'Graf: daty znajomych',
          );
        },
        fireImmediately: true,
      );
      ref.onDispose(notes.dispose);
      return notes;
    });
