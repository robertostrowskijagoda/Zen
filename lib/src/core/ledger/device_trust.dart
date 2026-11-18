/// Which devices of one account count, judged from what one phone knows
/// of them: their certificates with co-signatures, the cut-offs, and when
/// this phone first saw each device and got each cut-off
/// (docs/SECURITY_MODEL.md, "Cutting a device off").
///
/// The account key alone cannot decide this: every device of the account
/// holds it, so whoever stole one unlocked (and knows the account
/// password) can sign anything the account can. What the thief does not
/// have is the device keys of the owner's other devices, and time:
///
/// * a device co-signed by a device that counts, counts at once;
/// * any other device (restored from paper, a file or friends, or made by
///   a thief) counts only [kNewDeviceWait] after this phone first saw it,
///   and a device that counts can cut it off in that time (a veto, which
///   the vetoed device can never answer);
/// * a cut-off counts only when a device that could count signed it;
/// * a cut-off names the devices its signer keeps: what its target
///   co-signed, and any device certified before it without a co-signature
///   from a kept device, is left out with the target;
/// * cut-offs that leave out each other's signer, made within
///   [kNewDeviceWait] of each other here, all count (two devices that cut
///   each other off are both cut off); one that stood here that long
///   unanswered is settled, and a later one cannot undo it.
///
/// Pure: the caller hands in what it knows and the time. An account whose
/// devices never co-signed anything (`strict` false: all from before
/// co-signatures) keeps the old rule: every certified device counts unless
/// a cut-off signed by the account key names it.
library;

/// How long a device without a co-signature waits before it counts, and
/// how long a cut-off can be answered.
const Duration kNewDeviceWait = Duration(hours: 24);

/// Devices first seen within this time of the first device of an account
/// a phone ever saw count at once: when someone meets an account, its
/// devices come one by one, and nobody could veto them for a new friend.
const Duration kFirstContactWindow = Duration(hours: 1);

/// One device of the account as this phone knows it.
final class TrustDevice {
  const TrustDevice({
    required this.id,
    required this.issued,
    required this.readyAt,
    this.coBy,
  });

  final String id;

  /// The device (another one of the account) whose co-signature this
  /// device's certificate carries, checked; null for none.
  final String? coBy;

  /// When the account certified it (its certificate's word).
  final int issued;

  /// From when it counts without a co-signature (ms): first seen here plus
  /// [kNewDeviceWait], or first seen when it came with the first contact.
  /// The smallest int for this phone itself.
  final int readyAt;
}

/// One cut-off of a device of the account.
final class TrustCut {
  const TrustCut({
    required this.id,
    required this.target,
    required this.issued,
    required this.receivedAt,
    this.by,
    this.keep,
  });

  final String id;

  /// The device cut off.
  final String target;

  /// The device that signed it (checked); null for one the account key
  /// alone signed. In a strict judgement such a one is handed in only
  /// when this phone took it before the account used co-signatures, and
  /// it counts as it did then.
  final String? by;

  /// The devices its signer keeps; null for none named.
  final Set<String>? keep;

  /// When it was made (its signer's word).
  final int issued;

  /// When this phone got it.
  final int receivedAt;
}

/// What [judgeDevices] decided.
final class TrustVerdict {
  const TrustVerdict({
    required this.counting,
    required this.pendingUntil,
    required this.cuts,
    required this.signers,
  });

  /// The devices that count now.
  final Set<String> counting;

  /// The devices whose cut-offs are judged at all: those that would count
  /// were nothing cut off.
  final Set<String> signers;

  /// Devices that do not count yet and will at the given time (ms) unless
  /// cut off before.
  final Map<String, int> pendingUntil;

  /// The cut-offs that count, by target device.
  final Map<String, List<TrustCut>> cuts;

  /// Whether [device] is cut off (or left out by a cut-off) for good:
  /// neither counting nor waiting.
  bool isOut(String device) =>
      !counting.contains(device) && !pendingUntil.containsKey(device);
}

/// Most steps up a chain of co-signatures (a chain is never longer than
/// the account's devices; this bounds a made-up loop).
const int _maxChain = 64;

/// Judges the devices of one account at [now] (ms).
TrustVerdict judgeDevices({
  required bool strict,
  required Map<String, TrustDevice> devices,
  required List<TrustCut> cuts,
  required int now,
}) {
  if (!strict) {
    final Map<String, List<TrustCut>> byTarget = <String, List<TrustCut>>{};
    for (final TrustCut c in cuts) {
      (byTarget[c.target] ??= <TrustCut>[]).add(c);
    }
    final Set<String> counting = <String>{
      for (final String d in devices.keys)
        if (!byTarget.containsKey(d)) d,
    };
    return TrustVerdict(
      counting: counting,
      pendingUntil: const <String, int>{},
      cuts: byTarget,
      signers: counting,
    );
  }
  return _StrictJudge(devices, cuts, now).judge();
}

/// How a cut-off leaves a device out.
enum _Reach { none, target, descendant, older }

final class _StrictJudge {
  _StrictJudge(this.devices, this.cuts, this.now);

  final Map<String, TrustDevice> devices;
  final List<TrustCut> cuts;
  final int now;

  static final int _wait = kNewDeviceWait.inMilliseconds;

  /// The co-signer of [d] when it is another known device.
  String? _co(String d) {
    final String? by = devices[d]?.coBy;
    return by != null && by != d && devices.containsKey(by) ? by : null;
  }

  bool _ready(String d) => now >= devices[d]!.readyAt;

  /// [d], its co-signer, that one's co-signer… (no device twice).
  List<String> _chain(String d) {
    final List<String> out = <String>[d];
    String? next = _co(d);
    while (next != null && !out.contains(next) && out.length < _maxChain) {
      out.add(next);
      next = _co(next);
    }
    return out;
  }

