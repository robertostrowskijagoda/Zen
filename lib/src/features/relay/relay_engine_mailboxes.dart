part of 'relay_engine.dart';

// Choosing this device's mailboxes, and keeping an eye on them.
//
// * **What a device is.** Every device announces its kind with its relay set
//   (`rly_announce` `dc`, [RelayDeviceClass]): a computer in the tray, an
//   Android phone with its background service, an iPhone with or without
//   the keep-alive. No traffic of its own: a change of kind is announced
//   like a new relay set.
// * **How it answers.** This device counts, per friend's device, the asks
//   that wanted an answer (its own polls of its mailboxes, mail handed to
//   friends' mailboxes for others) and whether anything came back from that
//   device before the next ask ([RelayReach]). The periodic polls carry
//   [kRelayProbeKey], so a mailbox with nothing to hand over still says
//   `rly_here`.
// * **The choice.** [_MailboxJudge] ranks friends' devices by both, keeps
//   one device per friend, and changes the set rarely (see
//   [RelayEngine.rankRelays]). A mailbox that went quiet with nobody good
//   enough to take its place shows in [RelayOverview.quiet]: the person is
//   asked to pick another.

/// The mailbox choice over a set of friends at one moment.
final class _MailboxJudge {
  _MailboxJudge({
    required this.friends,
    required this.deviceClass,
    required this.reach,
    required this.nowMillis,
    required this.config,
  }) {
    for (final RelayFriend f in friends) {
      for (final String a in f.allAddresses) {
        owner.putIfAbsent(a, () => f);
      }
    }
  }

  final List<RelayFriend> friends;
  final RelayDeviceClass Function(String address) deviceClass;
  final RelayReach? Function(String address) reach;
  final int nowMillis;
  final RelayConfig config;

  /// Each friend by every address of theirs (canonical).
  final Map<String, RelayFriend> owner = <String, RelayFriend>{};

  /// The friend's own address, canonical: one key per person.
  static String keyOf(RelayFriend friend) =>
      PeerShareCodec.normalizeAddress(friend.address);

  /// When [device] was last seen. The friend's own last sign of life (from
  /// any of their devices) tells about [device] only when it is their only
  /// one: a friend whose old phone is gone looks alive through the new one.
  int seenAt(String device) {
    final RelayFriend? friend = owner[device];
    final int heard = reach(device)?.heardAtMillis ?? 0;
    return max(
      heard,
      friend != null && friend.devices.isEmpty ? friend.lastSeenAtMillis : 0,
    );
  }

  /// Since when [device] has gone quiet as a mailbox, 0 when it has not.
  ///
  /// A device this device has asked: not heard from for
  /// [RelayConfig.staleRelayAfter], with asks going unanswered for at least
  /// [RelayConfig.quietObservedFor] (this device coming back after a week
  /// away does not make its mailboxes quiet with one missed poll). A device
  /// never asked: not seen for [RelayConfig.staleRelayAfter] (never seen at
  /// all is not quiet).
  int quietSince(String device) {
    final int stale = config.staleRelayAfter.inMilliseconds;
    final RelayReach? r = reach(device);
    if (r != null && r.wasAsked) {
      if (r.failingSinceMillis == 0) {
        return 0;
      }
      final int since = r.heardAtMillis > 0
          ? r.heardAtMillis
          : r.failingSinceMillis;
      return nowMillis - since >= stale &&
              nowMillis - r.failingSinceMillis >=
                  config.quietObservedFor.inMilliseconds
          ? since
          : 0;
    }
    final int seen = seenAt(device);
    return seen > 0 && nowMillis - seen > stale ? seen : 0;
  }

  bool quiet(String device) => quietSince(device) > 0;

  /// See [RelayReach.quality].
  double quality(String device) {
    final RelayDeviceClass kind = deviceClass(device);
    final RelayReach? r = reach(device);
    return r == null
        ? kind.prior
        : r.quality(kind, nowMillis, config.reachHalfLife);
  }

  int _tier(String device) => (owner[device]?.closeness ?? 0) > 0 ? 1 : 0;

