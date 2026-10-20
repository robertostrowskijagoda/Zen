import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';

/// One end-to-end sealed payload in transit through relays.
@immutable
final class RelayEnvelope {
  const RelayEnvelope({
    required this.id,
    required this.sender,
    required this.recipient,
    required this.createdAtMillis,
    required this.expiresAtMillis,
    required this.box,
  });

  /// Same as the reliable id (`_rid`) of the wrapped payload.
  final String id;
  final String sender;
  final String recipient;
  final int createdAtMillis;
  final int expiresAtMillis;
  final RelaySealedBox box;

  /// Everything a relay could be tempted to rewrite, bound into the AEAD.
  static Uint8List associatedDataFor({
    required String id,
    required String sender,
    required String recipient,
    required int createdAtMillis,
    required int expiresAtMillis,
  }) {
    return Uint8List.fromList(
      utf8.encode(
        'zen.relay.env|$id|$sender|$recipient|$createdAtMillis|$expiresAtMillis',
      ),
    );
  }

  Uint8List get associatedData => associatedDataFor(
    id: id,
    sender: sender,
    recipient: recipient,
    createdAtMillis: createdAtMillis,
    expiresAtMillis: expiresAtMillis,
  );

  int get approximateBytes =>
      box.cipherText.length + id.length + sender.length + recipient.length + 96;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    's': sender,
    'r': recipient,
    'c': createdAtMillis,
    'x': expiresAtMillis,
    'e': base64Url.encode(box.ephemeralPublicKey),
    'n': base64Url.encode(box.nonce),
    'b': base64Url.encode(box.cipherText),
  };

  /// Parses an envelope from untrusted input; `null` when anything is off.
  static RelayEnvelope? tryParse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? sender = json['s'];
    final Object? recipient = json['r'];
    final Object? created = json['c'];
    final Object? expires = json['x'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 128 ||
        sender is! String ||
        sender.isEmpty ||
        recipient is! String ||
        recipient.isEmpty ||
        created is! num ||
        expires is! num) {
      return null;
    }
    try {
      final Uint8List ephemeral = base64Url.decode(
        base64Url.normalize(json['e'] as String),
      );
      final Uint8List nonce = base64Url.decode(
        base64Url.normalize(json['n'] as String),
      );
      final Uint8List body = base64Url.decode(
        base64Url.normalize(json['b'] as String),
      );
      if (ephemeral.length != 32 || nonce.length != 12 || body.length < 16) {
        return null;
      }
      return RelayEnvelope(
        id: id,
        sender: sender,
        recipient: recipient,
        createdAtMillis: created.toInt(),
        expiresAtMillis: expires.toInt(),
        box: RelaySealedBox(
          ephemeralPublicKey: ephemeral,
          nonce: nonce,
          cipherText: body,
        ),
      );
    } catch (_) {
      return null;
    }
  }
}

/// What this device knows about a friend's relay setup.
@immutable
final class RelayPeerInfo {
  const RelayPeerInfo({
    required this.address,
    this.publicKey,
    this.relays = const <String>[],
    this.version = 0,
    this.updatedAtMillis = 0,
    this.depositKey,
    this.depositToken,
  });

  final String address;
  final Uint8List? publicKey;

  /// The friends this peer chose to hold its mail while it is offline.
  final List<String> relays;

  /// Monotonic per-peer counter of its relay announcements.
  final int version;
  final int updatedAtMillis;

  /// The peer's deposit key — only known while this device is one of its
  /// relays. Checks the tokens senders show when they hand in its mail.
  final Uint8List? depositKey;

  /// This device's token for leaving mail with the peer's relays.
  final String? depositToken;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    if (publicKey != null) 'pk': base64Url.encode(publicKey!),
    'rl': relays,
    'v': version,
    'u': updatedAtMillis,
    if (depositKey != null) 'dk': base64Url.encode(depositKey!),
    if (depositToken != null) 'tk': depositToken,
  };

  static RelayPeerInfo? fromJson(Object? json) {
    if (json is! Map || json['a'] is! String) {
      return null;
    }
    final Object? token = json['tk'];
    return RelayPeerInfo(
      address: json['a'] as String,
      publicKey: decodeRelayKey(json['pk']),
      relays: _stringList(json['rl']),
      version: (json['v'] as num?)?.toInt() ?? 0,
      updatedAtMillis: (json['u'] as num?)?.toInt() ?? 0,
      depositKey: decodeRelayKey(json['dk']),
      depositToken: token is String && token.isNotEmpty ? token : null,
    );
  }
}