  /// The least set closed under: a device in [allowed] that is ready, or
  /// whose co-signer is in the set.
  Set<String> _closure(bool Function(String d) allowed) {
    final Set<String> out = <String>{};
    bool grew = true;
    while (grew) {
      grew = false;
      for (final String d in devices.keys) {
        if (out.contains(d) || !allowed(d)) {
          continue;
        }
        final String? co = _co(d);
        if (_ready(d) || (co != null && out.contains(co))) {
          out.add(d);
          grew = true;
        }
      }
    }
    return out;
  }

  /// Whether and how cut-off [c] leaves [d] out: [d] is its target, or
  /// co-signed (through a chain) by its target before any kept device;
  /// or, when [c] names what it keeps, [d] reaches no kept device and was
  /// certified before [c] was made.
  _Reach _reach(TrustCut c, String d) {
    final Set<String>? keep = c.keep;
    for (final String x in _chain(d)) {
      if (x == c.target) {
        return x == d ? _Reach.target : _Reach.descendant;
      }
      if (x == c.by || (keep?.contains(x) ?? false)) {
        return _Reach.none;
      }
    }
    final TrustDevice? known = devices[d];
    return keep != null && known != null && known.issued <= c.issued
        ? _Reach.older
        : _Reach.none;
  }

  /// Whether [c] reached this phone before its target could count here:
  /// a veto of a device without a co-signature.
  bool _isVeto(TrustCut c, Set<String> base) {
    final TrustDevice? t = devices[c.target];
    if (t == null) {
      return true;
    }
    final String? co = _co(c.target);
    if (co != null && base.contains(co)) {
      return false;
    }
    return c.receivedAt < t.readyAt;
  }

  TrustVerdict judge() {
    // Who could count, cut-offs aside: only they sign cut-offs that count.
    final Set<String> base = _closure((_) => true);
    // Signed by the account key alone: handed in only when this phone took
    // it before the account used co-signatures; it counts as it did then.
    final List<TrustCut> unsigned = <TrustCut>[
      for (final TrustCut c in cuts)
        if (c.by == null) c,
    ];
    final List<TrustCut> signed = <TrustCut>[
      for (final TrustCut c in cuts)
        if (c.by != null && c.by != c.target && base.contains(c.by)) c,
    ];
    final Set<TrustCut> vetoes = <TrustCut>{
      for (final TrustCut c in signed)
        if (_isVeto(c, base)) c,
    };
    // Whether [other] (when it counts) undoes [c] by leaving [c]'s signer
    // out directly or as what [c]'s signer's co-signer vouched for. Never
    // when [other] came a day or more after [c] (an answer too late), nor
    // when [c] is a veto of [other]'s signer.
    bool strongly(TrustCut other, TrustCut c) {
      if (identical(other, c) ||
          other.receivedAt >= c.receivedAt + _wait ||
          (vetoes.contains(c) && c.target == other.by)) {
        return false;
      }
      final _Reach r = _reach(other, c.by!);
      return r == _Reach.target || r == _Reach.descendant;
    }

    // Leaving out an older device the signer did not keep is weaker: it
    // does not undo a cut-off that leaves its own signer out.
    bool undoes(TrustCut other, TrustCut c) {
      if (strongly(other, c)) {
        return true;
      }
      if (identical(other, c) ||
          other.receivedAt >= c.receivedAt + _wait ||
          (vetoes.contains(c) && c.target == other.by) ||
          _reach(other, c.by!) != _Reach.older) {
        return false;
      }
      return other.by == null || !strongly(c, other);
    }

    final Map<TrustCut, List<TrustCut>> undoers = <TrustCut, List<TrustCut>>{
      for (final TrustCut c in signed)
        c: <TrustCut>[
          for (final TrustCut other in <TrustCut>[...unsigned, ...signed])
            if (undoes(other, c)) other,
        ],
    };
    // Decided from the bottom up: a cut-off counts once everything that
    // could undo it is known not to count, and does not once one that
    // counts undoes it. What stays undecided (cut-offs undoing each other,
    // two devices cutting each other off) counts: in doubt, cut off.
    final Map<TrustCut, bool> counts = <TrustCut, bool>{
      for (final TrustCut c in unsigned) c: true,
    };
    bool changed = true;
    while (changed) {
      changed = false;
      for (final TrustCut c in signed) {
        if (counts.containsKey(c)) {
          continue;
        }
        final List<TrustCut> by = undoers[c]!;
        if (by.any((TrustCut o) => counts[o] == true)) {
          counts[c] = false;
          changed = true;
        } else if (by.every((TrustCut o) => counts[o] == false)) {
          counts[c] = true;
          changed = true;
        }
      }
    }
    final List<TrustCut> counting = <TrustCut>[
      ...unsigned,
      for (final TrustCut c in signed)
        if (counts[c] ?? true) c,
    ];
    final Set<String> out = <String>{
      for (final String d in devices.keys)
        if (counting.any((TrustCut c) => _reach(c, d) != _Reach.none)) d,
    };
    final Set<String> trusted = _closure((String d) => !out.contains(d));
    final Map<String, int> pending = <String, int>{
      for (final String d in devices.keys)
        if (!trusted.contains(d) && !out.contains(d) && !_ready(d))
          d: devices[d]!.readyAt,
    };
    final Map<String, List<TrustCut>> byTarget = <String, List<TrustCut>>{};
    for (final TrustCut c in counting) {
      (byTarget[c.target] ??= <TrustCut>[]).add(c);
    }
    return TrustVerdict(
      counting: trusted,
      pendingUntil: pending,
      cuts: byTarget,
      signers: base,
    );
  }
}
