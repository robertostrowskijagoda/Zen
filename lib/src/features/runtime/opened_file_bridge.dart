import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/presentation/account_backup_screen.dart';
import 'package:zen/src/features/account/presentation/key_restore_screen.dart';
import 'package:zen/src/features/runtime/opened_files.dart';
import 'package:zen/src/features/update/presentation/updates_screen.dart';

/// Opens the screen for a file opened in Zen from outside
/// ([ZenOpenedFiles]): a backup on "Mam kopię", a key backup on "Przywróć
/// klucz", an update on "Aktualizacje", each with the file chosen already.
///
/// In the app's first screen, which is only built past the lock screen and
/// the first-start setup: a file that came while Zen was locked opens once
/// it is unlocked, a backup on a fresh start once the setup is done.
class OpenedFileBridge extends ConsumerStatefulWidget {
  const OpenedFileBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<OpenedFileBridge> createState() => _OpenedFileBridgeState();
}

class _OpenedFileBridgeState extends ConsumerState<OpenedFileBridge> {
  late final ZenOpenedFiles _files;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _files = ref.read(zenOpenedFilesProvider)..addListener(_schedule);
    _schedule();
  }

  @override
  void dispose() {
    _files.removeListener(_schedule);
    super.dispose();
  }

  void _schedule() {
    if (_scheduled || _files.pending == null) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _scheduled = false;
        unawaitedLogged(_open(), context: 'Opening an opened file failed');
      })
      // Nothing else may be drawing (the screen on top did not change).
      ..ensureVisualUpdate();
  }

  Future<void> _open() async {
    if (!mounted) {
      return;
    }
    final ZenOpenedFile? file = _files.take();
    final String? path = file?.path;
    if (file == null) {
      return;
    }
    if (path == null) {
      _tell(t('Nie udało się otworzyć pliku.'));
      return;
    }
    switch (file.kind) {
      case ZenOpenedFileKind.accountBackup:
        await AccountBackupRestoreScreen.open(context, path: path);
      case ZenOpenedFileKind.keyFile:
        final Uint8List bytes = await File(path).readAsBytes();
        if (!mounted) {
          return;
        }
        await KeyRestoreScreen.open(context, fileBytes: bytes);
      case ZenOpenedFileKind.update:
        await UpdatesScreen.open(context, file: path);
      case ZenOpenedFileKind.other:
        _tell(
          t(
            'To nie jest plik Zen. Zen otwiera kopię konta, kopię klucza '
            'i plik aktualizacji.',
          ),
        );
    }
  }

  void _tell(String text) {
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
