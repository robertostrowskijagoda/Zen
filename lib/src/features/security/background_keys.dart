import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';

const int _backgroundKeyBytes = 32;

/// Reads within one isolate wait for each other, so two first callers can
/// never make two different keys (the second would orphan whatever the
/// first sealed). Only the app makes the key; the service only reads it.
Future<void> _backgroundKeyQueue = Future<void>.value();

/// The background key, made now when [create] and there is none yet;
/// `null` when there is none (and [create] is off).
Future<Uint8List?> loadBackgroundKey(
  AppSecurityCredentialsStore credentials, {
  bool create = false,
}) {
  final Completer<Uint8List?> result = Completer<Uint8List?>();
  _backgroundKeyQueue = _backgroundKeyQueue.then((_) async {
    try {
      result.complete(await _readOrCreateBackgroundKey(credentials, create));
    } on Object catch (error, stackTrace) {
      result.completeError(error, stackTrace);
    }
  });
  return result.future;
}

Future<Uint8List?> _readOrCreateBackgroundKey(
  AppSecurityCredentialsStore credentials,
  bool create,
) async {
  final String? stored = (await credentials.read(
    appSecurityBackgroundKeyStorageKey,
  ))?.trim();
  if (stored != null && stored.length == _backgroundKeyBytes * 2) {
    try {
      return securityBytesFromHex(stored);
    } on FormatException {
      // Damaged: treated like a missing key below.
    }
  }
  if (!create) {
    return null;
  }
  final Uint8List key = randomSecurityBytes(_backgroundKeyBytes);
  await credentials.write(
    appSecurityBackgroundKeyStorageKey,
    securityHexFromBytes(key),
  );
  return key;
}

/// Seals stored payloads with the background key (AES-256-GCM, bound to
/// the key they are stored under), for what the background service must
/// open without the app password: the node config and the
/// [BackgroundCapability].
///
/// Like [EncryptedBinaryPayloadProtector], only its own envelope opens
/// (`ZENBGK1`); anything else reads as "nothing stored". Without a key it
/// throws a [StateError], which the node config reader takes as "wait",
/// never as "make a new identity".
final class BackgroundKeyProtector implements KeyedBinaryPayloadProtector {
  BackgroundKeyProtector(this._credentials, {this.createKey = false});

  /// Whether this side makes the key when there is none (the app does; the
  /// service never does).
  final bool createKey;

  final AppSecurityCredentialsStore _credentials;

  /// `ZENBGK1`.
  static const List<int> _magic = <int>[
    0x5A,
    0x45,
    0x4E,
    0x42,
    0x47,
    0x4B,
    0x31,
  ];

  static List<int> _aad(String storageKey) =>
      utf8.encode('zen.background.v1|$storageKey');

  Future<Uint8List> _key() async {
    final Uint8List? key = await loadBackgroundKey(
      _credentials,
      create: createKey,
    );
    if (key == null) {
      throw StateError('There is no background key yet.');
    }
    return key;
  }

  /// Not used: every payload is sealed for the key it is stored under.
  @override
  Future<Uint8List> seal(Uint8List payload) => Future<Uint8List>.error(
    UnsupportedError('Background payloads are sealed with sealFor.'),
  );

  /// Not used: every payload is opened for the key it is stored under.
  @override
  Future<Uint8List> unseal(Uint8List payload) => Future<Uint8List>.error(
    UnsupportedError('Background payloads are opened with unsealFor.'),
  );

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) async {
    final Uint8List encrypted = await encryptSecurityBytes(
      payload,
      await _key(),
      aad: _aad(storageKey),
    );
    final Uint8List out = Uint8List(_magic.length + encrypted.length);
    out
      ..setRange(0, _magic.length, _magic)
      ..setRange(_magic.length, out.length, encrypted);
    return out;
  }

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async {
    if (!isSealed(payload)) {
      throw const UnsupportedStoredPayloadException(
        'Only payloads sealed with the background key open.',
      );
    }
    return decryptSecurityBytes(
      Uint8List.fromList(payload.sublist(_magic.length)),
      await _key(),
      aad: _aad(storageKey),
    );
  }

  @override
  bool isSealed(Uint8List payload) {
    if (payload.length < _magic.length) {
      return false;
    }
    for (int index = 0; index < _magic.length; index++) {
      if (payload[index] != _magic[index]) {
        return false;
      }
    }
    return true;
  }
}

