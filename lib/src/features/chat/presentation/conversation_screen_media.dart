part of 'conversation_screen.dart';

extension _ConversationScreenMediaState on _ConversationScreenState {
  Widget _buildComposer(FriendProfile? friend) {
    final ZenColors zen = ZenColors.of(context);
    final bool canCompose = friend?.status == FriendRelationshipStatus.accepted;
    // Someone who is not a friend: text only.
    final bool canText =
        canCompose || isStrangerConversation(friend, widget.peerAddress);
    final bool idle = !_isRecordingVoice && !_isRecordingBusy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Toolbar: attachments and voice toggle live above the input box.
          Row(
            children: <Widget>[
              _ComposerActionButton(
                key: const Key('conversation-emoji-button'),
                icon: Icons.emoji_emotions_outlined,
                tooltip: t('Emotikony'),
                toneIndex: 0,
                onPressed: canText && idle ? _pickEmoji : null,
              ),
              const SizedBox(width: 6),
              _ComposerActionButton(
                key: const Key('conversation-gif-button'),
                icon: Icons.gif_box_outlined,
                tooltip: 'GIF',
                toneIndex: 1,
                onPressed: canCompose && idle ? _pickAndSendGif : null,
              ),
              const SizedBox(width: 6),
              _ComposerActionButton(
                key: const Key('conversation-camera-button'),
                icon: Icons.photo_camera_outlined,
                tooltip: t('Zrób zdjęcie lub nagraj film'),
                toneIndex: 2,
                onPressed: canCompose && idle ? _capturePhotoOrVideo : null,
              ),
              const SizedBox(width: 6),
              _ComposerActionButton(
                key: const Key('conversation-attach-button'),
                icon: Icons.attach_file_rounded,
                tooltip: t('Załącznik'),
                toneIndex: 3,
                onPressed: canCompose && idle ? _pickAndSendAttachment : null,
              ),
              // Voice notes are an outgoing action, so the mic sits on the
              // right, over the send button - not with the attachment pickers.
              const Spacer(),
              _ComposerActionButton(
                key: const Key('conversation-record-button'),
                toneIndex: 5,
                icon: _isRecordingVoice
                    ? Icons.mic_rounded
                    : Icons.mic_none_rounded,
                active: _isRecordingVoice,
                onLongPressStart: canCompose && !_isRecordingBusy
                    ? (_) => _startVoiceRecording()
                    : null,
                onLongPressEnd: canCompose && _isRecordingVoice
                    ? (_) => _stopVoiceRecording()
                    : null,
                onLongPressCancel: canCompose && _isRecordingVoice
                    ? () => _cancelVoiceRecording()
                    : null,
                onPressed: canCompose && !_isRecordingBusy
                    ? (_isRecordingVoice
                          ? _stopVoiceRecording
                          : _startVoiceRecording)
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 6),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            decoration: BoxDecoration(
              color: zen.surfaceRaised,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: _isRecordingVoice
                    ? zen.warning.withValues(alpha: 0.6)
                    : zen.outlineSoft,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: _isRecordingVoice
                        ? _RecordingComposerStatus(
                            key: const ValueKey<String>('recording-composer'),
                            elapsed: _recordingElapsed,
                          )
                        : TextField(
                            key: const Key('conversation-composer-field'),
                            controller: _composerController,
                            // Keyboard must not learn what you write.
                            enableIMEPersonalizedLearning: false,
                            enabled: canText && !_isRecordingBusy,
                            minLines: 1,
                            maxLines: 6,
                            textCapitalization: TextCapitalization.sentences,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 15,
                              height: 1.35,
                            ),
                            decoration: InputDecoration(
                              filled: false,
                              isDense: true,
                              contentPadding: const EdgeInsets.fromLTRB(
                                18,
                                13,
                                8,
                                13,
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              hintStyle: TextStyle(
                                color: zen.textMuted,
                                fontSize: 14.5,
                              ),
                              hintText: canCompose
                                  ? t('Wiadomość…')
                                  : canText
                                  ? t('Wiadomość (tylko tekst)…')
                                  : t(
                                      'Rozmowa odblokuje się po akceptacji '
                                      'relacji',
                                    ),
                            ),
                          ),
                  ),
                ),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _composerController,
                  builder:
                      (
                        BuildContext context,
                        TextEditingValue value,
                        Widget? child,
                      ) {
                        final bool hasText = value.text.trim().isNotEmpty;
                        final VoidCallback? onPressed =
                            !canText || _isRecordingBusy
                            ? null
                            : _isRecordingVoice
                            ? _stopVoiceRecording
                            : hasText
                            ? _sendMessage
                            : null;
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(2, 4, 4, 4),
                          child: SizedBox(
                            width: 40,
                            height: 40,
                            child: _isRecordingVoice
                                ? IconButton.filled(
                                    key: const Key(
                                      'conversation-stop-record-button',
                                    ),
                                    onPressed: onPressed,
                                    style: IconButton.styleFrom(
                                      backgroundColor: zen.warning,
                                      foregroundColor: ZenColors.foregroundFor(
                                        zen.warning,
                                      ),
                                      disabledBackgroundColor: zen.surfaceSunk,
                                      padding: EdgeInsets.zero,
                                      shape: const CircleBorder(),
                                    ),
                                    icon: const Icon(
                                      Icons.stop_rounded,
                                      size: 20,
                                    ),
                                  )
                                : ZenBreathingGlow(
                                    active: hasText,
                                    child: IconButton.filled(
                                      key: const Key(
                                        'conversation-send-button',
                                      ),
                                      onPressed: onPressed,
                                      style: IconButton.styleFrom(
                                        backgroundColor: hasText
                                            ? zen.accent
                                            : zen.surfaceMuted,
                                        foregroundColor: hasText
                                            ? zen.onAccent
                                            : zen.textSecondary,
                                        disabledBackgroundColor:
                                            zen.surfaceMuted,
                                        disabledForegroundColor: zen.textMuted
                                            .withValues(alpha: 0.6),
                                        padding: EdgeInsets.zero,
                                        shape: const CircleBorder(),
                                      ),
                                      icon: _isRecordingBusy
                                          ? SizedBox(
                                              width: 16,
                                              height: 16,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color: zen.textSecondary,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.send_rounded,
                                              size: 20,
                                            ),
                                    ),
                                  ),
                          ),
                        );
                      },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickEmoji() async {
    final String? emoji = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => const _EmojiPickerSheet(),
    );
    if (emoji == null) {
      return;
    }
    final TextEditingValue value = _composerController.value;
    final int offset = value.selection.isValid
        ? value.selection.baseOffset
        : value.text.length;
    final String next =
        value.text.substring(0, offset) + emoji + value.text.substring(offset);
    _composerController.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: offset + emoji.length),
    );
  }

  Future<void> _pickAndSendGif() async {
    final GifCatalogEntry? entry = await showDialog<GifCatalogEntry>(
      context: context,
      builder: (BuildContext context) {
        return _ConversationGifPickerDialog(
          catalog: ref.read(gifCatalogProvider),
        );
      },
    );
    if (entry == null || !mounted) {
      return;
    }
    // The sender fetches the GIF and sends its bytes as an ordinary image
    // attachment: the recipient never contacts the GIF host, and the bytes
    // pass through media_guard on arrival like any other image.
    final Uint8List bytes;
    try {
      bytes = await ref.read(gifDownloaderProvider).download(entry.sendUrl);
    } on Object {
      if (mounted) {
        _showComposerSnackBar(t('Nie udało się pobrać GIF-a.'));
      }
      return;
    }
    if (!mounted) {
      return;
    }
    try {
      await _socialHubController.sendLocalAttachment(
        peerAddress: widget.peerAddress,
        displayName: _conversationDisplayName,
        bytes: bytes,
        fileName: 'gif.gif',
        mimeType: 'image/gif',
        type: ChatMessageType.image,
      );
    } on FormatException catch (error) {
      _showComposerSnackBar(error.message);
    }
  }

  Future<void> _capturePhotoOrVideo() async {
    final ZenColors zen = ZenColors.of(context);
    final ImagePicker picker = ImagePicker();

    final _CaptureOption? option = await showModalBottomSheet<_CaptureOption>(
      context: context,
      backgroundColor: zen.surfaceRaised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: Icon(Icons.photo_camera_rounded, color: zen.accent),
                  title: Text(t('Zrób zdjęcie (Aparat)')),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_CaptureOption.photo),
                ),
                ListTile(
                  leading: Icon(Icons.videocam_rounded, color: zenTone(zen, 2)),
                  title: Text(t('Nagraj film (Wideo)')),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_CaptureOption.video),
                ),
                ListTile(
                  leading: Icon(
                    Icons.photo_library_rounded,
                    color: zenTone(zen, 4),
                  ),
                  title: Text(t('Wybierz z galerii')),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_CaptureOption.gallery),
                ),
                ListTile(
                  key: const Key('capture-audio-file'),
                  leading: Icon(
                    Icons.audio_file_rounded,
                    color: zenTone(zen, 1),
                  ),
                  title: Text(t('Nagranie audio z pliku')),
                  onTap: () =>
                      Navigator.of(sheetContext).pop(_CaptureOption.audio),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (option == null || !mounted) return;
    if (option == _CaptureOption.audio) {
      await _pickAndSendAudioFile();
      return;
    }

    try {
      final XFile? file = switch (option) {
        _CaptureOption.photo => await picker.pickImage(
          source: ImageSource.camera,
        ),
        _CaptureOption.video => await picker.pickVideo(
          source: ImageSource.camera,
        ),
        _CaptureOption.gallery || _CaptureOption.audio =>
          await picker.pickImage(source: ImageSource.gallery),
      };

      if (file == null || !mounted) return;

      Uint8List bytes = await file.readAsBytes();
      final bool fromCamera =
          option == _CaptureOption.photo || option == _CaptureOption.video;
      if (fromCamera && (Platform.isAndroid || Platform.isIOS)) {
        // The camera left a plain copy in the app's cache: the bytes are
        // in memory now, and the message keeps them encrypted.
        try {
          await File(file.path).delete();
        } on FileSystemException {
          // Removed with the cache later.
        }
      }
      String fileName = file.name.trim().isNotEmpty
          ? file.name.trim()
          : (option == _CaptureOption.video
                ? 'video-${DateTime.now().millisecondsSinceEpoch}.mp4'
                : 'photo-${DateTime.now().millisecondsSinceEpoch}.jpg');
      String? sendPath = fromCamera ? null : file.path;
      if (option != _CaptureOption.video) {
        // A photo goes out as a fresh JPEG: no location or camera data in
        // it, and small enough to arrive quickly.
        try {
          bytes = await sanitizePhoto(bytes);
          final int dot = fileName.lastIndexOf('.');
          fileName = '${dot > 0 ? fileName.substring(0, dot) : fileName}.jpg';
          sendPath = null;
        } on ArgumentError {
          // Not a picture this can read: it goes as it is.
        }
        if (!mounted) return;
      }

      final String mimeType =
          lookupMimeType(
            fileName,
            headerBytes: bytes.length > 16
                ? Uint8List.sublistView(bytes, 0, 16)
                : bytes,
          ) ??
          (option == _CaptureOption.video ? 'video/mp4' : 'image/jpeg');

      final String displayName =
          ref
              .read(socialHubControllerProvider)
              .friendByAddress(widget.peerAddress)
              ?.displayLabel ??
          widget.title;

      await _socialHubController.sendLocalAttachment(
        peerAddress: widget.peerAddress,
        displayName: displayName,
        bytes: bytes,
        attachmentPath: sendPath,
        fileName: fileName,
        mimeType: mimeType,
      );
    } catch (error) {
      if (!mounted) return;
      _showComposerSnackBar(
        t('Nie udało się zarejestrować pliku: {error}', {'error': error}),
      );
    }
  }

  /// A recording from a file (a song, a recorded talk): it goes as a voice
  /// message, played in the chat.
  Future<void> _pickAndSendAudioFile() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: false,
    );
    final PlatformFile? picked = result == null || result.files.isEmpty
        ? null
        : result.files.first;
    final String? path = picked?.path;
    if (picked == null || path == null || path.isEmpty || !mounted) {
      return;
    }
    if (picked.size > kMaxAudioFileBytes) {
      _showComposerSnackBar(
        t('Nagranie jest za duże (najwyżej {size} MB).', {
          'size': kMaxAudioFileBytes ~/ (1024 * 1024),
        }),
      );
      return;
    }
    final Uint8List? head = await _readAttachmentHeader(path);
    if (head == null || sniffMediaKind(head) == MediaKind.file) {
      _showComposerSnackBar(t('To nie jest nagranie audio.'));
      return;
    }
    try {
      await _socialHubController.sendLocalAttachment(
        peerAddress: widget.peerAddress,
        displayName: _conversationDisplayName,
        attachmentPath: path,
        fileName: picked.name,
        mimeType: sniffMimeType(head) ?? lookupMimeType(picked.name),
        type: ChatMessageType.voice,
      );
    } on FormatException catch (error) {
      _showComposerSnackBar(error.message);
    }
  }

  Future<void> _startVoiceRecording() async {
    if (_isRecordingVoice || _isRecordingBusy) {
      return;
    }
    _updateUi(() {
      _isRecordingBusy = true;
    });
    final VoiceMessageRecorder recorder = ref.read(
      voiceMessageRecorderFactoryProvider,
    )();
    try {
      final bool started = await recorder.start();
      if (!started) {
        await recorder.cancel();
        if (mounted) {
          _showComposerSnackBar(t('Brak dostępu do mikrofonu.'));
        }
        return;
      }
      if (!mounted) {
        await recorder.cancel();
        return;
      }
      _voiceRecorder = recorder;
      _recordingStartedAt = DateTime.now();
      _recordingElapsed = Duration.zero;
      _recordingTicker?.cancel();
      _recordingTicker = Timer.periodic(const Duration(seconds: 1), (
        Timer timer,
      ) {
        final DateTime? startedAt = _recordingStartedAt;
        if (!mounted || !_isRecordingVoice || startedAt == null) {
          timer.cancel();
          return;
        }
        _updateUi(() {
          _recordingElapsed = DateTime.now().difference(startedAt);
        });
      });
      _updateUi(() {
        _isRecordingVoice = true;
      });
    } catch (error) {
      await recorder.cancel();
      if (mounted) {
        _showComposerSnackBar(t('Nie udało się rozpocząć nagrania.'));
      }
    } finally {
      if (mounted) {
        _updateUi(() {
          _isRecordingBusy = false;
        });
      }
    }
  }

  Future<void> _stopVoiceRecording() async {
    final VoiceMessageRecorder? recorder = _voiceRecorder;
    if (recorder == null || _isRecordingBusy) {
      return;
    }
    _voiceRecorder = null;
    _recordingTicker?.cancel();
    _recordingTicker = null;
    _updateUi(() {
      _isRecordingBusy = true;
      _isRecordingVoice = false;
      _recordingElapsed = Duration.zero;
      _recordingStartedAt = null;
    });
    try {
      final RecordedVoiceClip? clip = await recorder.stop();
      if (clip == null) {
        if (mounted) {
          _showComposerSnackBar(t('Nagranie nie zawiera danych.'));
        }
        return;
      }
      if (!mounted) {
        return;
      }
      await _socialHubController.sendLocalAttachment(
        peerAddress: widget.peerAddress,
        displayName: _conversationDisplayName,
        attachmentPath: clip.path,
        fileName: clip.fileName,
        mimeType: clip.mimeType,
        type: ChatMessageType.voice,
        durationMs: clip.durationMs,
      );
    } on FormatException catch (error) {
      if (mounted) {
        _showComposerSnackBar(error.message);
      }
    } catch (error) {
      if (mounted) {
        _showComposerSnackBar(t('Nie udało się wysłać nagrania.'));
      }
    } finally {
      if (mounted) {
        _updateUi(() {
          _isRecordingBusy = false;
        });
      }
    }
  }

  Future<void> _cancelVoiceRecording() async {
    final VoiceMessageRecorder? recorder = _voiceRecorder;
    if (recorder == null) {
      return;
    }
    _voiceRecorder = null;
    _recordingTicker?.cancel();
    _recordingTicker = null;
    _updateUi(() {
      _isRecordingVoice = false;
      _recordingElapsed = Duration.zero;
      _recordingStartedAt = null;
    });
    try {
      await recorder.cancel();
    } catch (_) {}
  }

  String get _conversationDisplayName {
    return ref
            .read(socialHubControllerProvider)
            .friendByAddress(widget.peerAddress)
            ?.displayLabel ??
        widget.title;
  }

  void _showComposerSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ComposerActionButton extends StatelessWidget {
  const _ComposerActionButton({
    required this.icon,
    this.onPressed,
    this.onLongPressStart,
    this.onLongPressEnd,
    this.onLongPressCancel,
    this.tooltip,
    this.active = false,
    this.toneIndex = 0,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final GestureLongPressStartCallback? onLongPressStart;
  final GestureLongPressEndCallback? onLongPressEnd;
  final VoidCallback? onLongPressCancel;
  final String? tooltip;
  final bool active;

  final int toneIndex;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool hasLongPress =
        onLongPressStart != null || onLongPressEnd != null;
    final bool enabled = onPressed != null || hasLongPress;
    final Color tone = zenTone(zen, toneIndex);
    final Widget button = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: GestureDetector(
          onLongPressStart: onLongPressStart,
          onLongPressEnd: onLongPressEnd,
          onLongPressCancel: onLongPressCancel,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? zen.warning
                    : enabled
                    ? tone.withValues(alpha: 0.12)
                    : Colors.transparent,
              ),
              child: Icon(
                icon,
                size: 20,
                color: !enabled
                    ? zen.textMuted.withValues(alpha: 0.5)
                    : active
                    ? ZenColors.foregroundFor(zen.warning)
                    : tone,
              ),
            ),
          ),
        ),
      ),
    );
    if (hasLongPress || tooltip == null) {
      return button;
    }
    return Tooltip(message: tooltip!, child: button);
  }
}

