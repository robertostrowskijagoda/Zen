import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';

/// Network updates (§14.2): a new version travels from friend to friend
/// like any file. The app takes it only when [kReleaseThreshold] of the
/// project maintainers signed it, waits [kReleaseEmbargo] after first
/// seeing it (time for anyone to notice a forced release and for any one
/// maintainer to veto it), and then still only asks — it never installs
/// by itself.
const int kReleaseThreshold = 2;
const Duration kReleaseEmbargo = Duration(days: 7);

/// Public keys (Ed25519, base64url) of release maintainers. Deliberately
/// empty: the project does not want anyone holding publishing keys (they
/// can die, lose them or be coerced), so network updates stay off until
/// another way to approve versions is decided (docs/PLAN.md,
/// §14.2, "Otwarta decyzja"). While it is empty nothing signed is taken:
/// no releases, vetoes, canaries or signed donation details.
///
/// Turning it on (docs/RELEASES.md §8): each maintainer runs
/// `dart run tool/zen_release.dart keygen <file>` on their own offline
/// machine and sends only the public key; then
/// `dart run tool/zen_release.dart maintainers --write <key1> <key2> <key3>`
/// fills this list, and the next release built with it takes updates.
const List<String> kReleaseMaintainers = <String>[];

const String kReleaseApp = 'zen';

/// Payload type on the mesh: `{type, rel?, rev?}`.
const String kReleaseOfferType = 'zen_rel';

/// The platform names used in release files.
String currentReleasePlatform() {
  if (kIsWeb) {
    return 'web';
  }
  if (Platform.isAndroid) {
    return 'android';
  }
  if (Platform.isWindows) {
    return 'windows';
  }
  if (Platform.isMacOS) {
    return 'macos';
  }
  if (Platform.isLinux) {
    return 'linux';
  }
  return Platform.operatingSystem;
}

/// One file of a release (an APK, a Windows installer…).
@immutable
final class ReleaseFile {
  const ReleaseFile({
    required this.platform,
    required this.name,
    required this.size,
    required this.blob,
    required this.sha256,
  });

  /// `android`, `windows`, …
  final String platform;
  final String name;
  final int size;

  /// The ledger blob id: the hash of the file's manifest, so it pins down
  /// every byte.
  final String blob;

  /// SHA-256 of the whole file (for people checking by hand).
  final String sha256;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'p': platform,
    'name': name,
    'size': size,
    'blob': blob,
    'sha256': sha256,
  };

  static ReleaseFile? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? p = json['p'];
    final Object? name = json['name'];
    final Object? size = json['size'];
    final Object? blob = json['blob'];
    final Object? sha = json['sha256'];
    if (p is! String ||
        p.isEmpty ||
        p.length > 20 ||
        name is! String ||
        !_safeFileName(name) ||
        size is! int ||
        size <= 0 ||
        size > kMaxBlobBytes ||
        !isHex(blob, 64) ||
        !isHex(sha, 64)) {
      return null;
    }
    return ReleaseFile(
      platform: p,
      name: name,
      size: size,
      blob: blob as String,
      sha256: sha as String,
    );
  }

  /// Describes [bytes] as the file [name] for [platform].
  static ReleaseFile describe(
    Uint8List bytes, {
    required String platform,
    required String name,
  }) => ReleaseFile(
    platform: platform,
    name: name,
    size: bytes.length,
    blob: BlobManifest.describe(bytes, releaseMime(name)).id,
    sha256: sha256Hex(bytes),
  );
}

/// The mime type a release file is stored under (part of its blob id).
String releaseMime(String name) {
  final String lower = name.toLowerCase();
  if (lower.endsWith('.apk')) {
    return 'application/vnd.android.package-archive';
  }
  if (lower.endsWith('.zip')) {
    return 'application/zip';
  }
  return 'application/octet-stream';
}

bool _safeFileName(String name) =>
    name.isNotEmpty &&
    name.length <= 100 &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$').hasMatch(name);

/// A link a signed file may carry (donation page, repository, mirror):
/// `https://` with a host (no Tor or plain `http://` links).
bool isSafeReleaseLink(Object? value) {
  if (value is! String || value.isEmpty || value.length > 200) {
    return false;
  }
  final Uri? uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    return false;
  }
  return uri.scheme == 'https';
}

