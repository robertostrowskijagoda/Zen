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
    this.canReceiveBlobs = false,
    this.blobQuotaBytes = 0,
    this.blobRelays = const <String, int>{},
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

  /// Whether the peer takes attachments through its mailboxes (it announced
  /// [kRelayBlobCapability]). Peers that did not (1.10.0 and older) only get
  /// attachments while both devices are online.
  final bool canReceiveBlobs;

  /// How many bytes of attachments the peer holds per sender for each friend
  /// it serves as a mailbox (0: none).
  final int blobQuotaBytes;

  /// The peer's mailboxes that hold attachments, with their per-sender
  /// quota in bytes.
  final Map<String, int> blobRelays;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    if (publicKey != null) 'pk': base64Url.encode(publicKey!),
    'rl': relays,
    'v': version,
    'u': updatedAtMillis,
    if (depositKey != null) 'dk': base64Url.encode(depositKey!),
    if (depositToken != null) 'tk': depositToken,
    if (canReceiveBlobs) 'cb': true,
    if (blobQuotaBytes > 0) 'bq': blobQuotaBytes,
    if (blobRelays.isNotEmpty) 'br': blobRelays,
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
      canReceiveBlobs: json['cb'] == true,
      blobQuotaBytes: (json['bq'] as num?)?.toInt() ?? 0,
      blobRelays: _intMap(json['br']),
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
    this.blobId,
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

  /// For a payload too large for one envelope: the blob ([RelayBlobOut]) its
  /// copy for the mailboxes was cut into.
  final String? blobId;

  RelayOutboxEntry copyWith({
    int? directAttempts,
    int? nextDirectAttemptAtMillis,
    List<String>? depositedTo,
    Map<String, int>? depositAttemptAtMillis,
    String? blobId,
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
      blobId: blobId ?? this.blobId,
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
    if (blobId != null) 'blob': blobId,
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
      blobId: json['blob'] is String ? json['blob'] as String : null,
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
    this.blobQuotaBytes,
    Map<String, RelayBlobOut>? outBlobs,
    Map<String, Map<String, RelayHeldBlob>>? heldBlobs,
    Map<String, RelayBlobIn>? inBlobs,
  }) : peers = peers ?? <String, RelayPeerInfo>{},
       outBlobs = outBlobs ?? <String, RelayBlobOut>{},
       heldBlobs = heldBlobs ?? <String, Map<String, RelayHeldBlob>>{},
       inBlobs = inBlobs ?? <String, RelayBlobIn>{},
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

  /// How many bytes of attachments this device holds per sender for each
  /// friend it serves as a mailbox; `null` = the default
  /// (`RelayConfig.defaultBlobQuotaBytes`), 0 = none.
  int? blobQuotaBytes;

  /// Attachments from here on their way to mailboxes, by blob id.
  final Map<String, RelayBlobOut> outBlobs;

  /// Attachments held for friends: recipient -> `sender|blobId` -> blob.
  final Map<String, Map<String, RelayHeldBlob>> heldBlobs;

  /// Attachments for this device being collected: `sender|blobId` -> blob.
  final Map<String, RelayBlobIn> inBlobs;

  String toJsonString({bool includeMailbox = true}) => jsonEncode(
    <String, dynamic>{
      'v': 1,
      if (identity != null) 'id': identity!.toJson(),
      'peers': peers.values.map((RelayPeerInfo p) => p.toJson()).toList(),
      if (manualRelays != null) 'manual': manualRelays,
      'cur': currentRelays,
      'ver': relaySetVersion,
      // Confirmations of announcements (deposit tokens, capabilities).
      'ann': announcedVersions,
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
      if (blobQuotaBytes != null) 'bq': blobQuotaBytes,
      if (outBlobs.isNotEmpty)
        'bo': outBlobs.values.map((RelayBlobOut b) => b.toJson()).toList(),
      if (heldBlobs.isNotEmpty)
        'bh': <String, dynamic>{
          for (final MapEntry<String, Map<String, RelayHeldBlob>> e
              in heldBlobs.entries)
            e.key: e.value.values.map((RelayHeldBlob b) => b.toJson()).toList(),
        },
      if (inBlobs.isNotEmpty)
        'bi': inBlobs.values.map((RelayBlobIn b) => b.toJson()).toList(),
    },
  );

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
    final Object? manual = decoded['manual'];
    return RelayState(
      identity: RelayIdentity.fromJson(decoded['id']),
      peers: peers,
      manualRelays: manual is List ? _stringList(manual) : null,
      currentRelays: _stringList(decoded['cur']),
      relaySetVersion: (decoded['ver'] as num?)?.toInt() ?? 0,
      announcedVersions: _intMap(decoded['ann']),
      outbox: outbox,
      mailbox: mailbox,
      tombstones: _intMap(decoded['tomb']),
      seen: _intMap(decoded['seen']),
      seenFloorMillis: (decoded['sfl'] as num?)?.toInt() ?? 0,
      seenFloors: _intMap(decoded['sfls']),
      shareWithGroups: decoded['swg'] == true,
      deliveryReports: reports,
      blobQuotaBytes: (decoded['bq'] as num?)?.toInt(),
      outBlobs: <String, RelayBlobOut>{
        for (final RelayBlobOut blob
            in ((decoded['bo'] as List?) ?? const <Object?>[])
                .map(RelayBlobOut.fromJson)
                .whereType<RelayBlobOut>())
          blob.blobId: blob,
      },
      heldBlobs: _heldBlobsFromJson(decoded['bh']),
      inBlobs: <String, RelayBlobIn>{
        for (final RelayBlobIn blob
            in ((decoded['bi'] as List?) ?? const <Object?>[])
                .map(RelayBlobIn.fromJson)
                .whereType<RelayBlobIn>())
          blob.scope: blob,
      },
    );
  }
}

