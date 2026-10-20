import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/chat/remote_media_guard.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Largest GIF fetched for display, in bytes.
const int _maxGifBytes = 12 * 1024 * 1024;

/// Longest side, in pixels, an animated image is decoded at. Every frame is
/// decoded at this size; a GIF declaring huge dimensions would otherwise
/// cost gigabytes per frame.
const int _maxDecodePx = 1024;

/// Redirects followed for one GIF, each checked against the allow-list.
const int _maxGifRedirects = 3;

/// Largest canvas, in pixels per side, a GIF fetched by URL may declare.
const int _maxRemoteGifCanvasPx = 4096;

/// Fetches the bytes of the GIF at a URL; null when it cannot be had.
typedef GifFetcher = Future<Uint8List?> Function(String url);

/// Whether [bytes] fetched from a GIF host may be handed to the platform
/// image decoder: they must be a GIF (`GIF87a`/`GIF89a` — not any other
/// format the system decoder would also parse) within the byte limit, whose
/// declared canvas is non-empty and at most [_maxRemoteGifCanvasPx] a side.
/// Checked before decoding, so third-party content reaches only the GIF
/// decoder and only with sane dimensions.
bool isAcceptableRemoteGif(Uint8List bytes) {
  if (bytes.length < 13 || bytes.length > _maxGifBytes) {
    return false;
  }
  final bool signature =
      bytes[0] == 0x47 && // G
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x38 && // 8
      (bytes[4] == 0x37 || bytes[4] == 0x39) && // 7 or 9
      bytes[5] == 0x61; // a
  if (!signature) {
    return false;
  }
  // Logical screen descriptor: little-endian width and height.
  final int width = bytes[6] | (bytes[7] << 8);
  final int height = bytes[8] | (bytes[9] << 8);
  return width > 0 &&
      height > 0 &&
      width <= _maxRemoteGifCanvasPx &&
      height <= _maxRemoteGifCanvasPx;
}

ui.TargetImageSize _boundedDecodeSize(int width, int height) {
  if (width <= _maxDecodePx && height <= _maxDecodePx) {
    return const ui.TargetImageSize();
  }
  final int longest = width >= height ? width : height;
  final double scale = _maxDecodePx / longest;
  final int targetWidth = (width * scale).round();
  final int targetHeight = (height * scale).round();
  return ui.TargetImageSize(
    width: targetWidth < 1 ? 1 : targetWidth,
    height: targetHeight < 1 ? 1 : targetHeight,
  );
}

/// Recently shown GIFs, so scrolling back does not download them again.
final LinkedHashMap<String, Uint8List> _gifCache =
    LinkedHashMap<String, Uint8List>();
final Map<String, Future<Uint8List?>> _gifInFlight =
    <String, Future<Uint8List?>>{};

/// Whether the GIF at [url] is already in memory: showing it then costs no
/// request.
bool _isGifCached(String url) => _gifCache.containsKey(url);

Future<Uint8List?> _fetchGif(String url) {
  final Uint8List? cached = _gifCache.remove(url);
  if (cached != null) {
    _gifCache[url] = cached; // most recently used last
    return Future<Uint8List?>.value(cached);
  }
  return _gifInFlight.putIfAbsent(url, () async {
    try {
      if (!isAllowedRemoteMediaUrl(url)) {
        return null;
      }
      final HttpClient client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        // Redirects are followed by hand: an automatic one could lead off
        // the allow-listed host (to a tracker, or the local network).
        Uri target = Uri.parse(url);
        HttpClientResponse? response;
        for (int hop = 0; hop <= _maxGifRedirects; hop++) {
          final HttpClientRequest request = await client.getUrl(target);
          request.followRedirects = false;
          final HttpClientResponse candidate = await request.close();
          if (!candidate.isRedirect) {
            response = candidate;
            break;
          }
          final String? location = candidate.headers.value(
            HttpHeaders.locationHeader,
          );
          await candidate.drain<void>();
          final Uri next = location == null ? target : target.resolve(location);
          if (location == null || !isAllowedRemoteMediaUrl(next.toString())) {
            return null;
          }
          target = next;
        }
        if (response == null || response.statusCode != HttpStatus.ok) {
          return null;
        }
        if (response.contentLength > _maxGifBytes) {
          // Not read at all; the forced close below drops the connection.
          return null;
        }
        final BytesBuilder builder = BytesBuilder(copy: false);
        await for (final List<int> chunk in response) {
          builder.add(chunk);
          if (builder.length > _maxGifBytes) {
            return null;
          }
        }
        final Uint8List bytes = builder.takeBytes();
        if (!isAcceptableRemoteGif(bytes)) {
          logZenWarning('A fetched GIF is not a GIF of acceptable size');
          return null;
        }
        _gifCache[url] = bytes;
        while (_gifCache.length > 40) {
          _gifCache.remove(_gifCache.keys.first);
        }
        return bytes;
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      logZenWarning('Fetching a GIF failed: $error');
      return null;
    } finally {
      unawaited(Future<void>(() => _gifInFlight.remove(url)));
    }
  });
}

/// An animated image that keeps playing on every platform.
///
/// Plays frames itself from the decoded codec instead of relying on
/// `Image`'s own animation, which stayed on the first frame here. Takes
/// either a (allow-listed) [url], raw [bytes] or a [file].
///
/// A [url] is fetched as soon as this is built: for a GIF a peer sent, use
/// [ZenRemoteGif], which waits for a tap.
class ZenAnimatedImage extends StatefulWidget {
  const ZenAnimatedImage({
    super.key,
    this.url,
    this.bytes,
    this.file,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.errorBuilder,
    this.fetcher,
  });