/// A reliable payload this device still has to get to its recipient.
@immutable
final class RelayOutboxEntry {
  const RelayOutboxEntry({
    required this.rid,
    required this.recipient,
    required this.payload,
    required this.createdAtMillis,
    required this.expiresAtMillis,
    required this.relayable,
    this.directAttempts = 0,
    this.nextDirectAttemptAtMillis = 0,
    this.depositedTo = const <String>[],
    this.depositAttemptAtMillis = const <String, int>{},
  });

  final String rid;
  final String recipient;

  /// The payload exactly as delivered, `_rid` included.
  final Map<String, dynamic> payload;
  final int createdAtMillis;
  final int expiresAtMillis;

  /// False for payloads that may only go direct (too large, or addressed to
  /// someone whose relays/key we cannot know, like a friend request).
  final bool relayable;
  final int directAttempts;
  final int nextDirectAttemptAtMillis;

  /// Relays that confirmed holding a copy.
  final List<String> depositedTo;

  /// Last deposit attempt per relay, to space out retries.
  final Map<String, int> depositAttemptAtMillis;

  RelayOutboxEntry copyWith({
    int? directAttempts,
    int? nextDirectAttemptAtMillis,
    List<String>? depositedTo,
    Map<String, int>? depositAttemptAtMillis,
  }) {
    return RelayOutboxEntry(
      rid: rid,
      recipient: recipient,
      payload: payload,
      createdAtMillis: createdAtMillis,
      expiresAtMillis: expiresAtMillis,
      relayable: relayable,
      directAttempts: directAttempts ?? this.directAttempts,
      nextDirectAttemptAtMillis:
          nextDirectAttemptAtMillis ?? this.nextDirectAttemptAtMillis,
      depositedTo: depositedTo ?? this.depositedTo,
      depositAttemptAtMillis:
          depositAttemptAtMillis ?? this.depositAttemptAtMillis,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rid': rid,
    'to': recipient,
    'p': payload,
    'c': createdAtMillis,
    'x': expiresAtMillis,
    'rel': relayable,
    'da': directAttempts,
    'nd': nextDirectAttemptAtMillis,
    'dep': depositedTo,
    'dat': depositAttemptAtMillis,
  };

  static RelayOutboxEntry? fromJson(Object? json) {
    if (json is! Map ||
        json['rid'] is! String ||
        json['to'] is! String ||
        json['p'] is! Map) {
      return null;
    }
    final Map<String, int> attempts = <String, int>{};
    final Object? rawAttempts = json['dat'];
    if (rawAttempts is Map) {
      rawAttempts.forEach((Object? key, Object? value) {
        if (key is String && value is num) {
          attempts[key] = value.toInt();
        }
      });
    }
    return RelayOutboxEntry(
      rid: json['rid'] as String,
      recipient: json['to'] as String,
      payload: Map<String, dynamic>.from(json['p'] as Map),
      createdAtMillis: (json['c'] as num?)?.toInt() ?? 0,
      expiresAtMillis: (json['x'] as num?)?.toInt() ?? 0,
      relayable: json['rel'] == true,
      directAttempts: (json['da'] as num?)?.toInt() ?? 0,
      nextDirectAttemptAtMillis: (json['nd'] as num?)?.toInt() ?? 0,
      depositedTo: _stringList(json['dep']),
      depositAttemptAtMillis: attempts,
    );
  }
}

/// What the relay layer can tell the chat about a queued chat message that is
/// not (or no longer) on its way the way the sender may assume.
enum RelayDeliveryStatus {
  /// Too large for friends' mailboxes (`RelayConfig.maxRelayablePayloadBytes`):
  /// it only reaches the recipient while both devices are online at the same
  /// time. Still being retried, so not a failure — but not "sent and safe"
  /// either.
  directOnly,

  /// Nobody acknowledged it within `RelayConfig.messageTtl` (14 days) and it
  /// was dropped from the queue: it will not be delivered any more.
  expired,
}

/// One piece of delivery news about a queued chat message, kept in the stored
/// state until the chat layer has taken it over (see
/// `RelayEngine.takeDeliveryReports`), so it survives restarts and the hand-off
/// between the UI isolate and the Android background service.
@immutable
final class RelayDeliveryReport {
  const RelayDeliveryReport({
    required this.rid,
    required this.recipient,
    required this.messageId,
    required this.status,
    required this.atMillis,
  });

  /// The reliable id (`_rid`) of the queued payload.
  final String rid;

  /// Canonical address the message was addressed to (the chat's peer).
  final String recipient;

  /// The chat message id (`msgId` of the payload).
  final String messageId;
  final RelayDeliveryStatus status;
  final int atMillis;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rid': rid,
    'to': recipient,
    'mid': messageId,
    's': status.name,
    'at': atMillis,
  };

