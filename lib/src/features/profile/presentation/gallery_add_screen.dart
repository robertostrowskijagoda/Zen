import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/presentation/animated_gif.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/media_transfer.dart';
import 'package:zen/src/features/profile/profile_gallery.dart';

/// Adds photos and videos to the profile's gallery. Not a post: it
/// does not show on the wall. Friends only unless chosen otherwise.
class GalleryAddScreen extends StatefulWidget {
  const GalleryAddScreen({
    required this.node,
    this.pickPhotos,
    this.pickVideos,
    super.key,
  });

  final LedgerNode node;

  /// Override the pickers (tests).
  final Future<List<Uint8List>> Function()? pickPhotos;
  final Future<List<DraftMedia>> Function()? pickVideos;

  /// Opens the screen; true once something was added.
  static Future<bool> open(
    BuildContext context,
    LedgerNode node, {
    Future<List<Uint8List>> Function()? pickPhotos,
    Future<List<DraftMedia>> Function()? pickVideos,
  }) async =>
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (BuildContext context) => GalleryAddScreen(
            node: node,
            pickPhotos: pickPhotos,
            pickVideos: pickVideos,
          ),
        ),
      ) ??
      false;

  @override
  State<GalleryAddScreen> createState() => _GalleryAddScreenState();
}

class _GalleryAddScreenState extends State<GalleryAddScreen> {
  final List<DraftMedia> _media = <DraftMedia>[];
  Audience _audience = Audience.all;
  int _processing = 0;
  bool _saving = false;
  String? _error;

  int get _room => kMaxGalleryBatch - _media.length - _processing;

  Future<void> _addPhotos() async {
    if (_room <= 0) {
      setState(
        () =>
            _error = t('Najwyżej {count} naraz.', {'count': kMaxGalleryBatch}),
      );
      return;
    }
    List<Uint8List> raw;
    try {
      raw =
          await (widget.pickPhotos ??
              () => pickImageBytes(limit: _room > 1 ? _room : null))();
    } on Object catch (e) {
      if (mounted) {
        setState(
          () =>
              _error = t('Nie udało się otworzyć zdjęć: {error}', {'error': e}),
        );
      }
      return;
    }
    for (final Uint8List bytes in raw.take(_room)) {
      if (!mounted) {
        return;
      }
      setState(() => _processing++);
      try {
        // A GIF stays animated; a photo becomes a fresh JPEG.
        final DraftMedia picture = await pictureForPost(bytes);
        if (mounted) {
          setState(() => _media.add(picture));
        }
      } on ArgumentError catch (e) {
        if (mounted) {
          setState(
            () => _error =
                e.message as String? ?? t('Ten plik nie jest zdjęciem.'),
          );
        }
      } finally {
        if (mounted) {
          setState(() => _processing--);
        }
      }
    }
  }

