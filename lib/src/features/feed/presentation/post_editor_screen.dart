import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/voice_message_recorder.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/presentation/rich_post_body.dart';
import 'package:zen/src/features/feed/presentation/rich_text_controller.dart';
import 'package:zen/src/features/feed/rich_text.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/media/audio_clip_player.dart';
import 'package:zen/src/features/media/media_guard.dart';

/// A photo, video or recording ready to go into a post.
@immutable
final class DraftMedia {
  const DraftMedia({
    required this.bytes,
    required this.mime,
    this.name = '',
    this.stored,
    this.durationMs,
  });

  /// Photos are already sanitised (EXIF stripped, scaled down, JPEG).
  final Uint8List bytes;
  final String mime;
  final String name;

  /// When editing: the post's existing file (its reference), kept as it is
  /// instead of being stored again.
  final Map<String, dynamic>? stored;

  /// How long a recording is (a voice message recorded here).
  final int? durationMs;

  bool get isVideo => isVideoMime(mime);
  bool get isAudio => isAudioMime(mime);
}

/// What the editor hands over for publishing: [text] with `{{media:N}}`
/// lines where the N-th of [media] goes.
@immutable
final class PostDraft {
  const PostDraft({
    required this.text,
    required this.audience,
    this.media = const <DraftMedia>[],
  });

  final String text;
  final Audience audience;
  final List<DraftMedia> media;
}

/// Publishes a draft; returns an error message ('' = stay quietly), or null
/// on success.
typedef PostSubmit = Future<String?> Function(PostDraft draft);

/// Picks raw files; replaced in tests.
typedef PhotoSource = Future<List<Uint8List>> Function();
typedef VideoSource = Future<List<DraftMedia>> Function();
typedef AudioSource = Future<List<DraftMedia>> Function();

/// One recording picked from the files (a song, a recorded talk); throws
/// [ArgumentError] when it is too big or not a recording.
Future<List<DraftMedia>> pickAudioMedia() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.audio,
    dialogTitle: t('Wybierz nagranie'),
  );
  final PlatformFile? f = result?.files.firstOrNull;
  if (f == null || f.path == null) {
    return const <DraftMedia>[];
  }
  if (f.size > kMaxAudioFileBytes) {
    throw ArgumentError(
      t('Nagranie jest za duże (maks. {size}).', {
        'size': sizeLabel(kMaxAudioFileBytes),
      }),
    );
  }
  return <DraftMedia>[
    audioDraft(await File(f.path!).readAsBytes(), name: f.name),
  ];
}

/// [bytes] of a recording as a post's media; throws [ArgumentError] for
/// anything that is not one (by its content, not its name).
DraftMedia audioDraft(Uint8List bytes, {String name = '', int? durationMs}) {
  final MediaKind kind = sniffMediaKind(bytes);
  if ((kind != MediaKind.audio && kind != MediaKind.video) ||
      !looksLikeSafeContainer(bytes)) {
    throw ArgumentError(t('Ten plik nie jest nagraniem audio.'));
  }
  final String sniffed = sniffMimeType(bytes) ?? 'audio/mp4';
  return DraftMedia(
    bytes: bytes,
    // A recording in an MP4 or WebM box is still a recording.
    mime: sniffed.startsWith('audio/')
        ? sniffed
        : (sniffed.contains('webm') ? 'audio/webm' : 'audio/mp4'),
    name: name,
    durationMs: durationMs,
  );
}

/// Videos are shared as they are (no re-encoding on the phone), so they
/// are kept small enough to travel between friends.
const int kMaxVideoBytes = 50 * 1024 * 1024;

const Map<Audience, IconData> kAudienceIcons = <Audience, IconData>{
  Audience.public: Icons.public_rounded,
  Audience.all: Icons.group_rounded,
  Audience.mid: Icons.people_alt_outlined,
  Audience.close: Icons.favorite_rounded,
};

Map<Audience, String> get kAudienceHints => <Audience, String>{
  Audience.public: t('Każdy, kto Cię obserwuje, także nieznajomi.'),
  Audience.all: t('Wszyscy Twoi znajomi.'),
  Audience.mid: t('Znajomi oznaczeni jako „znajomi” i przyjaciele.'),
  Audience.close: t('Tylko najbliżsi, oznaczeni jako przyjaciele.'),
};