  static RelayDeliveryReport? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? rid = json['rid'];
    final Object? recipient = json['to'];
    final Object? messageId = json['mid'];
    final RelayDeliveryStatus? status = json['s'] is String
        ? RelayDeliveryStatus.values.asNameMap()[json['s'] as String]
        : null;
    if (rid is! String ||
        rid.isEmpty ||
        recipient is! String ||
        recipient.isEmpty ||
        messageId is! String ||
        messageId.isEmpty ||
        status == null) {
      return null;
    }
    return RelayDeliveryReport(
      rid: rid,
      recipient: recipient,
      messageId: messageId,
      status: status,
      atMillis: (json['at'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Version of the stored *settings* (as opposed to the delivery data) in
/// [RelayState]. Bumped whenever a setting's default changes in a way that has
/// to reach devices that already stored the old default.
///
/// * (absent) — states written before the version existed. They stored
///   `shareWithGroups` as `true` by default, and a stored `true` cannot be told
///   apart from "never touched".
/// * 2 — `shareWithGroups` is off by default and, from here on, a stored value
///   is the person's own choice.
const int kRelaySettingsVersion = 2;

/// Everything the relay layer persists for this device.
final class RelayState {
  RelayState({
    this.identity,
    Map<String, RelayPeerInfo>? peers,
    this.manualRelays,
    List<String>? currentRelays,
    this.relaySetVersion = 0,
    Map<String, int>? announcedVersions,
    Map<String, RelayOutboxEntry>? outbox,
    Map<String, Map<String, Map<String, dynamic>>>? mailbox,
    Map<String, int>? tombstones,
    Map<String, int>? seen,
    this.seenFloorMillis = 0,
    Map<String, int>? seenFloors,
    this.shareWithGroups = false,
    List<RelayDeliveryReport>? deliveryReports,
  }) : peers = peers ?? <String, RelayPeerInfo>{},
       seenFloors = seenFloors ?? <String, int>{},
       currentRelays = currentRelays ?? <String>[],
       announcedVersions = announcedVersions ?? <String, int>{},
       outbox = outbox ?? <String, RelayOutboxEntry>{},
       mailbox = mailbox ?? <String, Map<String, Map<String, dynamic>>>{},
       tombstones = tombstones ?? <String, int>{},
       seen = seen ?? <String, int>{},
       deliveryReports = deliveryReports ?? <RelayDeliveryReport>[];

  RelayIdentity? identity;

  /// Friends' relay announcements, by canonical address.
  final Map<String, RelayPeerInfo> peers;

  /// `null` = pick automatically; otherwise the user's own choice.
  List<String>? manualRelays;

  /// The relay set this device currently announces.
  List<String> currentRelays;
  int relaySetVersion;

  /// Last announcement version each friend confirmed.
  final Map<String, int> announcedVersions;

  final Map<String, RelayOutboxEntry> outbox;

  /// Mail held for friends: recipient -> envelope id -> envelope JSON.
  final Map<String, Map<String, Map<String, dynamic>>> mailbox;

  /// Envelope ids known to be delivered -> expiry; never stored again.
  final Map<String, int> tombstones;

  /// Reliable ids already delivered to this device -> expiry (for relayed
  /// mail: the envelope's own expiry, so it is remembered as long as a copy
  /// could still be handed over).
  final Map<String, int> seen;

  /// Highest expiry among [seen] entries dropped early to keep the list
  /// short. A relayed envelope expiring no later than this may have been
  /// delivered already, so it is refused instead of being taken twice.
  int seenFloorMillis;

  /// The same, per sender (what replaced [seenFloorMillis]): entries are
  /// dropped from whoever holds the most, so one busy or hostile contact
  /// can only ever refuse its own old copies, never everybody's mail.
  final Map<String, int> seenFloors;

  /// Whether group members who are not friends learn this device's key and
  /// mailboxes. Revealing the mailboxes means revealing which friends hold
  /// them (part of the trust graph), so it is the person's explicit opt-in and
  /// off by default: only friends ever get the mailbox addresses unless this
  /// is switched on. Group messages to someone offline then wait in mailboxes
  /// only for members who are friends (or who also opted in).
  bool shareWithGroups;

  /// Delivery news for the chat layer that it has not taken over yet, oldest
  /// first (see [RelayDeliveryReport]).
  final List<RelayDeliveryReport> deliveryReports;

  String toJsonString({bool includeMailbox = true}) =>
      jsonEncode(<String, dynamic>{
        'v': 1,
        // Settings version (see [kRelaySettingsVersion]): lets a loader tell
        // a `swg` the person chose from the old default.
        'sv': kRelaySettingsVersion,
        if (identity != null) 'id': identity!.toJson(),
        'peers': peers.values.map((RelayPeerInfo p) => p.toJson()).toList(),
        if (manualRelays != null) 'manual': manualRelays,
        'cur': currentRelays,
        'ver': relaySetVersion,
        // `ann2` (was `ann`): confirmations of announcements that carry deposit
        // tokens; older ones are dropped so every contact gets its token once.
        'ann2': announcedVersions,
        'out': outbox.values.map((RelayOutboxEntry e) => e.toJson()).toList(),
        if (includeMailbox) 'mail': mailbox,
        'tomb': tombstones,
        'seen': seen,
        if (seenFloorMillis > 0) 'sfl': seenFloorMillis,
        if (seenFloors.isNotEmpty) 'sfls': seenFloors,
        'swg': shareWithGroups,
        if (deliveryReports.isNotEmpty)
          'rep': deliveryReports
              .map((RelayDeliveryReport r) => r.toJson())
              .toList(),
      });

  static RelayState fromJsonString(String raw) {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return RelayState();
    }
    final Map<String, RelayPeerInfo> peers = <String, RelayPeerInfo>{};
    for (final Object? item
        in (decoded['peers'] as List?) ?? const <Object?>[]) {
      final RelayPeerInfo? info = RelayPeerInfo.fromJson(item);
      if (info != null) {
        peers[info.address] = info;
      }
    }
    final Map<String, RelayOutboxEntry> outbox = <String, RelayOutboxEntry>{};
    for (final Object? item in (decoded['out'] as List?) ?? const <Object?>[]) {
      final RelayOutboxEntry? entry = RelayOutboxEntry.fromJson(item);
      if (entry != null) {
        outbox[entry.rid] = entry;
      }
    }
    final Map<String, Map<String, Map<String, dynamic>>> mailbox =
        <String, Map<String, Map<String, dynamic>>>{};
    final Object? rawMail = decoded['mail'];
    if (rawMail is Map) {
      rawMail.forEach((Object? recipient, Object? envelopes) {
        if (recipient is! String || envelopes is! Map) {
          return;
        }
        final Map<String, Map<String, dynamic>> held =
            <String, Map<String, dynamic>>{};
        envelopes.forEach((Object? id, Object? envelope) {
          if (id is String && envelope is Map) {
            held[id] = Map<String, dynamic>.from(envelope);
          }
        });
        if (held.isNotEmpty) {
          mailbox[recipient] = held;
        }
      });
    }
    final List<RelayDeliveryReport> reports = <RelayDeliveryReport>[];
    final Object? rawReports = decoded['rep'];
    if (rawReports is List) {
      for (final Object? item in rawReports) {
        final RelayDeliveryReport? report = RelayDeliveryReport.fromJson(item);
        if (report != null) {
          reports.add(report);
        }
      }
    }
    // One-time migration (S-5). Before `sv` existed `shareWithGroups` was on by
    // default and always written out, so a stored `true` could be the untouched
    // default as well as a deliberate choice, and announcing mailboxes to
    // strangers in groups must not stay on for people who never decided it.
    // Everything stored without (or with an older) `sv` therefore loads as
    // "off"; the next save writes the current `sv`, from then on `swg` is the
    // person's own choice again and survives restarts — so this runs once, and
    // they can switch it back on.
    final bool storedChoiceIsTheirs =
        ((decoded['sv'] as num?)?.toInt() ?? 0) >= kRelaySettingsVersion;
    final Object? manual = decoded['manual'];
    return RelayState(
      identity: RelayIdentity.fromJson(decoded['id']),
      peers: peers,
      manualRelays: manual is List ? _stringList(manual) : null,
      currentRelays: _stringList(decoded['cur']),
      relaySetVersion: (decoded['ver'] as num?)?.toInt() ?? 0,
      announcedVersions: _intMap(decoded['ann2']),
      outbox: outbox,
      mailbox: mailbox,
      tombstones: _intMap(decoded['tomb']),
      seen: _intMap(decoded['seen']),
      seenFloorMillis: (decoded['sfl'] as num?)?.toInt() ?? 0,
      seenFloors: _intMap(decoded['sfls']),
      shareWithGroups: storedChoiceIsTheirs && decoded['swg'] == true,
      deliveryReports: reports,
    );
  }
}

List<String> _stringList(Object? value) {
  if (value is! List) {
    return <String>[];
  }
  return value.whereType<String>().toList();
}

Map<String, int> _intMap(Object? value) {
  final Map<String, int> result = <String, int>{};
  if (value is Map) {
    value.forEach((Object? key, Object? entry) {
      if (key is String && entry is num) {
        result[key] = entry.toInt();
      }
    });
  }
  return result;
}
