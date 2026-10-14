import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Protection against media that is not what it claims to be (§19).
///
/// Everything a friend (or a stranger) sends is checked by what its bytes
/// are, never by its name or by the type the sender claims:
///
/// * **Photos** are decoded by pure-Dart code and encoded again. The
///   phone's own image decoder (where image exploits live, like the WebP
///   hole of 2023) only ever sees a fresh file made here, without metadata.
///   Pictures too large to be a photo (decompression bombs) are refused
///   before they are decoded.
/// * **Videos and audio** cannot be re-encoded on the phone, so their
///   container is checked: a known format, and a structure that adds up
///   (no boxes reaching past the end of the file). Anything else becomes a
///   plain file, which Zen never plays.
/// * **Files** are kept as they are, but Zen never opens them, and a file
///   that could start a program (by its content or its name) gets a warning
///   before it is saved.
enum MediaKind { image, video, audio, file }

/// The largest picture accepted: 40 million pixels (a 7700 × 5200 photo).
const int kMaxIncomingImagePixels = 40 * 1000 * 1000;

/// The longest side of a picture after it is re-encoded.
const int kMaxIncomingImageSide = 2560;

/// Pictures above this many bytes are re-encoded in a separate isolate.
const int _isolateThresholdBytes = 32 * 1024;

@immutable
final class GuardedMedia {
  const GuardedMedia({
    required this.bytes,
    required this.kind,
    required this.mimeType,
    required this.fileName,
    this.note,
    this.risky = false,
  });

  /// What is stored: the re-encoded picture, or the original bytes.
  final Uint8List bytes;

  /// What it is now (a "photo" that is not a picture becomes a file).
  final MediaKind kind;
  final String mimeType;
  final String fileName;

  /// Why it was not taken as what it claimed to be (for a system note), or
  /// null.
  final String? note;

  /// Could start a program if opened outside Zen.
  final bool risky;
}

/// Checks [bytes] that arrived as [declared] (see the library comment).
Future<GuardedMedia> guardIncomingMedia(
  Uint8List bytes, {
  required MediaKind declared,
  String? mimeType,
  String? fileName,
}) async {
  final String name = _cleanName(fileName, declared);
  final MediaKind actual = sniffMediaKind(bytes);
  switch (declared) {
    case MediaKind.image:
      if (actual == MediaKind.image) {
        final Uint8List? clean = bytes.length > _isolateThresholdBytes
            ? await Isolate.run(() => reencodeIncomingImage(bytes))
            : reencodeIncomingImage(bytes);
        if (clean != null) {
          final bool png = _isPng(clean);
          return GuardedMedia(
            bytes: clean,
            kind: MediaKind.image,
            mimeType: png ? 'image/png' : 'image/jpeg',
            fileName: _withExtension(name, png ? 'png' : 'jpg'),
          );
        }
      }
      return _asFile(
        bytes,
        name,
        'To nie był obraz, więc zapisano go jako plik.',
      );
    case MediaKind.video:
      if (actual == MediaKind.video && looksLikeSafeContainer(bytes)) {
        return GuardedMedia(
          bytes: bytes,
          kind: MediaKind.video,
          mimeType: sniffMimeType(bytes) ?? 'video/mp4',
          fileName: name,
        );
      }
      return _asFile(
        bytes,
        name,
        'To nie był film, więc zapisano go jako plik.',
      );
    case MediaKind.audio:
      if ((actual == MediaKind.audio || actual == MediaKind.video) &&
          looksLikeSafeContainer(bytes)) {
        return GuardedMedia(
          bytes: bytes,
          kind: MediaKind.audio,
          mimeType: sniffMimeType(bytes) ?? 'audio/mp4',
          fileName: name,
        );
      }
      return _asFile(
        bytes,
        name,
        'To nie było nagranie, więc zapisano je jako plik.',
      );
    case MediaKind.file:
      return _asFile(bytes, name, null, mimeType: mimeType);
  }
}

GuardedMedia _asFile(
  Uint8List bytes,
  String name,
  String? note, {
  String? mimeType,
}) {
  final bool risky = isRiskyFile(bytes, name);
  return GuardedMedia(
    bytes: bytes,
    kind: MediaKind.file,
    // The claimed type is not trusted for anything that could run.
    mimeType: risky
        ? 'application/octet-stream'
        : (sniffMimeType(bytes) ??
              (mimeType != null && _plainMime.hasMatch(mimeType)
                  ? mimeType
                  : 'application/octet-stream')),
    fileName: name,
    note: note,
    risky: risky,
  );
}

