import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/safe_file_name.dart';

/// Protection against media that is not what it claims to be.
///
/// Everything a friend (or a stranger) sends is checked by what its bytes
/// are, never by its name or by the type the sender claims:
///
/// * **Photos** are decoded by pure-Dart code and encoded again. The
///   phone's own image decoder (where image exploits live, like the WebP
///   hole of 2023) only ever sees a fresh file made here, without metadata.
///   Pictures too large to be a photo (decompression bombs) are refused
///   before they are decoded. An animated GIF is not re-encoded (that would
///   flatten it to one frame): its blocks are walked and it is accepted only
///   when complete and within [kMaxGifBytes], [kMaxGifSide], [kMaxGifFrames]
///   and [kMaxGifTotalPixels]; otherwise it becomes a plain file.
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

/// The largest animated GIF accepted, in bytes.
const int kMaxGifBytes = 12 * 1024 * 1024;

/// The largest GIF canvas accepted, in pixels per side.
const int kMaxGifSide = 2560;

/// The most frames an accepted GIF may have.
const int kMaxGifFrames = 400;

/// The most pixels an accepted GIF may have summed over all its frames
/// (frames x canvas): bounds the memory and time of playing it.
const int kMaxGifTotalPixels = 200 * 1000 * 1000;

/// The most memory a picture from someone else may take once decoded
/// (width × height × channels × bytes per channel), judged from its header
/// before anything is decoded: a 40-million-pixel photo fits, the same
/// picture as a 16-bit PNG does not.
const int kMaxIncomingImageDecodedBytes = 128 * 1024 * 1024;

/// Pictures that decode to more than this many bytes are re-encoded in a
/// separate isolate. Judged from the header, not the file size: a file of
/// a few KB may hold a picture of many millions of pixels.
const int _inlineDecodedBytes = 256 * 256 * 4;

/// What decoding a picture takes, read from its header.
typedef ImageCost = ({int width, int height, int decodedBytes});

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
      if (isAcceptableGif(bytes)) {
        return GuardedMedia(
          bytes: bytes,
          kind: MediaKind.image,
          mimeType: 'image/gif',
          fileName: _withExtension(name, 'gif'),
        );
      }
      if (actual == MediaKind.image && !_isGif(bytes)) {
        final int? cost = incomingImageCost(bytes)?.decodedBytes;
        final Uint8List? clean =
            cost == null || cost > kMaxIncomingImageDecodedBytes
            ? null
            : cost > _inlineDecodedBytes
            ? await _reencodeInIsolate(bytes)
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
        t('To nie był obraz, więc zapisano go jako plik.'),
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
        t('To nie był film, więc zapisano go jako plik.'),
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
        t('To nie było nagranie, więc zapisano je jako plik.'),
      );
    case MediaKind.file:
      return _asFile(bytes, name, null, mimeType: mimeType);
  }
}

// Not async on purpose: a closure made in an async function may drag its
// suspended frame along, which cannot be sent to another isolate.
Future<Uint8List?> _reencodeInIsolate(Uint8List bytes) =>
    Isolate.run(() => reencodeIncomingImage(bytes));

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

/// Whether [bytes] are a well-formed GIF within the limits: the `GIF87a` or
/// `GIF89a` signature, a canvas of at most [kMaxGifSide] a side, between 1
/// and [kMaxGifFrames] frames, at most [kMaxGifTotalPixels] pixels over all
/// frames, every block inside the file, and the trailer at the end.
/// Checked by walking the blocks, without decoding any pixels.
bool isAcceptableGif(Uint8List bytes) {
  final int length = bytes.length;
  if (length < 14 || length > kMaxGifBytes) {
    return false;
  }
  final bool signature =
      _isGif(bytes) &&
      (bytes[4] == 0x37 || bytes[4] == 0x39) &&
      bytes[5] == 0x61;
  if (!signature) {
    return false;
  }
  final int width = bytes[6] | (bytes[7] << 8);
  final int height = bytes[8] | (bytes[9] << 8);
  if (width <= 0 ||
      height <= 0 ||
      width > kMaxGifSide ||
      height > kMaxGifSide) {
    return false;
  }
  final int packed = bytes[10];
  int offset = 13;
  if ((packed & 0x80) != 0) {
    offset += 3 * (1 << ((packed & 0x07) + 1));
  }
  // Skips a chain of data sub-blocks; the new offset, or -1 if truncated.
  int skipSubBlocks(int at) {
    int i = at;
    while (true) {
      if (i >= length) {
        return -1;
      }
      final int size = bytes[i];
      i += 1 + size;
      if (size == 0) {
        return i <= length ? i : -1;
      }
    }
  }

  int frames = 0;
  while (offset < length) {
    final int block = bytes[offset];
    if (block == 0x3B) {
      // Trailer: must be the last byte.
      return offset == length - 1 &&
          frames >= 1 &&
          frames * width * height <= kMaxGifTotalPixels;
    }
    if (block == 0x21) {
      if (offset + 2 > length) {
        return false;
      }
      offset = skipSubBlocks(offset + 2);
    } else if (block == 0x2C) {
      if (offset + 10 > length || ++frames > kMaxGifFrames) {
        return false;
      }
      final int framePacked = bytes[offset + 9];
      final int frameWidth = bytes[offset + 5] | (bytes[offset + 6] << 8);
      final int frameHeight = bytes[offset + 7] | (bytes[offset + 8] << 8);
      if (frameWidth > width || frameHeight > height) {
        return false;
      }
      offset += 10;
      if ((framePacked & 0x80) != 0) {
        offset += 3 * (1 << ((framePacked & 0x07) + 1));
      }
      // The LZW minimum code size byte, then the pixel data.
      offset = offset >= length ? -1 : skipSubBlocks(offset + 1);
    } else {
      return false;
    }
    if (offset < 0) {
      return false;
    }
  }
  return false;
}

