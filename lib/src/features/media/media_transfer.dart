import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/gif_shrink.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/outgoing_media.dart';
import 'package:zen/src/features/media/platform_picture.dart';

// Files and pictures dropped on Zen or pasted from the clipboard.
//
// The system side is the `zen/media_transfer` channel of each runner
// (Windows: WM_DROPFILES and the clipboard's CF_HDROP / PNG / GIF / CF_DIB;
// macOS: the window as a dragging destination and NSPasteboard; Linux: the
// GTK window as a drop site and the GTK clipboard; iOS: UIPasteboard, for
// the GIFs keyboards copy there):
//  - `read` {textFirst} → [{name, path} | {name, bytes}]: files copied in a
//    file manager, else a picture. With textFirst, a clipboard that holds
//    text gives [] (Ctrl+V then pastes the text as usual);
//  - `drop` {paths, x, y} from the system: files dropped on the window at
//    (x, y) logical pixels of the Flutter view;
//  - `has` → whether the clipboard holds a picture, asked without reading
//    it (iOS: the text fields' menu offers "Wklej obrazek" only then).
//
// [MediaDropArea] is what a screen wraps its content in; it hands the items
// on, and [prepareOutgoing] turns each into what goes out (a photo as a
// fresh JPEG, a GIF still animated, a film, or a plain file).

/// One file or picture dropped on Zen or pasted.
@immutable
final class TransferItem {
  const TransferItem({required this.name, this.path, this.bytes});

  /// Its file name (made up for a picture from the clipboard).
  final String name;

  /// A file on the disk (dropped, or copied in a file manager).
  final String? path;

  /// A picture straight from the clipboard.
  final Uint8List? bytes;
}

/// Files dropped on the window, at [position] (logical pixels of the view)
/// when the system says where.
@immutable
final class MediaDrop {
  const MediaDrop(this.items, {this.position});

  final List<TransferItem> items;
  final Offset? position;
}

/// The system's clipboard and drops.
abstract interface class MediaTransferPlatform {
  /// What the clipboard holds (see the library comment for [textFirst]).
  Future<List<TransferItem>> readClipboard({bool textFirst = false});

  /// Files dropped on the window.
  Stream<MediaDrop> get drops;
}

/// [MediaTransferPlatform] over the runners' `zen/media_transfer` channel.
final class ChannelMediaTransfer implements MediaTransferPlatform {
  ChannelMediaTransfer([
    this._channel = const MethodChannel('zen/media_transfer'),
  ]) {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<MediaDrop> _drops =
      StreamController<MediaDrop>.broadcast();

  @override
  Stream<MediaDrop> get drops => _drops.stream;

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'drop') {
      final MediaDrop? drop = mediaDropFromMessage(call.arguments);
      if (drop != null) {
        _drops.add(drop);
      }
    }
    return null;
  }

  @override
  Future<List<TransferItem>> readClipboard({bool textFirst = false}) async {
    try {
      final List<Object?>? raw = await _channel.invokeListMethod<Object?>(
        'read',
        <String, Object?>{'textFirst': textFirst},
      );
      return transferItemsFromMessage(raw);
    } on MissingPluginException {
      return const <TransferItem>[];
    } on PlatformException {
      return const <TransferItem>[];
    }
  }
}

/// The items of a `read` answer (anything malformed is skipped).
List<TransferItem> transferItemsFromMessage(Object? raw) {
  if (raw is! List) {
    return const <TransferItem>[];
  }
  final List<TransferItem> items = <TransferItem>[];
  for (final Object? entry in raw) {
    if (entry is! Map) {
      continue;
    }
    final Object? path = entry['path'];
    final Object? bytes = entry['bytes'];
    final Object? name = entry['name'];
    if (path is String && path.isNotEmpty) {
      items.add(
        TransferItem(
          name: name is String && name.isNotEmpty ? name : _baseName(path),
          path: path,
        ),
      );
    } else if (bytes is Uint8List && bytes.isNotEmpty) {
      items.add(
        TransferItem(
          name: name is String && name.isNotEmpty ? name : 'schowek',
          bytes: bytes,
        ),
      );
    }
  }
  return items;
}

/// A `drop` message: {paths, x, y}; null without any path.
MediaDrop? mediaDropFromMessage(Object? raw) {
  if (raw is! Map) {
    return null;
  }
  final Object? paths = raw['paths'];
  final Object? x = raw['x'];
  final Object? y = raw['y'];
  final List<TransferItem> items = <TransferItem>[
    if (paths is List)
      for (final Object? p in paths)
        if (p is String && p.isNotEmpty)
          TransferItem(name: _baseName(p), path: p),
  ];
  if (items.isEmpty) {
    return null;
  }
  return MediaDrop(
    items,
    position: x is num && y is num ? Offset(x.toDouble(), y.toDouble()) : null,
  );
}

