import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// The alarm kit: what the locked Android service needs to raise
// this person's alarm without the master key — whom to send it to (their
// devices, mailbox copies sealed in advance), the settings, and the alarm
// key: a key of its own that signs alarm frames only. Friends learn its
// public part, certified by this device's key, while the app is unlocked.

/// Most friends the kit sends to (the app sends to all once unlocked).
const int kAlarmKitMaxRecipients = 100;

/// Most addresses (devices) one friend gets the alarm at.
const int kAlarmKitMaxDevices = 8;

/// The kit is written again at least this often while the app is
/// unlocked, so its mailbox copies (valid for the relay lifetime) stay
/// fresh.
const Duration kAlarmKitRefreshEvery = Duration(days: 7);

/// What an alarm frame's signature covers (all of it but the transport's
/// own fields and the "please confirm" flag).
const List<String> kSignedAlarmFields = <String>[
  'type',
  'id',
  'at',
  'lat',
  'lon',
  'acc',
  'locAt',
  'note',
  'resp',
  'end',
  'duress',
  'kit',
];

/// The bytes the alarm key signs for [payload]: positions in millionths
/// and times in whole milliseconds, so the text form of a number on the
/// way never changes them.
Uint8List alarmSignedBytes(Map<String, dynamic> payload) {
  int? whole(Object? v) => v is num && v.isFinite ? v.round() : null;
  int? micro(Object? v) =>
      v is num && v.isFinite ? (v * 1000000).round() : null;
  final Map<String, Object?> signed = <String, Object?>{'c': 'zen.alarm.v1'};
  for (final String field in kSignedAlarmFields) {
    final Object? v = payload[field];
    if (v == null) {
      continue;
    }
    signed[field] = switch (field) {
      'lat' || 'lon' || 'acc' => micro(v),
      'at' || 'locAt' || 'end' => whole(v),
      'resp' =>
        v is Map
            ? <String, Object?>{
                for (final MapEntry<dynamic, dynamic> e in v.entries)
                  if (e.key is String && e.value is String)
                    e.key as String: e.value,
              }
            : null,
      _ => v is String || v is bool ? v : null,
    };
  }
  return canonicalJsonBytes(signed);
}

/// [payload] signed with the alarm [key]: `sg` the signature, `sk` the
/// key's hybrid id (the receiver looks it up among the sender's keys).
Future<Map<String, dynamic>> signAlarmFrame(
  LedgerKeyPair key,
  Map<String, dynamic> payload,
) async {
  final Map<String, dynamic> clean = Map<String, dynamic>.from(payload)
    ..remove('sg')
    ..remove('sk');
  // Keyed: an alarm may come from a mailbox long after, and must check
  // out on its own wherever the alarm key's certificate is all there is.
  final Uint8List signature = await key.signWithKey(alarmSignedBytes(clean));
  return <String, dynamic>{...clean, 'sg': b64(signature), 'sk': key.hybridId};
}

/// Whether [payload] carries a good signature of the alarm key whose
/// hybrid id ([LedgerKeyPair.hybridId]) is [keyId]: both halves, the
/// ML-DSA one exactly the certified key.
Future<bool> verifyAlarmFrame(String keyId, Map<String, dynamic> payload) {
  final Object? signature = payload['sg'];
  final ({String ed, String pq})? key = parseHybridKeyId(keyId);
  if (signature is! String || key == null) {
    return Future<bool>.value(false);
  }
  return verifyLedgerSignature(
    publicKey: key.ed,
    message: alarmSignedBytes(payload),
    signature: signature,
    pqId: key.pq,
  );
}

/// "[key] is the alarm key of [address]", signed by the device key in
/// [device] (which the account key certified). A friend keeps the key only
/// when this checks out and the account is the one it knows for the
/// sender.
@immutable
final class AlarmKeyCertificate {
  const AlarmKeyCertificate({
    required this.address,
    required this.key,
    required this.issued,
    required this.device,
    required this.signature,
  });

  /// The address of the device whose alarms the key signs (normalised).
  final String address;