/// How many of [maintainers] signed [message]: [signatures] maps a
/// maintainer key to its signature (base64url). Each key counts once.
Future<int> countMaintainerSignatures({
  required Uint8List message,
  required Map<String, String> signatures,
  required List<String> maintainers,
}) async {
  int valid = 0;
  for (final String key in maintainers.toSet()) {
    final String? sig = signatures[key];
    if (sig != null &&
        await verifyLedgerSignature(
          publicKey: key,
          message: message,
          signature: sig,
        )) {
      valid++;
    }
  }
  return valid;
}

/// Reads the `sigs` list of a signed file (`[{k, s}]`), or null.
Map<String, String>? readSignatureList(Object? sigs) {
  if (sigs is! List || sigs.length > 10) {
    return null;
  }
  final Map<String, String> signatures = <String, String>{};
  for (final Object? s in sigs) {
    if (s is Map && s['k'] is String && s['s'] is String) {
      signatures[s['k'] as String] = s['s'] as String;
    }
  }
  return Map<String, String>.unmodifiable(signatures);
}

/// The fields of an official build that a modified copy would change to
/// take the money or the credit (§14.3 point 6): signed in the release
/// manifest, compared with what this build shows.
@immutable
final class OfficialInfo {
  const OfficialInfo({this.donation, this.author, this.repository});

  /// The only official collection (`kDonationUrl`).
  final String? donation;

  /// Who makes Zen.
  final String? author;

  /// The source repository.
  final String? repository;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'donation': ?donation,
    'author': ?author,
    'repo': ?repository,
  };

  static OfficialInfo? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? donation = json['donation'];
    final Object? author = json['author'];
    final Object? repo = json['repo'];
    if ((donation != null && !isSafeReleaseLink(donation)) ||
        (repo != null && !isSafeReleaseLink(repo)) ||
        (author != null &&
            (author is! String || author.isEmpty || author.length > 100)) ||
        (donation == null && author == null && repo == null)) {
      return null;
    }
    return OfficialInfo(
      donation: donation as String?,
      author: author as String?,
      repository: repo as String?,
    );
  }

  /// Which of the signed fields [build] shows differently (`donation`,
  /// `author`, `repo`); fields not signed are not compared.
  List<String> differencesFrom(OfficialInfo build) {
    String norm(String v) {
      String out = v.trim().toLowerCase();
      while (out.endsWith('/')) {
        out = out.substring(0, out.length - 1);
      }
      return out;
    }

    bool differs(String? signed, String? shown) =>
        signed != null && (shown == null || norm(signed) != norm(shown));
    return <String>[
      if (differs(donation, build.donation)) 'donation',
      if (differs(author, build.author)) 'author',
      if (differs(repository, build.repository)) 'repo',
    ];
  }
}

/// What the maintainers sign: the files (APK, ZIP… by SHA-256 and blob
/// id), and optionally the official donation link and author (§14.3) and
/// the mirrors of the repository (§14.2).
@immutable
final class ReleaseManifest {
  const ReleaseManifest({
    required this.version,
    required this.build,
    required this.publishedAt,
    required this.files,
    this.notes = '',
    this.official,
    this.mirrors = const <String>[],
    this.extra = const <String, Object?>{},
  });

  final String version;
  final int build;

  /// When the maintainers say they published it (their clock).
  final int publishedAt;
  final String notes;
  final List<ReleaseFile> files;

  /// The signed donation link, author and repository.
  final OfficialInfo? official;

  /// Other places the source and releases can be found (Codeberg, …).
  final List<String> mirrors;

  /// Fields this version does not know, kept so that the signature of a
  /// manifest written by a newer tool still verifies.
  final Map<String, Object?> extra;

  static const Set<String> _known = <String>{
    't',
    'app',
    'version',
    'build',
    'at',
    'notes',
    'files',
    'official',
    'mirrors',
  };

  ReleaseFile? fileFor(String platform) =>
      files.where((ReleaseFile f) => f.platform == platform).firstOrNull;

  Map<String, dynamic> toJson() => <String, dynamic>{
    't': 'zen_release',
    'app': kReleaseApp,
    'version': version,
    'build': build,
    'at': publishedAt,
    'notes': notes,
    'files': <Map<String, dynamic>>[
      for (final ReleaseFile f in files) f.toJson(),
    ],
    if (official != null) 'official': official!.toJson(),
    if (mirrors.isNotEmpty) 'mirrors': mirrors,
    ...extra,
  };

  Uint8List signedBytes() => canonicalJsonBytes(toJson());