/// The size of the picture [bytes] once decoded, from its header alone
/// (nothing is decompressed): a PNG by its bit depth and colour type (a
/// 16-bit channel takes two bytes), a JPEG as 8-bit RGB, a WebP or BMP as
/// 8-bit RGBA. Null when it is not a JPEG, PNG, WebP or BMP whose header
/// reads.
ImageCost? incomingImageCost(Uint8List bytes) {
  if (_isPng(bytes)) {
    return _pngCost(bytes);
  }
  final bool jpeg = _isJpeg(bytes);
  if (!jpeg &&
      !_isRiff(bytes, 'WEBP') &&
      !_startsWith(bytes, const <int>[0x42, 0x4D])) {
    return null;
  }
  try {
    final img.DecodeInfo? info = img
        .findDecoderForData(bytes)
        ?.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) {
      return null;
    }
    return (
      width: info.width,
      height: info.height,
      decodedBytes: info.width * info.height * (jpeg ? 3 : 4),
    );
  } on Object {
    return null;
  }
}

ImageCost? _pngCost(Uint8List b) {
  // The signature (8 bytes), then the IHDR chunk: length (4), "IHDR",
  // width (4), height (4), bit depth, colour type.
  if (b.length < 33 || String.fromCharCodes(b.sublist(12, 16)) != 'IHDR') {
    return null;
  }
  final ByteData data = ByteData.sublistView(b);
  final int width = data.getUint32(16);
  final int height = data.getUint32(20);
  final int depth = b[24];
  final int channels = switch (b[25]) {
    0 => 1, // grey
    2 => 3, // RGB
    3 => 4, // palette: may become RGBA
    4 => 2, // grey and alpha
    6 => 4, // RGBA
    _ => 0,
  };
  if (width <= 0 ||
      height <= 0 ||
      channels == 0 ||
      !const <int>{1, 2, 4, 8, 16}.contains(depth)) {
    return null;
  }
  return (
    width: width,
    height: height,
    decodedBytes: width * height * channels * (depth == 16 ? 2 : 1),
  );
}

