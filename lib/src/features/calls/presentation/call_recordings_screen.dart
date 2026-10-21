import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/call_recordings.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/security/sensitive_access.dart';

/// "Nagrania rozmów": play, export or delete what you recorded.
class CallRecordingsScreen extends ConsumerStatefulWidget {
  const CallRecordingsScreen({super.key});

  /// Opens after the person confirms who they are.
  static Future<void> open(BuildContext context) async {
    if (!await confirmSensitiveAccess(
          context,
          reason: t('Nagrania rozmów są chronione. Potwierdź, że to Ty.'),
        ) ||
        !context.mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const CallRecordingsScreen(),
      ),
    );
  }

  @override
  ConsumerState<CallRecordingsScreen> createState() =>
      _CallRecordingsScreenState();
}

class _CallRecordingsScreenState extends ConsumerState<CallRecordingsScreen> {
  late final CallRecordingStore _store = CallRecordingStore(
    ref.read(ledgerDiskProvider),
  );
  List<CallRecording>? _items;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final List<CallRecording> items = await _store.list();
    if (mounted) {
      setState(() => _items = items);
    }
  }

  String _when(int millis) {
    return ZenFormat.dateTime(DateTime.fromMillisecondsSinceEpoch(millis));
  }

  String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).ceil()} KB';

  /// A plain copy only for the moment of playing, deleted afterwards.
  Future<void> _play(CallRecording rec) async {
    final Uint8List? data = await _store.read(rec.id);
    if (data == null || !mounted) {
      return;
    }
    // Random name in the temporary media folder (emptied at every start).
    final File file = await writeTemporaryMedia(
      data,
      extension: '.${rec.extension}',
    );
    final VideoPlayerController player = VideoPlayerController.file(file);
    try {
      await player.initialize();
      await player.play();
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialog) => AlertDialog(
          title: Text(t('Rozmowa: {name}', {'name': rec.peer})),
          content: rec.isAudioOnly
              // Sound only (recorded on a computer): nothing to look at.
              ? const SizedBox(
                  height: 120,
                  child: Center(
                    child: Icon(Icons.graphic_eq_rounded, size: 56),
                  ),
                )
              : AspectRatio(
                  aspectRatio: player.value.aspectRatio == 0
                      ? 16 / 9
                      : player.value.aspectRatio,
                  child: VideoPlayer(player),
                ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text(t('Zamknij')),
            ),
          ],
        ),
      );
    } finally {
      await player.dispose();
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  Future<void> _export(CallRecording rec) async {
    final Uint8List? data = await _store.read(rec.id);
    if (data == null) {
      return;
    }
    final String name = 'rozmowa-${rec.id}.${rec.extension}';
    String? target;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      target = await FilePicker.platform.saveFile(
        dialogTitle: t('Eksportuj nagranie'),
        fileName: name,
      );
    } else {
      final Directory? dir = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getApplicationDocumentsDirectory();
      if (dir != null) {
        final Directory zen = Directory('${dir.path}/Zen');
        await zen.create(recursive: true);
        target = '${zen.path}/$name';
      }
    }
    if (target == null) {
      return;
    }
    await File(target).writeAsBytes(data, flush: true);
    // A plain copy on purpose: the panic password deletes it too.
    await rememberExportedFile(target);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('Zapisano bez szyfrowania: {path}', {'path': target}),
          ),
        ),
      );
    }
  }

  Future<void> _delete(CallRecording rec) async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(t('Usunąć nagranie?')),
        content: Text(
          t('Rozmowa z: {name}, {date}.', {
            'name': rec.peer,
            'date': _when(rec.millis),
          }),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Usuń')),
          ),
        ],
      ),
    );
    if (sure == true) {
      await _store.delete(rec.id);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) =>
      SecureScreen(child: Builder(builder: _buildScreen));

  Widget _buildScreen(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<CallRecording>? items = _items;
    return Scaffold(
      key: const Key('call-recordings-screen'),
      appBar: AppBar(title: Text(t('Nagrania rozmów'))),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? Center(
              child: SingleChildScrollView(
                child: ZenEmpty(
                  icon: Icons.mic_none_rounded,
                  title: t('Nie masz nagrań'),
                  text: t(
                    'Nagrywanie włączysz w trakcie rozmowy; '
                    'rozmówca zawsze widzi, że nagrywasz.',
                  ),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: <Widget>[
                ZenInfo(
                  icon: Icons.lock_outline_rounded,
                  text: t(
                    'Nagrania są zaszyfrowane. Dotknij, aby odtworzyć; '
                    'eksport zapisuje kopię bez szyfrowania.',
                  ),
                ),
                const SizedBox(height: 6),
                for (final CallRecording rec in items)
                  ZenTile(
                    key: Key('recording-${rec.id}'),
                    icon: rec.isAudioOnly
                        ? Icons.graphic_eq_rounded
                        : Icons.videocam_outlined,
                    tone: rec.isAudioOnly ? zenTone(zen, 2) : zenTone(zen, 5),
                    title: rec.peer,
                    subtitle: <String>[
                      _when(rec.millis),
                      _size(rec.bytes),
                      if (rec.isAudioOnly) t('dźwięk'),
                    ].join(' · '),
                    onTap: () => unawaited(_play(rec)),
                    trailing: PopupMenuButton<String>(
                      tooltip: t('Więcej'),
                      onSelected: (String v) => unawaited(
                        v == 'export' ? _export(rec) : _delete(rec),
                      ),
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<String>>[
                            PopupMenuItem<String>(
                              value: 'export',
                              child: Text(t('Eksportuj')),
                            ),
                            PopupMenuItem<String>(
                              value: 'delete',
                              child: Text(t('Usuń')),
                            ),
                          ],
                    ),
                  ),
              ],
            ),
    );
  }
}