  static ReleaseManifest? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'zen_release' ||
        json['app'] != kReleaseApp) {
      return null;
    }
    final Object? version = json['version'];
    final Object? build = json['build'];
    final Object? at = json['at'];
    final Object? notes = json['notes'];
    final Object? files = json['files'];
    if (version is! String ||
        version.isEmpty ||
        version.length > 30 ||
        build is! int ||
        build <= 0 ||
        at is! int ||
        (notes != null && (notes is! String || notes.length > 4000)) ||
        files is! List ||
        files.isEmpty ||
        files.length > 10) {
      return null;
    }
    final List<ReleaseFile> parsed = <ReleaseFile>[];
    for (final Object? f in files) {
      final ReleaseFile? file = ReleaseFile.fromJson(f);
      if (file == null ||
          parsed.any((ReleaseFile p) => p.platform == file.platform)) {
        return null;
      }
      parsed.add(file);
    }
    OfficialInfo? official;
    if (json['official'] != null) {
      official = OfficialInfo.fromJson(json['official']);
      if (official == null) {
        return null;
      }
    }
    final Object? mirrors = json['mirrors'];
    if (mirrors != null &&
        (mirrors is! List ||
            mirrors.length > 10 ||
            !mirrors.every(isSafeReleaseLink))) {
      return null;
    }
    final Map<String, Object?> extra = <String, Object?>{
      for (final MapEntry<Object?, Object?> e in json.entries)
        if (e.key is String && !_known.contains(e.key))
          e.key as String: e.value,
    };
    if (extra.length > 8) {
      return null;
    }
    if (extra.isNotEmpty) {
      try {
        // Must sign the same way as everything else (no fractions…).
        if (canonicalJson(extra).length > 8 * 1024) {
          return null;
        }
      } on ArgumentError {
        return null;
      }
    }
    return ReleaseManifest(
      version: version,
      build: build,
      publishedAt: at,
      notes: (notes as String?) ?? '',
      files: List<ReleaseFile>.unmodifiable(parsed),
      official: official,
      mirrors: List<String>.unmodifiable(
        (mirrors as List<Object?>?)?.cast<String>() ?? const <String>[],
      ),
      extra: Map<String, Object?>.unmodifiable(extra),
    );
  }
}

/// A manifest with the maintainers' signatures.
@immutable
final class SignedRelease {
  const SignedRelease(this.manifest, this.signatures);

  final ReleaseManifest manifest;

  /// Maintainer key → signature (base64url).
  final Map<String, String> signatures;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'm': manifest.toJson(),
    'sigs': <Map<String, String>>[
      for (final MapEntry<String, String> e in signatures.entries)
        <String, String>{'k': e.key, 's': e.value},
    ],
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  static SignedRelease? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final ReleaseManifest? manifest = ReleaseManifest.fromJson(json['m']);
    final Map<String, String>? signatures = readSignatureList(json['sigs']);
    if (manifest == null || signatures == null) {
      return null;
    }
    return SignedRelease(manifest, signatures);
  }

  /// Adds the signature of [maintainer].
  Future<SignedRelease> signedBy(LedgerKeyPair maintainer) async {
    final Uint8List sig = await maintainer.sign(manifest.signedBytes());
    return SignedRelease(manifest, <String, String>{
      ...signatures,
      maintainer.id: b64(sig),
    });
  }

  /// How many of [maintainers] really signed it.
  Future<int> validSignatures(List<String> maintainers) =>
      countMaintainerSignatures(
        message: manifest.signedBytes(),
        signatures: signatures,
        maintainers: maintainers,
      );

  Future<bool> isTrusted({
    List<String> maintainers = kReleaseMaintainers,
    int threshold = kReleaseThreshold,
  }) async =>
      maintainers.length >= threshold &&
      await validSignatures(maintainers) >= threshold;
}

/// "Do not install build [build]", signed by one maintainer: a veto any of
/// them can use (a forced or broken release).
@immutable
final class ReleaseRevocation {
  const ReleaseRevocation({
    required this.build,
    required this.at,
    required this.reason,
    required this.key,
    required this.signature,
  });

  final int build;
  final int at;
  final String reason;
  final String key;
  final String signature;

  static Map<String, dynamic> _body(int build, int at, String reason) =>
      <String, dynamic>{
        't': 'zen_revoke',
        'app': kReleaseApp,
        'build': build,
        'at': at,
        'why': reason,
      };

  static Future<ReleaseRevocation> create({
    required int build,
    required String reason,
    required LedgerKeyPair maintainer,
    int? at,
  }) async {
    final int when = at ?? DateTime.now().millisecondsSinceEpoch;
    final Uint8List sig = await maintainer.sign(
      canonicalJsonBytes(_body(build, when, reason)),
    );
    return ReleaseRevocation(
      build: build,
      at: when,
      reason: reason,
      key: maintainer.id,
      signature: b64(sig),
    );
  }