/// The inbox key pair (X25519) for [masterKey]: derived from it, so its
/// private part exists only where the master key does — in the unlocked
/// app. The background service gets only the public part.
Future<SimpleKeyPair> inboxKeyPairFor(Uint8List masterKey) {
  return X25519().newKeyPairFromSeed(securitySubkey(masterKey, 'inbox.x25519'));
}

/// The public part of [inboxKeyPairFor].
Future<Uint8List> inboxPublicKeyFor(Uint8List masterKey) async {
  final SimpleKeyPair pair = await inboxKeyPairFor(masterKey);
  final SimplePublicKey publicKey = await pair.extractPublicKey();
  return Uint8List.fromList(publicKey.bytes);
}

/// How the background service treats a sender while the app is locked.
enum BackgroundContactKind {
  /// An accepted friend, one of their devices, or one of this account's
  /// own devices: kept, answered (presence).
  friend,

  /// A member of a group this person joined: kept, presence answered
  /// without anything else.
  groupMember,

  /// Blocked: nothing is kept and nothing answered.
  blocked,

  /// Anyone else: only what must reach this phone (a friend request, a
  /// neighbour), within a small budget.
  stranger,
}

/// What the app hands the background service to receive with while it is
/// locked (§14.1): the public part of the inbox key, the people who count
/// as contacts, and the mailboxes (friends who hold this phone's mail) to
/// ask for it. Addresses are given normalized
/// (`PeerShareCodec.normalizeAddress`).
@immutable
final class BackgroundCapabilityDraft {
  const BackgroundCapabilityDraft({
    required this.inboxPublicKey,
    this.friends = const <String>{},
    this.groupMembers = const <String>{},
    this.blocked = const <String>{},
    this.mailboxes = const <String>[],
  });

  final Uint8List inboxPublicKey;
  final Set<String> friends;
  final Set<String> groupMembers;
  final Set<String> blocked;

  /// At most six close friends; the only addresses stored readable, since
  /// the service has to send to them (`rly_poll`).
  final List<String> mailboxes;
}

/// The [BackgroundCapabilityDraft] as the background service reads it.
///
/// Contacts are kept as keyed tags (HMAC-SHA256 with a subkey of the
/// background key), not as addresses: the service only has to recognise a
/// sender, never to list the friends.
final class BackgroundCapability {
  BackgroundCapability._({
    required this.inboxPublicKey,
    required this.mailboxes,
    required Uint8List routingKey,
    required Set<String> friendTags,
    required Set<String> groupTags,
    required Set<String> blockedTags,
  }) : _routingKey = routingKey,
       _friendTags = friendTags,
       _groupTags = groupTags,
       _blockedTags = blockedTags;

  /// The capability [draft] gives under [backgroundKey].
  factory BackgroundCapability.fromDraft(
    BackgroundCapabilityDraft draft, {
    required Uint8List backgroundKey,
  }) {
    final Uint8List routingKey = _routingKeyOf(backgroundKey);
    return BackgroundCapability._(
      inboxPublicKey: draft.inboxPublicKey,
      mailboxes: List<String>.unmodifiable(draft.mailboxes),
      routingKey: routingKey,
      friendTags: draft.friends.map((String a) => _tag(routingKey, a)).toSet(),
      groupTags: draft.groupMembers
          .map((String a) => _tag(routingKey, a))
          .toSet(),
      blockedTags: draft.blocked.map((String a) => _tag(routingKey, a)).toSet(),
    );
  }

  final Uint8List inboxPublicKey;
  final List<String> mailboxes;
  final Uint8List _routingKey;
  final Set<String> _friendTags;
  final Set<String> _groupTags;
  final Set<String> _blockedTags;