  /// The alarm key's hybrid id ([LedgerKeyPair.hybridId]): both public
  /// halves, so the ML-DSA key of the alarms is certified too.
  final String key;
  final int issued;
  final DeviceCertificate device;
  final String signature;

  static Map<String, dynamic> _payload(
    String address,
    String key,
    int issued,
    DeviceCertificate device,
  ) => <String, dynamic>{
    't': 'alarm_key',
    'a': address,
    'k': key,
    'at': issued,
    'acc': device.account,
    'dev': device.device,
  };

  static Future<AlarmKeyCertificate> issue({
    required LedgerKeyPair deviceKey,
    required DeviceCertificate certificate,
    required String address,
    required String alarmKey,
    required int issued,
  }) async {
    final String a = PeerShareCodec.normalizeAddress(address);
    final Uint8List sig = await deviceKey.sign(
      canonicalJsonBytes(_payload(a, alarmKey, issued, certificate)),
    );
    return AlarmKeyCertificate(
      address: a,
      key: alarmKey,
      issued: issued,
      device: certificate,
      signature: b64(sig),
    );
  }

  /// Whether this is a sound certificate of a key for alarms from [from].
  /// [account]: the account this phone knows for [from] (`null` when it
  /// knows none: then the certificate must be for [from] itself).
  Future<bool> verify({required String from, String? account}) async {
    if (account != null && account.isNotEmpty) {
      if (account != device.account) {
        return false;
      }
    } else if (!PeerShareCodec.addressesEqual(address, from)) {
      return false;
    }
    return await device.verify() &&
        await device.verifyByDevice(
          canonicalJsonBytes(_payload(address, key, issued, device)),
          signature,
        );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    'k': key,
    'at': issued,
    'd': device.toJson(),
    's': signature,
  };

  static AlarmKeyCertificate? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? a = json['a'];
    final Object? k = json['k'];
    final Object? at = json['at'];
    final Object? s = json['s'];
    final DeviceCertificate? device = DeviceCertificate.fromJson(json['d']);
    if (a is! String ||
        a.isEmpty ||
        a.length > 200 ||
        parseHybridKeyId(k) == null ||
        at is! int ||
        !isHybridSignatureText(s) ||
        device == null) {
      return null;
    }
    return AlarmKeyCertificate(
      address: a,
      key: k as String,
      issued: at,
      device: device,
      signature: s as String,
    );
  }
}

/// One `rly_deposit` frame sealed in advance for a [mailbox] of a friend.
@immutable
final class AlarmKitDeposit {
  const AlarmKitDeposit({
    required this.mailbox,
    required this.id,
    required this.frame,
  });

  final String mailbox;

  /// The envelope's id (the mailbox confirms it with `rly_deposit_ack`).
  final String id;
  final Map<String, dynamic> frame;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'm': mailbox,
    'i': id,
    'f': frame,
  };

  static AlarmKitDeposit? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? m = json['m'];
    final Object? i = json['i'];
    final Object? f = json['f'];
    if (m is! String || m.isEmpty || i is! String || f is! Map) {
      return null;
    }
    return AlarmKitDeposit(
      mailbox: m,
      id: i,
      frame: Map<String, dynamic>.from(f),
    );
  }
}

/// A friend the kit's alarm goes to.
@immutable
final class AlarmKitRecipient {
  const AlarmKitRecipient({
    required this.address,
    this.devices = const <String>[],
    this.pairKey,
    this.nearbyKey,
    this.deposits = const <AlarmKitDeposit>[],
  });

  /// As in [AlarmRecord.sentTo] (normalised).
  final String address;

  /// Where the alarm goes: [address] and the friend's other devices.
  final List<String> devices;

  /// This phone's pair key for the friend (base64url): it signs only the
  /// Bluetooth alarm waves the friend checks.
  final String? pairKey;

  /// What the friend gave this phone ([FriendNearbyKey]): recognises
  /// their phone nearby.
  final String? nearbyKey;

