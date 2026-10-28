import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/chat/presentation/animated_gif.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/media_transfer.dart';
import 'package:zen/src/features/shell/composer_drafts.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/presentation/mention_field.dart';

/// Sends a comment: [text] and [pictures]; returns an error to show, or
/// null when it went (the field is cleared then).
typedef CommentSend =
    Future<String?> Function(String text, List<CommentPicture> pictures);

/// The same with mentions: [text] holds `<@N>` tokens of [mentions].
typedef CommentMentionSend =
    Future<String?> Function(
      String text,
      List<CommentPicture> pictures,
      List<Mention> mentions,
    );

/// Where a picture for a comment comes from.
enum CommentPictureSource { camera, gallery, file, gif, paste }

/// The side of the buttons next to the field: a finger-sized target. The
/// theme's compact density would shrink them to a flat 36 x 26 box.
const double _kSideButton = 44;

/// Centres a [_kSideButton] on the field's first line (48 tall).
const double _kSideButtonTop = 2;

final ButtonStyle _sideButtonStyle = IconButton.styleFrom(
  minimumSize: const Size.square(_kSideButton),
  fixedSize: const Size.square(_kSideButton),
  padding: EdgeInsets.zero,
  visualDensity: VisualDensity.standard,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// The field under comments (posts, films): text and up to
/// [kMaxCommentImages] photos or GIFs. Pictures come from the camera, the
/// gallery, a file, the GIF search (when it is on), a keyboard that
/// inserts GIFs (Android), the clipboard ("Wklej obrazek" in the field's
/// menu on an iPhone, Ctrl+V on a computer) and files dropped on it. A GIF
/// stays animated (`commentPicture`).
class CommentComposer extends ConsumerStatefulWidget {
  const CommentComposer({
    this.onSend,
    this.onSendMentioning,
    this.mentionCandidates,
    this.fieldKey,
    this.sendKey,
    this.prefixIcon,
    this.draftKey,
    super.key,
  }) : assert(onSend != null || onSendMentioning != null);

  final CommentSend? onSend;

  /// Sends with mentions (used instead of [onSend] when given).
  final CommentMentionSend? onSendMentioning;

  /// Who "@" offers to mention; no suggestions when `null`.
  final List<MentionCandidate> Function()? mentionCandidates;
  final Key? fieldKey;
  final Key? sendKey;
  final Widget? prefixIcon;

  /// The draft the unsent text is kept as (`ComposerDrafts.comment`), also
  /// after the app was closed; none when `null`.
  final String? draftKey;

  @override
  ConsumerState<CommentComposer> createState() => _CommentComposerState();
}

class _CommentComposerState extends ConsumerState<CommentComposer> {
  final MentionTextController _field = MentionTextController();
  final List<CommentPicture> _pictures = <CommentPicture>[];
  String? _error;

  /// Pictures being made ready.
  int _preparing = 0;
  bool _sending = false;

  int get _room => kMaxCommentImages - _pictures.length - _preparing;

  ComposerDrafts? _drafts;

  @override
  void initState() {
    super.initState();
    final String? draftKey = widget.draftKey;
    if (draftKey == null) {
      return;
    }
    final ComposerDrafts drafts = ref.read(composerDraftsProvider);
    _drafts = drafts;
    // What was written here and not sent is back (unless something was
    // typed meanwhile); the pictures are not kept.
    void fill() {
      final ComposerDraft? draft = drafts[draftKey];
      if (mounted && draft != null && _field.text.isEmpty) {
        _field.setStoredText(draft.text, draft.mentions);
      }
    }

    if (drafts.isLoaded) {
      fill();
    } else {
      unawaited(drafts.load().then((_) => fill()));
    }
    _field.addListener(_keepDraft);
  }

  void _keepDraft() {
    final String? draftKey = widget.draftKey;
    if (draftKey == null) {
      return;
    }
    final ({String text, List<Mention> mentions}) stored = _field.storedText();
    _drafts?.put(
      draftKey,
      ComposerDraft(text: stored.text, mentions: stored.mentions),
    );
  }

  @override
  void dispose() {
    _field.removeListener(_keepDraft);
    _field.dispose();
    super.dispose();
  }

  void _fail(String message) {
    if (mounted) {
      setState(() => _error = message);
    }
  }

  String get _full => tn(
    kMaxCommentImages,
    one: 'Komentarz może mieć najwyżej {n} obrazek.',
    few: 'Komentarz może mieć najwyżej {n} obrazki.',
    many: 'Komentarz może mieć najwyżej {n} obrazków.',
  );

  /// Makes [bytes] ready (a GIF stays animated) and adds it.
  Future<void> _addBytes(Uint8List bytes) async {
    if (_room <= 0) {
      _fail(_full);
      return;
    }
    setState(() {
      _preparing++;
      _error = null;
    });
    try {
      final CommentPicture picture = await commentPicture(bytes);
      if (mounted) {
        setState(() => _pictures.add(picture));
      }
    } on ArgumentError catch (e) {
      _fail('${e.message}');
    } finally {
      if (mounted) {
        setState(() => _preparing--);
      }
    }
  }

  /// Files dropped on the field or pasted: each as a picture.
  Future<void> _addItems(List<TransferItem> items) async {
    for (final TransferItem item in items) {
      if (!mounted) {
        return;
      }
      if (_room <= 0) {
        _fail(_full);
        return;
      }
      Uint8List? bytes = item.bytes;
      final String? path = item.path;
      if (bytes == null && path != null) {
        try {
          final File file = File(path);
          bytes = await file.length() > kMaxTransferPhotoBytes
              ? null
              : await file.readAsBytes();
        } on FileSystemException {
          bytes = null;
        }
      }
      if (bytes == null || bytes.isEmpty) {
        _fail(
          t('Nie udało się odczytać pliku „{name}”.', <String, Object>{
            'name': item.name,
          }),
        );
        continue;
      }
      await _addBytes(bytes);
    }
  }

  /// A picture the keyboard inserted (a GIF or a sticker).
  void _onInserted(KeyboardInsertedContent content) {
    final Uint8List? data = content.data;
    if (data == null || data.isEmpty) {
      _fail(t('Klawiatura nie przekazała obrazka.'));
      return;
    }
    unawaited(_addBytes(data));
  }

  Future<void> _attach() async {
    final bool gifs = ref.read(gifSearchEnabledProvider);
    final ZenColors zen = ZenColors.of(context);
    Widget option(
      BuildContext sheet,
      CommentPictureSource source,
      IconData icon,
      String label,
    ) => ListTile(
      key: Key('comment-attach-${source.name}'),
      leading: Icon(icon, color: zen.accent),
      title: Text(label),
      onTap: () => Navigator.of(sheet).pop(source),
    );
    final CommentPictureSource? source =
        await showModalBottomSheet<CommentPictureSource>(
          context: context,
          showDragHandle: true,
          builder: (BuildContext sheet) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_mobile)
                    option(
                      sheet,
                      CommentPictureSource.camera,
                      Icons.photo_camera_rounded,
                      t('Zrób zdjęcie (Aparat)'),
                    ),
                  option(
                    sheet,
                    CommentPictureSource.gallery,
                    Icons.photo_library_rounded,
                    t('Wybierz z galerii'),
                  ),
                  option(
                    sheet,
                    CommentPictureSource.file,
                    Icons.attach_file_rounded,
                    t('Plik z dysku'),
                  ),
                  if (gifs)
                    option(
                      sheet,
                      CommentPictureSource.gif,
                      Icons.gif_box_outlined,
                      t('Szukaj GIF-ów'),
                    ),
                  if (clipboardPasteButtonShown)
                    option(
                      sheet,
                      CommentPictureSource.paste,
                      Icons.content_paste_rounded,
                      t('Wklej obrazek ze schowka'),
                    ),
                ],
              ),
            ),
          ),
        );
    if (source == null || !mounted) {
      return;
    }
    try {
      switch (source) {
        case CommentPictureSource.camera:
          await _fromCamera();
        case CommentPictureSource.gallery:
          final List<Uint8List> picked = await pickImageBytes(
            limit: _room > 1 ? _room : null,
          );
          for (final Uint8List bytes in picked) {
            await _addBytes(bytes);
          }
        case CommentPictureSource.file:
          await _fromFiles();
        case CommentPictureSource.gif:
          await _fromGifSearch();
        case CommentPictureSource.paste:
          final List<TransferItem> items = await MediaTransfer.platform
              .readClipboard();
          if (items.isEmpty) {
            _fail(t('W schowku nie ma obrazka ani pliku.'));
          } else {
            await _addItems(items);
          }
      }
    } on Object catch (e) {
      _fail(t('Nie udało się: {error}', {'error': e}));
    }
  }

  Future<void> _fromCamera() async {
    final XFile? file = await ImagePicker().pickImage(
      source: ImageSource.camera,
    );
    if (file == null) {
      return;
    }
    final Uint8List bytes = await file.readAsBytes();
    // The camera left a plain copy in the app's cache.
    try {
      await File(file.path).delete();
    } on FileSystemException {
      // Removed with the cache later.
    }
    await _addBytes(bytes);
  }

  Future<void> _fromFiles() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    await _addItems(<TransferItem>[
      for (final PlatformFile f in result?.files ?? const <PlatformFile>[])
        if (f.bytes != null || f.path != null)
          TransferItem(name: f.name, bytes: f.bytes, path: f.path),
    ]);
  }

  Future<void> _fromGifSearch() async {
    final GifCatalogEntry? entry = await showChatGifPicker(context, ref);
    if (entry == null || !mounted) {
      return;
    }
    // This phone fetches the GIF; the readers never contact the GIF host.
    final Uint8List bytes;
    try {
      bytes = await ref.read(gifDownloaderProvider).download(entry.sendUrl);
    } on Object {
      _fail(t('Nie udało się pobrać GIF-a.'));
      return;
    }
    await _addBytes(bytes);
  }

  Future<void> _send() async {
    if (_sending || _preparing > 0) {
      return;
    }
    setState(() => _sending = true);
    final CommentMentionSend? mentioning = widget.onSendMentioning;
    final ({String text, List<Mention> mentions}) stored = _field.storedText();
    final String? error = mentioning != null
        ? await mentioning(
            stored.text,
            List<CommentPicture>.of(_pictures),
            stored.mentions,
          )
        : await widget.onSend!(_field.text, List<CommentPicture>.of(_pictures));
    if (!mounted) {
      return;
    }
    setState(() {
      _sending = false;
      _error = error;
      if (error == null) {
        _field.clear();
        _pictures.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return MediaDropArea(
      onItems: _addItems,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (widget.mentionCandidates != null)
            MentionSuggestions(
              controller: _field,
              candidates: widget.mentionCandidates!,
              padding: const EdgeInsets.only(bottom: 8),
            ),
          if (_pictures.isNotEmpty || _preparing > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  for (final (int i, CommentPicture p) in _pictures.indexed)
                    _PendingPicture(
                      key: Key('comment-pending-$i'),
                      picture: p,
                      onRemove: () => setState(() => _pictures.removeAt(i)),
                    ),
                  for (int i = 0; i < _preparing; i++)
                    SizedBox.square(
                      dimension: 64,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: zen.surfaceSunk,
                          borderRadius: context.zenRadius(10),
                        ),
                        child: const Center(
                          child: SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: _kSideButtonTop),
                child: IconButton(
                  key: const Key('comment-attach'),
                  tooltip: t('Dodaj obrazek'),
                  style: _sideButtonStyle,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  onPressed: _room > 0 && !_sending
                      ? () => unawaited(_attach())
                      : null,
                ),
              ),
              Expanded(
                child: TextField(
                  key: widget.fieldKey,
                  controller: _field,
                  maxLength: kMaxCommentChars,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  // GIFs and stickers from the keyboard (Android's rich
                  // content): a GIF stays animated.
                  contentInsertionConfiguration: ContentInsertionConfiguration(
                    onContentInserted: _onInserted,
                  ),
                  // iPhone keyboards copy GIFs to the clipboard instead.
                  contextMenuBuilder: picturePasteMenu(_addItems),
                  decoration: InputDecoration(
                    hintText: t('Napisz komentarz'),
                    prefixIcon: widget.prefixIcon,
                    counterText: '',
                    errorText: _error,
                    errorMaxLines: 3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: _kSideButtonTop),
                child: IconButton.filled(
                  key: widget.sendKey,
                  tooltip: t('Wyślij'),
                  // The theme tints every icon button with the accent, which
                  // would paint the icon in the button's own colour.
                  style: _sideButtonStyle.copyWith(
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (Set<WidgetState> states) =>
                          states.contains(WidgetState.disabled)
                          ? zen.surfaceMuted
                          : zen.accent,
                    ),
                    foregroundColor: WidgetStateProperty.resolveWith(
                      (Set<WidgetState> states) =>
                          states.contains(WidgetState.disabled)
                          ? zen.textMuted
                          : zen.onAccent,
                    ),
                  ),
                  icon: const Icon(Icons.send_rounded),
                  onPressed: _sending || _preparing > 0
                      ? null
                      : () => unawaited(_send()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A picture waiting to go with the comment, with a button to drop it.
class _PendingPicture extends StatelessWidget {
  const _PendingPicture({
    required this.picture,
    required this.onRemove,
    super.key,
  });

  final CommentPicture picture;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return SizedBox.square(
      dimension: 64,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          ClipRRect(
            borderRadius: context.zenRadius(10),
            child: looksLikeGif(picture.bytes)
                ? ZenAnimatedImage(
                    bytes: picture.bytes,
                    width: double.infinity,
                    height: double.infinity,
                  )
                : Image.memory(picture.bytes, fit: BoxFit.cover),
          ),
          Align(
            alignment: AlignmentDirectional.topEnd,
            // A finger-sized (48 dp) area around the small round button.
            child: SizedBox.square(
              dimension: 48,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: onRemove,
                child: Align(
                  alignment: AlignmentDirectional.topEnd,
                  child: Material(
                    color: scheme.scrim.withValues(alpha: 0.55),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onRemove,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: ZenColors.foregroundFor(scheme.scrim),
                          semanticLabel: t('Usuń obrazek'),
                        ),
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
