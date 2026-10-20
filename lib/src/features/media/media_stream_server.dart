import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// A film the [MediaStreamServer] plays while it downloads (§10): its
/// plain bytes in segments that open one by one.
abstract interface class StreamedMedia {
  /// All the plain bytes, or `null` while that is not known yet.
  int? get length;

  /// Plain bytes in every segment but the last.
  int get segmentBytes;

  /// What the player is told the bytes are (`video/mp4`).
  String get contentType;

  /// Segment [index] in plain bytes, or `null` while it has not arrived.
  /// Throws when it never will open (damaged, not this key, not a film):
  /// the server then stops serving the film.
  Future<Uint8List?> segment(int index);
}

/// A small HTTP server on this phone's loopback address (127.0.0.1) that
/// hands encrypted films to the system player while they download: the
/// player asks for byte ranges, the server opens the segments that hold
/// them and waits for those still on their way.
///
/// Nothing is written to disk in plain form. Every film gets a random,
/// unguessable path, and only connections from this device are answered.
final class MediaStreamServer {
  MediaStreamServer({
    this.waitFor = const Duration(minutes: 2),
    this.pollEvery = const Duration(milliseconds: 250),
    Random? random,
  }) : _random = random ?? Random.secure();

  /// The one the app uses.
  static final MediaStreamServer instance = MediaStreamServer();

  /// How long a request waits for a segment (or the length) before giving
  /// up; the player then shows that it is still loading or retries.
  final Duration waitFor;
  final Duration pollEvery;
  final Random _random;

  Future<HttpServer>? _starting;
  final Map<String, StreamedMedia> _media = <String, StreamedMedia>{};

  /// Calls to [publish] that wait for the server: it stays open for them
  /// even when the last film is withdrawn meanwhile.
  int _publishing = 0;

  /// Films being served now.
  @visibleForTesting
  int get serving => _media.length;

  /// The address the player opens [media] at, until [withdraw].
  Future<Uri> publish(StreamedMedia media) async {
    _publishing++;
    final HttpServer server;
    try {
      final Future<HttpServer> starting = _starting ??= _start();
      try {
        server = await starting;
      } on Object {
        // A start that failed is not remembered: the next call tries again.
        if (identical(_starting, starting)) {
          _starting = null;
        }
        rethrow;
      }
    } finally {
      _publishing--;
    }
    final String token = <String>[
      for (int i = 0; i < 32; i++) _random.nextInt(16).toRadixString(16),
    ].join();
    _media[token] = media;
    return Uri(
      scheme: 'http',
      host: InternetAddress.loopbackIPv4.address,
      port: server.port,
      path: '/$token',
    );
  }

  /// Stops serving the film at [uri]; the server closes with the last one.
  Future<void> withdraw(Uri uri) async {
    _media.remove(uri.path.replaceFirst('/', ''));
    if (_media.isEmpty && _publishing == 0 && _starting != null) {
      final Future<HttpServer> starting = _starting!;
      _starting = null;
      try {
        await (await starting).close(force: true);
      } on Object catch (error) {
        logZenWarning('Serwer filmów: zamknięcie: $error');
      }
    }
  }

  Future<HttpServer> _start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen(
      (HttpRequest request) =>
          unawaitedLogged(_serve(request), context: 'Serwer filmów: żądanie'),
      onError: (Object error) => logZenWarning('Serwer filmów: $error'),
    );
    return server;
  }

  Future<void> _serve(HttpRequest request) async {
    final HttpResponse response = request.response;
    String token = '';
    try {
      token = request.uri.path.replaceFirst('/', '');
      final StreamedMedia? media = _media[token];
      final bool fromHere =
          request.connectionInfo?.remoteAddress.isLoopback ?? false;
      if (media == null ||
          !fromHere ||
          (request.method != 'GET' && request.method != 'HEAD')) {
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
      }
      final int? length = await _waitLength(media);
      if (length == null) {
        response.statusCode = HttpStatus.serviceUnavailable;
        await response.close();
        return;
      }
      final ({int start, int end})? range = parseByteRange(
        request.headers.value(HttpHeaders.rangeHeader),
        length,
      );
      response.headers
        ..set(HttpHeaders.acceptRangesHeader, 'bytes')
        ..set(HttpHeaders.contentTypeHeader, media.contentType)
        ..set(HttpHeaders.cacheControlHeader, 'no-store');
      if (range == null) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
        await response.close();
        return;
      }
      final bool partial =
          request.headers.value(HttpHeaders.rangeHeader) != null;
      response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
      if (partial) {
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end}/$length',
        );
      }
      response.contentLength = range.end - range.start + 1;
      if (request.method == 'HEAD') {
        await response.close();
        return;
      }
      final int size = media.segmentBytes;
      for (int i = range.start ~/ size; i <= range.end ~/ size; i++) {
        final Uint8List? plain;
        try {
          plain = await _waitSegment(media, i);
        } on Object {
          // A segment that never opens (or is not a film): the film is not
          // served any more, so the player stops instead of asking again.
          _media.remove(token);
          rethrow;
        }
        if (plain == null) {
          // Not here in time: the response ends short, and the player asks
          // again for what it is missing.
          throw TimeoutException('segment $i');
        }
        final int segmentStart = i * size;
        final int from = max(range.start, segmentStart) - segmentStart;
        final int to =
            min(range.end + 1, segmentStart + plain.length) - segmentStart;
        if (from < to) {
          response.add(Uint8List.sublistView(plain, from, to));
          await response.flush();
        }
      }
      await response.close();
    } on Object catch (error) {
      // The player went away mid-way (a seek, the screen closed).
      logZenWarning('Serwer filmów: $error');
      try {
        await response.close();
      } on Object {
        // Already closed.
      }
    }
  }

  Future<int?> _waitLength(StreamedMedia media) async {
    final DateTime until = DateTime.now().add(waitFor);
    while (true) {
      final int? length = media.length;
      if (length != null || DateTime.now().isAfter(until)) {
        return length;
      }
      await Future<void>.delayed(pollEvery);
    }
  }

  Future<Uint8List?> _waitSegment(StreamedMedia media, int index) async {
    final DateTime until = DateTime.now().add(waitFor);
    while (true) {
      final Uint8List? plain = await media.segment(index);
      if (plain != null || DateTime.now().isAfter(until)) {
        return plain;
      }
      await Future<void>.delayed(pollEvery);
    }
  }
}

/// The bytes asked for by an HTTP `Range` header ([header], `null` for the
/// whole file) in a file of [length] bytes, both ends included; `null` when
/// the range cannot be served. Only one range (`bytes=a-b`, `a-`, `-n`).
({int start, int end})? parseByteRange(String? header, int length) {
  if (length <= 0) {
    return null;
  }
  if (header == null) {
    return (start: 0, end: length - 1);
  }
  final RegExpMatch? m = RegExp(
    r'^\s*bytes\s*=\s*(\d*)\s*-\s*(\d*)\s*$',
  ).firstMatch(header);
  if (m == null) {
    return null;
  }
  final int? first = int.tryParse(m.group(1)!);
  final int? last = int.tryParse(m.group(2)!);
  if (first == null) {
    if (last == null || last <= 0) {
      return null;
    }
    return (start: max(0, length - last), end: length - 1);
  }
  if (first >= length || (last != null && last < first)) {
    return null;
  }
  return (start: first, end: last == null ? length - 1 : min(last, length - 1));
}
