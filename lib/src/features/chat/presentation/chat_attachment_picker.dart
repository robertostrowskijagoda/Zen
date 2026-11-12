import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/chat/voice_message_recorder.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/media_transfer.dart';

/// Where a file for a chat comes from.
/// Where a chat attachment comes from; [poll] is no file: a group's poll
/// made in a dialog (`group_poll.dart`).
enum ChatAttachmentSource {
  camera,
  video,
  gallery,
  file,
  gif,
  voice,
  paste,
  poll,
}

/// A file picked for a chat, ready for `sendLocalAttachment` /
/// `sendGroupAttachment`: a photo already as a fresh JPEG (no location or
/// camera data), a GIF without its metadata.
@immutable
final class PickedChatAttachment {
  const PickedChatAttachment({
    this.bytes,
    this.path,
    required this.fileName,
    this.mimeType,
    this.type,
    this.durationMs,
  });

  final Uint8List? bytes;
  final String? path;
  final String fileName;
  final String? mimeType;
  final ChatMessageType? type;
  final int? durationMs;
}

/// Asks where the file comes from; `null` when dismissed.
Future<ChatAttachmentSource?> pickChatAttachmentSource(
  BuildContext context, {
  required bool gifEnabled,
  bool pollEnabled = false,
}) {
  final ZenColors zen = ZenColors.of(context);
  Widget option(
    BuildContext sheetContext,
    ChatAttachmentSource source,
    IconData icon,
    String label, {
    String? note,
  }) => ListTile(
    key: Key('chat-attach-${source.name}'),
    leading: Icon(icon, color: zen.accent),
    title: Text(label),
    subtitle: note == null ? null : Text(note),
    onTap: () => Navigator.of(sheetContext).pop(source),
  );
  return showModalBottomSheet<ChatAttachmentSource>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            option(
              sheetContext,
              ChatAttachmentSource.camera,
              Icons.photo_camera_rounded,
              t('Zrób zdjęcie (Aparat)'),
            ),
            option(
              sheetContext,
              ChatAttachmentSource.video,
              Icons.videocam_rounded,
              t('Nagraj film (Wideo)'),
            ),
            option(
              sheetContext,
              ChatAttachmentSource.gallery,
              Icons.photo_library_rounded,
              t('Wybierz z galerii'),
            ),
            option(
              sheetContext,
              ChatAttachmentSource.file,
              Icons.attach_file_rounded,
              t('Załącznik'),
              // Said before anything is picked: what Zen cleans and what it
              // sends as it is.
              note: t(
                'Zdjęcia, filmy i nagrania idą bez miejsca i danych '
                'urządzenia. Inne pliki idą bez zmian.',
              ),
            ),
            if (gifEnabled)
              option(
                sheetContext,
                ChatAttachmentSource.gif,
                Icons.gif_box_outlined,
                'GIF',
              ),
            option(
              sheetContext,
              ChatAttachmentSource.voice,
              Icons.mic_none_rounded,
              t('Wiadomość głosowa'),
            ),
            // iPhone keyboards copy GIFs to the clipboard.
            if (clipboardPasteButtonShown)
              option(
                sheetContext,
                ChatAttachmentSource.paste,
                Icons.content_paste_rounded,
                t('Wklej obrazek ze schowka'),
              ),
            if (pollEnabled)
              option(
                sheetContext,
                ChatAttachmentSource.poll,
                Icons.poll_outlined,
                t('Ankieta'),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Picks (or records) a file from [source]; `null` when nothing was picked.
/// Throws a [FormatException] with a message for the person when the file
/// cannot go.
Future<PickedChatAttachment?> pickChatAttachment(
  BuildContext context,
  WidgetRef ref,
  ChatAttachmentSource source,
) async {
  switch (source) {
    case ChatAttachmentSource.camera:
    case ChatAttachmentSource.video:
      return _fromCamera(context, source == ChatAttachmentSource.video);
    case ChatAttachmentSource.gallery:
      return _fromGallery(context);
    case ChatAttachmentSource.file:
      return _fromFiles(context);
    case ChatAttachmentSource.gif:
      return _fromGifSearch(context, ref);
    case ChatAttachmentSource.voice:
      return _fromVoice(context, ref);
    case ChatAttachmentSource.paste:
      return _fromClipboard(context);
    case ChatAttachmentSource.poll:
      return null;
  }
}

/// What the clipboard holds (a GIF a keyboard copied, a picture, a file),
/// made ready like a dropped file (media_transfer.dart).
Future<PickedChatAttachment?> _fromClipboard(BuildContext context) async {
  final List<TransferItem> items = await MediaTransfer.platform.readClipboard();
  if (items.isEmpty) {
    throw FormatException(t('W schowku nie ma obrazka ani pliku.'));
  }
  if (!context.mounted) {
    return null;
  }
  return _prepared(context, items.first);
}

/// [item] made ready to send by [prepareOutgoing], the one way every
/// picked photo, film and file goes: without its location, device and
/// time data where Zen can take them out. A GIF that cannot play asks
/// before it goes as a file; a file that goes unchanged says so.
Future<PickedChatAttachment?> _prepared(
  BuildContext context,
  TransferItem item,
) async {
  final OutgoingAttachment? attachment = await prepareOutgoing(item);
  if (attachment == null) {
    throw FormatException(
      t('Nie udało się odczytać pliku „{name}”.', <String, Object>{
        'name': item.name,
      }),
    );
  }
  final PickedGifStatus? problem = attachment.gifProblem;
  if (problem != null &&
      (!context.mounted || !await confirmGifAsFile(context, problem))) {
    return null;
  }
  if (context.mounted) {
    tellFilesGoUnchanged(context, attachment);
  }
  return PickedChatAttachment(
    bytes: attachment.bytes,
    path: attachment.path,
    fileName: attachment.fileName,
    mimeType: attachment.mimeType,
    type: attachment.chatType,
  );
}

Future<PickedChatAttachment?> _fromCamera(
  BuildContext context,
  bool video,
) async {
  final ImagePicker picker = ImagePicker();
  final XFile? file = video
      ? await picker.pickVideo(source: ImageSource.camera)
      : await picker.pickImage(source: ImageSource.camera);
  if (file == null) {
    return null;
  }
  final Uint8List bytes = await file.readAsBytes();
  if (Platform.isAndroid || Platform.isIOS) {
    // The camera left a plain copy in the app's cache: the bytes are in
    // memory now, and the message keeps them encrypted.
    try {
      await File(file.path).delete();
    } on FileSystemException {
      // Removed with the cache later.
    }
  }
  final int now = DateTime.now().millisecondsSinceEpoch;
  final String name = file.name.trim().isNotEmpty
      ? file.name.trim()
      : (video ? 'video-$now.mp4' : 'photo-$now.jpg');
  if (!context.mounted) {
    return null;
  }
  return _prepared(context, TransferItem(name: name, bytes: bytes));
}

Future<PickedChatAttachment?> _fromGallery(BuildContext context) async {
  final XFile? file = await ImagePicker().pickMedia();
  if (file == null || !context.mounted) {
    return null;
  }
  final String name = file.name.trim().isNotEmpty
      ? file.name.trim()
      : 'media-${DateTime.now().millisecondsSinceEpoch}';
  return _prepared(context, TransferItem(name: name, path: file.path));
}

Future<PickedChatAttachment?> _fromFiles(BuildContext context) async {
  final PlatformFile? picked = await FilePicker.pickFile();
  if (picked == null) {
    return null;
  }
  final String? path = picked.path?.trim().isNotEmpty == true
      ? picked.path!.trim()
      : null;
  // The picker hands a path over, never the bytes.
  if (path == null || !context.mounted) {
    return null;
  }
  final String name = picked.name.trim().isNotEmpty
      ? picked.name.trim()
      : 'zalacznik-${DateTime.now().millisecondsSinceEpoch}';
  return _prepared(context, TransferItem(name: name, path: path));
}

Future<PickedChatAttachment?> _fromGifSearch(
  BuildContext context,
  WidgetRef ref,
) async {
  final GifCatalogEntry? entry = await showChatGifPicker(context, ref);
  if (entry == null) {
    return null;
  }
  // The sender fetches the GIF: the recipients never contact the GIF
  // host, and the bytes pass through the media guard like any picture.
  final Uint8List bytes;
  try {
    bytes = await downloadGifToSend(ref.read(gifDownloaderProvider), entry);
  } on Object {
    throw FormatException(t('Nie udało się pobrać GIF-a.'));
  }
  return PickedChatAttachment(
    bytes: bytes,
    fileName: 'gif.gif',
    mimeType: 'image/gif',
    type: ChatMessageType.image,
  );
}

Future<PickedChatAttachment?> _fromVoice(
  BuildContext context,
  WidgetRef ref,
) async {
  if (!context.mounted) {
    return null;
  }
  final RecordedVoiceClip? clip = await showDialog<RecordedVoiceClip>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) => _VoiceRecordDialog(
      recorder: ref.read(voiceMessageRecorderFactoryProvider)(),
    ),
  );
  if (clip == null) {
    return null;
  }
  return PickedChatAttachment(
    path: clip.path,
    fileName: clip.fileName,
    mimeType: clip.mimeType,
    type: ChatMessageType.voice,
    durationMs: clip.durationMs,
  );
}

