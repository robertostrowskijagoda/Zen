import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/chat/presentation/animated_gif.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/gif_files.dart';

/// The side of a picture tile under a comment.
const double kCommentPictureTile = 112;

/// Asks, then removes this account's own [comment] under [postId] (with
/// its pictures, see `deleteComment`). Null when it is removed, '' when the
/// person changed their mind, else an error to show.
Future<String?> confirmDeleteComment(
  BuildContext context,
  LedgerNode node,
  String postId,
  FeedComment comment,
) async {
  final bool? sure = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      scrollable: true,
      title: Text(t('Usunąć komentarz?')),
      content: Text(
        t('Komentarz i jego obrazki znikną u Ciebie i u znajomych.'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('comment-delete-confirm'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(t('Usuń')),
        ),
      ],
    ),
  );
  if (sure != true) {
    return '';
  }
  try {
    await deleteComment(node, postId, comment);
    return null;
  } on Object catch (e) {
    return t('Nie udało się usunąć: {error}', {'error': e});
  }
}

/// The comment entry behind [comment] when this node holds it (to fetch
/// its pictures on a tap when media are not downloaded on their own).
LogEntry? commentEntryOf(LedgerNode node, FeedComment comment) =>
    comment.account.isEmpty
    ? null
    : node.store.entryById(accountSpace('acts', comment.account), comment.id);

/// The photos and GIFs of a comment as small tiles (a GIF plays); a tap
/// opens them full screen. Each one is made safe before it is shown, like
/// a post's photo (`openSafeImage`): anything that is not a picture shows
/// as an invalid file and is never decoded by the phone.
class CommentPictures extends StatelessWidget {
  const CommentPictures({required this.node, required this.comment, super.key});

  final LedgerNode node;
  final FeedComment comment;

  @override
  Widget build(BuildContext context) => PictureTiles(
    key: Key('comment-pictures-${comment.id}'),
    node: node,
    images: comment.images,
    download: (MediaRef media) {
      final LogEntry? entry = commentEntryOf(node, comment);
      if (entry != null) {
        node.downloadMedia(entry);
      } else {
        // Passed on by a friend: whoever of the friends has it.
        node.fetchBlobFrom(media.id, node.friendAccounts.keys);
      }
    },
  );
}

/// Pictures (sealed files in the blob store) as small tiles that open full
/// screen. [download] starts fetching one that is not here: on a tap when
/// media are not downloaded on their own, and right away otherwise when
/// [fetchOnShow] (pictures no ledger entry names, so nothing else fetches
/// them).
class PictureTiles extends StatelessWidget {
  const PictureTiles({
    required this.node,
    required this.images,
    required this.download,
    this.fetchOnShow = false,
    super.key,
  });