/// Lightweight built-in emoji picker with real-time search and keywords.
class _EmojiPickerSheet extends StatefulWidget {
  const _EmojiPickerSheet();

  @override
  State<_EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends State<_EmojiPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  static const List<({String emoji, List<String> tags})>
  _catalog = <({String emoji, List<String> tags})>[
    (
      emoji: '😀',
      tags: <String>['usmiech', 'smile', 'happy', 'wesoly', 'buzka'],
    ),
    (
      emoji: '😄',
      tags: <String>['usmiech', 'smile', 'joy', 'radosc', 'szczescie'],
    ),
    (
      emoji: '😂',
      tags: <String>['smiech', 'laugh', 'lol', 'lzy', 'haha', 'rofl'],
    ),
    (emoji: '🤣', tags: <String>['smiech', 'laugh', 'rofl', 'haha', 'turlac']),
    (
      emoji: '😊',
      tags: <String>['rumieniec', 'smile', 'blush', 'mily', 'cieply'],
    ),
    (
      emoji: '😍',
      tags: <String>['milosc', 'love', 'serca', 'zakochany', 'hearts'],
    ),
    (emoji: '😘', tags: <String>['calus', 'kiss', 'buziak', 'love']),
    (emoji: '😎', tags: <String>['okulary', 'cool', 'sunglasses', 'szef']),
    (emoji: '🤔', tags: <String>['mysli', 'think', 'zastanawia', 'pytanie']),
    (emoji: '😅', tags: <String>['pot', 'sweat', 'ulga', 'nervous']),
    (emoji: '😉', tags: <String>['oczko', 'wink', 'zart']),
    (emoji: '🙃', tags: <String>['odwrocony', 'upside', 'ironia', 'sarkazm']),
    (
      emoji: '😴',
      tags: <String>['sen', 'sleep', 'dobranoc', 'zmeczony', 'zzz'],
    ),
    (emoji: '😭', tags: <String>['placz', 'cry', 'smutek', 'sad', 'rozpacz']),
    (
      emoji: '😡',
      tags: <String>['zlosc', 'angry', 'wsciekly', 'gniew', 'rage'],
    ),
    (
      emoji: '🥳',
      tags: <String>['impreza', 'party', 'urodziny', 'swieto', 'celeb'],
    ),
    (
      emoji: '🤝',
      tags: <String>['zgoda', 'handshake', 'umowa', 'partner', 'uscisk'],
    ),
    (
      emoji: '👍',
      tags: <String>['kciuk', 'like', 'super', 'dobrze', 'yes', 'tak', 'ok'],
    ),
    (emoji: '👎', tags: <String>['dislike', 'nie', 'zle', 'slabo', 'no']),
    (emoji: '👏', tags: <String>['brawa', 'clap', 'applause', 'gratulacje']),
    (
      emoji: '🙏',
      tags: <String>['prosze', 'pray', 'dziekuje', 'thanks', 'modlitwa'],
    ),
    (emoji: '💪', tags: <String>['biceps', 'muscle', 'sila', 'moc', 'strong']),
    (emoji: '👋', tags: <String>['czesc', 'wave', 'hej', 'pa', 'hello', 'bye']),
    (emoji: '✌️', tags: <String>['pokoj', 'peace', 'victory', 'zwyciestwo']),
    (emoji: '❤️', tags: <String>['serce', 'heart', 'love', 'milosc', 'red']),
    (
      emoji: '💔',
      tags: <String>['zlamane serce', 'broken', 'heartbreak', 'smutek'],
    ),
    (emoji: '🔥', tags: <String>['ogien', 'fire', 'hot', 'petarda', 'lit']),
    (
      emoji: '✨',
      tags: <String>['magia', 'sparkles', 'gwiazdki', 'blysly', 'shine'],
    ),
    (
      emoji: '🎉',
      tags: <String>['konfetti', 'party', 'tada', 'sukces', 'brawo'],
    ),
    (
      emoji: '⚡',
      tags: <String>['blyskawica', 'lightning', 'prad', 'volt', 'energy'],
    ),
    (emoji: '🌙', tags: <String>['ksiezyc', 'moon', 'noc', 'night']),
    (emoji: '☀️', tags: <String>['slonce', 'sun', 'dzien', 'cieplo', 'lato']),
    (emoji: '🍕', tags: <String>['pizza', 'jedzenie', 'food']),
    (emoji: '☕', tags: <String>['kawa', 'coffee', 'herbata', 'tea', 'napoj']),
    (emoji: '🍺', tags: <String>['piwo', 'beer', 'alkohol', 'toast']),
    (emoji: '🎧', tags: <String>['sluchawki', 'music', 'muzyka', 'headphones']),
    (emoji: '🐱', tags: <String>['kot', 'cat', 'zwierze', 'kotek']),
    (emoji: '🐶', tags: <String>['pies', 'dog', 'piesek', 'szczenie']),
    (
      emoji: '🚀',
      tags: <String>['rakieta', 'rocket', 'start', 'kosmos', 'fast'],
    ),
    (emoji: '💡', tags: <String>['zarowka', 'idea', 'pomysl', 'lightbulb']),
    (
      emoji: '✅',
      tags: <String>['ptaszek', 'check', 'sukces', 'poprawne', 'done'],
    ),
    (emoji: '❌', tags: <String>['krzyzyk', 'cross', 'blad', 'zakaz', 'no']),
    (emoji: '❓', tags: <String>['pytanie', 'question', 'znak zapytania']),
    (emoji: '❗', tags: <String>['wykrzyknik', 'exclamation', 'uwaga']),
    (emoji: '💯', tags: <String>['sto', 'hundred', 'perfect', '100']),
    (emoji: '👀', tags: <String>['oczy', 'eyes', 'patrze', 'look']),
    (emoji: '🤷', tags: <String>['wzruszenie', 'shrug', 'niewiem', 'trudno']),
    (emoji: '🫡', tags: <String>['salut', 'salute', 'szacun', 'rozkaz']),
  ];

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<({String emoji, List<String> tags})> filtered = _query.isEmpty
        ? _catalog
        : _catalog.where((({String emoji, List<String> tags}) item) {
            final String q = _query.toLowerCase().trim();
            return item.emoji.contains(q) ||
                item.tags.any((String tag) => tag.toLowerCase().contains(q));
          }).toList();

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: TextField(
              key: const Key('emoji-search-field'),
              controller: _searchController,
              onChanged: (String text) {
                setState(() {
                  _query = text;
                });
              },
              decoration: InputDecoration(
                hintText: t('Szukaj emotikony...'),
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _query = '';
                          });
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                filled: true,
                fillColor: zen.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: zen.outlineSoft),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: zen.outlineSoft),
                ),
              ),
            ),
          ),
          SizedBox(
            height: 220,
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      t('Brak emotikonów dla "{query}"', {'query': _query}),
                      style: TextStyle(color: zen.textMuted, fontSize: 13),
                    ),
                  )
                : GridView.builder(
                    key: const Key('emoji-picker-grid'),
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 8,
                          crossAxisSpacing: 4,
                          mainAxisSpacing: 4,
                        ),
                    itemCount: filtered.length,
                    itemBuilder: (BuildContext context, int index) {
                      final item = filtered[index];
                      return InkWell(
                        key: Key('emoji-$index'),
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.of(context).pop(item.emoji),
                        child: Center(
                          child: Text(
                            item.emoji,
                            style: const TextStyle(fontSize: 22),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _RecordingComposerStatus extends StatelessWidget {
  const _RecordingComposerStatus({required this.elapsed, super.key});

  final Duration elapsed;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 9, 8, 9),
      child: Row(
        children: <Widget>[
          ZenPulsingDot(
            color: zen.warning,
            active: true,
            dimension: 14,
            dotSize: 8,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t('Nagrywanie wiadomości głosowej'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  t('{time} • naciśnij stop, aby wysłać', {
                    'time': _formatMediaDuration(elapsed.inMilliseconds),
                  }),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: zen.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationGifPickerDialog extends StatefulWidget {
  const _ConversationGifPickerDialog({required this.catalog});

  final GifCatalog catalog;

  @override
  State<_ConversationGifPickerDialog> createState() =>
      _ConversationGifPickerDialogState();
}

class _ConversationGifPickerDialogState
    extends State<_ConversationGifPickerDialog> {
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<GifCatalogEntry> _entries = const <GifCatalogEntry>[];
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadEntries());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadEntries([String query = '']) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<GifCatalogEntry> entries = query.trim().isEmpty
          ? await widget.catalog.loadFeatured()
          : await widget.catalog.search(query);
      if (!mounted) {
        return;
      }
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Dialog.fullscreen(
      backgroundColor: zen.background,
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(
                children: <Widget>[
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  Expanded(
                    child: Text(
                      t('Wybierz GIF'),
                      style: zen.display(
                        color: zen.textPrimary,
                        size: 20,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ZenPill(text: 'KLIPY', tone: zenTone(zen, 1)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: TextField(
                key: const Key('conversation-gif-search-field'),
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: t('Szukaj GIF-ów'),
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
                onChanged: (String value) {
                  _searchDebounce?.cancel();
                  _searchDebounce = Timer(
                    const Duration(milliseconds: 350),
                    () => unawaited(_loadEntries(value)),
                  );
                },
              ),
            ),
            // The search text and this device's IP address go to a third
            // party (api.klipy.com): say so.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  t('Wyszukiwanie GIF-ów łączy się z klipy.com.'),
                  key: const Key('conversation-gif-klipy-note'),
                  style: TextStyle(color: zen.textMuted, fontSize: 12),
                ),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 160),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.cloud_off_rounded,
                                color: zen.textMuted,
                                size: 44,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                t('Nie udało się pobrać GIF-ów.'),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              FilledButton.tonal(
                                onPressed: () => unawaited(
                                  _loadEntries(_searchController.text),
                                ),
                                child: Text(t('Spróbuj ponownie')),
                              ),
                            ],
                          ),
                        ),
                      )
                    : _entries.isEmpty
                    ? Center(
                        child: ZenEmpty(
                          icon: Icons.gif_box_outlined,
                          title: t('Brak wyników dla tego zapytania.'),
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 2,
                              mainAxisSpacing: 12,
                              crossAxisSpacing: 12,
                              childAspectRatio: 1,
                            ),
                        itemCount: _entries.length,
                        itemBuilder: (BuildContext context, int index) {
                          final GifCatalogEntry entry = _entries[index];
                          return InkWell(
                            key: Key('conversation-gif-tile-$index'),
                            borderRadius: BorderRadius.circular(20),
                            onTap: () => Navigator.of(context).pop(entry),
                            child: Ink(
                              decoration: BoxDecoration(
                                color: zen.surfaceRaised,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: zen.outlineSoft),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(20),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: <Widget>[
                                    _GifPreview(
                                      url: entry.previewUrl,
                                      errorBuilder:
                                          (
                                            BuildContext context,
                                            Object error,
                                            StackTrace? stackTrace,
                                          ) {
                                            return Center(
                                              child: Icon(
                                                Icons.broken_image_outlined,
                                                color: zen.textMuted,
                                                size: 40,
                                              ),
                                            );
                                          },
                                    ),
                                    Align(
                                      alignment: Alignment.bottomLeft,
                                      child: DecoratedBox(
                                        decoration: const BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: <Color>[
                                              Color(0xD0000000),
                                              Color(0x00000000),
                                            ],
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(12),
                                          child: Text(
                                            entry.label ?? 'GIF',
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VoiceAttachmentContent extends StatefulWidget {
  const _VoiceAttachmentContent({required this.message});

  final ChatMessage message;

  @override
  State<_VoiceAttachmentContent> createState() =>
      _VoiceAttachmentContentState();
}

class _VoiceAttachmentContentState extends State<_VoiceAttachmentContent> {
  VideoPlayerController? _player;
  _ResolvedAttachmentPath? _resolvedAttachmentPath;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isLoading = false;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    final int? durationMs = widget.message.durationMs;
    if (durationMs != null && durationMs > 0) {
      _duration = Duration(milliseconds: durationMs);
    }
  }

  @override
  void didUpdateWidget(covariant _VoiceAttachmentContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.id != widget.message.id ||
        oldWidget.message.attachmentPath != widget.message.attachmentPath ||
        oldWidget.message.attachmentBytes != widget.message.attachmentBytes) {
      unawaited(_disposePlayer());
      _resolvedAttachmentPath = null;
      _position = Duration.zero;
      final int? durationMs = widget.message.durationMs;
      _duration = durationMs == null || durationMs <= 0
          ? Duration.zero
          : Duration(milliseconds: durationMs);
    }
  }

  @override
  void dispose() {
    unawaited(_disposePlayer());
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    if (!widget.message.hasAttachment) {
      return;
    }
    final VideoPlayerController player;
    try {
      player = await _ensurePlayer();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Plik audio jest niedostępny.'))),
        );
      }
      return;
    }
    if (player.value.isPlaying) {
      await player.pause();
      return;
    }
    final Duration duration = player.value.duration;
    final Duration position = player.value.position;
    if (duration > Duration.zero && position >= duration) {
      await player.seekTo(Duration.zero);
    }
    await player.play();
  }

  void _handlePlayerUpdate() {
    final VideoPlayerController? player = _player;
    if (!mounted || player == null) {
      return;
    }
    final VideoPlayerValue value = player.value;
    setState(() {
      _isPlaying = value.isPlaying;
      _position = value.position;
      if (value.duration > Duration.zero) {
        _duration = value.duration;
      }
    });
  }

  Future<VideoPlayerController> _ensurePlayer() async {
    final VideoPlayerController? existing = _player;
    if (existing != null) {
      return existing;
    }
    setState(() {
      _isLoading = true;
    });
    final _ResolvedAttachmentPath? attachmentPath;
    try {
      attachmentPath = await _resolveReadableAttachmentPath(widget.message);
    } catch (_) {
      // An encrypted file that does not open (locked, damaged).
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      rethrow;
    }
    if (!mounted) {
      if (attachmentPath != null && attachmentPath.isTemporary) {
        await _deleteTemporaryCopy(attachmentPath.path);
      }
      throw StateError('Voice attachment screen was closed.');
    }
    if (attachmentPath == null) {
      setState(() {
        _isLoading = false;
      });
      throw StateError('Voice attachment is unavailable.');
    }

    final VideoPlayerController player = VideoPlayerController.file(
      File(attachmentPath.path),
    );
    player.addListener(_handlePlayerUpdate);
    try {
      await player.initialize();
    } catch (error) {
      player.removeListener(_handlePlayerUpdate);
      await player.dispose();
      rethrow;
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
    if (!mounted) {
      player.removeListener(_handlePlayerUpdate);
      await player.dispose();
      throw StateError('Voice attachment screen was closed.');
    }
    _player = player;
    _resolvedAttachmentPath = attachmentPath;
    return player;
  }

  Future<void> _disposePlayer() async {
    final VideoPlayerController? player = _player;
    _player = null;
    _isPlaying = false;
    if (player != null) {
      player.removeListener(_handlePlayerUpdate);
      await player.dispose();
    }
    final _ResolvedAttachmentPath? attachmentPath = _resolvedAttachmentPath;
    _resolvedAttachmentPath = null;
    if (attachmentPath != null && attachmentPath.isTemporary) {
      await _deleteTemporaryCopy(attachmentPath.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool outgoing = widget.message.isOutgoing;
    final int totalDurationMs = _duration.inMilliseconds > 0
        ? _duration.inMilliseconds
        : (widget.message.durationMs ?? 0);
    final String title = widget.message.fileName ?? t('Wiadomość głosowa');
    final String subtitle = totalDurationMs > 0 && _position > Duration.zero
        ? '${_formatMediaDuration(_position.inMilliseconds)} / '
              '${_formatMediaDuration(totalDurationMs)}'
              '${widget.message.attachmentSizeBytes == null ? '' : ' • ${formatAttachmentSize(widget.message.attachmentSizeBytes!)}'}'
        : _buildMediaSubtitle(
            sizeBytes: widget.message.attachmentSizeBytes,
            durationMs: widget.message.durationMs,
          );
    final double progress = totalDurationMs <= 0
        ? 0.0
        : (_position.inMilliseconds / totalDurationMs).clamp(0.0, 1.0);

    final Color accentColor = outgoing ? zen.accent : zen.accentSecondary;

    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            IconButton.filledTonal(
              iconSize: 22,
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
              style: IconButton.styleFrom(
                backgroundColor: accentColor.withValues(alpha: 0.18),
                foregroundColor: accentColor,
              ),
              onPressed: widget.message.hasAttachment && !_isLoading
                  ? _togglePlayback
                  : null,
              icon: _isLoading
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: accentColor,
                      ),
                    )
                  : Icon(
                      _isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 5,
                      value: progress > 0 ? progress : 0.0,
                      backgroundColor: zen.surfaceMuted,
                      valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: zen.textMuted,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (widget.message.hasAttachment)
                        InkWell(
                          onTap: () =>
                              _saveAttachmentCopy(context, widget.message),
                          child: Icon(
                            Icons.download_rounded,
                            size: 14,
                            color: zen.textMuted,
                          ),
                        )
                      else
                        Text(
                          t('Transfer w toku'),
                          style: TextStyle(color: zen.textMuted, fontSize: 11),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoAttachmentContent extends StatelessWidget {
  const _VideoAttachmentContent({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    return _MediaAttachmentPanel(
      icon: Icons.videocam_rounded,
      accent: ZenColors.of(context).accentTertiary,
      title: message.fileName ?? t('Wideo'),
      subtitle: _buildMediaSubtitle(
        sizeBytes: message.attachmentSizeBytes,
        durationMs: message.durationMs,
      ),
      actions: <Widget>[
        FilledButton.tonalIcon(
          onPressed: message.hasAttachment
              ? () {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) {
                        return _VideoAttachmentPreviewScreen(message: message);
                      },
                    ),
                  );
                }
              : null,
          icon: const Icon(Icons.play_arrow_rounded),
          label: Text(
            message.hasAttachment ? t('Otwórz podglad') : t('Transfer w toku'),
          ),
        ),
        if (message.hasAttachment)
          TextButton.icon(
            onPressed: () => _saveAttachmentCopy(context, message),
            icon: const Icon(Icons.download_rounded),
            label: Text(t('Zapisz kopie')),
          ),
      ],
    );
  }
}

class _MediaAttachmentPanel extends StatelessWidget {
  const _MediaAttachmentPanel({
    required this.icon,
    required this.accent,
    required this.title,
    required this.subtitle,
    required this.actions,
  });

  final IconData icon;
  final Color accent;
  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[accent.withAlpha(70), accent.withAlpha(20)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withAlpha(90)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Icon(icon, color: accent),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(color: zen.textMuted, fontSize: 12),
              ),
              if (actions.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: actions),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _VideoAttachmentPreviewScreen extends StatefulWidget {
  const _VideoAttachmentPreviewScreen({required this.message});

  final ChatMessage message;

  @override
  State<_VideoAttachmentPreviewScreen> createState() =>
      _VideoAttachmentPreviewScreenState();
}

class _VideoAttachmentPreviewScreenState
    extends State<_VideoAttachmentPreviewScreen> {
  VideoPlayerController? _controller;
  _ResolvedAttachmentPath? _resolvedAttachmentPath;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isLoading = true;
  bool _isPlaying = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    unawaited(_disposePlayer());
    super.dispose();
  }

  Future<void> _initialize() async {
    _ResolvedAttachmentPath? attachmentPath;
    try {
      attachmentPath = await _resolveReadableAttachmentPath(widget.message);
    } catch (_) {
      // An encrypted file that does not open (locked, damaged).
      attachmentPath = null;
    }
    if (!mounted || attachmentPath == null) {
      if (mounted) {
        setState(() {
          _error = StateError('Video attachment is unavailable.');
          _isLoading = false;
        });
      }
      return;
    }

    final VideoPlayerController controller = VideoPlayerController.file(
      File(attachmentPath.path),
    );
    controller.addListener(_handlePlayerUpdate);
    try {
      await controller.initialize();
      if (!mounted) {
        controller.removeListener(_handlePlayerUpdate);
        await controller.dispose();
        if (attachmentPath.isTemporary) {
          await _deleteTemporaryCopy(attachmentPath.path);
        }
        return;
      }
      _controller = controller;
      _resolvedAttachmentPath = attachmentPath;
      await controller.play();
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
      });
    } catch (error) {
      if (!identical(_controller, controller)) {
        controller.removeListener(_handlePlayerUpdate);
        await controller.dispose();
      }
      if (attachmentPath.isTemporary && _resolvedAttachmentPath == null) {
        await _deleteTemporaryCopy(attachmentPath.path);
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error;
        _isLoading = false;
      });
    }
  }

  void _handlePlayerUpdate() {
    final VideoPlayerController? controller = _controller;
    if (!mounted || controller == null) {
      return;
    }
    final VideoPlayerValue value = controller.value;
    setState(() {
      _isPlaying = value.isPlaying;
      _position = value.position;
      if (value.duration > Duration.zero) {
        _duration = value.duration;
      }
    });
  }

  Future<void> _togglePlayback() async {
    final VideoPlayerController? player = _controller;
    if (player == null) {
      return;
    }
    if (player.value.isPlaying) {
      await player.pause();
      return;
    }
    final Duration duration = player.value.duration;
    final Duration position = player.value.position;
    if (duration > Duration.zero && position >= duration) {
      await player.seekTo(Duration.zero);
    }
    await player.play();
  }

  Future<void> _disposePlayer() async {
    final VideoPlayerController? controller = _controller;
    _controller = null;
    if (controller != null) {
      controller.removeListener(_handlePlayerUpdate);
      await controller.dispose();
    }
    final _ResolvedAttachmentPath? attachmentPath = _resolvedAttachmentPath;
    _resolvedAttachmentPath = null;
    if (attachmentPath != null && attachmentPath.isTemporary) {
      await _deleteTemporaryCopy(attachmentPath.path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final double? progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.message.fileName ?? t('Wideo')),
        actions: <Widget>[
          IconButton(
            onPressed: widget.message.hasAttachment
                ? () => _saveAttachmentCopy(context, widget.message)
                : null,
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: zen.outline),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null || _controller == null
                    ? Center(
                        child: Text(
                          t('Nie udało się uruchomić podgladu wideo.'),
                          style: const TextStyle(color: Colors.white70),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : Column(
                        children: <Widget>[
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: ColoredBox(
                                color: Colors.black,
                                child: Center(
                                  child: AspectRatio(
                                    aspectRatio:
                                        _controller!.value.aspectRatio <= 0
                                        ? 16 / 9
                                        : _controller!.value.aspectRatio,
                                    child: VideoPlayer(_controller!),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (progress != null)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(999),
                              child: LinearProgressIndicator(
                                minHeight: 6,
                                value: progress,
                                backgroundColor: Colors.white10,
                                valueColor: const AlwaysStoppedAnimation<Color>(
                                  Colors.white70,
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          Row(
                            children: <Widget>[
                              FilledButton.tonalIcon(
                                onPressed: _togglePlayback,
                                icon: Icon(
                                  _isPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                ),
                                label: Text(
                                  _isPlaying ? t('Pauza') : t('Odtwarzaj'),
                                ),
                              ),
                              const Spacer(),
                              Text(
                                _duration.inMilliseconds > 0
                                    ? '${_formatMediaDuration(_position.inMilliseconds)} / '
                                          '${_formatMediaDuration(_duration.inMilliseconds)}'
                                    : _buildMediaSubtitle(
                                        sizeBytes:
                                            widget.message.attachmentSizeBytes,
                                        durationMs: widget.message.durationMs,
                                      ),
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _ResolvedAttachmentPath {
  const _ResolvedAttachmentPath({
    required this.path,
    required this.isTemporary,
  });

  final String path;
  final bool isTemporary;
}

String _buildMediaSubtitle({int? sizeBytes, int? durationMs}) {
  final List<String> parts = <String>[];
  if (durationMs != null && durationMs > 0) {
    parts.add(_formatMediaDuration(durationMs));
  }
  if (sizeBytes != null && sizeBytes > 0) {
    parts.add(formatAttachmentSize(sizeBytes));
  }
  return parts.isEmpty ? t('Nieznane metadane') : parts.join(' • ');
}

String _formatMediaDuration(int durationMs) {
  final Duration duration = Duration(milliseconds: durationMs);
  final String minutes = duration.inMinutes.toString().padLeft(2, '0');
  final String seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

/// A path a player can open: the user's own file as it is, or a short-lived
/// plain copy (random name, temporary media folder) of an encrypted file or
/// of bytes kept in the message. The players delete the copy when done;
/// leftovers go at the next start.
Future<_ResolvedAttachmentPath?> _resolveReadableAttachmentPath(
  ChatMessage message,
) async {
  final String extension = _attachmentExtension(message);
  final String? sourcePath = message.attachmentPath?.trim();
  if (sourcePath != null &&
      sourcePath.isNotEmpty &&
      await File(sourcePath).exists()) {
    if (!isMediaVaultPath(sourcePath)) {
      return _ResolvedAttachmentPath(path: sourcePath, isTemporary: false);
    }
    final MediaVault? vault = MediaVault.current;
    if (vault == null) {
      return null;
    }
    final File copy = await vault.openTemporary(
      sourcePath,
      extension: extension,
    );
    return _ResolvedAttachmentPath(path: copy.path, isTemporary: true);
  }
  final Uint8List? bytes = message.attachmentBytes;
  if (bytes == null || bytes.isEmpty) {
    return null;
  }
  final File copy = await writeTemporaryMedia(bytes, extension: extension);
  return _ResolvedAttachmentPath(path: copy.path, isTemporary: true);
}

/// Deletes a plain copy a player used. One still held open (Windows) is
/// left for the cleanup at the next start.
Future<void> _deleteTemporaryCopy(String path) async {
  try {
    final File file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  } on FileSystemException {
    // Removed with the temporary media folder at the next start.
  }
}

String _attachmentExtension(ChatMessage message) {
  final String? fileName = message.fileName?.trim();
  if (fileName != null) {
    final int dotIndex = fileName.lastIndexOf('.');
    if (dotIndex > 0 && dotIndex < fileName.length - 1) {
      return fileName.substring(dotIndex);
    }
  }
  return switch (message.mimeType?.toLowerCase()) {
    'audio/mp4' => '.m4a',
    'audio/mpeg' => '.mp3',
    'video/mp4' => '.mp4',
    'video/quicktime' => '.mov',
    _ => '.bin',
  };
}

Future<void> _saveAttachmentCopy(
  BuildContext context,
  ChatMessage message,
) async {
  final Uint8List? bytes = message.attachmentBytes;
  final String? sourcePath = message.attachmentPath;
  if ((bytes == null || bytes.isEmpty) &&
      (sourcePath == null || sourcePath.isEmpty)) {
    return;
  }
  // An encrypted file is opened in memory: the copy (meant to leave Zen)
  // is the plain content.
  Uint8List? plain = bytes != null && bytes.isNotEmpty ? bytes : null;
  if (plain == null && isMediaVaultPath(sourcePath)) {
    try {
      plain = await readMediaFile(sourcePath!);
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Nie udało się odczytać załącznika.'))),
        );
      }
      return;
    }
  }
  // The name comes from the other side: never let it leave the folder.
  final String suggestedName =
      safeFileName(message.fileName) ?? 'zalacznik-${message.id}';
  // Zen never opens files; one that could start a program gets a warning
  // before it lands where a double-click would run it. For every direction:
  // a message stored as "outgoing" may be a copy from another device of the
  // account (device_chat_sync), which a stolen device could have sent, and
  // the stored message does not say which it is.
  Uint8List head = plain ?? Uint8List(0);
  if (head.isEmpty && sourcePath != null) {
    try {
      final RandomAccessFile handle = await File(sourcePath).open();
      try {
        head = await handle.read(16);
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      head = Uint8List(0);
    }
  }
  if (isRiskyFile(head, suggestedName)) {
    if (!context.mounted) {
      return;
    }
    final bool? go = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        key: const Key('attachment-risky-warning'),
        icon: const Icon(Icons.gpp_maybe_rounded),
        title: Text(t('Ten plik może uruchomić program')),
        content: Text(
          t(
            '„{name}” to program albo coś, co go uruchamia. '
            'Tak najczęściej przychodzą wirusy — nawet od znajomych, '
            'którym ktoś przejął telefon.\n\n'
            'Zapisz go tylko, jeśli wiesz, co to jest, i ufasz nadawcy.',
            {'name': suggestedName},
          ),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('attachment-risky-save'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Zapisz mimo to')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Nie zapisuj')),
          ),
        ],
      ),
    );
    if (go != true) {
      return;
    }
  }
  String? targetPath;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    targetPath = await FilePicker.platform.saveFile(
      dialogTitle: t('Zapisz zalacznik'),
      fileName: suggestedName,
    );
  } else if (Platform.isAndroid) {
    final Directory? directory = await getExternalStorageDirectory();
    if (directory != null) {
      final Directory targetDirectory = Directory(
        '${directory.path}${Platform.pathSeparator}Zen',
      );
      await targetDirectory.create(recursive: true);
      targetPath =
          '${targetDirectory.path}${Platform.pathSeparator}$suggestedName';
    }
  } else {
    final Directory directory = await getApplicationDocumentsDirectory();
    final Directory targetDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}Zen',
    );
    await targetDirectory.create(recursive: true);
    targetPath =
        '${targetDirectory.path}${Platform.pathSeparator}$suggestedName';
  }
  if (targetPath == null || targetPath.isEmpty) {
    return;
  }
  final Uint8List? content = plain;
  if (content != null) {
    await File(targetPath).writeAsBytes(content, flush: true);
  } else {
    await File(sourcePath!).copy(targetPath);
  }
  // From someone else (or from another device of the account, which the
  // stored message cannot tell apart from this one): Windows should treat
  // the copy like any download (Mark of the Web). Best effort, Windows only.
  await markFileFromInternet(targetPath);
  // A plain file outside Zen on purpose: the panic password finds it.
  await rememberExportedFile(targetPath);
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(t('Zapisano kopie do:\n{path}', {'path': targetPath})),
    ),
  );
}

/// A catalog GIF preview in the picker: downloaded by this device (the
/// sender's, which already talks to the GIF host to search) and played from
/// memory.
class _GifPreview extends ConsumerStatefulWidget {
  const _GifPreview({required this.url, required this.errorBuilder});

  final String url;
  final ImageErrorWidgetBuilder errorBuilder;

  @override
  ConsumerState<_GifPreview> createState() => _GifPreviewState();
}

class _GifPreviewState extends ConsumerState<_GifPreview> {
  Uint8List? _bytes;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final Uint8List bytes = await ref
          .read(gifDownloaderProvider)
          .download(widget.url);
      if (mounted) {
        setState(() => _bytes = bytes);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Object? error = _error;
    if (error != null) {
      return widget.errorBuilder(context, error, null);
    }
    final Uint8List? bytes = _bytes;
    if (bytes == null) {
      return const Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return ZenAnimatedImage(bytes: bytes, errorBuilder: widget.errorBuilder);
  }
}