  Future<bool> isValid({
    List<String> maintainers = kReleaseMaintainers,
  }) async =>
      maintainers.contains(key) &&
      await verifyLedgerSignature(
        publicKey: key,
        message: canonicalJsonBytes(_body(build, at, reason)),
        signature: signature,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._body(build, at, reason),
    'k': key,
    's': signature,
  };

  static ReleaseRevocation? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'zen_revoke' ||
        json['app'] != kReleaseApp ||
        json['build'] is! int ||
        json['at'] is! int ||
        json['why'] is! String ||
        (json['why'] as String).length > 1000 ||
        json['k'] is! String ||
        json['s'] is! String) {
      return null;
    }
    return ReleaseRevocation(
      build: json['build'] as int,
      at: json['at'] as int,
      reason: json['why'] as String,
      key: json['k'] as String,
      signature: json['s'] as String,
    );
  }
}

/// A release with its files in one file (`.zenupdate`), for loading by
/// hand ("Wczytaj aktualizację z pliku") or putting on a website:
///
/// `ZENUPD1` · u32 length · signed release JSON · then per file:
/// u16 name length · name · u64 size · bytes.
final class ReleaseBundle {
  ReleaseBundle(this.release, this.files);

  static const List<int> magic = <int>[
    0x5A,
    0x45,
    0x4E,
    0x55,
    0x50,
    0x44,
    0x31,
  ];

  final SignedRelease release;

  /// File name → bytes.
  final Map<String, Uint8List> files;

  Uint8List encode() {
    final BytesBuilder out = BytesBuilder(copy: false)..add(magic);
    final Uint8List json = Uint8List.fromList(
      utf8.encode(jsonEncode(release.toJson())),
    );
    out
      ..add(_u32(json.length))
      ..add(json);
    files.forEach((String name, Uint8List bytes) {
      final List<int> n = utf8.encode(name);
      out
        ..add(<int>[n.length >> 8, n.length & 0xFF])
        ..add(n)
        ..add(_u64(bytes.length))
        ..add(bytes);
    });
    return out.takeBytes();
  }

  static Uint8List _u32(int v) =>
      (ByteData(4)..setUint32(0, v)).buffer.asUint8List();

  static Uint8List _u64(int v) =>
      (ByteData(8)
            ..setUint32(0, v ~/ 0x100000000)
            ..setUint32(4, v % 0x100000000))
          .buffer
          .asUint8List();

  /// Reads a bundle; `null` when it is not one or is damaged. Files whose
  /// bytes do not match the release are dropped.
  static ReleaseBundle? decode(Uint8List data) {
    try {
      if (data.length < magic.length + 4) {
        return null;
      }
      for (int i = 0; i < magic.length; i++) {
        if (data[i] != magic[i]) {
          return null;
        }
      }
      final ByteData view = ByteData.sublistView(data);
      int at = magic.length;
      final int jsonLength = view.getUint32(at);
      at += 4;
      if (jsonLength > 64 * 1024 || at + jsonLength > data.length) {
        return null;
      }
      final SignedRelease? release = SignedRelease.fromJson(
        jsonDecode(
          utf8.decode(Uint8List.sublistView(data, at, at + jsonLength)),
        ),
      );
      at += jsonLength;
      if (release == null) {
        return null;
      }
      final Map<String, Uint8List> files = <String, Uint8List>{};
      while (at + 2 <= data.length) {
        final int nameLength = view.getUint16(at);
        at += 2;
        if (at + nameLength + 8 > data.length) {
          return null;
        }
        final String name = utf8.decode(
          Uint8List.sublistView(data, at, at + nameLength),
        );
        at += nameLength;
        final int size =
            view.getUint32(at) * 0x100000000 + view.getUint32(at + 4);
        at += 8;
        if (size > kMaxBlobBytes || at + size > data.length) {
          return null;
        }
        final Uint8List bytes = Uint8List.sublistView(data, at, at + size);
        at += size;
        final ReleaseFile? meant = release.manifest.files
            .where((ReleaseFile f) => f.name == name)
            .firstOrNull;
        if (meant != null &&
            meant.size == bytes.length &&
            BlobManifest.describe(bytes, releaseMime(name)).id == meant.blob) {
          files[name] = bytes;
        }
      }
      return ReleaseBundle(release, files);
    } on Object {
      return null;
    }
  }
}
