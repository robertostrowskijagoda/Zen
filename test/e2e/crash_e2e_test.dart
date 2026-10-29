@Tags(<String>['e2e'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';

import 'support/zen_mesh.dart';

/// A device killed in the middle of writing starts again from what is on
/// its disk (R5-#8, #22).
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final String? skip = await zenMeshSkipReason();

  test(
    'a device killed while it writes starts again from what is on its disk',
    () async {
      final ZenMesh mesh = await ZenMesh.open();
      final ZenDevice ala = await mesh.device('Ala');
      final ZenDevice ola = await mesh.device('Ola');
      await mesh.befriend(ala, ola, within: kInvitationWithin);

      // Ola's folder copied file by file while a burst of messages is
      // being written into it: a power cut at a random moment leaves some
      // files of before and some of after, and maybe a half-written one.
      mesh.mark('a burst while Ola\'s disk is copied');
      final Directory crash = Directory('${mesh.base.path}/ola-crash');
      final Future<void> burst = () async {
        for (int i = 0; i < 40; i++) {
          await ala.send(ola, 'wiadomość $i');
        }
      }();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await copyFolder(ola.directory, crash);
      final File secrets = File('${ola.directory.path}.secrets.json');
      final File crashSecrets = File('${crash.path}.secrets.json');
      await secrets.copy(crashSecrets.path);
      await burst;

      // The device dies (its files stay as the copy has them) and starts.
      mesh.mark('Ola starts from the copy');
      await ola.stop();
      await replaceFolder(ola.directory, crash);
      await crashSecrets.copy(secrets.path);
      await ola.start();
      expect(ola.friendOf(ala)?.status, FriendRelationshipStatus.accepted);
      mesh.mark('Ala writes after the crash');
      await ala.send(ola, 'po awarii');
      final Duration took = await ola.waitForText(
        ala,
        'po awarii',
        within: kAfterRestartWithin,
      );
      mesh.timings.add(
        'the message after the crash took ${took.inMilliseconds} ms',
      );
      mesh.report();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

/// The diagnostics log stays open a while on Windows; it is no data.
bool _isLog(String path) => path.contains('zen-diagnostics');

/// Copies [from] into [to] file by file, as it is at each moment.
Future<void> copyFolder(Directory from, Directory to) async {
  await for (final FileSystemEntity e in from.list(recursive: true)) {
    final String relative = e.path.substring(from.path.length);
    if (e is File && !_isLog(e.path)) {
      final File target = File('${to.path}$relative');
      await target.parent.create(recursive: true);
      try {
        await e.copy(target.path);
      } on FileSystemException {
        // Renamed or removed while copied: as after a power cut.
      }
    }
  }
}

/// Makes [folder] hold exactly the files of [copy] (logs aside).
Future<void> replaceFolder(Directory folder, Directory copy) async {
  await for (final FileSystemEntity e in folder.list(recursive: true)) {
    final String relative = e.path.substring(folder.path.length);
    if (e is File &&
        !_isLog(e.path) &&
        !File('${copy.path}$relative').existsSync()) {
      await _deleteSoon(e);
    }
  }
  await copyFolder(copy, folder);
}

/// Deletes [file], waiting a moment for a write of the stopped device that
/// is still under way: Windows refuses to delete a file that is open. The
/// temporary file of a write that does not finish stays, as after a power
/// cut (the app removes such leftovers itself, binary_store.dart).
Future<void> _deleteSoon(File file) async {
  for (int attempt = 0; ; attempt++) {
    try {
      await file.delete();
      return;
    } on FileSystemException {
      if (!file.existsSync()) {
        return;
      }
      if (attempt >= 20) {
        if (file.path.endsWith('.tmp')) {
          return;
        }
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}