final RegExp _plainMime = RegExp(r'^[a-z]+/[a-z0-9.+-]{1,60}$');

/// What [bytes] are by their first bytes.
MediaKind sniffMediaKind(Uint8List bytes) {
  if (_isJpeg(bytes) ||
      _isPng(bytes) ||
      _isGif(bytes) ||
      _isRiff(bytes, 'WEBP') ||
      _startsWith(bytes, const <int>[0x42, 0x4D])) {
    return MediaKind.image;
  }
  final String? brand = _isoBrand(bytes);
  if (brand != null) {
    if (const <String>{'M4A ', 'M4B ', 'M4P ', 'F4A '}.contains(brand)) {
      return MediaKind.audio;
    }
    if (const <String>{
      'heic',
      'heix',
      'mif1',
      'msf1',
      'avif',
      'avis',
    }.contains(brand)) {
      // A HEIC/AVIF picture: no decoder here can make a safe copy of it.
      return MediaKind.file;
    }
    return MediaKind.video;
  }
  if (_isMatroska(bytes)) {
    return MediaKind.video;
  }
  if (_startsWith(bytes, const <int>[0x4F, 0x67, 0x67, 0x53]) || // OggS
      _isRiff(bytes, 'WAVE') ||
      _startsWith(bytes, const <int>[0x66, 0x4C, 0x61, 0x43]) || // fLaC
      _startsWith(bytes, const <int>[0x23, 0x21, 0x41, 0x4D, 0x52]) || // #!AMR
      _startsWith(bytes, const <int>[0x49, 0x44, 0x33]) || // ID3 (MP3)
      _isMpegAudioFrame(bytes)) {
    return MediaKind.audio;
  }
  return MediaKind.file;
}

/// The real type of [bytes] when it is a known media format, else null.
String? sniffMimeType(Uint8List bytes) {
  if (_isJpeg(bytes)) {
    return 'image/jpeg';
  }
  if (_isPng(bytes)) {
    return 'image/png';
  }
  if (_isGif(bytes)) {
    return 'image/gif';
  }
  if (_isRiff(bytes, 'WEBP')) {
    return 'image/webp';
  }
  final String? brand = _isoBrand(bytes);
  if (brand != null) {
    if (brand.startsWith('M4')) {
      return 'audio/mp4';
    }
    if (brand == 'qt  ') {
      return 'video/quicktime';
    }
    if (brand.startsWith('3g')) {
      return 'video/3gpp';
    }
    return 'video/mp4';
  }
  if (_isMatroska(bytes)) {
    return 'video/webm';
  }
  if (_startsWith(bytes, const <int>[0x4F, 0x67, 0x67, 0x53])) {
    return 'audio/ogg';
  }
  if (_isRiff(bytes, 'WAVE')) {
    return 'audio/wav';
  }
  if (_startsWith(bytes, const <int>[0x49, 0x44, 0x33]) ||
      _isMpegAudioFrame(bytes)) {
    return 'audio/mpeg';
  }
  if (_startsWith(bytes, const <int>[0x25, 0x50, 0x44, 0x46])) {
    return 'application/pdf';
  }
  return null;
}

/// Re-encodes a picture from someone else: decoded here (pure Dart), only
/// its first frame, upright, scaled to [kMaxIncomingImageSide], without
/// metadata. JPEG, or PNG when it has transparency. Null when it is not a
/// picture this can read, or it is too large to be a photo.
Uint8List? reencodeIncomingImage(Uint8List bytes) {
  try {
    final img.Decoder? decoder = img.findDecoderForData(bytes);
    if (decoder == null) {
      return null;
    }
    final img.DecodeInfo? info = decoder.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > kMaxIncomingImagePixels) {
      return null;
    }
    final img.Image? decoded = decoder.decode(bytes, frame: 0);
    if (decoded == null ||
        decoded.width * decoded.height > kMaxIncomingImagePixels) {
      return null;
    }
    img.Image image = img.bakeOrientation(decoded);
    final int longest = math.max(image.width, image.height);
    if (longest > kMaxIncomingImageSide) {
      image = image.width >= image.height
          ? img.copyResize(image, width: kMaxIncomingImageSide)
          : img.copyResize(image, height: kMaxIncomingImageSide);
    }
    image.exif = img.ExifData();
    if (image.numChannels == 4) {
      return img.encodePng(image);
    }
    return img.encodeJpg(image, quality: 88);
  } on Object {
    return null;
  }
}