  /// The alarm sealed in advance for the friend's mailboxes.
  final List<AlarmKitDeposit> deposits;

  /// Where frames go: [devices], or [address] when there are none.
  List<String> get targets => devices.isEmpty ? <String>[address] : devices;

  AlarmKitRecipient copyWith({
    List<String>? devices,
    List<AlarmKitDeposit>? deposits,
  }) => AlarmKitRecipient(
    address: address,
    devices: devices ?? this.devices,
    pairKey: pairKey,
    nearbyKey: nearbyKey,
    deposits: deposits ?? this.deposits,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    if (devices.isNotEmpty) 'd': devices,
    if (pairKey != null) 'p': pairKey,
    if (nearbyKey != null) 'n': nearbyKey,
    if (deposits.isNotEmpty)
      'x': <Map<String, dynamic>>[
        for (final AlarmKitDeposit d in deposits) d.toJson(),
      ],
  };

  static AlarmKitRecipient? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? a = json['a'];
    if (a is! String || a.isEmpty || a.length > 200) {
      return null;
    }
    final Object? d = json['d'];
    final Object? p = json['p'];
    final Object? n = json['n'];
    final Object? x = json['x'];
    return AlarmKitRecipient(
      address: a,
      devices: <String>[
        if (d is List)
          for (final Object? device in d.take(kAlarmKitMaxDevices))
            if (device is String && device.isNotEmpty) device,
      ],
      pairKey: p is String ? p : null,
      nearbyKey: n is String ? n : null,
      deposits: <AlarmKitDeposit>[
        if (x is List)
          for (final Object? deposit in x.take(8))
            if (AlarmKitDeposit.fromJson(deposit) case final AlarmKitDeposit k)
              k,
      ],
    );
  }
}

/// What the locked Android service raises this person's alarm with.
/// Never holds the master key, the account key or the device key:
/// only the alarm key, which signs alarm frames and nothing else.
@immutable
final class AlarmKit {
  const AlarmKit({
    required this.createdAt,
    required this.self,
    required this.alarmId,
    required this.alarmKeySeed,
    this.recipients = const <AlarmKitRecipient>[],
    this.note = '',
    this.shortcut = false,
    this.recordAudio = false,
    this.nearby = false,
    this.running,
  });

  final int createdAt;

  /// This device's address (what the service's own records come from).
  final String self;

  /// The id of the alarm raised from the kit; the id of [running] when
  /// there is one.
  final String alarmId;

  /// Seed (base64url) of the alarm key.
  final String alarmKeySeed;
  final List<AlarmKitRecipient> recipients;
  final String note;

  /// The power-button shortcut is on and both PINs are set.
  final bool shortcut;
  final bool recordAudio;

  /// Tell phones nearby over Bluetooth too.
  final bool nearby;

  /// This person's alarm already going on when the kit was written: the
  /// service carries on with it (position, sound, resends).
  final AlarmRecord? running;

  static const int version = 1;

  AlarmKit copyWith({List<AlarmKitRecipient>? recipients}) => AlarmKit(
    createdAt: createdAt,
    self: self,
    alarmId: alarmId,
    alarmKeySeed: alarmKeySeed,
    recipients: recipients ?? this.recipients,
    note: note,
    shortcut: shortcut,
    recordAudio: recordAudio,
    nearby: nearby,
    running: running,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': version,
    't': createdAt,
    'me': self,
    'id': alarmId,
    'ak': alarmKeySeed,
    'r': <Map<String, dynamic>>[
      for (final AlarmKitRecipient r in recipients) r.toJson(),
    ],
    if (note.isNotEmpty) 'note': note,
    if (shortcut) 'sc': true,
    if (recordAudio) 'au': true,
    if (nearby) 'nb': true,
    if (running != null) 'run': running!.toJson(),
  };