  /// How [address] (normalized) counts.
  BackgroundContactKind kindOf(String address) {
    final String tag = _tag(_routingKey, address);
    if (_blockedTags.contains(tag)) {
      return BackgroundContactKind.blocked;
    }
    if (_friendTags.contains(tag)) {
      return BackgroundContactKind.friend;
    }
    if (_groupTags.contains(tag)) {
      return BackgroundContactKind.groupMember;
    }
    return BackgroundContactKind.stranger;
  }

  static Uint8List _routingKeyOf(Uint8List backgroundKey) =>
      securitySubkey(backgroundKey, 'background.routing');

  static String _tag(Uint8List routingKey, String address) => crypto.Hmac(
    crypto.sha256,
    routingKey,
  ).convert(utf8.encode(address)).toString().substring(0, 32);
}

/// Where the app leaves the [BackgroundCapability] for the background
/// service and where the service leaves what it received (the sealed
/// inbox).
abstract interface class BackgroundVault {
  /// Stores [draft] for the service (sealed with the background key).
  Future<void> publish(BackgroundCapabilityDraft draft);

  /// What the app last published; `null` before the first publish (the
  /// service then cannot receive at all).
  Future<BackgroundCapability?> load();

  /// Whether the service left anything for the app.
  Future<bool> hasInbox();

  /// Opens everything the service kept (with the inbox key of
  /// [masterKey]) and hands each record to [deliver], oldest first; the
  /// files go only after the last one plus [settle] (time for the app to
  /// store what it was handed). Returns how many records were handed over.
  Future<int> drain({
    required Uint8List masterKey,
    required Future<void> Function(Uint8List record) deliver,
    Duration settle,
  });
}

/// How long the drained inbox files stay after the last record was handed
/// over, so what it held is stored before the only sealed copy goes.
const Duration kInboxDrainSettle = Duration(seconds: 3);

/// [BackgroundVault] in the `background` folder next to the app's data.
final class FileBackgroundVault implements BackgroundVault {
  FileBackgroundVault({
    required Future<Directory> Function() supportDirectory,
    required AppSecurityCredentialsStore credentials,
    this.createKey = false,
  }) : _supportDirectory = supportDirectory,
       _credentials = credentials;

  /// The folder, inside the support folder.
  static const String folderName = 'background';

  static const String _capabilityStorageKey = 'background/capability';
  static const String _capabilityFile = 'capability.zenbg';
  static const String _inboxFile = 'inbox.zbox';
  static const String _drainingPrefix = 'draining-';
  static const String _drainingSuffix = '.zbox';

  /// Whether the app side makes the background key when there is none.
  final bool createKey;

  final Future<Directory> Function() _supportDirectory;
  final AppSecurityCredentialsStore _credentials;

  Future<Directory> directory() async {
    final Directory support = await _supportDirectory();
    return Directory('${support.path}${Platform.pathSeparator}$folderName');
  }

  /// The file the service appends to.
  Future<File> inboxFile() async =>
      File('${(await directory()).path}${Platform.pathSeparator}$_inboxFile');

  Future<File> _capability() async => File(
    '${(await directory()).path}${Platform.pathSeparator}$_capabilityFile',
  );