  /// Negative when [a] makes the better mailbox (see
  /// [RelayEngine.rankRelays]). Quality counts in steps of a tenth, so a
  /// hair's difference in answers does not outweigh closeness.
  int compare(String a, String b) {
    final int byQuiet = (quiet(a) ? 1 : 0).compareTo(quiet(b) ? 1 : 0);
    if (byQuiet != 0) {
      return byQuiet;
    }
    final int byTier = _tier(b).compareTo(_tier(a));
    if (byTier != 0) {
      return byTier;
    }
    final int byQuality = (quality(b) * 10).round().compareTo(
      (quality(a) * 10).round(),
    );
    if (byQuality != 0) {
      return byQuality;
    }
    final int byLevel = (owner[b]?.closeness ?? 0).compareTo(
      owner[a]?.closeness ?? 0,
    );
    return byLevel != 0 ? byLevel : seenAt(b).compareTo(seenAt(a));
  }

  /// The best of [friend]'s devices.
  String bestOf(RelayFriend friend) =>
      (friend.allAddresses.toList()..sort(compare)).first;

  /// What could take [mailbox]'s place among [kept], best first: the best
  /// device of each friend not in [kept] and the friend's own other
  /// devices, never one that has gone quiet.
  List<String> optionsFor(String mailbox, Iterable<String> kept) {
    final Set<String> taken = <String>{
      for (final String a in kept)
        if (owner[a] != null) keyOf(owner[a]!),
    };
    final RelayFriend? own = owner[mailbox];
    return <String>[
      for (final RelayFriend f in friends)
        if (!taken.contains(keyOf(f))) bestOf(f),
      if (own != null)
        for (final String a in own.allAddresses)
          if (a != mailbox) a,
    ].where((String a) => !quiet(a)).toList()..sort(compare);
  }

  /// The automatic set (see [RelayEngine.rankRelays]).
  List<String> rank({required List<String> current, required bool mayReplace}) {
    final List<String> kept = <String>[];
    final Set<String> taken = <String>{};
    for (final String raw in current) {
      final String a = PeerShareCodec.normalizeAddress(raw);
      final RelayFriend? friend = owner[a];
      if (friend == null || !taken.add(keyOf(friend))) {
        continue; // no friend any more, or one of theirs is there already
      }
      kept.add(a);
      if (kept.length >= config.maxRelays) {
        break;
      }
    }
    final List<String> candidates = <String>[
      for (final RelayFriend f in friends)
        if (!taken.contains(keyOf(f))) bestOf(f),
    ]..sort(compare);
    // Empty places first.
    while (kept.length < config.maxRelays && candidates.isNotEmpty) {
      kept.add(candidates.removeAt(0));
    }
    if (!mayReplace || kept.isEmpty) {
      return kept;
    }
    // Then at most one replacement: the worst mailbox, if it went quiet or
    // a far better device is there.
    final String worst = (List<String>.of(kept)..sort(compare)).last;
    final List<String> options = optionsFor(worst, kept);
    if (options.isEmpty) {
      return kept;
    }
    final String best = options.first;
    final bool replace = quiet(worst)
        ? quality(best) >= kMinMailboxQuality
        // Not while it is away right now: an outage is waited out until it
        // is quiet; a far better device replaces only one that answers but
        // is often away.
        : (reach(worst)?.failingSinceMillis ?? 0) == 0 &&
              _tier(best) >= _tier(worst) &&
              quality(best) - quality(worst) >= kMailboxQualityGap;
    if (replace) {
      kept[kept.indexOf(worst)] = best;
    }
    return kept;
  }

  /// The person's own choice of friends ([chosen], the addresses the app
  /// knows them by), each served by one of their devices: the one serving
  /// already ([current]) unless it went quiet and another of theirs did
  /// not, otherwise the best.
  List<String> resolve(List<String> chosen, {required List<String> current}) {
    final Set<String> serving = current
        .map(PeerShareCodec.normalizeAddress)
        .toSet();
    final Set<String> taken = <String>{};
    final List<String> out = <String>[];
    for (final String raw in chosen) {
      final RelayFriend? friend = owner[PeerShareCodec.normalizeAddress(raw)];
      if (friend == null || !taken.add(keyOf(friend))) {
        continue;
      }
      final List<String> devices = friend.allAddresses.toList()..sort(compare);
      String pick = devices.firstWhere(
        serving.contains,
        orElse: () => devices.first,
      );
      if (quiet(pick) && !quiet(devices.first)) {
        pick = devices.first;
      }
      out.add(pick);
      if (out.length >= config.maxRelays) {
        break;
      }
    }
    return out;
  }
}

extension _RelayEngineMailboxes on RelayEngine {
  /// Something came from [address] at [now]: if it is a friend's device,
  /// what it was asked is answered.
  void _heardFrom(RelayState state, String address, int now) {
    if (address.isEmpty || address == _self) {
      return;
    }
    RelayReach? reach = state.reach[address];
    if (reach == null) {
      if (!_isAcceptedFriend(address)) {
        return;
      }
      reach = state.reach[address] = RelayReach();
    }
    reach.heard(now, config.reachHalfLife);
    if (_reachDirtySince == 0) {
      _reachDirtySince = now;
    }
  }