  final LedgerNode node;
  final List<MediaRef> images;
  final void Function(MediaRef media) download;
  final bool fetchOnShow;

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: <Widget>[
          for (final (int i, MediaRef ref) in images.indexed)
            ClipRRect(
              borderRadius: context.zenRadius(10),
              child: SizedBox.square(
                dimension: kCommentPictureTile,
                child: _PictureTile(
                  key: Key('comment-picture-${ref.id}'),
                  node: node,
                  media: ref,
                  download: () => download(ref),
                  fetchOnShow: fetchOnShow,
                  onOpen: () => unawaited(
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        fullscreenDialog: true,
                        builder: (BuildContext context) => CommentPictureViewer(
                          node: node,
                          images: images,
                          initial: i,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PictureTile extends StatefulWidget {
  const _PictureTile({
    required this.node,
    required this.media,
    required this.download,
    required this.fetchOnShow,
    required this.onOpen,
    super.key,
  });

  final LedgerNode node;
  final MediaRef media;
  final VoidCallback download;
  final bool fetchOnShow;
  final VoidCallback onOpen;

  @override
  State<_PictureTile> createState() => _PictureTileState();
}

class _PictureTileState extends State<_PictureTile> {
  Uint8List? _bytes;
  bool _unsafe = false;
  bool _asked = false;
  StreamSubscription<String>? _done;

  @override
  void initState() {
    super.initState();
    _done = widget.node.mediaCompleted.listen((String id) {
      if (id == widget.media.id && _bytes == null) {
        unawaited(_load());
      }
    });
    if (widget.fetchOnShow &&
        widget.node.autoDownloadMedia() &&
        !widget.node.blobs.isComplete(widget.media.id)) {
      widget.download();
      _asked = true;
    }
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final Uint8List? bytes = await openSafeImage(
        widget.node.blobs,
        widget.media,
      );
      if (bytes != null && mounted) {
        setState(() => _bytes = bytes);
      }
    } on UnsafeMediaException {
      if (mounted) {
        setState(() => _unsafe = true);
      }
    }
  }

  void _download() {
    widget.download();
    setState(() => _asked = true);
  }

  @override
  void dispose() {
    unawaited(_done?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Uint8List? bytes = _bytes;
    if (_unsafe) {
      return Container(
        key: const Key('comment-picture-unsafe'),
        alignment: Alignment.center,
        color: zen.surfaceSunk,
        padding: const EdgeInsets.all(6),
        child: Icon(
          Icons.gpp_maybe_rounded,
          color: zen.warning,
          semanticLabel: t('Nieprawidłowy plik — nie otwarto go'),
        ),
      );
    }
    if (bytes == null) {
      final bool waiting = widget.node.autoDownloadMedia() || _asked;
      return Material(
        color: zen.surfaceSunk,
        child: InkWell(
          onTap: waiting ? null : _download,
          child: Center(
            child: waiting
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.download_rounded,
                    color: zen.accent,
                    semanticLabel: t('Dotknij, aby pobrać'),
                  ),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: widget.onOpen,
      child: looksLikeGif(bytes)
          ? ZenAnimatedImage(
              bytes: bytes,
              width: double.infinity,
              height: double.infinity,
              autoplay: widget.node.autoDownloadMedia(),
            )
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              gaplessPlayback: true,
            ),
    );
  }
}

/// The pictures of a comment full screen: swipe between them, pinch to
/// zoom; a GIF plays.
class CommentPictureViewer extends StatefulWidget {
  const CommentPictureViewer({
    required this.node,
    required this.images,
    this.initial = 0,
    super.key,
  });

  final LedgerNode node;
  final List<MediaRef> images;
  final int initial;

  @override
  State<CommentPictureViewer> createState() => _CommentPictureViewerState();
}

class _CommentPictureViewerState extends State<CommentPictureViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initial,
  );
  late int _index = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('comment-picture-viewer'),
      backgroundColor: ZenFixed.photoBackdrop,
      appBar: zenFixedAppBar(
        context,
        background: ZenFixed.photoBackdrop,
        foreground: ZenFixed.onPhoto,
        title: widget.images.length > 1
            ? Text('${_index + 1} / ${widget.images.length}')
            : null,
      ),
      body: PageView(
        controller: _pages,
        onPageChanged: (int i) => setState(() => _index = i),
        children: <Widget>[
          for (final MediaRef ref in widget.images)
            FutureBuilder<Uint8List?>(
              future: openSafeImage(widget.node.blobs, ref),
              builder: (BuildContext context, AsyncSnapshot<Uint8List?> s) {
                final Uint8List? bytes = s.data;
                if (s.hasError) {
                  return Center(
                    child: Icon(
                      Icons.gpp_maybe_rounded,
                      color: ZenFixed.onPhoto,
                      semanticLabel: t('Nieprawidłowy plik — nie otwarto go'),
                    ),
                  );
                }
                if (bytes == null) {
                  return const Center(
                    child: CircularProgressIndicator(color: ZenFixed.onPhoto),
                  );
                }
                return InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: looksLikeGif(bytes)
                        ? ZenAnimatedImage(bytes: bytes, fit: BoxFit.contain)
                        : Image.memory(bytes),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