  static AlarmKit? fromJson(Object? json) {
    if (json is! Map || json['v'] != version) {
      return null;
    }
    final Object? t = json['t'];
    final Object? me = json['me'];
    final Object? id = json['id'];
    final Object? ak = json['ak'];
    final Object? r = json['r'];
    final Object? note = json['note'];
    if (t is! int ||
        me is! String ||
        me.isEmpty ||
        id is! String ||
        !kAlarmIdPattern.hasMatch(id) ||
        unb64(ak, length: 32) == null) {
      return null;
    }
    final AlarmRecord? running = AlarmRecord.fromJson(json['run']);
    return AlarmKit(
      createdAt: t,
      self: me,
      alarmId: id,
      alarmKeySeed: ak as String,
      recipients: <AlarmKitRecipient>[
        if (r is List)
          for (final Object? item in r.take(kAlarmKitMaxRecipients))
            if (AlarmKitRecipient.fromJson(item)
                case final AlarmKitRecipient recipient)
              recipient,
      ],
      note: note is String
          ? (note.length > AlarmRecord.maxNoteChars
                ? note.substring(0, AlarmRecord.maxNoteChars)
                : note)
          : '',
      shortcut: json['sc'] == true,
      recordAudio: json['au'] == true,
      nearby: json['nb'] == true,
      running: running != null && running.isOwn && running.isActive
          ? running
          : null,
    );
  }
}

/// Where the kit is kept for the service.
abstract interface class AlarmKitStore {
  Future<void> write(AlarmKit kit);

  /// The kit last written; `null` when there is none or it does not open.
  Future<AlarmKit?> read();
}

/// [AlarmKitStore] in the background folder, sealed with the background
/// key (`BackgroundKeyProtector`): the service opens it without the app
/// password, nothing else on the disk reads it.
final class FileAlarmKitStore implements AlarmKitStore {
  FileAlarmKitStore({
    required Future<Directory> Function() supportDirectory,
    required AppSecurityCredentialsStore credentials,
    this.createKey = false,
  }) : _supportDirectory = supportDirectory,
       _credentials = credentials;

  static const String _storageKey = 'background/alarm-kit';
  static const String _fileName = 'alarm-kit.zenbg';

  /// Whether this side makes the background key when there is none (the
  /// app does; the service never does).
  final bool createKey;
  final Future<Directory> Function() _supportDirectory;
  final AppSecurityCredentialsStore _credentials;

  Future<File> file() async {
    final Directory support = await _supportDirectory();
    final String sep = Platform.pathSeparator;
    return File(
      '${support.path}$sep${FileBackgroundVault.folderName}$sep$_fileName',
    );
  }

  @override
  Future<void> write(AlarmKit kit) async {
    final Uint8List sealed = await BackgroundKeyProtector(
      _credentials,
      createKey: createKey,
    ).sealFor(_storageKey, Uint8List.fromList(utf8.encode(jsonEncode(kit))));
    final File target = await file();
    await target.parent.create(recursive: true);
    // Beside the file and moved over it: the service reads the old kit or
    // the new one, never half of one.
    final File next = File('${target.path}.next');
    await next.writeAsBytes(sealed, flush: true);
    await next.rename(target.path);
  }

  @override
  Future<AlarmKit?> read() async {
    final File source = await file();
    if (!await source.exists()) {
      return null;
    }
    try {
      final Uint8List plain = await BackgroundKeyProtector(
        _credentials,
      ).unsealFor(_storageKey, await source.readAsBytes());
      return AlarmKit.fromJson(jsonDecode(utf8.decode(plain)));
    } on Object catch (error, stackTrace) {
      logZenError('The alarm kit is unreadable', error, stackTrace);
      return null;
    }
  }
}

/// A friend's mailbox copies of [payload], sealed now (the relay layer's
/// `presealDeposits`).
typedef AlarmKitPreseal =
    Future<List<({String mailbox, String id, Map<String, dynamic> frame})>>
    Function(String recipient, Map<String, dynamic> payload);