  /// Something that wants an answer goes to [address] at [now].
  void _askedOf(RelayState state, String address, int now) {
    if (address.isEmpty || address == _self) {
      return;
    }
    RelayReach? reach = state.reach[address];
    if (reach == null) {
      if (!_isAcceptedFriend(address)) {
        return;
      }
      reach = state.reach[address] = RelayReach();
    }
    reach.asked(
      now,
      answerWithin: config.answerWithin,
      halfLife: config.reachHalfLife,
    );
    if (_reachDirtySince == 0) {
      _reachDirtySince = now;
    }
  }

  /// Polls the mailbox [relay], asking for a word even when it holds
  /// nothing.
  Future<void> _probe(RelayState state, String relay, int now) async {
    _askedOf(state, relay, now);
    await _sendQuietly(relay, const <String, dynamic>{
      'type': 'rly_poll',
      kRelayProbeKey: true,
    });
  }

  /// This device's kind changed (or was never announced): friends hear it
  /// with the next announcement.
  bool _noteOwnClass(RelayState state) {
    final String wire = _deviceClass().wire;
    if (wire == state.announcedClass) {
      return false;
    }
    state.announcedClass = wire;
    state.relaySetVersion += 1;
    _lastAnnounceAt.clear();
    return true;
  }

  /// The person each of [RelayState.currentRelays] belongs to, how good a
  /// mailbox each friend makes, and the mailboxes the person should
  /// replace (see [RelayOverview]).
  ({
    List<String> friends,
    Map<String, RelayMailboxCandidate> candidates,
    List<RelayQuietMailbox> quiet,
  })
  _mailboxView(RelayState state) {
    final int now = _now();
    final _MailboxJudge judge = _judgeOf(state, now);
    final Set<String> current = state.currentRelays.toSet();
    final Map<String, RelayMailboxCandidate> candidates =
        <String, RelayMailboxCandidate>{};
    for (final RelayFriend friend in judge.friends) {
      final String key = _MailboxJudge.keyOf(friend);
      final String device = friend.allAddresses.firstWhere(
        current.contains,
        orElse: () => judge.bestOf(friend),
      );
      candidates[key] = RelayMailboxCandidate(
        friend: key,
        device: device,
        deviceClass:
            state.peers[device]?.deviceClass ?? RelayDeviceClass.unknown,
        quality: judge.quality(device),
        answeredShare: state.reach[device]?.answeredShare(
          now,
          config.reachHalfLife,
        ),
        heardAtMillis: state.reach[device]?.heardAtMillis ?? 0,
        quietSinceMillis: judge.quietSince(device),
        deviceClasses: <RelayDeviceClass>[
          for (final RelayDeviceClass kind in RelayDeviceClass.values)
            if (kind != RelayDeviceClass.unknown &&
                friend.allAddresses.any(
                  (String a) => state.peers[a]?.deviceClass == kind,
                ))
              kind,
        ],
      );
    }
    final List<RelayQuietMailbox> quiet = <RelayQuietMailbox>[];
    for (final String device in state.currentRelays) {
      final int since = judge.quietSince(device);
      if (since == 0) {
        continue;
      }
      // The automatic choice replaces it by itself when it can.
      if (state.manualRelays == null &&
          judge
              .optionsFor(device, state.currentRelays)
              .any((String o) => judge.quality(o) >= kMinMailboxQuality)) {
        continue;
      }
      final RelayFriend? friend = judge.owner[device];
      quiet.add(
        RelayQuietMailbox(
          friend: friend == null ? device : _MailboxJudge.keyOf(friend),
          device: device,
          sinceMillis: since,
          told: state.quietTold[device] == since,
        ),
      );
    }
    return (
      friends: <String>[
        for (final String a in state.currentRelays)
          judge.owner[a] == null ? a : _MailboxJudge.keyOf(judge.owner[a]!),
      ],
      candidates: candidates,
      quiet: quiet,
    );
  }

  /// What [RelayOverview.quiet] would be now, as a number that changes when
  /// it does.
  int _quietSignatureOf(RelayState state) => Object.hashAll(<Object>[
    for (final RelayQuietMailbox q in _mailboxView(state).quiet)
      Object.hash(q.device, q.sinceMillis, q.told),
  ]);
}
