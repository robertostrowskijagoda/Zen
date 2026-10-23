import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What the routing needs to know about accounts and their devices (the
/// ledger knows it, see `LedgerNode`).
abstract interface class AccountDeviceDirectory {
  /// This account ('' while unknown).
  String get ownAccount;

  /// Account of a mesh address (a friend, a friend's other device, an own
  /// device), or `null`.
  String? accountOf(String address);

  /// Every known address of [account] (never this device's own).
  List<String> addressesOf(String account);

  /// The address the app knows [account] by (the friend's entry), or
  /// `null` when it is not a contact.
  String? contactAddressOf(String account);

  /// The account whose device at [address] its owner unlinked (a lost or
  /// stolen phone), or `null`: nothing goes there and nothing from there
  /// is taken; the account's other devices stand in for it.
  String? unlinkedAccountOf(String address);
}

/// Called on this device for something another device of the account sent
/// to [peer] (so the conversation shows it here too).
typedef MirroredSend =
    Future<void> Function(String peer, Map<String, dynamic> payload);

/// Messages another own device sent, copied here: `{type, to, p}`.
const String kMirrorType = 'acct_mirror';

/// What is copied to the account's other devices: text messages, the
/// disappearing-messages timer (those messages never go into the ledger's
/// lasting copies, so this live copy is how the other devices see them),
/// and reactions, edits and deletions of messages (1:1 and groups), so the
/// conversation looks the same on each.
const Set<String> kMirroredTypes = <String>{
  'message',
  'disappear_timer',
  'msg_react',
  'msg_edit',
  'msg_delete',
};

/// Whether [payload] is copied to the account's other devices.
bool isMirroredPayload(Map<String, dynamic> payload) =>
    kMirroredTypes.contains(payload['type']) ||
    (payload['type'] == 'group_message' && payload['ttl'] is int);

/// Call signals after which one device "owns" the call.
const Set<String> _callCommit = <String>{
  'call_accept',
  'call_answer',
  'call_offer',
  'call_offer_request',
};

/// Makes an account with several devices look like one person to the app
/// (several devices), without the app knowing:
///
/// * whatever the app sends to a friend goes to every device of the
///   friend's account;
/// * whatever any of those devices sends arrives as if from the address the
///   app knows the friend by;
/// * a call belongs to the device that answered it: from then on its
///   signals go there only, and the friend's other devices stop ringing;
/// * text messages sent from here are copied to this account's other
///   devices, so the conversation is complete on each;
/// * a device its owner unlinked (a lost or stolen phone) gets nothing and
///   is not heard, even at the address the app knows the friend by: what
///   the app sends there goes to the account's other devices.
final class AccountRoutingTransport implements SignalTransport {
  AccountRoutingTransport({
    required this.delegate,
    required AccountDeviceDirectory? Function() directory,
    MirroredSend? onMirrored,
  }) : _directory = directory,
       _onMirrored = onMirrored;

  /// The transport underneath (the ledger and account linking use it
  /// directly).
  final SignalTransport delegate;
  final AccountDeviceDirectory? Function() _directory;
  MirroredSend? _onMirrored;

  set onMirrored(MirroredSend? value) => _onMirrored = value;

  /// Call id → the device that took the call.
  final Map<String, String> _callOwner = <String, String>{};

  late final Stream<SignalTransportFrame> _frames = delegate.frames
      .asyncExpand(_route)
      .asBroadcastStream();

  @override
  Stream<SignalTransportFrame> get frames => _frames;

  Stream<SignalTransportFrame> _route(SignalTransportFrame frame) async* {
    final AccountDeviceDirectory? dir = _directory();
    if (dir == null || dir.ownAccount.isEmpty) {
      yield frame;
      return;
    }
    if (dir.unlinkedAccountOf(frame.from) != null) {
      // Whoever holds an unlinked device is not that person any more.
      return;
    }
    final String? acc = dir.accountOf(frame.from);
    final Object? type = frame.payload['type'];
    if (type == kMirrorType) {
      // Only another device of this very account may say "I sent this".
      if (acc == dir.ownAccount) {
        final Object? to = frame.payload['to'];
        final Object? p = frame.payload['p'];
        if (to is String && p is Map<String, dynamic>) {
          try {
            await _onMirrored?.call(to, p);
          } on Object catch (error, stack) {
            logZenError('Kopia wiadomości z innego urządzenia', error, stack);
          }
        }
      }
      return;
    }
    if (acc == null || acc == dir.ownAccount) {
      yield frame;
      return;
    }
    final String? contact = dir.contactAddressOf(acc);
    final Object? callId = frame.payload['callId'];
    if (callId is String && callId.isNotEmpty) {
      _onCallSignal(dir, acc, callId, type, frame.from);
    }
    if (contact == null || PeerShareCodec.addressesEqual(contact, frame.from)) {
      yield frame;
      return;
    }
    yield SignalTransportFrame(
      from: contact,
      payload: frame.payload,
      receivedAtMillis: frame.receivedAtMillis,
    );
  }

  void _onCallSignal(
    AccountDeviceDirectory dir,
    String acc,
    String callId,
    Object? type,
    String from,
  ) {
    if (type == 'call_invite') {
      // The device that calls owns the call on that side.
      _callOwner.putIfAbsent(callId, () => from);
      return;
    }
    final bool commit = _callCommit.contains(type);
    final bool declined = type == 'call_decline';
    if ((!commit && !declined) || _callOwner.containsKey(callId)) {
      return;
    }
    if (commit) {
      _callOwner[callId] = from;
      if (_callOwner.length > 200) {
        _callOwner.remove(_callOwner.keys.first);
      }
    }
    // Answered (or declined) on one device: the others stop ringing.
    for (final String other in dir.addressesOf(acc)) {
      if (!PeerShareCodec.addressesEqual(other, from)) {
        unawaited(
          _sendQuietly(other, <String, dynamic>{
            'type': 'call_end',
            'callId': callId,
          }),
        );
      }
    }
  }

  Future<void> _sendQuietly(String to, Map<String, dynamic> payload) async {
    try {
      await delegate.send(remoteAddress: to, payload: payload);
    } on Object catch (error) {
      logZenWarning('Wysłanie do innego urządzenia nie udało się: $error');
    }
  }

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final AccountDeviceDirectory? dir = _directory();
    final String? unlinked = dir?.unlinkedAccountOf(remoteAddress);
    if (dir != null && unlinked != null) {
      // Never to the unlinked device: to the account's other devices.
      for (final String other in dir.addressesOf(unlinked)) {
        if (!PeerShareCodec.addressesEqual(other, remoteAddress)) {
          await _sendQuietly(other, payload);
        }
      }
      await _mirror(dir, remoteAddress, payload);
      return;
    }
    final String? acc = dir?.accountOf(remoteAddress);
    if (dir != null && acc != null && acc == dir.ownAccount) {
      // Another device of this account (e.g. listed in a group): it gets
      // what the account gets from others, never a copy addressed to it.
      return;
    }
    if (dir == null || acc == null) {
      await delegate.send(remoteAddress: remoteAddress, payload: payload);
      // Someone outside any known account: only group traffic (a member who
      // is not a friend) is copied; a direct message to a stranger is not.
      if (payload['type'] != 'message') {
        await _mirror(dir, remoteAddress, payload);
      }
      return;
    }
    final Object? callId = payload['callId'];
    final String? owner = callId is String ? _callOwner[callId] : null;
    if (owner != null) {
      await delegate.send(remoteAddress: owner, payload: payload);
      if (payload['type'] == 'call_end') {
        _callOwner.remove(callId);
      }
      return;
    }
    final Set<String> targets = <String>{
      PeerShareCodec.normalizeAddress(remoteAddress),
      for (final String a in dir.addressesOf(acc))
        PeerShareCodec.normalizeAddress(a),
    };
    // The address the app chose must get it (errors count); the other
    // devices are best effort.
    await delegate.send(remoteAddress: remoteAddress, payload: payload);
    for (final String t in targets) {
      if (!PeerShareCodec.addressesEqual(t, remoteAddress)) {
        await _sendQuietly(t, payload);
      }
    }
    await _mirror(dir, remoteAddress, payload);
  }

  /// A copy of what this device sent, for the account's other devices.
  Future<void> _mirror(
    AccountDeviceDirectory? dir,
    String remoteAddress,
    Map<String, dynamic> payload,
  ) async {
    if (dir == null || dir.ownAccount.isEmpty || !isMirroredPayload(payload)) {
      return;
    }
    for (final String sibling in dir.addressesOf(dir.ownAccount)) {
      await _sendQuietly(sibling, <String, dynamic>{
        'type': kMirrorType,
        'to': remoteAddress,
        'p': payload,
      });
    }
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) => delegate.openRelay(
    callId: callId,
    remoteAddress: _callOwner[callId] ?? remoteAddress,
  );

  @override
  Future<void> closeRelay(String callId) => delegate.closeRelay(callId);

  @override
  Future<void> start() => delegate.start();

  @override
  Future<void> stop() => delegate.stop();
}