bool get _mobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Photos picked by the user (raw bytes, not yet sanitised).
Future<List<Uint8List>> pickImageBytes({int? limit}) async {
  if (_mobile) {
    final List<XFile> files = await ImagePicker().pickMultiImage(limit: limit);
    return <Uint8List>[for (final XFile f in files) await f.readAsBytes()];
  }
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.image,
    allowMultiple: true,
    withData: true,
    dialogTitle: t('Wybierz zdjęcia'),
  );
  return <Uint8List>[
    for (final PlatformFile f in result?.files ?? const <PlatformFile>[])
      ?(f.bytes ??
          (f.path != null && !kIsWeb
              ? await File(f.path!).readAsBytes()
              : null)),
  ];
}

/// One video picked (or recorded) by the user; throws [ArgumentError] when
/// it is too big.
Future<List<DraftMedia>> pickVideoMedia({bool camera = false}) async {
  if (_mobile) {
    final XFile? f = await ImagePicker().pickVideo(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxDuration: const Duration(minutes: 3),
    );
    if (f == null) {
      return const <DraftMedia>[];
    }
    if (await f.length() > kMaxVideoBytes) {
      throw ArgumentError(
        t('Film jest za duży (maks. {size}).', {
          'size': sizeLabel(kMaxVideoBytes),
        }),
      );
    }
    return <DraftMedia>[
      DraftMedia(
        bytes: await f.readAsBytes(),
        mime: _mimeFor(f.name),
        name: f.name,
      ),
    ];
  }
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.video,
    dialogTitle: t('Wybierz film'),
  );
  final PlatformFile? f = result?.files.firstOrNull;
  if (f == null || f.path == null) {
    return const <DraftMedia>[];
  }
  if (f.size > kMaxVideoBytes) {
    throw ArgumentError(
      t('Film jest za duży (maks. {size}).', {
        'size': sizeLabel(kMaxVideoBytes),
      }),
    );
  }
  return <DraftMedia>[
    DraftMedia(
      bytes: await File(f.path!).readAsBytes(),
      mime: _mimeFor(f.name),
      name: f.name,
    ),
  ];
}

String _mimeFor(String name) {
  final String n = name.toLowerCase();
  if (n.endsWith('.webm')) {
    return 'video/webm';
  }
  if (n.endsWith('.mov')) {
    return 'video/quicktime';
  }
  if (n.endsWith('.mkv')) {
    return 'video/x-matroska';
  }
  return 'video/mp4';
}

String sizeLabel(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).round()} kB';

sealed class _Block {}

final class _TextBlock extends _Block {
  _TextBlock(String text)
    : controller = RichTextController(text: text),
      focus = FocusNode();

  final RichTextController controller;
  final FocusNode focus;

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

final class _MediaBlock extends _Block {
  _MediaBlock(this.media);
  final DraftMedia media;
}

/// The post editor (§24), Discord-style: formatting from a toolbar or
/// shortcuts (Ctrl+B/I/U, Ctrl+Shift+X, Ctrl+E), shown live, and photos or
/// videos placed exactly where the cursor is. A preview shows the post as
/// friends will see it. Also edits an existing post ([editing]): its text,
/// photos and videos ([initialMedia], placed by the `{{media:N}}` lines of
/// [initialText]); who sees it stays as it was.
class PostEditorScreen extends StatefulWidget {
  const PostEditorScreen({
    required this.onSubmit,
    this.initialText = '',
    this.initialMedia = const <DraftMedia>[],
    this.initialAudience = Audience.public,
    this.editing = false,
    this.pickPhotos,
    this.pickVideos,
    this.pickAudio,
    this.recorder,
    this.pickOnOpen = false,
    super.key,
  });

  final PostSubmit onSubmit;
  final String initialText;
  final List<DraftMedia> initialMedia;
  final Audience initialAudience;
  final bool editing;

  /// Override the pickers (tests).
  final PhotoSource? pickPhotos;
  final VideoSource? pickVideos;
  final AudioSource? pickAudio;

  /// Records a voice message (tests replace it).
  final VoiceMessageRecorder Function()? recorder;

  /// Opens the photo picker right away ("add a photo" on the wall).
  final bool pickOnOpen;