  @override
  Future<void> publish(BackgroundCapabilityDraft draft) async {
    final Uint8List? backgroundKey = await loadBackgroundKey(
      _credentials,
      create: createKey,
    );
    if (backgroundKey == null) {
      throw StateError('There is no background key yet.');
    }
    final BackgroundCapability capability = BackgroundCapability.fromDraft(
      draft,
      backgroundKey: backgroundKey,
    );
    final Uint8List json = Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, Object>{
          'v': 1,
          'pk': base64Url.encode(capability.inboxPublicKey),
          'mb': capability.mailboxes,
          'f': capability._friendTags.toList()..sort(),
          'g': capability._groupTags.toList()..sort(),
          'b': capability._blockedTags.toList()..sort(),
        }),
      ),
    );
    final Uint8List sealed = await BackgroundKeyProtector(
      _credentials,
      createKey: createKey,
    ).sealFor(_capabilityStorageKey, json);
    final File file = await _capability();
    await file.parent.create(recursive: true);
    // Beside the file and moved over it: the service reads either the old
    // capability or the new one, never half of one.
    final File next = File('${file.path}.next');
    await next.writeAsBytes(sealed, flush: true);
    await next.rename(file.path);
  }

  @override
  Future<BackgroundCapability?> load() async {
    final File file = await _capability();
    if (!await file.exists()) {
      return null;
    }
    final Uint8List? backgroundKey = await loadBackgroundKey(_credentials);
    if (backgroundKey == null) {
      return null;
    }
    try {
      final Uint8List plain = await BackgroundKeyProtector(
        _credentials,
      ).unsealFor(_capabilityStorageKey, await file.readAsBytes());
      final Object? json = jsonDecode(utf8.decode(plain));
      if (json is! Map<String, dynamic> || json['v'] != 1) {
        return null;
      }
      final Object? pk = json['pk'];
      if (pk is! String) {
        return null;
      }
      final Uint8List publicKey = base64Url.decode(base64Url.normalize(pk));
      if (publicKey.length != 32) {
        return null;
      }
      Set<String> tags(Object? list) => <String>{
        if (list is List)
          for (final Object? tag in list)
            if (tag is String) tag,
      };
      return BackgroundCapability._(
        inboxPublicKey: publicKey,
        mailboxes: List<String>.unmodifiable(<String>[
          if (json['mb'] case final List<dynamic> mailboxes)
            for (final Object? m in mailboxes)
              if (m is String && m.isNotEmpty) m,
        ]),
        routingKey: BackgroundCapability._routingKeyOf(backgroundKey),
        friendTags: tags(json['f']),
        groupTags: tags(json['g']),
        blockedTags: tags(json['b']),
      );
    } on Object catch (error, stackTrace) {
      logZenError('The background capability is unreadable', error, stackTrace);
      return null;
    }
  }

  Future<List<File>> _drainingFiles(Directory folder) async {
    if (!await folder.exists()) {
      return <File>[];
    }
    final List<File> files = <File>[
      await for (final FileSystemEntity entity in folder.list())
        if (entity is File &&
            entity.uri.pathSegments.last.startsWith(_drainingPrefix) &&
            entity.path.endsWith(_drainingSuffix))
          entity,
    ];
    files.sort((File a, File b) => a.path.compareTo(b.path));
    return files;
  }

  @override
  Future<bool> hasInbox() async {
    final Directory folder = await directory();
    return await (await inboxFile()).exists() ||
        (await _drainingFiles(folder)).isNotEmpty;
  }

  @override
  Future<int> drain({
    required Uint8List masterKey,
    required Future<void> Function(Uint8List record) deliver,
    Duration settle = kInboxDrainSettle,
  }) async {
    final Directory folder = await directory();
    final File inbox = await inboxFile();
    if (await inbox.exists()) {
      // Moved aside first: whatever the service appends from now on starts
      // a new inbox instead of growing the one being read. The name sorts
      // after any file a drain cut short left behind (read again first:
      // what it already delivered is dropped as a repeat further on).
      final String stamp = DateTime.now().microsecondsSinceEpoch
          .toString()
          .padLeft(20, '0');
      await inbox.rename(
        '${folder.path}${Platform.pathSeparator}'
        '$_drainingPrefix$stamp$_drainingSuffix',
      );
    }
    final List<File> files = await _drainingFiles(folder);
    if (files.isEmpty) {
      return 0;
    }
    final SimpleKeyPair recipient = await inboxKeyPairFor(masterKey);
    int delivered = 0;
    for (final File file in files) {
      final List<Uint8List> records = await readSealedInbox(file, recipient);
      for (final Uint8List record in records) {
        await deliver(record);
        delivered += 1;
      }
    }
    if (settle > Duration.zero) {
      await Future<void>.delayed(settle);
    }
    for (final File file in files) {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        logZenWarning('A drained inbox file stayed: $error');
      }
    }
    return delivered;
  }
}
