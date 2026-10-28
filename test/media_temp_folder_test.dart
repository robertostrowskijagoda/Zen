import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/media/media_temp_folder.dart';

/// Modes kept in memory: the test host's own permissions play no part, so
/// the same checks run on Windows too. Entries in [foreign] belong to
/// another user: their mode cannot be changed.
final class _FakeAccess implements PosixFolderAccess {
  final Map<String, int> modes = <String, int>{};
  final Set<String> foreign = <String>{};

  /// What a folder gets when it is made (a umask of 022).
  int created = 0x1ED; // 0755

  @override
  Future<FileSystemEntityType> typeOf(String path) =>
      FileSystemEntity.type(path, followLinks: false);

  @override
  Future<int> permissionsOf(String path) async => modes[path] ?? created;

  @override
  bool setPermissions(String path, int mode) {
    if (foreign.contains(path)) {
      return false;
    }
    modes[path] = mode;
    return true;
  }
}

void main() {
  late Directory base;
  final String sep = Platform.pathSeparator;

  setUp(() async {
    base = await Directory.systemTemp.createTemp('zen-media-base-');
  });

  tearDown(() async {
    if (base.existsSync()) {
      await base.delete(recursive: true);
    }
  });

  String inBase(String name) => '${base.path}$sep$name';

  test('a new folder is made private at once', () async {
    final _FakeAccess access = _FakeAccess();
    final Directory folder = await preparePrivateFolder(
      base,
      'zen-media',
      access: access,
    );
    expect(folder.path, inBase('zen-media'));
    expect(folder.existsSync(), isTrue);
    expect(access.modes[folder.path], kOwnerOnlyFolderMode);
  });

  test('an own private folder is used again', () async {
    final _FakeAccess access = _FakeAccess();
    Directory(inBase('zen-media')).createSync();
    access.modes[inBase('zen-media')] = kOwnerOnlyFolderMode;
    final Directory folder = await preparePrivateFolder(
      base,
      'zen-media',
      access: access,
    );
    expect(folder.path, inBase('zen-media'));
  });

  test('a folder others could open is not used', () async {
    final _FakeAccess access = _FakeAccess();
    Directory(inBase('zen-media')).createSync();
    access.modes[inBase('zen-media')] = 0x1FF; // 0777
    final Directory folder = await preparePrivateFolder(
      base,
      'zen-media',
      access: access,
    );
    expect(folder.path, isNot(inBase('zen-media')));
    expect(folder.path, startsWith(inBase('zen-media.')));
    expect(access.modes[folder.path], kOwnerOnlyFolderMode);
    // Its mode was not "fixed": whoever could open it may hold it open.
    expect(access.modes[inBase('zen-media')], 0x1FF);

    // The replacement is used again while it stays private.
    final Directory again = await preparePrivateFolder(
      base,
      'zen-media',
      access: access,
      replacement: folder,
    );
    expect(again.path, folder.path);
  });

  test('a private-looking folder of another user is not used', () async {
    final _FakeAccess access = _FakeAccess();
    Directory(inBase('zen-media')).createSync();
    access
      ..modes[inBase('zen-media')] = kOwnerOnlyFolderMode
      ..foreign.add(inBase('zen-media'));
    final Directory folder = await preparePrivateFolder(
      base,
      'zen-media',
      access: access,
    );
    expect(folder.path, startsWith(inBase('zen-media.')));
  });

  test('a file in place of the folder is not used', () async {
    final _FakeAccess access = _FakeAccess();
    File(inBase('zen-media')).writeAsStringSync('x');
    final Directory folder = await preparePrivateFolder(
      base,
      'zen-media',
      access: access,
    );
    expect(folder.path, startsWith(inBase('zen-media.')));
  });

  test('a link in place of the folder is not followed', () async {
    final _FakeAccess access = _FakeAccess();
    final Directory elsewhere = Directory(inBase('elsewhere'))..createSync();
    access.modes[elsewhere.path] = kOwnerOnlyFolderMode;
    _linkFolder(inBase('zen-media'), elsewhere.path);
    final Directory folder = await preparePrivateFolder(
      base,
      'zen-media',
      access: access,
    );
    expect(folder.path, startsWith(inBase('zen-media.')));

    // Clearing removes the link and the replacement, never what the link
    // points to.
    File('${elsewhere.path}${sep}keep.txt').writeAsStringSync('mine');
    await deleteMediaTemporaryFolders(base, 'zen-media');
    expect(Link(inBase('zen-media')).existsSync(), isFalse);
    expect(folder.existsSync(), isFalse);
    expect(File('${elsewhere.path}${sep}keep.txt').existsSync(), isTrue);
  });

  test(
    'no plain media is written when no folder can be made private',
    () async {
      final _FakeAccess access = _FakeAccess();
      Directory(inBase('zen-media')).createSync();
      access.modes[inBase('zen-media')] = 0x1FF;
      final _FakeAccess refusing = _NoChmod(access);
      await expectLater(
        preparePrivateFolder(base, 'zen-media', access: refusing),
        throwsStateError,
      );
      // The new folder it tried is gone again.
      expect(base.listSync().map((FileSystemEntity e) => e.path), <String>[
        inBase('zen-media'),
      ]);
    },
  );

  test('a base others may write into is skipped', () async {
    final _FakeAccess access = _FakeAccess();
    final Directory shared = Directory(inBase('shared'))..createSync();
    final Directory own = Directory(inBase('own'))..createSync();
    access
      ..modes[shared.path] =
          0x3FF // 1777, like /tmp
      ..modes[own.path] = kOwnerOnlyFolderMode;
    final Directory missing = Directory(inBase('missing'));
    expect(
      (await pickPrivateBase(<Directory>[
        missing,
        shared,
        own,
      ], access: access))?.path,
      own.path,
    );
    expect(await pickPrivateBase(<Directory>[shared], access: access), isNull);
  });

  test('only this instance\'s folders are cleared', () async {
    Directory(inBase('zen-media')).createSync();
    Directory(inBase('zen-media.ab12Cd')).createSync();
    Directory(inBase('zen-media-other')).createSync();
    File(inBase('inny-program.tmp')).writeAsStringSync('x');
    await deleteMediaTemporaryFolders(base, 'zen-media');
    expect(
      base.listSync().map((FileSystemEntity e) => e.path).toSet(),
      <String>{inBase('zen-media-other'), inBase('inny-program.tmp')},
    );
    expect(isMediaTemporaryFolderEntry('zen-media.x', 'zen-media'), isTrue);
    expect(isMediaTemporaryFolderEntry('zen-media-p', 'zen-media'), isFalse);
  });

  test('on this computer the folder is 0700 and a file 0600', () async {
    final Directory folder = await preparePrivateFolder(base, 'zen-media');
    expect((await folder.stat()).mode & 0x1FF, kOwnerOnlyFolderMode);
    final File file = await createPrivateTemporaryFile(
      '${folder.path}${sep}clip.m4a',
    );
    await file.writeAsBytes(<int>[1, 2, 3], flush: true);
    expect((await file.stat()).mode & 0x1FF, kOwnerOnlyFileMode);
  }, skip: Platform.isLinux || Platform.isMacOS ? false : 'POSIX only');
}

/// A link at [path] to the folder [target]. On Windows a symbolic link needs
/// Developer Mode (or administrator rights); without them a directory
/// junction is made instead, which Dart and the app also see as a link.
void _linkFolder(String path, String target) {
  try {
    Link(path).createSync(target);
  } on FileSystemException {
    if (!Platform.isWindows) {
      rethrow;
    }
    final ProcessResult r = Process.runSync('cmd', <String>[
      '/c',
      'mklink',
      '/J',
      path,
      target,
    ]);
    if (r.exitCode != 0) {
      fail('No link and no junction at $path: ${r.stdout}${r.stderr}');
    }
  }
}

/// [_FakeAccess] where no mode can be changed (as for another user).
final class _NoChmod extends _FakeAccess {
  _NoChmod(_FakeAccess from) {
    modes.addAll(from.modes);
  }

  @override
  bool setPermissions(String path, int mode) => false;
}