/// Keeps the kit in step with the alarm setup while the app is unlocked:
/// [refresh] writes it again whenever something it holds changed (the
/// friends it goes to and their devices, the settings, the running alarm,
/// the keys) or it is older than [kAlarmKitRefreshEvery].
final class AlarmKitKeeper {
  AlarmKitKeeper({required this.meet, required this.store, int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final MeetService meet;
  final AlarmKitStore store;
  final int Function() _now;

  /// What the kit last written was made of.
  String? _written;
  Future<void> _queue = Future<void>.value();

  /// How many times the kit was written (tests, logs).
  int get writes => _writes;
  int _writes = 0;

  /// Writes the kit when it changed. [devicesOf]: every address of a friend
  /// (the account directory); [preseal]: the relay layer's sealing for the
  /// friend's mailboxes. Returns whether it wrote.
  Future<bool> refresh({
    List<String> Function(String friend)? devicesOf,
    AlarmKitPreseal? preseal,
  }) {
    final Completer<bool> done = Completer<bool>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await _refresh(devicesOf, preseal));
      } on Object catch (error, stackTrace) {
        logZenError('Writing the alarm kit failed', error, stackTrace);
        done.complete(false);
      }
    });
    return done.future;
  }

  Future<bool> _refresh(
    List<String> Function(String friend)? devicesOf,
    AlarmKitPreseal? preseal,
  ) async {
    final AlarmKit? prepared = await meet.prepareAlarmKit();
    if (prepared == null) {
      return false;
    }
    // Whom the alarm goes to (friends' addresses, Bluetooth keys) opens
    // without the app password: kept only while the locked service can use
    // it, with the power-button shortcut on or an alarm going on.
    final AlarmKit base = prepared.shortcut || prepared.running != null
        ? prepared
        : prepared.copyWith(recipients: const <AlarmKitRecipient>[]);
    List<String> devices(AlarmKitRecipient r) {
      final List<String> out = <String>[r.address];
      for (final String d in devicesOf?.call(r.address) ?? const <String>[]) {
        final String n = PeerShareCodec.normalizeAddress(d);
        if (n.isNotEmpty &&
            !out.contains(n) &&
            out.length < kAlarmKitMaxDevices) {
          out.add(n);
        }
      }
      return out;
    }

    final AlarmKit kit = base.copyWith(
      recipients: <AlarmKitRecipient>[
        for (final AlarmKitRecipient r in base.recipients)
          r.copyWith(devices: devices(r)),
      ],
    );
    final Map<String, dynamic> inputs = kit.toJson()
      ..remove('t')
      ..['b'] = _now() ~/ kAlarmKitRefreshEvery.inMilliseconds;
    final String signature = sha256Hex(utf8.encode(jsonEncode(inputs)));
    if (signature == _written) {
      return false;
    }
    AlarmKit out = kit;
    if (preseal != null && kit.running == null && kit.recipients.isNotEmpty) {
      // The alarm sealed in advance for each friend's mailboxes: whoever is
      // offline still gets it, from a mailbox, once back.
      final Map<String, dynamic> template = await meet.alarmKitTemplate(kit);
      out = kit.copyWith(
        recipients: <AlarmKitRecipient>[
          for (final AlarmKitRecipient r in kit.recipients)
            r.copyWith(deposits: await _sealFor(preseal, r, template)),
        ],
      );
    }
    await store.write(out);
    _written = signature;
    _writes += 1;
    logZenMessage(
      'Alarm kit written: ${out.recipients.length} friend(s)'
      '${out.running == null ? '' : ', running alarm'}.',
    );
    return true;
  }

  static Future<List<AlarmKitDeposit>> _sealFor(
    AlarmKitPreseal preseal,
    AlarmKitRecipient recipient,
    Map<String, dynamic> template,
  ) async {
    try {
      return <AlarmKitDeposit>[
        for (final ({String mailbox, String id, Map<String, dynamic> frame}) d
            in await preseal(recipient.address, template))
          AlarmKitDeposit(mailbox: d.mailbox, id: d.id, frame: d.frame),
      ];
    } on Object catch (error) {
      logZenWarning('Alarm kit: no mailbox copies for a friend: $error');
      return const <AlarmKitDeposit>[];
    }
  }
}