/// Whether a video or audio container adds up: an MP4/MOV/3GP/M4A whose
/// boxes all fit inside the file (and one of them holds the media), or a
/// WebM/Matroska file that says so in its header, or a plain audio stream.
bool looksLikeSafeContainer(Uint8List bytes) {
  if (_isoBrand(bytes) != null) {
    return _isoBoxesAddUp(bytes);
  }
  if (_isMatroska(bytes)) {
    final int end = math.min(bytes.length, 64);
    final String head = String.fromCharCodes(
      bytes.sublist(0, end).map((int b) => b >= 0x20 && b < 0x7F ? b : 0x2E),
    );
    return head.contains('webm') || head.contains('matroska');
  }
  return sniffMediaKind(bytes) == MediaKind.audio;
}

bool _isoBoxesAddUp(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  int offset = 0;
  int boxes = 0;
  bool media = false;
  while (offset + 8 <= bytes.length) {
    if (++boxes > 4096) {
      return false;
    }
    int size = data.getUint32(offset);
    int header = 8;
    for (int i = 4; i < 8; i++) {
      final int c = bytes[offset + i];
      // Box names are printable (QuickTime also uses ©).
      if ((c < 0x20 || c > 0x7E) && c != 0xA9) {
        return false;
      }
    }
    final String type = String.fromCharCodes(
      bytes.sublist(offset + 4, offset + 8),
    );
    if (size == 1) {
      if (offset + 16 > bytes.length) {
        return false;
      }
      final int high = data.getUint32(offset + 8);
      final int low = data.getUint32(offset + 12);
      if (high != 0) {
        return false; // over 4 GB: not something that came through Zen
      }
      size = low;
      header = 16;
    } else if (size == 0) {
      size = bytes.length - offset; // the last box runs to the end
    }
    if (size < header || offset + size > bytes.length) {
      return false;
    }
    if (boxes == 1 && type != 'ftyp') {
      return false;
    }
    if (type == 'moov' || type == 'mdat' || type == 'moof') {
      media = true;
    }
    offset += size;
  }
  return media;
}

/// Whether [bytes] named [fileName] could start a program when opened on a
/// computer or phone: an executable or script by its content, a package
/// (APK, JAR, any ZIP named like one), or a name ending in such an
/// extension.
bool isRiskyFile(Uint8List bytes, String fileName) {
  if (looksExecutable(bytes)) {
    return true;
  }
  return hasRiskyExtension(fileName);
}

/// Program code by its first bytes: Windows (MZ), Linux (ELF), macOS
/// (Mach-O), Android (DEX), Java classes and scripts with `#!`.
bool looksExecutable(Uint8List bytes) {
  return _startsWith(bytes, const <int>[0x4D, 0x5A]) || // MZ
      _startsWith(bytes, const <int>[0x7F, 0x45, 0x4C, 0x46]) || // ELF
      _startsWith(bytes, const <int>[0xFE, 0xED, 0xFA, 0xCE]) ||
      _startsWith(bytes, const <int>[0xFE, 0xED, 0xFA, 0xCF]) ||
      _startsWith(bytes, const <int>[0xCE, 0xFA, 0xED, 0xFE]) ||
      _startsWith(bytes, const <int>[0xCF, 0xFA, 0xED, 0xFE]) ||
      _startsWith(bytes, const <int>[0xCA, 0xFE, 0xBA, 0xBE]) ||
      _startsWith(bytes, const <int>[0x64, 0x65, 0x78, 0x0A]) || // dex\n
      _startsWith(bytes, const <int>[0x23, 0x21]); // #!
}

