import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/update/android_abi.dart';

/// Network updates: a new version travels from friend to friend
/// like any file. The app takes it only when [kReleaseThreshold] of the
/// project maintainers signed it, waits [kReleaseEmbargo] after first
/// seeing it (time for anyone to notice a forced release and for any one
/// maintainer to veto it), and then still only asks — it never installs
/// by itself.
const int kReleaseThreshold = 2;
const Duration kReleaseEmbargo = Duration(days: 7);

/// Hybrid ids of the release maintainers' keys ([LedgerKeyPair.hybridId]:
/// the Ed25519 key and the fingerprint of the ML-DSA-65 key, so both
/// halves of their signatures are pinned here). Empty for now.
/// Network updates stay off while it holds fewer than [kReleaseThreshold]
/// keys, until another way to approve versions is decided.
/// While it is empty nothing signed is taken:
/// no releases, vetoes, canaries or signed donation details.
///
/// Turning it on (docs/RELEASES.md, section 8): each maintainer runs
/// `dart run tool/zen_release.dart keygen <file>` on their own offline
/// machine and sends only the hybrid id it prints; then
/// `dart run tool/zen_release.dart maintainers --write <id1> <id2> <id3>`
/// fills this list, and the next release built with it takes updates.
///
/// The same keys sign the `SHA256SUMS` of GitHub releases ([SignedSums],
/// RELEASES.md, section 8.6): once this list is not empty, the self-update from
/// GitHub installs only a file one of them signed. One key is enough for
/// that; network updates still need [kReleaseThreshold] of them.
const List<String> kReleaseMaintainers = <String>[
  'QUiwGQh42Cea69lDpvgKCnOOk7aPpWRf7-ez8cKONUM=.UrlEj3eS6wepS2cQFvUTyJYb_kFpNvr4cIUsKxnveXI=',
];

const String kReleaseApp = 'zen';

/// Most entries in a release's `files` (only valid ones are used).
const int kMaxReleaseFiles = 64;

/// Payload type on the mesh: `{type, rel?, rev?}`.
const String kReleaseOfferType = 'zen_rel';

/// The platform names used in release files. Android has one APK per
/// ABI: `android-<the ABI this app runs as>` ([androidReleasePlatform]),
/// the file that surely installs over this one.
String currentReleasePlatform() {
  if (kIsWeb) {
    return 'web';
  }
  if (Platform.isAndroid) {
    return androidReleasePlatform(runningAndroidAbi ?? kDefaultAndroidAbi);
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

  /// `android-arm64-v8a` (one per ABI), `windows`, …
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

/// How many of [maintainers] (hybrid ids) signed [message]: [signatures]
/// maps a maintainer's hybrid id to its hybrid signature (base64url). Each
/// key counts once, and only with both halves: the Ed25519 one and the
/// ML-DSA one of exactly the pinned key.
Future<int> countMaintainerSignatures({
  required Uint8List message,
  required Map<String, String> signatures,
  required List<String> maintainers,
}) async {
  int valid = 0;
  for (final String key in maintainers.toSet()) {
    final String? sig = signatures[key];
    if (sig != null &&
        await verifyMaintainerSignature(
          maintainer: key,
          message: message,
          signature: sig,
        )) {
      valid++;
    }
  }
  return valid;
}

/// Whether [signature] over [message] is by the maintainer with the hybrid
/// id [maintainer]: both halves, the ML-DSA one of the pinned key.
Future<bool> verifyMaintainerSignature({
  required String maintainer,
  required Uint8List message,
  required String signature,
}) async {
  final ({String ed, String pq})? key = parseHybridKeyId(maintainer);
  return key != null &&
      await verifyLedgerSignature(
        publicKey: key.ed,
        message: message,
        signature: signature,
        pqId: key.pq,
      );
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
/// take the money or the credit: signed in the release
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
/// id), and optionally the official donation link and author and
/// the mirrors of the repository.
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
    this.rawFiles,
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

  /// The `files` list exactly as received (with entries this build skips:
  /// another platform's new kind of file, a size it does not take), so the
  /// signature still verifies; `null` for a manifest made here.
  final List<Object?>? rawFiles;

  /// The oldest Zen this release still supports (`min`, kept in [extra]),
  /// when it names one.
  String? get minVersion {
    final Object? min = extra['min'];
    return min is String && min.length <= 30 ? min : null;
  }

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
    'files':
        rawFiles ??
        <Map<String, dynamic>>[for (final ReleaseFile f in files) f.toJson()],
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
        files.length > kMaxReleaseFiles) {
      return null;
    }
    // An entry this build does not take (a newer tool's new kind of file,
    // a second file for one platform) is skipped, not a reason to miss the
    // update: only this platform's own file has to be right.
    final List<ReleaseFile> parsed = <ReleaseFile>[];
    for (final Object? f in files) {
      final ReleaseFile? file = ReleaseFile.fromJson(f);
      if (file != null &&
          !parsed.any((ReleaseFile p) => p.platform == file.platform)) {
        parsed.add(file);
      }
    }
    if (parsed.isEmpty) {
      return null;
    }
    try {
      // Signed as received: must encode the same way (no fractions…).
      if (canonicalJson(files).length > 64 * 1024) {
        return null;
      }
    } on ArgumentError {
      return null;
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
      rawFiles: List<Object?>.unmodifiable(files),
    );
  }
}