/// Re-encodes a picture from someone else: decoded here (pure Dart), only
/// its first frame, upright, scaled to [kMaxIncomingImageSide], without
/// metadata. JPEG, or PNG when it has transparency. Null when it is not a
/// JPEG, PNG, WebP or BMP this can read, or its header says it is too
/// large to be a photo ([kMaxIncomingImagePixels],
/// [kMaxIncomingImageDecodedBytes]): then nothing is decoded at all.
Uint8List? reencodeIncomingImage(Uint8List bytes) {
  try {
    final ImageCost? cost = incomingImageCost(bytes);
    if (cost == null ||
        cost.width * cost.height > kMaxIncomingImagePixels ||
        cost.decodedBytes > kMaxIncomingImageDecodedBytes) {
      return null;
    }
    final img.Decoder? decoder = img.findDecoderForData(bytes);
    if (decoder == null) {
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

/// Whether a film that is still downloading may go to the player,
/// from its first bytes [head] and its whole [length]: a video, and for an
/// MP4/MOV file the first box is `ftyp` and every top-level box that starts
/// in [head] has a printable name and fits in [length]. What comes later is
/// left to the player, which reads it as it arrives.
bool looksLikeSafeStreamStart(Uint8List head, int length) {
  if (sniffMediaKind(head) != MediaKind.video || head.length > length) {
    return false;
  }
  if (_isoBrand(head) == null) {
    return looksLikeSafeContainer(head);
  }
  final ByteData data = ByteData.sublistView(head);
  int offset = 0;
  int boxes = 0;
  while (offset + 8 <= head.length) {
    if (++boxes > 4096) {
      return false;
    }
    for (int i = 4; i < 8; i++) {
      final int c = head[offset + i];
      if ((c < 0x20 || c > 0x7E) && c != 0xA9) {
        return false;
      }
    }
    int size = data.getUint32(offset);
    int header = 8;
    if (size == 1) {
      if (offset + 16 > head.length || data.getUint32(offset + 8) != 0) {
        return false;
      }
      size = data.getUint32(offset + 12);
      header = 16;
    } else if (size == 0) {
      size = length - offset;
    }
    if (size < header || offset + size > length) {
      return false;
    }
    offset += size;
  }
  return true;
}

/// Whether [head] starts an MP4/MOV file (its first box is `ftyp`).
bool isIsoMedia(Uint8List head) => _isoBrand(head) != null;

/// The size of the top-level box of an MP4/MOV file that starts at
/// [offset] of a file of [length] bytes, from its first bytes [header] (16,
/// fewer only at the very end of the file); -1 when the box does not add up
/// (unprintable name, smaller than its header, reaching past the file).
/// Checked piece by piece as a film that plays while it downloads arrives.
int isoBoxSizeAt(Uint8List header, int offset, int length) {
  if (header.length < 8 || offset < 0 || offset + 8 > length) {
    return -1;
  }
  for (int i = 4; i < 8; i++) {
    final int c = header[i];
    if ((c < 0x20 || c > 0x7E) && c != 0xA9) {
      return -1;
    }
  }
  final ByteData data = ByteData.sublistView(header);
  int size = data.getUint32(0);
  int headerSize = 8;
  if (size == 1) {
    if (header.length < 16 || data.getUint32(8) != 0) {
      return -1;
    }
    size = data.getUint32(12);
    headerSize = 16;
  } else if (size == 0) {
    size = length - offset;
  }
  if (size < headerSize || offset + size > length) {
    return -1;
  }
  return size;
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
  'exe', 'com', 'scr', 'pif', 'bat', 'cmd', 'msi', 'msp', 'mst', 'msc',
  'dll', 'cpl', 'sys', 'drv', 'ocx', 'lnk', 'url', 'scf', 'inf', 'reg',
  'hta', 'htc', 'chm', 'hlp', 'gadget', 'application', 'xbap', 'website',
  'appref-ms', 'settingcontent-ms', 'library-ms', 'search-ms',
  'searchconnector-ms', 'appx', 'appxbundle', 'msix', 'msixbundle',
  'ps1', 'ps1xml', 'ps2', 'ps2xml', 'psc1', 'psc2', 'psm1', 'psd1',
  'msh', 'msh1', 'msh2', 'mshxml', 'msh1xml', 'msh2xml', 'vb', 'vbs',
  'vbe', 'js', 'jse', 'wsf', 'wsh', 'ws', 'wsc', 'sct', 'job', 'jar',
  'jnlp', 'iso', 'img', 'vhd', 'vhdx', 'xll', 'iqy', 'cab', 'diagcab',
  'diagcfg', 'diagpkg', 'theme', 'themepack', 'shb', 'shs',
  // Office documents with macros
  'docm', 'dotm', 'xlsm', 'xltm', 'xlam', 'pptm', 'potm', 'ppam', 'sldm',
  // Android
  'apk', 'apks', 'xapk', 'apkm', 'aab', 'dex',
  // macOS / iOS / Linux
  'app', 'dmg', 'pkg', 'mpkg', 'command', 'sh', 'bash', 'zsh', 'csh',
  'ksh', 'fish', 'run', 'deb', 'rpm', 'appimage', 'snap', 'flatpak',
  'flatpakref', 'desktop', 'workflow', 'action', 'scpt', 'scptd',
  'applescript', 'terminal', 'osx', 'ipa', 'py', 'pyw', 'pyc', 'pyz',
  'pyzw', 'pl', 'rb',
};

/// Whether [fileName] ends in an extension that runs something.
///
/// The name is read the way the system will: Windows drops dots and spaces
/// at the end (`faktura.exe.`, `skrypt.ps1 ` run as `.exe` and `.ps1`), and
/// invisible characters (zero-width spaces, direction marks) never count.
/// Only the last extension matters, so a double extension that dresses a
/// program up as a document (`zdjecie.jpg.exe`) is risky too. A name with an
/// alternate data stream (`plik.exe:strumien`) is taken for the file the
/// stream hangs on. Compared case-insensitively.
bool hasRiskyExtension(String fileName) {
  final String name = fileName
      .replaceAll(_invisibleInName, '')
      .trim()
      .toLowerCase();
  if (_endsInRiskyExtension(name)) {
    return true;
  }
  final int colon = name.indexOf(':');
  return colon > 0 && _endsInRiskyExtension(name.substring(0, colon));
}

final RegExp _invisibleInName = RegExp(
  r'[\u0000-\u001f\u007f-\u009f\u00AD\u200B-\u200F\u202A-\u202E'
  r'\u2060-\u2064\u2066-\u2069\uFEFF]',
);

bool _endsInRiskyExtension(String name) {
  final String trimmed = trimNameEnd(name);
  final int dot = trimmed.lastIndexOf('.');
  if (dot < 0 || dot == trimmed.length - 1) {
    return false;
  }
  return _riskyExtensions.contains(trimmed.substring(dot + 1));
}

String _cleanName(String? raw, MediaKind declared) {
  String name = (raw ?? '').replaceAll(RegExp(r'[\\/]'), '_').trim();
  // Direction marks can turn "gpj.exe" into what looks like "exe.jpg".
  name = name.replaceAll(
    RegExp(r'[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069]'),
    '',
  );
  // Windows drops dots and spaces at the end: "faktura.exe." is "faktura.exe".
  name = trimNameEnd(name.replaceAll(RegExp(r'^\.+'), ''));
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