  /// Opens the editor; true once something was published.
  static Future<bool> open(
    BuildContext context, {
    required PostSubmit onSubmit,
    String initialText = '',
    List<DraftMedia> initialMedia = const <DraftMedia>[],
    Audience initialAudience = Audience.public,
    bool editing = false,
    PhotoSource? pickPhotos,
    VideoSource? pickVideos,
    AudioSource? pickAudio,
    VoiceMessageRecorder Function()? recorder,
    bool pickOnOpen = false,
  }) async =>
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (BuildContext context) => PostEditorScreen(
            onSubmit: onSubmit,
            initialText: initialText,
            initialMedia: initialMedia,
            initialAudience: initialAudience,
            editing: editing,
            pickPhotos: pickPhotos,
            pickVideos: pickVideos,
            pickAudio: pickAudio,
            recorder: recorder,
            pickOnOpen: pickOnOpen,
          ),
        ),
      ) ??
      false;

  @override
  State<PostEditorScreen> createState() => _PostEditorScreenState();
}

class _PostEditorScreenState extends State<PostEditorScreen> {
  late final List<_Block> _blocks = _initialBlocks();
  late _TextBlock _active = _blocks.first as _TextBlock;

  /// What the editor started with, to tell whether anything changed.
  late final String _initialSource;
  late final List<DraftMedia> _initialMediaList;

  /// [PostEditorScreen.initialText] cut into text and media blocks at its
  /// `{{media:N}}` lines (a text block always comes first and after each
  /// photo or video, as when inserting).
  List<_Block> _initialBlocks() {
    final List<_Block> out = <_Block>[];
    final List<String> lines = <String>[];
    final Set<int> used = <int>{};
    void text() {
      out.add(_TextBlock(lines.join('\n')));
      lines.clear();
    }

    for (final String line in widget.initialText.split('\n')) {
      final List<int> ref = referencedMedia(line);
      final int? i = ref.isEmpty ? null : ref.first;
      if (i != null &&
          i >= 0 &&
          i < widget.initialMedia.length &&
          used.add(i)) {
        text();
        out.add(_MediaBlock(widget.initialMedia[i]));
      } else {
        lines.add(line);
      }
    }
    text();
    // Media the text never placed go at the end.
    for (int i = 0; i < widget.initialMedia.length; i++) {
      if (!used.contains(i)) {
        out
          ..add(_MediaBlock(widget.initialMedia[i]))
          ..add(_TextBlock(''));
      }
    }
    return out;
  }

  late Audience _audience = widget.initialAudience;

