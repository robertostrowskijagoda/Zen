import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// What the unlocked app does around the locked receiver, the same on
// Android (android_background_runtime.dart) and on an iPhone
// (ios_background.dart): it tells the receiver whom to take mail from
// ([BackgroundCapabilityPublisher]) and, after unlock, opens what the
// receiver kept ([drainLockedInbox]).

/// Publishes the [BackgroundCapability] whenever what it says changes: the
/// public part of the inbox key (derived again for a new master key: an
/// inbox sealed for the old one would never open), the contacts and the
/// mailboxes.
final class BackgroundCapabilityPublisher {
  BackgroundCapabilityPublisher(this._vault);

  final BackgroundVault _vault;
  Uint8List? _inboxPublicKey;

  /// Fingerprint of the master key [_inboxPublicKey] belongs to.
  String? _inboxKeyOwner;
  String? _publishedSignature;

  /// Publishes the capability for [state] unless it says what the last one
  /// said. Nothing without a [masterKey] (locked) unless a key was derived
  /// before.
  Future<void> publish({
    required Uint8List? masterKey,
    required SocialHubState state,
    AccountDeviceDirectory? directory,
    List<String> mailboxes = const <String>[],
  }) async {
    Uint8List? publicKey = _inboxPublicKey;
    if (masterKey != null) {
      final String owner = securityHexFromBytes(
        securityMasterFingerprint(masterKey),
      );
      if (publicKey == null || owner != _inboxKeyOwner) {
        publicKey = await inboxPublicKeyFor(masterKey);
        _inboxPublicKey = publicKey;
        _inboxKeyOwner = owner;
      }
    }
    if (publicKey == null) {
      return;
    }
    final BackgroundCapabilityDraft draft = backgroundCapabilityDraftOf(
      state,
      inboxPublicKey: publicKey,
      directory: directory,
      mailboxes: mailboxes,
    );
    String sorted(Iterable<String> values) =>
        (values.toList()..sort()).join(',');
    final String signature = <String>[
      base64Url.encode(publicKey),
      sorted(draft.friends),
      sorted(draft.groupMembers),
      sorted(draft.blocked),
      draft.mailboxes.join(','),
    ].join('|');
    if (signature == _publishedSignature) {
      return;
    }
    await _vault.publish(draft);
    _publishedSignature = signature;
  }
}

/// Opens what the locked receiver kept (with the inbox key of [masterKey])
/// and hands it to [runtime] as if it had just arrived; "Mijani" seen while
/// locked goes to [encounters] instead (only this device's own records,
/// [self]). Then the locked receiver's notices go. Returns how many records
/// were handed over. The caller makes sure the receiver no longer writes
/// and the app's services listen.
Future<int> drainLockedInbox({
  required BackgroundVault vault,
  required Uint8List masterKey,
  required RuntimeNodeRuntime runtime,
  required RuntimeSystemNotificationService notices,
  EncounterLog? encounters,
  String self = '',
}) async {
  final int delivered = await vault.drain(
    masterKey: masterKey,
    deliver: (Uint8List record) async {
      final SignalTransportFrame? frame = decodeInboxFrame(record);
      if (frame == null) {
        return;
      }
      if (frame.payload['type'] == kKeptEncountersType) {
        if (encounters != null &&
            !frame.door &&
            self.isNotEmpty &&
            PeerShareCodec.addressesEqual(frame.from, self)) {
          await encounters.takeKept(frame.payload);
        }
        return;
      }
      runtime.replayReceived(frame);
    },
  );
  for (final String slot in kLockedReceiverSlots) {
    await notices.dismissSlot(slot);
  }
  return delivered;
}