/// A manifest with the maintainers' signatures.
@immutable
final class SignedRelease {
  const SignedRelease(this.manifest, this.signatures);

  final ReleaseManifest manifest;

  /// Maintainer's hybrid id → hybrid signature (base64url).
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
    // Keyed, as every maintainer signature: phones pin a maintainer by
    // fingerprint and hold no other record of the key.
    final Uint8List sig = await maintainer.signWithKey(manifest.signedBytes());
    return SignedRelease(manifest, <String, String>{
      ...signatures,
      maintainer.hybridId: b64(sig),
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

/// The file of a GitHub release that carries [SignedSums].
/// (docs/RELEASES.md, section 8.6).
const String kSignedSumsAssetName = 'SHA256SUMS.sig';

/// What a maintainer signs for a GitHub release: its version and the
/// SHA-256 of every file in it, as its `SHA256SUMS` lists them. The format
/// is that of a signed release, `{"m": {"t": "zen_sums", "app", "version",
/// "files": {name: sha256}}, "sigs": [{"k", "s"}]}`, made by
/// `tool/zen_release.dart sums-manifest` and `sign`. The version is signed
/// too, so the files of an older release cannot be passed off as a newer
/// one.
@immutable
final class SignedSums {
  const SignedSums({
    required this.version,
    required this.files,
    required this.signatures,
  });

  final String version;

  /// File name → lower-case hex SHA-256.
  final Map<String, String> files;

  /// Maintainer's hybrid id → hybrid signature (base64url).
  final Map<String, String> signatures;

  static Map<String, dynamic> _body(
    String version,
    Map<String, String> files,
  ) => <String, dynamic>{
    't': 'zen_sums',
    'app': kReleaseApp,
    'version': version,
    'files': files,
  };

  Uint8List signedBytes() => canonicalJsonBytes(_body(version, files));

  Map<String, dynamic> toJson() => <String, dynamic>{
    'm': _body(version, files),
    'sigs': <Map<String, String>>[
      for (final MapEntry<String, String> e in signatures.entries)
        <String, String>{'k': e.key, 's': e.value},
    ],
  };

  static SignedSums? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? m = json['m'];
    final Map<String, String>? signatures = readSignatureList(json['sigs']);
    if (m is! Map ||
        m['t'] != 'zen_sums' ||
        m['app'] != kReleaseApp ||
        m.length != 4 ||
        signatures == null) {
      return null;
    }
    final Object? version = m['version'];
    final Object? files = m['files'];
    if (version is! String ||
        version.isEmpty ||
        version.length > 30 ||
        files is! Map ||
        files.isEmpty ||
        files.length > 64) {
      return null;
    }
    final Map<String, String> parsed = <String, String>{};
    for (final MapEntry<Object?, Object?> e in files.entries) {
      final Object? name = e.key;
      final Object? sha = e.value;
      if (name is! String || !_safeFileName(name) || !isHex(sha, 64)) {
        return null;
      }
      parsed[name] = sha as String;
    }
    return SignedSums(
      version: version,
      files: Map<String, String>.unmodifiable(parsed),
      signatures: signatures,
    );
  }

  /// Reads the text of a [kSignedSumsAssetName] file; null when it is not
  /// one.
  static SignedSums? decode(String text) {
    try {
      return fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  /// Adds the signature of [maintainer].
  Future<SignedSums> signedBy(LedgerKeyPair maintainer) async {
    final Uint8List sig = await maintainer.signWithKey(signedBytes());
    return SignedSums(
      version: version,
      files: files,
      signatures: <String, String>{
        ...signatures,
        maintainer.hybridId: b64(sig),
      },
    );
  }

  /// Whether one of [maintainers] signed that release [version] has the
  /// file [name] with exactly [sha256Hex]. Always false while
  /// [maintainers] is empty.
  Future<bool> confirms({
    required String version,
    required String name,
    required String sha256Hex,
    List<String> maintainers = kReleaseMaintainers,
  }) async =>
      maintainers.isNotEmpty &&
      this.version == version &&
      files[name] == sha256Hex.toLowerCase() &&
      await countMaintainerSignatures(
            message: signedBytes(),
            signatures: signatures,
            maintainers: maintainers,
          ) >=
          1;
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
    final Uint8List sig = await maintainer.signWithKey(
      canonicalJsonBytes(_body(build, when, reason)),
    );
    return ReleaseRevocation(
      build: build,
      at: when,
      reason: reason,
      key: maintainer.hybridId,
      signature: b64(sig),
    );
  }

  Future<bool> isValid({
    List<String> maintainers = kReleaseMaintainers,
  }) async =>
      maintainers.contains(key) &&
      await verifyMaintainerSignature(
        maintainer: key,
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