const Set<String> _riskyExtensions = <String>{
  // Windows
  'exe', 'com', 'scr', 'pif', 'bat', 'cmd', 'msi', 'msp', 'msc', 'dll',
  'cpl', 'sys', 'drv', 'ocx', 'lnk', 'url', 'scf', 'inf', 'reg', 'hta',
  'chm', 'gadget', 'application', 'appref-ms', 'appx', 'appxbundle',
  'msix', 'msixbundle', 'ps1', 'psm1', 'psd1', 'vbs', 'vbe', 'js', 'jse',
  'wsf', 'wsh', 'ws', 'jar', 'iso', 'img', 'vhd', 'vhdx', 'xll',
  // Office documents with macros
  'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'pptm', 'potm', 'ppam', 'sldm',
  // Android
  'apk', 'apks', 'xapk', 'apkm', 'aab', 'dex',
  // macOS / Linux
  'app', 'dmg', 'pkg', 'command', 'sh', 'bash', 'zsh', 'run',
  'deb', 'rpm', 'appimage', 'desktop', 'py', 'pyw', 'pl', 'rb',
};

/// Whether [fileName] ends in an extension that runs something.
bool hasRiskyExtension(String fileName) {
  final String name = fileName.trim().toLowerCase();
  final int dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) {
    return false;
  }
  return _riskyExtensions.contains(name.substring(dot + 1));
}

String _cleanName(String? raw, MediaKind declared) {
  String name = (raw ?? '').replaceAll(RegExp(r'[\\/]'), '_').trim();
  // Direction marks can turn "gpj.exe" into what looks like "exe.jpg".
  name = name.replaceAll(
    RegExp(r'[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069]'),
    '',
  );
  name = name.replaceAll(RegExp(r'^\.+'), '');
  if (name.isEmpty) {
    name = switch (declared) {
      MediaKind.image => 'zdjecie.jpg',
      MediaKind.video => 'film.mp4',
      MediaKind.audio => 'nagranie.m4a',
      MediaKind.file => 'plik',
    };
  }
  return name.length > 120 ? name.substring(name.length - 120) : name;
}

String _withExtension(String name, String extension) {
  final int dot = name.lastIndexOf('.');
  final String stem = dot > 0 ? name.substring(0, dot) : name;
  return '$stem.$extension';
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) {
    return false;
  }
  for (int i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) {
      return false;
    }
  }
  return true;
}

bool _isJpeg(Uint8List b) => _startsWith(b, const <int>[0xFF, 0xD8, 0xFF]);

bool _isPng(Uint8List b) => _startsWith(b, const <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
]);

bool _isGif(Uint8List b) =>
    _startsWith(b, const <int>[0x47, 0x49, 0x46, 0x38]); // GIF8

bool _isRiff(Uint8List b, String form) {
  if (b.length < 12 || !_startsWith(b, const <int>[0x52, 0x49, 0x46, 0x46])) {
    return false;
  }
  return String.fromCharCodes(b.sublist(8, 12)) == form;
}

bool _isMatroska(Uint8List b) =>
    _startsWith(b, const <int>[0x1A, 0x45, 0xDF, 0xA3]);

/// The major brand of an ISO media file (MP4, MOV, 3GP, M4A, HEIC), or
/// null when [b] does not start with an `ftyp` box.
String? _isoBrand(Uint8List b) {
  if (b.length < 12) {
    return null;
  }
  if (String.fromCharCodes(b.sublist(4, 8)) != 'ftyp') {
    return null;
  }
  return String.fromCharCodes(b.sublist(8, 12));
}

bool _isMpegAudioFrame(Uint8List b) {
  if (b.length < 4) {
    return false;
  }
  // Frame sync (11 bits), a valid version/layer, a bitrate that is not
  // "bad" (15) and a valid sampling rate.
  if (b[0] != 0xFF || (b[1] & 0xE0) != 0xE0) {
    return false;
  }
  final int layer = (b[1] >> 1) & 0x03;
  final int bitrate = (b[2] >> 4) & 0x0F;
  final int sampling = (b[2] >> 2) & 0x03;
  if ((b[1] & 0xF6) == 0xF0) {
    return true; // AAC in ADTS
  }
  return layer != 0 && bitrate != 0x0F && sampling != 0x03;
}

/// The largest recording (a voice message or an audio file) sent in a chat
/// or a post.
const int kMaxAudioFileBytes = 25 * 1024 * 1024;