  /// Photos, GIFs and films dropped on the screen or pasted.
  Future<void> _addTransferred(List<TransferItem> items) async {
    if (_room <= 0) {
      setState(
        () =>
            _error = t('Najwyżej {count} naraz.', {'count': kMaxGalleryBatch}),
      );
      return;
    }
    setState(() => _processing++);
    final ({List<DraftMedia> media, String? error}) got;
    try {
      got = await draftMediaFromTransfer(items);
    } finally {
      if (mounted) {
        setState(() => _processing--);
      }
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _media.addAll(got.media.take(_room < 0 ? 0 : _room));
      _error = got.error;
    });
  }

  Future<void> _addVideo() async {
    if (_room <= 0) {
      setState(
        () =>
            _error = t('Najwyżej {count} naraz.', {'count': kMaxGalleryBatch}),
      );
      return;
    }
    try {
      final List<DraftMedia> v = await (widget.pickVideos ?? pickVideoMedia)();
      if (mounted) {
        setState(() => _media.addAll(v.take(_room)));
      }
    } on ArgumentError catch (e) {
      if (mounted) {
        setState(() => _error = e.message as String? ?? '$e');
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () =>
              _error = t('Nie udało się otworzyć filmu: {error}', {'error': e}),
        );
      }
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await addToGallery(widget.node, <({Uint8List bytes, String mime})>[
        for (final DraftMedia m in _media) (bytes: m.bytes, mime: m.mime),
      ], audience: _audience);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = t('Nie udało się dodać: {error}', {'error': e});
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool ready = _media.isNotEmpty && _processing == 0 && !_saving;
    // Photos, GIFs and films dropped here or pasted with Ctrl+V on a
    // computer (media_transfer.dart).
    return MediaDropArea(
      autofocus: true,
      enabled: !_saving,
      onItems: _addTransferred,
      child: Scaffold(
        key: const Key('gallery-add-screen'),
        appBar: AppBar(
          title: Text(t('Dodaj do galerii')),
          actions: <Widget>[
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                key: const Key('gallery-add-save'),
                onPressed: ready ? () => unawaited(_save()) : null,
                child: _saving
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(t('Dodaj')),
              ),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            ZenHero(
              title: t('Twoja galeria'),
              icon: Icons.photo_library_rounded,
              tone: zenTone(zen, 2),
              text: t(
                'Zdjęcia i filmy w galerii profilu. Nie trafiają na '
                'tablicę jako post. Widoczność możesz potem zmienić, '
                'przytrzymując zdjęcie.',
              ),
            ),
            ZenSection(t('Kto zobaczy')),
            Wrap(
              key: const Key('gallery-audience'),
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final Audience a in Audience.values)
                  ChoiceChip(
                    key: Key('gallery-audience-${a.name}'),
                    showCheckmark: false,
                    avatar: Icon(kAudienceIcons[a], size: 18),
                    label: Text(kGalleryAudienceLabels[a]!),
                    selected: _audience == a,
                    onSelected: _saving
                        ? null
                        : (bool _) => setState(() => _audience = a),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                kGalleryAudienceHints[_audience]!,
                key: const Key('gallery-audience-hint'),
                style: TextStyle(color: zen.textSecondary, fontSize: 13),
              ),
            ),
            ZenSection(t('Co dodać')),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  key: const Key('gallery-pick-photos'),
                  onPressed: _saving ? null : () => unawaited(_addPhotos()),
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: Text(t('Zdjęcia')),
                ),
                FilledButton.tonalIcon(
                  key: const Key('gallery-pick-video'),
                  onPressed: _saving ? null : () => unawaited(_addVideo()),
                  icon: const Icon(Icons.video_library_outlined),
                  label: Text(t('Film')),
                ),
              ],
            ),
            if (_error != null)
              ZenInfo(
                icon: Icons.error_outline_rounded,
                tone: zen.danger,
                text: _error!,
              ),
            const SizedBox(height: 16),
            if (_media.isEmpty && _processing == 0)
              ZenEmpty(
                icon: Icons.add_photo_alternate_outlined,
                tone: zenTone(zen, 2),
                title: t('Nic jeszcze nie wybrano'),
                text: t(
                  'Wybierz zdjęcia albo film — zobaczysz je tutaj, '
                  'zanim je dodasz.',
                ),
              )
            else
              GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: <Widget>[
                  for (int i = 0; i < _media.length; i++)
                    Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        ClipRRect(
                          borderRadius: context.zenRadius(16),
                          child: _media[i].isVideo
                              ? ColoredBox(
                                  color: zen.surfaceSunk,
                                  child: Icon(
                                    Icons.play_circle_outline_rounded,
                                    size: 40,
                                    color: zen.textSecondary,
                                  ),
                                )
                              : _media[i].mime == 'image/gif'
                              ? ZenAnimatedImage(bytes: _media[i].bytes)
                              : Image.memory(
                                  _media[i].bytes,
                                  fit: BoxFit.cover,
                                ),
                        ),
                        Positioned(
                          top: 2,
                          right: 2,
                          child: IconButton.filledTonal(
                            key: Key('gallery-remove-$i'),
                            visualDensity: VisualDensity.compact,
                            tooltip: t('Usuń'),
                            onPressed: _saving
                                ? null
                                : () => setState(() => _media.removeAt(i)),
                            icon: const Icon(Icons.close_rounded, size: 16),
                          ),
                        ),
                      ],
                    ),
                  for (int i = 0; i < _processing; i++)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: zen.surfaceSunk,
                        borderRadius: context.zenRadius(16),
                      ),
                      child: const Center(
                        child: SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