/// Filled in by whoever knows the accounts (the ledger) once it runs.
final class AccountDirectoryHolder {
  AccountDeviceDirectory? directory;

  /// Where copies from the account's other devices go (the social hub).
  MirroredSend? mirrored;

  /// The user removed a friend / left a group here: the account's other
  /// devices follow (the ledger records it).
  void Function(String address)? friendRemoved;
  void Function(String groupId)? groupLeft;
}

final Provider<AccountDirectoryHolder> accountDirectoryHolderProvider =
    Provider<AccountDirectoryHolder>((Ref ref) => AccountDirectoryHolder());

/// [base] wrapped in account routing (see [AccountRoutingTransport]).
AccountRoutingTransport withAccountRouting(Ref ref, SignalTransport base) {
  final AccountDirectoryHolder holder = ref.read(
    accountDirectoryHolderProvider,
  );
  return AccountRoutingTransport(
    delegate: base,
    directory: () => holder.directory,
    onMirrored: (String peer, Map<String, dynamic> payload) async =>
        holder.mirrored?.call(peer, payload),
  );
}

/// The transport without account routing: what the ledger, account
/// linking and recovery use (they talk to one device, by its address).
SignalTransport meshOf(SignalTransport transport) =>
    transport is AccountRoutingTransport ? transport.delegate : transport;

final Provider<SignalTransport> meshTransportProvider =
    Provider<SignalTransport>(
      (Ref ref) => meshOf(ref.watch(signalTransportProvider)),
    );
