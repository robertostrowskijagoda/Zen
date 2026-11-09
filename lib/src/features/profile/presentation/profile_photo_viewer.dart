import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Someone's profile photo on the whole screen, to be looked at closely:
/// pinched or double-tapped up to five times its size and moved around.
class ProfilePhotoViewer extends StatefulWidget {
  const ProfilePhotoViewer({required this.image, super.key});

  final ImageProvider image;

  @override
  State<ProfilePhotoViewer> createState() => _ProfilePhotoViewerState();
}

class _ProfilePhotoViewerState extends State<ProfilePhotoViewer> {
  final TransformationController _zoom = TransformationController();
  TapDownDetails? _doubleTap;

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  /// A double tap brings the photo up around the spot tapped, or back.
  void _toggleZoom() {
    if (_zoom.value != Matrix4.identity()) {
      _zoom.value = Matrix4.identity();
      return;
    }
    final Offset at = _doubleTap?.localPosition ?? Offset.zero;
    const double scale = 2.5;
    _zoom.value = Matrix4.identity()
      ..translateByDouble(-at.dx * (scale - 1), -at.dy * (scale - 1), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('profile-photo-viewer'),
      backgroundColor: ZenFixed.photoBackdrop,
      appBar: zenFixedAppBar(
        context,
        background: ZenFixed.photoBackdrop,
        foreground: ZenFixed.onPhoto,
      ),
      body: GestureDetector(
        onDoubleTapDown: (TapDownDetails details) => _doubleTap = details,
        onDoubleTap: _toggleZoom,
        child: InteractiveViewer(
          transformationController: _zoom,
          maxScale: 5,
          child: Center(
            child: Image(
              image: widget.image,
              fit: BoxFit.contain,
              semanticLabel: t('Zdjęcie profilowe'),
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stack) =>
                      const Icon(
                        Icons.broken_image_rounded,
                        color: ZenFixed.onPhoto,
                      ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens [image] (a profile photo) on the whole screen.
Future<void> openProfilePhoto(BuildContext context, ImageProvider image) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => ProfilePhotoViewer(image: image),
      ),
    );

/// [child] (a profile photo's avatar) that opens [image] on the whole
/// screen when tapped; just [child] while there is no photo (an initial).
class ZoomableProfilePhoto extends StatelessWidget {
  const ZoomableProfilePhoto({
    required this.image,
    required this.child,
    super.key,
  });

  final ImageProvider? image;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ImageProvider? photo = image;
    if (photo == null) {
      return child;
    }
    return Semantics(
      button: true,
      label: t('Zdjęcie profilowe'),
      child: GestureDetector(
        key: const Key('profile-photo-open'),
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(openProfilePhoto(context, photo)),
        child: child,
      ),
    );
  }
}