  final String? url;
  final Uint8List? bytes;
  final File? file;
  final BoxFit fit;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Fetches [url]; the allow-listed HTTPS fetch unless replaced (tests).
  final GifFetcher? fetcher;

  @override
  State<ZenAnimatedImage> createState() => _ZenAnimatedImageState();
}

class _ZenAnimatedImageState extends State<ZenAnimatedImage> {
  ui.Codec? _codec;
  ui.Image? _frame;
  Timer? _timer;
  Object? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(ZenAnimatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        !identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.file?.path != widget.file?.path) {
      _stop();
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final int generation = ++_generation;
    try {
      Uint8List? bytes = widget.bytes;
      if (bytes == null && widget.file != null) {
        // An encrypted file is opened in memory, never in plain form.
        bytes = await readMediaFile(widget.file!.path);
      }
      if (bytes == null && widget.url != null) {
        bytes = await (widget.fetcher ?? _fetchGif)(widget.url!);
        // Third-party content: sized up before the system decoder sees it.
        if (bytes != null && !isAcceptableRemoteGif(bytes)) {
          throw StateError('Not a GIF of acceptable size.');
        }
      }
      if (bytes == null || bytes.isEmpty) {
        throw StateError('Brak obrazu.');
      }
      final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
        bytes,
      );
      final ui.Codec codec = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: _boundedDecodeSize,
      );
      if (!mounted || generation != _generation) {
        codec.dispose();
        return;
      }
      _codec = codec;
      await _showNextFrame(generation);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = error);
      }
    }
  }

  Future<void> _showNextFrame(int generation) async {
    final ui.Codec? codec = _codec;
    if (codec == null || !mounted || generation != _generation) {
      return;
    }
    final ui.FrameInfo info = await codec.getNextFrame();
    if (!mounted || generation != _generation) {
      info.image.dispose();
      return;
    }
    final ui.Image? previous = _frame;
    setState(() => _frame = info.image);
    if (previous != null) {
      // Still on screen until the next frame is painted.
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
    if (codec.frameCount > 1) {
      final Duration delay = info.duration < const Duration(milliseconds: 20)
          ? const Duration(milliseconds: 100)
          : info.duration;
      _timer = Timer(delay, () => unawaited(_showNextFrame(generation)));
    }
  }

  void _stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _codec?.dispose();
    _codec = null;
    _error = null;
  }

  @override
  void dispose() {
    _stop();
    final ui.Image? frame = _frame;
    _frame = null;
    frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Object? error = _error;
    if (error != null) {
      return widget.errorBuilder?.call(context, error, null) ??
          SizedBox(width: widget.width, height: widget.height);
    }
    final ui.Image? frame = _frame;
    if (frame == null) {
      return SizedBox(
        width: widget.width,
        height: widget.height,
        child: const Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return RawImage(
      image: frame,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
    );
  }
}

/// A GIF a chat message points to by URL (an [isAllowedRemoteMediaUrl]
/// host, in practice klipy.com).
///
/// A GIF from a peer is never fetched just because its message is on
/// screen: the request would tell the GIF host this device's IP address and
/// when the chat was opened, and hand third-party bytes to the system
/// decoder unasked. A placeholder waits for a tap instead. A GIF the user
/// picked themselves ([chosenByUser]) previews at once — the host already
/// served it to them in the picker — unless "Pobieraj zdjęcia i filmy"
/// (`autoDownloadMedia`) is off. One already fetched in this session shows
/// from memory without a new request.
class ZenRemoteGif extends ConsumerStatefulWidget {
  const ZenRemoteGif({
    super.key,
    required this.url,
    this.chosenByUser = false,
    this.width,
    this.height,
    this.errorBuilder,
    this.fetcher,
  });

  final String url;

  /// The user sent this GIF (picked it in the GIF picker) themselves.
  final bool chosenByUser;
  final double? width;
  final double? height;
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Fetches [url]; the allow-listed HTTPS fetch unless replaced (tests).
  final GifFetcher? fetcher;

  @override
  ConsumerState<ZenRemoteGif> createState() => _ZenRemoteGifState();
}

class _ZenRemoteGifState extends ConsumerState<ZenRemoteGif> {
  /// The user tapped the placeholder for this [ZenRemoteGif.url].
  bool _requested = false;

  @override
  void didUpdateWidget(ZenRemoteGif oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _requested = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool autoDownload = ref.watch(
      appSettingsControllerProvider.select(
        (settings) => settings.autoDownloadMedia,
      ),
    );
    final bool show =
        _requested ||
        (widget.chosenByUser && autoDownload) ||
        (widget.fetcher == null && _isGifCached(widget.url));
    if (show) {
      return ZenAnimatedImage(
        url: widget.url,
        width: widget.width,
        height: widget.height,
        errorBuilder: widget.errorBuilder,
        fetcher: widget.fetcher,
      );
    }
    final ZenColors zen = ZenColors.of(context);
    final String host = Uri.tryParse(widget.url)?.host ?? '';
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const Key('remote-gif-tap-to-load'),
        onTap: () => setState(() => _requested = true),
        child: SizedBox(
          width: widget.width,
          height: widget.height,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.gif_box_outlined, size: 40, color: zen.textMuted),
                  const SizedBox(height: 6),
                  Text(
                    t('GIF — dotknij, aby wczytać'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (host.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    // Where the tap connects to.
                    Text(
                      host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: zen.textMuted, fontSize: 12),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
