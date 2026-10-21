import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/neighbors/flat_door_mail.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// Tells knocks apart while Zen is locked (the Android background service,
/// `LockedReceiver`), without the master key: from the door kit only — the
/// household's public key, the door token and the household's sealing seed
/// ([flatSealSeed]), which opens sealed knocks and nothing else. Neither
/// signs nor answers anything: the frames wait in the sealed inbox, and the
/// neighbours section handles them after unlock. It only says "someone
/// knocks", so the phone can ring "Ktoś puka do drzwi" right away.
///
/// A knock counts when it is signed by the knocking flat, addressed to this
/// household and carries the current door token (an old sticker's knocks,
/// or a neighbour who only knows a door address, do not ring). It may come
/// straight to the door, sealed to this phone's door (a housemate's
/// sticker), sealed through a friend's mailbox door (`flat_held`), or
/// passed on by a housemate who just got it (`flat_house` with `ring`,
/// signed with the household's key).
final class LockedKnockWatch {
  LockedKnockWatch({
    required this.flatKey,
    required this.doorToken,
    required String sealSeed,
    this.tempTokens = const <String, int>{},
    int Function()? now,
  }) : _sealSeed = sealSeed,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// The household's public key.
  final String flatKey;

  /// The token of the current door sticker.
  final String doorToken;

  /// Short-lived tokens of invitations passed nearby (token → until when).
  final Map<String, int> tempTokens;

  /// Whether [token] opens the door now.
  bool _opens(Object? token) =>
      token == doorToken ||
      (token is String && (tempTokens[token] ?? 0) > _now());
  final String _sealSeed;
  final int Function() _now;
  RelayIdentity? _seal;
  bool _sealTried = false;

  /// Notifications of the last hour (when, which flat).
  final List<(int, String)> _rings = <(int, String)>[];

  /// The knocking flat (its key) when [frame] is a knock for this
  /// household, else `null`.
  Future<String?> knocker(SignalTransportFrame frame) async {
    final Map<String, dynamic> p = frame.payload;
    final Object? type = p['type'];
    try {
      if (frame.door && type == FlatTypes.hello) {
        return await _knock(p);
      }
      if ((frame.door && type == FlatTypes.seal) ||
          (!frame.door && type == FlatTypes.held)) {
        final Object? at = p['at'];
        if (type == FlatTypes.held &&
            (at is! int || _now() - at >= kHeldKnockLife.inMilliseconds)) {
          return null;
        }
        final Map<String, dynamic>? inner = await _open(p);
        return inner == null ? null : await _knock(inner);
      }
      if (!frame.door && type == FlatTypes.house) {
        return await _passedOn(p);
      }
    } on Object {
      return null;
    }
    return null;
  }

  /// Whether a knock from [flat] may ring now: as in the app, once an hour
  /// per knocker and [kKnockRingsPerHour] an hour in all.
  bool mayRing(String flat) {
    const int hour = 3600 * 1000;
    final int now = _now();
    _rings.removeWhere(((int, String) r) => now - r.$1 >= hour);
    if (_rings.length >= kKnockRingsPerHour ||
        _rings.any(((int, String) r) => r.$2 == flat)) {
      return false;
    }
    _rings.add((now, flat));
    return true;
  }

  /// The knocker of the signed knock [e], when it is one for this door.
  Future<String?> _knock(Map<String, dynamic> e) async {
    final Object? from = e['f'];
    final Object? to = e['to'];
    final Object? body = e['b'];
    final Object? sig = e['s'];
    if (e['type'] != FlatTypes.hello ||
        from is! String ||
        to != flatKey ||
        from == flatKey ||
        body is! Map ||
        sig is! String ||
        !_opens(body['door'])) {
      return null;
    }
    final bool ok = await verifyLedgerSignature(
      publicKey: from,
      message: canonicalJsonBytes(<String, dynamic>{
        'type': FlatTypes.hello,
        'f': from,
        'to': to,
        'b': body,
      }),
      signature: sig,
    );
    return ok ? from : null;
  }

  /// What a knocker sealed for this household, or `null`.
  Future<Map<String, dynamic>?> _open(Map<String, dynamic> p) async {
    final List<int>? seed = flatUnhex(_sealSeed);
    if (!_sealTried) {
      _sealTried = true;
      _seal = seed == null ? null : await flatSealIdentity(seed);
    }
    final RelayIdentity? seal = _seal;
    if (seal == null || seed == null) {
      return null;
    }
    final int now = _now();
    Map<String, dynamic>? box;
    for (final String token in <String>[
      doorToken,
      for (final MapEntry<String, int> t in tempTokens.entries)
        if (t.value > now) t.key,
    ]) {
      box = await FlatSeal.open(
        p,
        seal,
        doorToken: token,
        kemSeed: flatSealKemSeed(seed),
      );
      if (box != null || p['p'] != 1) {
        break;
      }
    }
    final Object? e = box?['e'];
    return e is Map ? Map<String, dynamic>.from(e) : null;
  }

  /// The newest knock a housemate passed on as it came ([e]: their shared
  /// state, signed with the household's key, marked to ring).
  Future<String?> _passedOn(Map<String, dynamic> e) async {
    final Object? body = e['b'];
    final Object? sig = e['s'];
    if (e['f'] != flatKey ||
        e['to'] != flatKey ||
        body is! Map ||
        sig is! String ||
        body['ring'] != true) {
      return null;
    }
    final Object? list = body['kn'];
    final FlatKnock? newest = list is List && list.isNotEmpty
        ? FlatKnock.fromJson(list.first)
        : null;
    if (newest == null || _now() - newest.at >= kHeldKnockLife.inMilliseconds) {
      return null;
    }
    final bool ok = await verifyLedgerSignature(
      publicKey: flatKey,
      message: canonicalJsonBytes(<String, dynamic>{
        'type': FlatTypes.house,
        'f': flatKey,
        'to': flatKey,
        'b': body,
      }),
      signature: sig,
    );
    return ok ? newest.key : null;
  }
}