String _baseName(String path) {
  final int slash = math.max(path.lastIndexOf('/'), path.lastIndexOf(r'\'));
  return slash >= 0 ? path.substring(slash + 1) : path;
}

/// The platform in use (replaced in tests).
abstract final class MediaTransfer {
  static MediaTransferPlatform? _platform;

  static MediaTransferPlatform get platform =>
      _platform ??= ChannelMediaTransfer();

  @visibleForTesting
  static set platform(MediaTransferPlatform value) {
    _platform = value;
    _hub?.cancel();
    _hub = null;
  }

  static StreamSubscription<MediaDrop>? _hub;
  static final List<_MediaDropAreaState> _areas = <_MediaDropAreaState>[];

  static void _add(_MediaDropAreaState area) {
    _areas.add(area);
    _hub ??= platform.drops.listen(_deliver);
  }

  static void _remove(_MediaDropAreaState area) => _areas.remove(area);

  /// A drop goes to the area under it, else to the newest area on the
  /// screen in front (a file dropped anywhere on a chat goes to the chat).
  static void _deliver(MediaDrop drop) {
    final List<_MediaDropAreaState> open = <_MediaDropAreaState>[
      for (final _MediaDropAreaState a in _areas)
        if (a._accepts) a,
    ];
    if (open.isEmpty) {
      return;
    }
    final Offset? at = drop.position;
    final _MediaDropAreaState target =
        (at == null
            ? null
            : open.reversed
                  .where((_MediaDropAreaState a) => a._contains(at))
                  .firstOrNull) ??
        open.last;
    unawaited(target._take(drop.items));
  }
}

/// Whether Ctrl+V (⌘V on a Mac) may paste pictures and files: on the
/// computers, where the runners read the clipboard.
bool get desktopPasteSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// Whether chats show a "Wklej" button for pictures on the clipboard: on
/// an iPhone or iPad, whose keyboards copy GIFs there instead of inserting
/// them (Android keyboards insert them, computers have Ctrl+V).
bool get clipboardPasteButtonShown =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

Future<bool> _channelHasPicture() async {
  try {
    return await const MethodChannel(
          'zen/media_transfer',
        ).invokeMethod<bool>('has') ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

/// Asks the system whether its clipboard holds a picture (replaced in
/// tests).
Future<bool> Function() clipboardHasPicture = _channelHasPicture;

/// The menu of a text field (a chat, a comment, a post) that also offers
/// "Wklej obrazek" when the clipboard holds a picture: on an iPhone or iPad
/// keyboards copy GIFs there, and the system's "Wklej" pastes only text.
/// The picture goes to [onItems] like a dropped file. Elsewhere it is the
/// usual menu (computers paste pictures with Ctrl+V, Android keyboards
/// insert them).
EditableTextContextMenuBuilder picturePasteMenu(
  FutureOr<void> Function(List<TransferItem> items) onItems,
) =>
    (BuildContext context, EditableTextState editableTextState) =>
        clipboardPasteButtonShown
        ? _PicturePasteMenu(state: editableTextState, onItems: onItems)
        : AdaptiveTextSelectionToolbar.editableText(
            editableTextState: editableTextState,
          );

class _PicturePasteMenu extends StatefulWidget {
  const _PicturePasteMenu({required this.state, required this.onItems});

  final EditableTextState state;
  final FutureOr<void> Function(List<TransferItem> items) onItems;

  @override
  State<_PicturePasteMenu> createState() => _PicturePasteMenuState();
}

class _PicturePasteMenuState extends State<_PicturePasteMenu> {
  bool _picture = false;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    bool has = false;
    try {
      has = await clipboardHasPicture();
    } on Object {
      has = false;
    }
    if (has && mounted) {
      setState(() => _picture = true);
    }
  }

  static Future<void> _paste(
    FutureOr<void> Function(List<TransferItem> items) onItems,
  ) async {
    List<TransferItem> items = const <TransferItem>[];
    try {
      items = await MediaTransfer.platform.readClipboard();
    } on Object {
      items = const <TransferItem>[];
    }
    if (items.isNotEmpty) {
      await onItems(items);
    }
  }

  @override
  Widget build(BuildContext context) =>
      AdaptiveTextSelectionToolbar.buttonItems(
        anchors: widget.state.contextMenuAnchors,
        buttonItems: <ContextMenuButtonItem>[
          ...widget.state.contextMenuButtonItems,
          if (_picture)
            ContextMenuButtonItem(
              label: t('Wklej obrazek'),
              onPressed: () {
                // The menu goes away with the field's toolbar: what to do with
                // the picture is kept here.
                final FutureOr<void> Function(List<TransferItem> items)
                onItems = widget.onItems;
                widget.state.hideToolbar();
                unawaited(_paste(onItems));
              },
            ),
        ],
      );
}

/// Takes files dropped on it and pictures or files pasted with Ctrl+V (⌘V)
/// while something inside has the focus, and hands them to [onItems].
/// Text on the clipboard is pasted as usual. With [autofocus] the area
/// takes the focus itself (a screen without a text field).
class MediaDropArea extends StatefulWidget {
  const MediaDropArea({
    required this.child,
    required this.onItems,
    this.enabled = true,
    this.autofocus = false,
    super.key,
  });

  final Widget child;
  final FutureOr<void> Function(List<TransferItem> items) onItems;
  final bool enabled;
  final bool autofocus;

  @override
  State<MediaDropArea> createState() => _MediaDropAreaState();
}

class _MediaDropAreaState extends State<MediaDropArea> {
  @override
  void initState() {
    super.initState();
    MediaTransfer._add(this);
  }

  @override
  void dispose() {
    MediaTransfer._remove(this);
    super.dispose();
  }

  /// Enabled and on the screen in front.
  bool get _accepts =>
      mounted &&
      widget.enabled &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      TickerMode.valuesOf(context).enabled;

  bool _contains(Offset at) {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      return false;
    }
    return (box.localToGlobal(Offset.zero) & box.size).contains(at);
  }

  Future<void> _take(List<TransferItem> items) async {
    if (items.isNotEmpty && mounted) {
      await widget.onItems(items);
    }
  }

  bool get _pasteChord {
    final HardwareKeyboard keys = HardwareKeyboard.instance;
    if (keys.isAltPressed || keys.isShiftPressed) {
      return false;
    }
    return defaultTargetPlatform == TargetPlatform.macOS
        ? keys.isMetaPressed && !keys.isControlPressed
        : keys.isControlPressed && !keys.isMetaPressed;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!widget.enabled ||
        !desktopPasteSupported ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyV ||
        !_pasteChord) {
      return KeyEventResult.ignored;
    }
    unawaited(_paste());
    return KeyEventResult.handled;
  }

  Future<void> _paste() async {
    List<TransferItem> items = const <TransferItem>[];
    try {
      items = await MediaTransfer.platform.readClipboard(textFirst: true);
    } on Object {
      items = const <TransferItem>[];
    }
    if (!mounted) {
      return;
    }
    if (items.isNotEmpty) {
      await widget.onItems(items);
      return;
    }
    // Text (or nothing): the usual paste in the field with the focus.
    final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
    if (focused != null && focused.mounted) {
      Actions.maybeInvoke<PasteTextIntent>(
        focused,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: widget.autofocus,
    canRequestFocus: widget.autofocus,
    skipTraversal: !widget.autofocus,
    onKeyEvent: _onKey,
    child: widget.child,
  );
}

/// What a dropped or pasted item goes out as.
enum OutgoingKind { photo, gif, video, file }

/// A dropped or pasted item ready to send.
@immutable
final class OutgoingAttachment {
  const OutgoingAttachment({
    required this.kind,
    required this.fileName,
    required this.mimeType,
    this.bytes,
    this.path,
    this.gifProblem,
    this.unchanged = false,
  });

  final OutgoingKind kind;
  final String fileName;

  /// The real type of a photo, GIF or film; for a file what its first bytes
  /// say, or null.
  final String? mimeType;

  /// What goes out; a big file or film is sent from [path] instead.
  final Uint8List? bytes;
  final String? path;

  /// A GIF that cannot play (too large or damaged): it goes as a file only
  /// if the person agrees ([confirmGifAsFile]).
  final PickedGifStatus? gifProblem;

  /// It goes exactly as it came, with whatever its author, place or device
  /// data it holds: a kind Zen cannot clean ([canStripMetadata]), or one
  /// too large to be read for it. The attach flow says so
  /// ([tellFilesGoUnchanged]).
  final bool unchanged;

  /// The kind of chat message it goes as.
  ChatMessageType get chatType => switch (kind) {
    OutgoingKind.photo || OutgoingKind.gif => ChatMessageType.image,
    OutgoingKind.video => ChatMessageType.video,
    OutgoingKind.file => ChatMessageType.file,
  };
}

/// The largest picture made into a photo; a bigger one goes as a file.
const int kMaxTransferPhotoBytes = 40 * 1024 * 1024;

/// [item] made ready to send, whatever way it was picked (camera, gallery,
/// files, a drop, the clipboard, the keyboard): a photo as a fresh JPEG
/// without metadata, a HEIC or AVIF photo too once the phone's own decoder
/// read it ([decode], `platform_picture.dart`), a GIF still animated
/// (without metadata, see `gif_files.dart`), a film and any other file
/// without the location, device and time data Zen knows how to remove
/// (`outgoing_media.dart`); a file it cannot clean goes as it is, marked
/// [OutgoingAttachment.unchanged]. Null when it cannot be read.
Future<OutgoingAttachment?> prepareOutgoing(
  TransferItem item, {
  PlatformPictureDecoder decode = decodeWithPlatform,
}) async {
  final String? path = item.path;
  final Uint8List? given = item.bytes;
  final Uint8List head;
  final int size;
  try {
    if (given != null) {
      head = Uint8List.sublistView(given, 0, math.min(16, given.length));
      size = given.length;
    } else if (path != null) {
      final File file = File(path);
      if (!await file.exists()) {
        return null;
      }
      size = await file.length();
      final RandomAccessFile handle = await file.open();
      try {
        head = await handle.read(16);
      } finally {
        await handle.close();
      }
    } else {
      return null;
    }
  } on FileSystemException {
    return null;
  }
  if (size == 0) {
    return null;
  }
  Future<Uint8List> whole() async => given ?? await File(path!).readAsBytes();
  final String stem = _stem(item.name);
  try {
    if (looksLikeGif(head)) {
      if (size > kMaxSentGifBytes) {
        return OutgoingAttachment(
          kind: OutgoingKind.file,
          fileName: gifFileName(item.name),
          mimeType: 'image/gif',
          bytes: given,
          path: given == null ? path : null,
          gifProblem: PickedGifStatus.tooLarge,
        );
      }
      final Uint8List bytes = await whole();
      final PickedGif gif = preparePickedGif(bytes);
      if (gif.status == PickedGifStatus.ready) {
        return OutgoingAttachment(
          kind: OutgoingKind.gif,
          fileName: gifFileName(item.name),
          mimeType: 'image/gif',
          bytes: gif.bytes,
        );
      }
      return OutgoingAttachment(
        kind: OutgoingKind.file,
        fileName: gifFileName(item.name),
        mimeType: 'image/gif',
        bytes: stripGifMetadata(bytes) ?? bytes,
        gifProblem: gif.status == PickedGifStatus.notGif
            ? PickedGifStatus.broken
            : gif.status,
      );
    }
    final MediaKind kind = sniffMediaKind(head);
    if ((kind == MediaKind.image || isIsoPicture(head)) &&
        size <= kMaxTransferPhotoBytes) {
      // A HEIC or AVIF photo (the default of iPhones and of many Android
      // cameras) is read by the phone's own decoder first; it then goes on
      // like any photo. An animated WebP or PNG goes as the GIF it is made
      // into, still playing, not as a still JPEG of its first frame.
      final Uint8List original = await whole();
      final Uint8List picture =
          await readablePicture(
            original,
            maxSide: kMaxImageSide,
            decode: decode,
          ) ??
          original;
      final Uint8List moving = await gifIfAnimated(picture);
      if (looksLikeGif(moving)) {
        final PickedGif gif = preparePickedGif(moving);
        if (gif.status == PickedGifStatus.ready) {
          return OutgoingAttachment(
            kind: OutgoingKind.gif,
            fileName: gifFileName(item.name),
            mimeType: 'image/gif',
            bytes: gif.bytes,
          );
        }
      }
      try {
        return OutgoingAttachment(
          kind: OutgoingKind.photo,
          fileName: '$stem.jpg',
          mimeType: 'image/jpeg',
          bytes: await sanitizePhoto(picture),
        );
      } on ArgumentError {
        // Not a picture this can read: it goes as a file below.
      }
    }
    // A film, a recording or a file: its metadata out where Zen knows the
    // kind, kept from the path when there was nothing to remove.
    final bool video = kind == MediaKind.video;
    if (!canStripMetadata(head) || size > kMaxCleanedTransferBytes) {
      return OutgoingAttachment(
        kind: video ? OutgoingKind.video : OutgoingKind.file,
        fileName: item.name,
        mimeType: sniffMimeType(head) ?? (video ? 'video/mp4' : null),
        bytes: given,
        path: given == null ? path : null,
        unchanged: true,
      );
    }
    final Uint8List original = await whole();
    final Uint8List clean = await stripOutgoingMetadataSized(original);
    final bool kept = identical(clean, original) && given == null;
    return OutgoingAttachment(
      kind: video ? OutgoingKind.video : OutgoingKind.file,
      fileName: item.name,
      mimeType: sniffMimeType(head) ?? (video ? 'video/mp4' : null),
      bytes: kept ? null : clean,
      path: kept ? path : null,
    );
  } on FileSystemException {
    return null;
  }
}

/// Whether this run of the app already said that a file goes unchanged.
bool _toldFilesGoUnchanged = false;

/// Says once in a run of the app, as [attachment] goes, that a file Zen
/// cannot clean goes exactly as it is, with what is written in it (the
/// author, sometimes the place). Photos, films and recordings never come
/// here: they go without that data.
void tellFilesGoUnchanged(BuildContext context, OutgoingAttachment attachment) {
  if (!attachment.unchanged || _toldFilesGoUnchanged || !context.mounted) {
    return;
  }
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) {
    return;
  }
  _toldFilesGoUnchanged = true;
  messenger.showSnackBar(
    SnackBar(
      key: const Key('file-goes-unchanged'),
      duration: const Duration(seconds: 8),
      content: Text(
        t(
          '„{name}” idzie bez zmian. Zen usuwa miejsce, czas i dane '
          'urządzenia ze zdjęć, filmów i nagrań; z innych plików nie umie, '
          'więc idą z tym, co w nich zapisano (np. autor, czasem miejsce).',
          <String, Object>{'name': attachment.fileName},
        ),
      ),
    ),
  );
}

@visibleForTesting
void debugResetToldFilesGoUnchanged() => _toldFilesGoUnchanged = false;

String _stem(String name) {
  final String trimmed = name.trim();
  final int dot = trimmed.lastIndexOf('.');
  final String stem = dot > 0 ? trimmed.substring(0, dot) : trimmed;
  return stem.isEmpty ? 'zdjecie' : stem;
}

/// Sends dropped or pasted [items] with [send], one by one: each is made
/// ready first ([prepareOutgoing]); a GIF that cannot play asks before it
/// goes as a file. A chat calls this with its own way of sending.
Future<void> sendTransferItems(
  BuildContext context,
  List<TransferItem> items, {
  required Future<void> Function(OutgoingAttachment attachment) send,
}) async {
  for (final TransferItem item in items) {
    final OutgoingAttachment? attachment = await prepareOutgoing(item);
    if (!context.mounted) {
      return;
    }
    if (attachment == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            t('Nie udało się odczytać pliku „{name}”.', <String, Object>{
              'name': item.name,
            }),
          ),
        ),
      );
      continue;
    }
    final PickedGifStatus? problem = attachment.gifProblem;
    if (problem != null && !await confirmGifAsFile(context, problem)) {
      continue;
    }
    if (!context.mounted) {
      return;
    }
    tellFilesGoUnchanged(context, attachment);
    await send(attachment);
  }
}

/// Asks whether a GIF that cannot play in a chat ([status]: too large or
/// damaged) goes as a plain file instead.
Future<bool> confirmGifAsFile(
  BuildContext context,
  PickedGifStatus status,
) async {
  if (!context.mounted) {
    return false;
  }
  final bool broken = status == PickedGifStatus.broken;
  final bool? go = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      key: const Key('gif-as-file-dialog'),
      icon: const Icon(Icons.gif_box_outlined),
      title: Text(broken ? t('Uszkodzony GIF') : t('Za duży GIF')),
      content: SingleChildScrollView(
        child: Text(
          broken
              ? t(
                  'Ten GIF jest uszkodzony albo niepełny, więc nie zagra '
                  'w rozmowie. Możesz wysłać go jako plik.',
                )
              : t(
                  'W rozmowie grają GIF-y do {size}, do {side} px na bok '
                  'i do {frames} klatek. Ten możesz wysłać jako plik.',
                  <String, Object>{
                    'size': '${kMaxSentGifBytes ~/ (1024 * 1024)} MB',
                    'side': kMaxGifSide,
                    'frames': kMaxGifFrames,
                  },
                ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('gif-send-as-file'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t('Wyślij jako plik')),
        ),
      ],
    ),
  );
  return go == true;
}