/// Records a voice message: "Wyślij" ends it, "Anuluj" drops it.
class _VoiceRecordDialog extends StatefulWidget {
  const _VoiceRecordDialog({required this.recorder});

  final VoiceMessageRecorder recorder;

  @override
  State<_VoiceRecordDialog> createState() => _VoiceRecordDialogState();
}

class _VoiceRecordDialogState extends State<_VoiceRecordDialog> {
  final Stopwatch _clock = Stopwatch();
  Timer? _ticker;
  bool _recording = false;
  bool _failed = false;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    bool started = false;
    try {
      started = await widget.recorder.start();
    } on Object {
      started = false;
    }
    if (!mounted) {
      await widget.recorder.cancel();
      return;
    }
    if (!started) {
      setState(() => _failed = true);
      return;
    }
    _clock.start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
    setState(() => _recording = true);
  }

  Future<void> _finish({required bool send}) async {
    if (_done) {
      return;
    }
    _done = true;
    _ticker?.cancel();
    _clock.stop();
    RecordedVoiceClip? clip;
    try {
      if (send && _recording) {
        clip = await widget.recorder.stop();
      } else {
        await widget.recorder.cancel();
      }
    } on Object {
      clip = null;
    }
    if (mounted) {
      Navigator.of(context).pop(clip);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    if (!_done) {
      unawaited(widget.recorder.cancel());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Duration elapsed = _clock.elapsed;
    final String seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    final String time = '${elapsed.inMinutes}:$seconds';
    return AlertDialog(
      scrollable: true,
      key: const Key('voice-record-dialog'),
      icon: Icon(Icons.mic_rounded, color: _failed ? zen.warning : zen.accent),
      title: Text(_failed ? t('Brak dostępu do mikrofonu.') : t('Nagrywanie…')),
      content: _failed ? null : Text(time, textAlign: TextAlign.center),
      actions: <Widget>[
        TextButton(
          onPressed: () => unawaited(_finish(send: false)),
          child: Text(t('Anuluj')),
        ),
        if (!_failed)
          FilledButton(
            key: const Key('voice-record-send'),
            onPressed: _recording ? () => unawaited(_finish(send: true)) : null,
            child: Text(t('Wyślij')),
          ),
      ],
    );
  }
}