  /// A voice message being recorded, and since when.
  VoiceMessageRecorder? _recording;
  DateTime? _recordingSince;
  Timer? _recordingTicker;
  int _processing = 0;
  bool _submitting = false;
  bool _preview = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final _Block b in _blocks) {
      if (b is _TextBlock) {
        _watch(b);
      }
    }
    _initialSource = _source;
    _initialMediaList = _media;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _active.focus.requestFocus();
      if (widget.pickOnOpen) {
        unawaited(_addPhotos());
      }
    });
  }

  void _watch(_TextBlock b) {
    b.controller.addListener(_changed);
    b.focus.addListener(() {
      if (b.focus.hasFocus) {
        _active = b;
      }
    });
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _recordingTicker?.cancel();
    unawaited(_recording?.cancel());
    for (final _Block b in _blocks) {
      if (b is _TextBlock) {
        b.dispose();
      }
    }
    super.dispose();
  }

  List<DraftMedia> get _media => <DraftMedia>[
    for (final _Block b in _blocks)
      if (b is _MediaBlock) b.media,
  ];

  int get _room => kMaxPostImages - _media.length - _processing;

  /// The post as text, media as `{{media:N}}` lines.
  String get _source {
    final List<String> parts = <String>[];
    int n = 0;
    for (final _Block b in _blocks) {
      switch (b) {
        case _TextBlock(:final RichTextController controller):
          final String t = controller.text.trimRight();
          if (t.trim().isNotEmpty) {
            parts.add(t);
          }
        case _MediaBlock():
          parts.add(mediaToken(n++));
      }
    }
    return parts.join('\n');
  }

  bool get _mediaChanged {
    final List<DraftMedia> now = _media;
    if (now.length != _initialMediaList.length) {
      return true;
    }
    for (int i = 0; i < now.length; i++) {
      if (!identical(now[i], _initialMediaList[i])) {
        return true;
      }
    }
    return false;
  }

  bool get _dirty => _source.trim() != _initialSource.trim() || _mediaChanged;

  bool get _canPublish {
    final String s = _source.trim();
    return !_submitting &&
        _processing == 0 &&
        _recording == null &&
        s.length <= kMaxPostChars &&
        s.isNotEmpty &&
        (!widget.editing || _dirty);
  }

  // ---- media ---------------------------------------------------------------

  /// Puts [media] where the cursor is, splitting the text there.
  void _insert(DraftMedia media) {
    final int at = _blocks.indexOf(_active);
    final String text = _active.controller.text;
    final TextSelection sel = _active.controller.selection;
    final int cut = sel.isValid ? sel.start.clamp(0, text.length) : text.length;
    final String before = text.substring(0, cut).trimRight();
    final String after = text
        .substring(cut)
        .replaceFirst(RegExp(r'^\s*\n'), '');
    _active.controller.value = TextEditingValue(
      text: before,
      selection: TextSelection.collapsed(offset: before.length),
    );
    final _TextBlock next = _TextBlock(after);
    _watch(next);
    setState(() {
      _blocks.insertAll(at + 1, <_Block>[_MediaBlock(media), next]);
      _active = next;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        next.focus.requestFocus();
      }
    });
  }

  void _remove(_MediaBlock m) {
    final int at = _blocks.indexOf(m);
    setState(() {
      _blocks.removeAt(at);
      // Glue the text around it back together.
      if (at > 0 &&
          at < _blocks.length &&
          _blocks[at - 1] is _TextBlock &&
          _blocks[at] is _TextBlock) {
        final _TextBlock a = _blocks[at - 1] as _TextBlock;
        final _TextBlock b = _blocks.removeAt(at) as _TextBlock;
        final String joined = <String>[
          a.controller.text.trimRight(),
          b.controller.text,
        ].where((String s) => s.isNotEmpty).join('\n');
        a.controller.text = joined;
        if (identical(_active, b)) {
          _active = a;
        }
        b.dispose();
      }
    });
  }

  Future<List<Uint8List>> _pickImages() =>
      pickImageBytes(limit: _room > 1 ? _room : null);

  Future<List<DraftMedia>> _pickVideo({bool camera = false}) =>
      pickVideoMedia(camera: camera);

  Future<void> _addPhotos({bool camera = false}) async {
    if (_room <= 0) {
      setState(
        () => _error = tn(
          kMaxPostImages,
          one: 'Najwyżej {n} zdjęcie, film lub nagranie.',
          few: 'Najwyżej {n} zdjęcia, filmy i nagrania.',
          many: 'Najwyżej {n} zdjęć, filmów i nagrań.',
        ),
      );
      return;
    }
    List<Uint8List> raw;
    try {
      if (camera) {
        final XFile? shot = await ImagePicker().pickImage(
          source: ImageSource.camera,
        );
        raw = shot == null
            ? <Uint8List>[]
            : <Uint8List>[await shot.readAsBytes()];
      } else {
        raw = await (widget.pickPhotos ?? _pickImages)();
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () =>
              _error = t('Nie udało się otworzyć zdjęć: {error}', {'error': e}),
        );
      }
      return;
    }
    if (raw.length > _room && mounted) {
      setState(
        () => _error = tn(
          kMaxPostImages,
          one: 'Najwyżej {n} zdjęcie, film lub nagranie — dodałem pierwsze.',
          few: 'Najwyżej {n} zdjęcia, filmy i nagrania — dodałem pierwsze.',
          many: 'Najwyżej {n} zdjęć, filmów i nagrań — dodałem pierwsze.',
        ),
      );
      raw = raw.take(_room).toList();
    }
    for (final Uint8List bytes in raw) {
      if (!mounted) {
        return;
      }
      setState(() => _processing++);
      try {
        final Uint8List clean = await sanitizePhoto(bytes);
        if (mounted) {
          _insert(DraftMedia(bytes: clean, mime: 'image/jpeg'));
        }
      } on ArgumentError {
        if (mounted) {
          setState(() => _error = t('Ten plik nie jest zdjęciem.'));
        }
      } finally {
        if (mounted) {
          setState(() => _processing--);
        }
      }
    }
  }

  Future<void> _addVideo({bool camera = false}) async {
    if (_room <= 0) {
      setState(
        () => _error = tn(
          kMaxPostImages,
          one: 'Najwyżej {n} zdjęcie, film lub nagranie.',
          few: 'Najwyżej {n} zdjęcia, filmy i nagrania.',
          many: 'Najwyżej {n} zdjęć, filmów i nagrań.',
        ),
      );
      return;
    }
    try {
      final List<DraftMedia> picked =
          await (widget.pickVideos ?? () => _pickVideo(camera: camera))();
      for (final DraftMedia m in picked) {
        if (m.bytes.length > kMaxVideoBytes) {
          throw ArgumentError(
            t('Film jest za duży (maks. {size}).', {
              'size': sizeLabel(kMaxVideoBytes),
            }),
          );
        }
        if (mounted) {
          _insert(m);
        }
      }
    } on ArgumentError catch (e) {
      if (mounted) {
        setState(() => _error = e.message as String?);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _error = t('Nie udało się dodać filmu: {error}', {'error': e}),
        );
      }
    }
  }

  Future<void> _addAudioFile() async {
    if (_room <= 0) {
      setState(
        () => _error = tn(
          kMaxPostImages,
          one: 'Najwyżej {n} zdjęcie, film lub nagranie.',
          few: 'Najwyżej {n} zdjęcia, filmy i nagrania.',
          many: 'Najwyżej {n} zdjęć, filmów i nagrań.',
        ),
      );
      return;
    }
    try {
      final List<DraftMedia> picked =
          await (widget.pickAudio ?? pickAudioMedia)();
      for (final DraftMedia m in picked) {
        if (mounted) {
          _insert(m);
        }
      }
    } on ArgumentError catch (e) {
      if (mounted) {
        setState(() => _error = e.message as String?);
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () =>
              _error = t('Nie udało się dodać nagrania: {error}', {'error': e}),
        );
      }
    }
  }

  /// Records into the temporary media folder; the bytes go into the post
  /// and the file is deleted right away.
  VoiceMessageRecorder _newRecorder() =>
      widget.recorder?.call() ?? PlatformVoiceMessageRecorder();

  Future<void> _startRecording() async {
    if (_recording != null) {
      return;
    }
    if (_room <= 0) {
      setState(
        () => _error = tn(
          kMaxPostImages,
          one: 'Najwyżej {n} zdjęcie, film lub nagranie.',
          few: 'Najwyżej {n} zdjęcia, filmy i nagrania.',
          many: 'Najwyżej {n} zdjęć, filmów i nagrań.',
        ),
      );
      return;
    }
    final VoiceMessageRecorder recorder = _newRecorder();
    try {
      if (!await recorder.start()) {
        await recorder.cancel();
        if (mounted) {
          setState(() => _error = t('Brak dostępu do mikrofonu.'));
        }
        return;
      }
    } on Object catch (e) {
      await recorder.cancel();
      if (mounted) {
        setState(
          () => _error = t('Nie udało się zacząć nagrania: {error}', {
            'error': e,
          }),
        );
      }
      return;
    }
    if (!mounted) {
      await recorder.cancel();
      return;
    }
    setState(() {
      _error = null;
      _recording = recorder;
      _recordingSince = DateTime.now();
    });
    _recordingTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  Future<void> _stopRecording({bool keep = true}) async {
    final VoiceMessageRecorder? recorder = _recording;
    if (recorder == null) {
      return;
    }
    _recordingTicker?.cancel();
    _recordingTicker = null;
    setState(() {
      _recording = null;
      _recordingSince = null;
    });
    if (!keep) {
      await recorder.cancel();
      return;
    }
    try {
      final RecordedVoiceClip? clip = await recorder.stop();
      if (clip == null) {
        if (mounted) {
          setState(() => _error = t('Nagranie nie zawiera dźwięku.'));
        }
        return;
      }
      final File file = File(clip.path);
      final Uint8List bytes = await file.readAsBytes();
      try {
        await file.delete();
      } on FileSystemException {
        // Left for the system to clean up.
      }
      if (mounted) {
        _insert(
          audioDraft(bytes, name: t('Głosówka'), durationMs: clip.durationMs),
        );
      }
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _error = t('Nie udało się zapisać nagrania: {error}', {
            'error': e,
          }),
        );
      }
    }
  }

  Widget _recordingBar(ZenColors zen) {
    final DateTime? since = _recordingSince;
    final int seconds = since == null
        ? 0
        : DateTime.now().difference(since).inSeconds;
    return Container(
      key: const Key('post-recording'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: zen.danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: zen.danger.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.fiber_manual_record_rounded, color: zen.danger, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t('Nagrywam… {time}', {
                'time':
                    '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}',
              }),
              style: TextStyle(
                color: zen.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            key: const Key('post-recording-cancel'),
            onPressed: () => unawaited(_stopRecording(keep: false)),
            child: Text(t('Anuluj')),
          ),
          FilledButton.icon(
            key: const Key('post-recording-stop'),
            onPressed: () => unawaited(_stopRecording()),
            icon: const Icon(Icons.stop_rounded, size: 18),
            label: Text(t('Wstaw')),
          ),
        ],
      ),
    );
  }

  // ---- formatting ----------------------------------------------------------

  void _wrap(String marker) {
    _active.controller.toggleWrap(marker);
    _active.focus.requestFocus();
  }

  void _prefix(String prefix) {
    _active.controller.toggleLinePrefix(prefix);
    _active.focus.requestFocus();
  }

  void _codeBlock() {
    _active.controller.toggleCodeBlock();
    _active.focus.requestFocus();
  }

  // ---- audience, close, publish -------------------------------------------

  Future<void> _chooseAudience() async {
    final Audience? picked = await showModalBottomSheet<Audience>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  t('Kto zobaczy ten post?'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            for (final Audience a in Audience.values)
              ListTile(
                key: Key('post-audience-${a.name}'),
                leading: ZenIconBadge(
                  icon: kAudienceIcons[a]!,
                  tone: a == _audience
                      ? ZenColors.of(context).accent
                      : ZenColors.of(context).textSecondary,
                  size: 38,
                ),
                title: Text(kAudienceLabels[a]!),
                subtitle: Text(kAudienceHints[a]!),
                trailing: a == _audience
                    ? Icon(
                        Icons.check_circle_rounded,
                        color: ZenColors.of(context).accent,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(a),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked != null && mounted) {
      setState(() => _audience = picked);
    }
  }

  Future<void> _close() async {
    if (!_dirty || _submitting) {
      Navigator.of(context).pop(false);
      return;
    }
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          widget.editing ? t('Porzucić zmiany?') : t('Odrzucić post?'),
        ),
        content: Text(t('To, co napisałeś, nie zostanie zapisane.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Pisz dalej')),
          ),
          FilledButton(
            key: const Key('post-discard'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Odrzuć')),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      Navigator.of(context).pop(false);
    }
  }

  Future<void> _submit() async {
    if (!_canPublish) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    final String? error = await widget.onSubmit(
      PostDraft(
        text: _source,
        audience: _audience,
        media: List<DraftMedia>.unmodifiable(_media),
      ),
    );
    if (!mounted) {
      return;
    }
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _submitting = false;
      _error = error.isEmpty ? null : error;
    });
  }

  // ---- UI ------------------------------------------------------------------

  Widget _mediaPreview(DraftMedia m, {VoidCallback? onRemove, Key? removeKey}) {
    final ZenColors zen = ZenColors.of(context);
    if (m.isAudio) {
      return Stack(
        children: <Widget>[
          AudioClipPlayer(
            load: () async => m.bytes,
            title: m.name.isEmpty ? t('Nagranie') : m.name,
            durationMs: m.durationMs,
            sizeBytes: m.bytes.length,
          ),
          if (onRemove != null)
            Positioned(
              top: 0,
              right: 0,
              child: IconButton(
                key: removeKey,
                tooltip: t('Usuń nagranie'),
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
                icon: Icon(Icons.close_rounded, size: 18, color: zen.textMuted),
              ),
            ),
        ],
      );
    }
    final Widget body = m.isVideo
        ? Container(
            height: 140,
            color: zen.surfaceSunk,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.movie_outlined, size: 36, color: zen.textSecondary),
                const SizedBox(height: 6),
                Text(
                  '${m.name.isEmpty ? t('Film') : m.name} · '
                  '${sizeLabel(m.bytes.length)}',
                  style: TextStyle(color: zen.textSecondary, fontSize: 12),
                ),
              ],
            ),
          )
        : Image.memory(
            m.bytes,
            width: double.infinity,
            height: 240,
            fit: BoxFit.cover,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        children: <Widget>[
          body,
          if (onRemove != null)
            Positioned(
              top: 6,
              right: 6,
              child: Material(
                color: Colors.black.withValues(alpha: 0.55),
                shape: const CircleBorder(),
                child: InkWell(
                  key: removeKey,
                  customBorder: const CircleBorder(),
                  onTap: onRemove,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _editor(ZenColors zen) {
    final TextStyle style = TextStyle(
      fontSize: 18,
      height: 1.45,
      color: zen.textPrimary,
    );
    int mediaIndex = 0;
    final bool onlyOne = _blocks.length == 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final _Block b in _blocks)
          switch (b) {
            _TextBlock() => TextField(
              key: identical(b, _blocks.first) ? const Key('post-text') : null,
              controller: b.controller,
              focusNode: b.focus,
              enableIMEPersonalizedLearning: false,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              minLines: onlyOne ? 6 : 1,
              maxLines: null,
              style: style,
              decoration: InputDecoration(
                hintText: widget.editing || !identical(b, _blocks.first)
                    ? null
                    : t('Co słychać? Podziel się czymś ze znajomymi…'),
                hintStyle: style.copyWith(color: zen.textMuted),
                filled: false,
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
            _MediaBlock(:final DraftMedia media) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: _mediaPreview(
                media,
                removeKey: Key('post-media-remove-${mediaIndex++}'),
                onRemove: () => _remove(b),
              ),
            ),
          },
        if (_recording != null) _recordingBar(zen),
        if (_processing > 0)
          Container(
            height: 120,
            margin: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: zen.surfaceSunk,
              borderRadius: BorderRadius.circular(18),
            ),
            alignment: Alignment.center,
            child: const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }

  Widget _toolbar(ZenColors zen) {
    Widget tool(String key, IconData icon, String tip, VoidCallback? onTap) =>
        IconButton(
          key: Key('post-tool-$key'),
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          onPressed: _preview ? null : onTap,
          icon: Icon(icon, size: 21),
        );
    Widget gap() => Container(
      width: 1,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: zen.outlineSoft,
    );
    // Wraps onto a second row on narrow screens: a sideways-scrolling bar
    // hid its last buttons behind the edge.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          ...<Widget>[
            tool(
              'photo',
              Icons.add_photo_alternate_outlined,
              t('Wstaw zdjęcia w miejscu kursora'),
              _room > 0 ? () => unawaited(_addPhotos()) : null,
            ),
            tool(
              'video',
              Icons.video_library_outlined,
              t('Wstaw film w miejscu kursora'),
              _room > 0 ? () => unawaited(_addVideo()) : null,
            ),
            tool(
              'voice',
              Icons.mic_none_rounded,
              t('Nagraj głosówkę'),
              _room > 0 && _recording == null
                  ? () => unawaited(_startRecording())
                  : null,
            ),
            tool(
              'audio',
              Icons.audio_file_outlined,
              t('Wstaw nagranie z pliku'),
              _room > 0 ? () => unawaited(_addAudioFile()) : null,
            ),
            if (_mobile) ...<Widget>[
              tool(
                'camera',
                Icons.photo_camera_outlined,
                t('Zrób zdjęcie'),
                _room > 0 ? () => unawaited(_addPhotos(camera: true)) : null,
              ),
              tool(
                'record',
                Icons.videocam_outlined,
                t('Nagraj film'),
                _room > 0 ? () => unawaited(_addVideo(camera: true)) : null,
              ),
            ],
            gap(),
          ],
          tool(
            'bold',
            Icons.format_bold_rounded,
            t('Pogrubienie (Ctrl+B)'),
            () => _wrap('**'),
          ),
          tool(
            'italic',
            Icons.format_italic_rounded,
            t('Kursywa (Ctrl+I)'),
            () => _wrap('*'),
          ),
          tool(
            'underline',
            Icons.format_underlined_rounded,
            t('Podkreślenie (Ctrl+U)'),
            () => _wrap('__'),
          ),
          tool(
            'strike',
            Icons.format_strikethrough_rounded,
            t('Przekreślenie (Ctrl+Shift+X)'),
            () => _wrap('~~'),
          ),
          tool('code', Icons.code_rounded, t('Kod (Ctrl+E)'), () => _wrap('`')),
          tool(
            'spoiler',
            Icons.visibility_off_outlined,
            t('Spoiler'),
            () => _wrap('||'),
          ),
          gap(),
          tool(
            'heading',
            Icons.title_rounded,
            t('Nagłówek'),
            () => _prefix('# '),
          ),
          tool(
            'quote',
            Icons.format_quote_rounded,
            t('Cytat'),
            () => _prefix('> '),
          ),
          tool(
            'list',
            Icons.format_list_bulleted_rounded,
            t('Lista'),
            () => _prefix('- '),
          ),
          tool(
            'numbered',
            Icons.format_list_numbered_rounded,
            t('Lista numerowana'),
            () => _prefix('1. '),
          ),
          tool(
            'codeblock',
            Icons.data_object_rounded,
            t('Blok kodu'),
            _codeBlock,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String source = _source;
    final int length = source.trim().length;
    final List<DraftMedia> media = _media;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop) {
          unawaited(_close());
        }
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
              unawaited(_submit()),
          const SingleActivator(LogicalKeyboardKey.keyB, control: true): () =>
              _wrap('**'),
          const SingleActivator(LogicalKeyboardKey.keyI, control: true): () =>
              _wrap('*'),
          const SingleActivator(LogicalKeyboardKey.keyU, control: true): () =>
              _wrap('__'),
          const SingleActivator(
            LogicalKeyboardKey.keyX,
            control: true,
            shift: true,
          ): () =>
              _wrap('~~'),
          const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
              _wrap('`'),
        },
        child: Scaffold(
          key: const Key('post-editor'),
          appBar: AppBar(
            leading: IconButton(
              key: const Key('post-close'),
              tooltip: t('Zamknij'),
              icon: const Icon(Icons.close_rounded),
              onPressed: () => unawaited(_close()),
            ),
            title: Text(widget.editing ? t('Edytuj post') : t('Nowy post')),
            actions: <Widget>[
              IconButton(
                key: const Key('post-preview'),
                tooltip: _preview ? t('Wróć do edycji') : t('Podgląd'),
                isSelected: _preview,
                icon: const Icon(Icons.visibility_outlined),
                selectedIcon: const Icon(Icons.edit_outlined),
                onPressed: () => setState(() => _preview = !_preview),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: FilledButton(
                  key: const Key('post-publish'),
                  onPressed: _canPublish ? () => unawaited(_submit()) : null,
                  child: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(widget.editing ? t('Zapisz') : t('Opublikuj')),
                ),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Column(
              children: <Widget>[
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Container(
                                width: 44,
                                height: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: <Color>[
                                      zen.accent,
                                      zen.accentSecondary,
                                    ],
                                  ),
                                ),
                                child: Text(
                                  t('Ty').characters.first,
                                  style: TextStyle(
                                    color: zen.onAccent,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 18,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    t('Ty'),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 15,
                                      color: zen.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  _AudiencePill(
                                    audience: _audience,
                                    onTap: widget.editing
                                        ? null
                                        : () => unawaited(_chooseAudience()),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (_preview)
                            Padding(
                              key: const Key('post-preview-body'),
                              padding: const EdgeInsets.only(top: 12),
                              child: source.trim().isEmpty
                                  ? Text(
                                      t('Na razie pusto.'),
                                      style: TextStyle(color: zen.textMuted),
                                    )
                                  : RichPostBody(
                                      source: source,
                                      mediaCount: media.length,
                                      fontSize: 16,
                                      mediaBuilder: (BuildContext c, int i) =>
                                          _mediaPreview(media[i]),
                                    ),
                            )
                          else
                            _editor(zen),
                          if (widget.editing)
                            Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: ZenInfo(
                                icon: Icons.info_outline_rounded,
                                text: t(
                                  'Możesz zmienić tekst, zdjęcia, filmy i '
                                  'nagrania. '
                                  'Odbiorcy posta zostają bez zmian.',
                                ),
                              ),
                            ),
                          if (_error != null)
                            Container(
                              margin: const EdgeInsets.only(top: 12),
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                12,
                                14,
                                12,
                              ),
                              decoration: BoxDecoration(
                                color: zen.danger.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: zen.danger.withValues(alpha: 0.30),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Icon(
                                    Icons.error_outline_rounded,
                                    color: zen.danger,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _error!,
                                      key: const Key('post-error'),
                                      style: TextStyle(
                                        color: zen.danger,
                                        fontSize: 13.5,
                                        height: 1.35,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: zen.surface,
                    border: Border(top: BorderSide(color: zen.outlineSoft)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: <Widget>[
                        Expanded(child: _toolbar(zen)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text(
                            '$length / $kMaxPostChars',
                            key: const Key('post-counter'),
                            style: TextStyle(
                              fontSize: 12,
                              color: length > kMaxPostChars
                                  ? zen.danger
                                  : length > kMaxPostChars - 200
                                  ? zen.warning
                                  : zen.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AudiencePill extends StatelessWidget {
  const _AudiencePill({required this.audience, this.onTap});

  final Audience audience;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Material(
      color: zen.surfaceSunk,
      shape: StadiumBorder(side: BorderSide(color: zen.outlineSoft)),
      child: InkWell(
        key: const Key('post-audience'),
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 5, 6, 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(kAudienceIcons[audience], size: 15, color: zen.textPrimary),
              const SizedBox(width: 6),
              Text(
                kAudienceLabels[audience]!,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: zen.textPrimary,
                ),
              ),
              if (onTap != null)
                Icon(
                  Icons.arrow_drop_down_rounded,
                  size: 20,
                  color: zen.textSecondary,
                )
              else
                const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}