Map<String, Map<String, RelayHeldBlob>> _heldBlobsFromJson(Object? raw) {
  final Map<String, Map<String, RelayHeldBlob>> result =
      <String, Map<String, RelayHeldBlob>>{};
  if (raw is! Map) {
    return result;
  }
  raw.forEach((Object? recipient, Object? blobs) {
    if (recipient is! String || blobs is! List) {
      return;
    }
    final Map<String, RelayHeldBlob> held = <String, RelayHeldBlob>{};
    for (final Object? item in blobs) {
      final RelayHeldBlob? blob = RelayHeldBlob.fromJson(item);
      if (blob != null) {
        held[blob.scope] = blob;
      }
    }
    if (held.isNotEmpty) {
      result[recipient] = held;
    }
  });
  return result;
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

/// Capability a device lists in its `rly_announce` (`cap`) when it can take
/// attachments through its mailboxes: collect the chunks a sender left with
/// its friends and put them back together.
const String kRelayBlobCapability = 'blob1';

/// What a blob carries.
enum RelayBlobKind {
  /// A reliable payload too large for one envelope (an inline photo or voice
  /// message, up to the size of one signal): once complete it is handed to
  /// the app exactly as if it had arrived directly.
  payload('p'),

  /// A chat attachment cut into the app's own transfer chunks: the app gets
  /// a `message_placeholder` and one `message_chunk` per chunk, as from the
  /// sender's live transfer.
  attachment('a');

  const RelayBlobKind(this.wire);

  final String wire;

  static RelayBlobKind? fromWire(Object? value) {
    for (final RelayBlobKind kind in values) {
      if (kind.wire == value) {
        return kind;
      }
    }
    return null;
  }
}

List<int> _intList(Object? value) {
  if (value is! List) {
    return <int>[];
  }
  return value.whereType<num>().map((num n) => n.toInt()).toList();
}

/// A blob this device sent: its sealed chunks wait here until the
/// recipient's mailboxes hold them (or the recipient collected it).
final class RelayBlobOut {
  RelayBlobOut({
    required this.blobId,
    required this.recipient,
    required this.kind,
    required this.manifestRid,
    required this.chunkCount,
    required this.cipherBytes,
    required this.createdAtMillis,
    required this.expiresAtMillis,
    this.ref,
    Map<String, List<int>>? stored,
    List<String>? refused,
  }) : stored = stored ?? <String, List<int>>{},
       refused = refused ?? <String>[];

  final String blobId;
  final String recipient;
  final RelayBlobKind kind;

  /// Reliable id of the manifest that tells the recipient about the blob.
  final String manifestRid;

  /// For [RelayBlobKind.payload]: the reliable id of the payload it carries.
  final String? ref;
  final int chunkCount;

  /// Sum of the sealed chunks' sizes (what a mailbox has to store).
  final int cipherBytes;
  final int createdAtMillis;
  final int expiresAtMillis;

  /// Mailbox -> chunk indexes it confirmed holding.
  final Map<String, List<int>> stored;

  /// Mailboxes that would not take it (over their quota).
  final List<String> refused;

  bool isCompleteAt(String relay) =>
      (stored[relay]?.toSet().length ?? 0) >= chunkCount;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'b': blobId,
    'to': recipient,
    'k': kind.wire,
    'm': manifestRid,
    if (ref != null) 'ref': ref,
    'n': chunkCount,
    'z': cipherBytes,
    'c': createdAtMillis,
    'x': expiresAtMillis,
    if (stored.isNotEmpty) 'st': stored,
    if (refused.isNotEmpty) 'no': refused,
  };

  static RelayBlobOut? fromJson(Object? json) {
    if (json is! Map ||
        json['b'] is! String ||
        json['to'] is! String ||
        json['m'] is! String) {
      return null;
    }
    final RelayBlobKind? kind = RelayBlobKind.fromWire(json['k']);
    if (kind == null) {
      return null;
    }
    final Map<String, List<int>> stored = <String, List<int>>{};
    final Object? rawStored = json['st'];
    if (rawStored is Map) {
      rawStored.forEach((Object? relay, Object? indexes) {
        if (relay is String) {
          stored[relay] = _intList(indexes);
        }
      });
    }
    return RelayBlobOut(
      blobId: json['b'] as String,
      recipient: json['to'] as String,
      kind: kind,
      manifestRid: json['m'] as String,
      ref: json['ref'] is String ? json['ref'] as String : null,
      chunkCount: (json['n'] as num?)?.toInt() ?? 0,
      cipherBytes: (json['z'] as num?)?.toInt() ?? 0,
      createdAtMillis: (json['c'] as num?)?.toInt() ?? 0,
      expiresAtMillis: (json['x'] as num?)?.toInt() ?? 0,
      stored: stored,
      refused: _stringList(json['no']),
    );
  }
}

