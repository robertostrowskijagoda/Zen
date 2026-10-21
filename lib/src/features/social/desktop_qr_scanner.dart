import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/social/qr_frame_decoder.dart';

/// Reads the QR code in a camera picture (in the background in the app).
typedef QrLumaDecoder = Future<String?> Function(LumaFrame frame);

/// The QR scanner on computers: the camera of the "Filmy" recorder
/// (camera_windows, ZenCameraBridge on macOS, GStreamer on Linux) shows its
/// picture, and a grey copy of it is read now and then until a code is
/// found; the page closes with its text.
class DesktopQrScannerPage extends StatefulWidget {
  const DesktopQrScannerPage({
    required this.camera,
    this.decode = decodeQrLumaInBackground,
    this.interval = const Duration(milliseconds: 350),
    super.key,
  });

  final FilmCamera camera;
  final QrLumaDecoder decode;

  /// The pause between two pictures.
  final Duration interval;

  @override
  State<DesktopQrScannerPage> createState() => _DesktopQrScannerPageState();
}

class _DesktopQrScannerPageState extends State<DesktopQrScannerPage> {
  bool _opening = true;
  bool _hasCamera = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final List<FilmLens> lenses = await widget.camera.lenses();
      if (lenses.isNotEmpty) {
        await widget.camera.open(
          lenses.contains(FilmLens.back) ? FilmLens.back : lenses.first,
        );
        _hasCamera = true;
      }
    } on Object catch (e) {
      _error = t('Nie udało się włączyć kamery: {error}', {'error': e});
    }
    if (!mounted) {
      return;
    }
    setState(() => _opening = false);
    if (_hasCamera) {
      unawaited(_look());
    }
  }

  /// Takes pictures until one has a code (or the page is left).
  Future<void> _look() async {
    while (mounted && !_done) {
      try {
        final LumaFrame? frame = await widget.camera.lumaFrame();
        final String? text = frame == null ? null : await widget.decode(frame);
        if (text != null && text.isNotEmpty && mounted && !_done) {
          _done = true;
          Navigator.of(context).pop(text);
          return;
        }
      } on Object {
        // One picture failed (the camera was busy): the next one.
      }
      await Future<void>.delayed(widget.interval);
    }
  }

  /// A code copied from elsewhere instead (a computer without a camera, a
  /// code sent in a message).
  Future<void> _paste() async {
    final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = data?.text?.trim() ?? '';
    if (text.isNotEmpty && mounted && !_done) {
      _done = true;
      Navigator.of(context).pop(text);
    }
  }

  @override
  void dispose() {
    _done = true;
    unawaited(widget.camera.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = ZenColors.foregroundFor(scheme.scrim);
    final Widget body;
    if (_opening) {
      body = Center(child: CircularProgressIndicator(color: ink));
    } else if (!_hasCamera) {
      body = Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ZenEmpty(
            key: const Key('qr-desktop-no-camera'),
            icon: Icons.videocam_off_outlined,
            title: t('Brak kamery'),
            text: _error,
            action: FilledButton.icon(
              key: const Key('qr-desktop-paste-empty'),
              onPressed: () => unawaited(_paste()),
              icon: const Icon(Icons.content_paste_rounded),
              label: Text(t('Wklej ze schowka')),
            ),
          ),
        ),
      );
    } else {
      body = Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Center(child: widget.camera.preview()),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                borderRadius: context.zenRadius(28),
                // The viewfinder in the accent of the theme.
                border: Border.all(color: zen.accent, width: 3),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.scrim.withValues(alpha: 0.7),
                    borderRadius: context.zenRadius(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Text(
                      t('Skieruj aparat na kod QR znajomego.'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ink, height: 1.4),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Scaffold(
      key: const Key('qr-desktop-scanner'),
      backgroundColor: _hasCamera ? scheme.scrim : zen.background,
      appBar: AppBar(
        title: Text(t('Skanuj kod QR')),
        actions: <Widget>[
          IconButton(
            key: const Key('qr-desktop-paste'),
            tooltip: t('Wklej ze schowka'),
            icon: const Icon(Icons.content_paste_rounded),
            onPressed: () => unawaited(_paste()),
          ),
        ],
      ),
      body: body,
    );
  }
}
