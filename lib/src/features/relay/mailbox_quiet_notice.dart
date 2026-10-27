import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Prefix of the notification entries about a mailbox that stopped
/// answering (one per mailbox and quiet spell).
const String kQuietMailboxEntryPrefix = 'mailbox-quiet:';

/// "od 4 dni" for how long a mailbox has been quiet: since [sinceMillis],
/// at [nowMillis] (at least a day: it counts as quiet after three).
String quietForText(int sinceMillis, int nowMillis) {
  final int days = ((nowMillis - sinceMillis) / Duration.millisecondsPerDay)
      .floor()
      .clamp(1, 9999);
  return tn(days, one: 'od {n} dnia', few: 'od {n} dni', many: 'od {n} dni');
}

/// "Skrzynka Ola nie odpowiada od 4 dni — wybierz inną".
String quietMailboxTitle(String name, int sinceMillis, int nowMillis) => t(
  'Skrzynka {name} nie odpowiada {time} — wybierz inną',
  {'name': name, 'time': quietForText(sinceMillis, nowMillis)},
);

/// What a quiet mailbox means and what to do about it.
String quietMailboxText() => t(
  'Gdy jesteś offline, wiadomości do Ciebie czekają w skrzynkach u '
  'znajomych. Ta od dawna nie odpowiada i nikt nie może jej sam zastąpić. '
  'Wybierz kogoś, kto bywa online — najlepiej z Zen na komputerze albo na '
  'Androidzie.',
);

/// The kind of a friend's device, for the mailbox picker ('' when not
/// known).
String relayDeviceKindLabel(RelayDeviceClass kind) => switch (kind) {
  RelayDeviceClass.desktop => t('komputer'),
  RelayDeviceClass.android => t('Android'),
  RelayDeviceClass.iphoneKeepAlive => t('iPhone, odbiera w tle'),
  RelayDeviceClass.iphone => t('iPhone'),
  RelayDeviceClass.unknown => '',
};

/// The name the app shows for the friend [address].
String friendNameFor(SocialHubState state, String address) =>
    state.friendByAddress(address)?.displayLabel ?? t('znajomy');

/// The notification entry about [quiet], told at [nowMillis]: a tap opens
/// the mailbox picker.
InboxEntry quietMailboxInboxEntry(
  RelayQuietMailbox quiet, {
  required String name,
  required int nowMillis,
}) => InboxEntry(
  id: '$kQuietMailboxEntryPrefix${quiet.device}:${quiet.sinceMillis}',
  type: InboxEntryType.mailbox,
  title: quietMailboxTitle(name, quiet.sinceMillis, nowMillis),
  body: quietMailboxText(),
  createdAtMillis: nowMillis,
  routeKey: buildMailboxesRouteKey(),
  peerAddress: quiet.friend,
);

/// Tells the person, once per quiet spell, in the notifications list that a
/// mailbox stopped answering and nobody can take its place by itself
/// ([RelayOverview.quiet]). The card on the chats list shows it as long as
/// it lasts.
final class RelayQuietWatch {
  RelayQuietWatch({
    required this.engine,
    required this.state,
    required this.addToInbox,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    engine.overview.addListener(_check);
    _check();
  }

  final RelayEngine engine;
  final SocialHubState Function() state;
  final Future<void> Function(InboxEntry entry) addToInbox;
  final int Function() _now;
  bool _busy = false;

  void _check() {
    if (_busy) {
      return;
    }
    final List<RelayQuietMailbox> untold = <RelayQuietMailbox>[
      for (final RelayQuietMailbox q in engine.overview.value.quiet)
        if (!q.told) q,
    ];
    if (untold.isEmpty) {
      return;
    }
    _busy = true;
    unawaited(_tell(untold).whenComplete(() => _busy = false));
  }

  Future<void> _tell(List<RelayQuietMailbox> untold) async {
    final int now = _now();
    for (final RelayQuietMailbox q in untold) {
      await addToInbox(
        quietMailboxInboxEntry(
          q,
          name: friendNameFor(state(), q.friend),
          nowMillis: now,
        ),
      );
    }
    await engine.markQuietTold(untold);
  }

  void dispose() => engine.overview.removeListener(_check);
}

/// Runs [RelayQuietWatch] while the app runs (`null` without mailboxes).
final Provider<RelayQuietWatch?> relayQuietWatchProvider =
    Provider<RelayQuietWatch?>((Ref ref) {
      final RelayEngine? engine = ref.watch(relayEngineProvider);
      if (engine == null) {
        return null;
      }
      final RelayQuietWatch watch = RelayQuietWatch(
        engine: engine,
        state: () => ref.read(socialHubControllerProvider),
        addToInbox: (InboxEntry entry) =>
            ref.read(socialHubControllerProvider.notifier).putInboxEntry(entry),
      );
      ref.onDispose(watch.dispose);
      return watch;
    });

/// Whether the friend's device in [candidate] makes a weak mailbox the
/// picker warns about: an iPhone without the keep-alive.
bool isWeakMailbox(RelayMailboxCandidate? candidate) =>
    candidate?.deviceClass == RelayDeviceClass.iphone;
