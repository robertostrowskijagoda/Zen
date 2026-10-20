import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// A picture from someone's profile in the ledger (photo or cover): made
/// safe first (`openSafeImage`), shown once it is downloaded.
class LedgerPicture extends StatefulWidget {
  const LedgerPicture({
    required this.node,
    required this.media,
    required this.builder,
    super.key,
  });

  final LedgerNode node;
  final MediaRef media;

  /// Builds the picture; [image] is `null` until it is on the device.
  final Widget Function(BuildContext context, ImageProvider? image) builder;

  @override
  State<LedgerPicture> createState() => _LedgerPictureState();
}

class _LedgerPictureState extends State<LedgerPicture> {
  ImageProvider? _image;
  StreamSubscription<String>? _done;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _done = widget.node.mediaCompleted.listen((String id) {
      if (id == widget.media.id) {
        unawaited(_load());
      }
    });
  }

  @override
  void didUpdateWidget(LedgerPicture old) {
    super.didUpdateWidget(old);
    if (old.media.id != widget.media.id) {
      _image = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    try {
      final Uint8List? bytes = await openSafeImage(
        widget.node.blobs,
        widget.media,
      );
      if (bytes != null && mounted) {
        setState(() => _image = MemoryImage(bytes));
      }
    } on UnsafeMediaException {
      // Not a picture: the placeholder stays.
    }
  }

  @override
  void dispose() {
    unawaited(_done?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _image);
}

/// Someone's profile photo from the ledger in the usual round frame (the
/// initial until it is downloaded).
class LedgerAvatar extends StatelessWidget {
  const LedgerAvatar({
    required this.node,
    required this.media,
    required this.name,
    this.size = 44,
    super.key,
  });

  final LedgerNode node;
  final MediaRef media;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => LedgerPicture(
    node: node,
    media: media,
    builder: (BuildContext context, ImageProvider? image) =>
        ZenBlobAvatar(name: name, size: size, showStatus: false, image: image),
  );
}

/// A cover from the ledger, filling its box.
class LedgerCover extends StatelessWidget {
  const LedgerCover({required this.node, required this.media, super.key});

  final LedgerNode node;
  final MediaRef media;

  @override
  Widget build(BuildContext context) => LedgerPicture(
    node: node,
    media: media,
    builder: (BuildContext context, ImageProvider? image) => image == null
        ? ColoredBox(color: ZenColors.of(context).surfaceSunk)
        : Image(image: image, fit: BoxFit.cover, gaplessPlayback: true),
  );
}