/// Sealed chunks this device holds for a friend (it is one of the friend's
/// mailboxes). Only ciphertext: the key travels inside the sealed manifest.
final class RelayHeldBlob {
  RelayHeldBlob({
    required this.blobId,
    required this.sender,
    required this.chunkCount,
    required this.cipherBytes,
    required this.arrivedAtMillis,
    required this.holdUntilMillis,
    this.storedBytes = 0,
    Set<int>? have,
  }) : have = have ?? <int>{};

  final String blobId;
  final String sender;
  final int chunkCount;

  /// Announced total size; reserved against the sender's quota up front.
  final int cipherBytes;
  final int arrivedAtMillis;
  final int holdUntilMillis;

  /// Bytes actually written so far (never more than [cipherBytes]).
  int storedBytes;

  /// Chunk indexes held.
  final Set<int> have;

  String get scope => '$sender|$blobId';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'b': blobId,
    's': sender,
    'n': chunkCount,
    'z': cipherBytes,
    'sz': storedBytes,
    'ha': arrivedAtMillis,
    'hx': holdUntilMillis,
    'i': have.toList()..sort(),
  };

  static RelayHeldBlob? fromJson(Object? json) {
    if (json is! Map || json['b'] is! String || json['s'] is! String) {
      return null;
    }
    return RelayHeldBlob(
      blobId: json['b'] as String,
      sender: json['s'] as String,
      chunkCount: (json['n'] as num?)?.toInt() ?? 0,
      cipherBytes: (json['z'] as num?)?.toInt() ?? 0,
      storedBytes: (json['sz'] as num?)?.toInt() ?? 0,
      arrivedAtMillis: (json['ha'] as num?)?.toInt() ?? 0,
      holdUntilMillis: (json['hx'] as num?)?.toInt() ?? 0,
      have: _intList(json['i']).toSet(),
    );
  }
}

/// A blob addressed to this device that is being collected from the
/// sender's deposits (the mailboxes, or the sender itself).
final class RelayBlobIn {
  RelayBlobIn({
    required this.blobId,
    required this.sender,
    required this.kind,
    required this.key,
    required this.chunkCount,
    required this.chunkSize,
    required this.plainBytes,
    required this.createdAtMillis,
    required this.expiresAtMillis,
    this.digest,
    this.ref,
    this.messageId,
    Map<String, dynamic>? meta,
    Set<int>? received,
  }) : meta = meta ?? <String, dynamic>{},
       received = received ?? <int>{};

  final String blobId;
  final String sender;
  final RelayBlobKind kind;

  /// The blob's chunk key (from the manifest, which only the recipient can
  /// open).
  final Uint8List key;
  final int chunkCount;
  final int chunkSize;
  final int plainBytes;
  final int createdAtMillis;
  final int expiresAtMillis;

  /// SHA-256 (base64url) of the whole plaintext ([RelayBlobKind.payload]).
  final String? digest;

  /// [RelayBlobKind.payload]: reliable id of the payload inside.
  final String? ref;

  /// [RelayBlobKind.attachment]: the chat message it belongs to.
  final String? messageId;

  /// [RelayBlobKind.attachment]: what the app needs to show it (name, type,
  /// size…), as in a `message_placeholder`.
  final Map<String, dynamic> meta;

  /// Chunk indexes already taken.
  final Set<int> received;

  String get scope => '$sender|$blobId';

  bool get isComplete => received.length >= chunkCount;

  /// Lowest indexes not received yet, at most [limit].
  List<int> missing(int limit) {
    final List<int> result = <int>[];
    for (int i = 0; i < chunkCount && result.length < limit; i++) {
      if (!received.contains(i)) {
        result.add(i);
      }
    }
    return result;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'b': blobId,
    's': sender,
    'k': kind.wire,
    'key': base64Url.encode(key),
    'n': chunkCount,
    'cs': chunkSize,
    'z': plainBytes,
    'c': createdAtMillis,
    'x': expiresAtMillis,
    if (digest != null) 'h': digest,
    if (ref != null) 'ref': ref,
    if (messageId != null) 'mid': messageId,
    if (meta.isNotEmpty) 'meta': meta,
    'i': received.toList()..sort(),
  };

  static RelayBlobIn? fromJson(Object? json) {
    if (json is! Map || json['b'] is! String || json['s'] is! String) {
      return null;
    }
    final RelayBlobKind? kind = RelayBlobKind.fromWire(json['k']);
    final Uint8List? key = decodeRelayKey(json['key']);
    if (kind == null || key == null) {
      return null;
    }
    final Object? meta = json['meta'];
    return RelayBlobIn(
      blobId: json['b'] as String,
      sender: json['s'] as String,
      kind: kind,
      key: key,
      chunkCount: (json['n'] as num?)?.toInt() ?? 0,
      chunkSize: (json['cs'] as num?)?.toInt() ?? 0,
      plainBytes: (json['z'] as num?)?.toInt() ?? 0,
      createdAtMillis: (json['c'] as num?)?.toInt() ?? 0,
      expiresAtMillis: (json['x'] as num?)?.toInt() ?? 0,
      digest: json['h'] is String ? json['h'] as String : null,
      ref: json['ref'] is String ? json['ref'] as String : null,
      messageId: json['mid'] is String ? json['mid'] as String : null,
      meta: meta is Map ? Map<String, dynamic>.from(meta) : null,
      received: _intList(json['i']).toSet(),
    );
  }
}
