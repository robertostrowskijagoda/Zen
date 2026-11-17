import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/media/media_vault_sweep.dart';

/// The sweep of the media vault on its own: what it may remove and what it
/// never touches.

String _name(int n) => '${n.toRadixString(16).padLeft(32, '0')}.zmedia';

File _file(Directory dir, String name, {int bytes = 10}) =>
    File('${dir.path}${Platform.pathSeparator}$name')
      ..writeAsBytesSync(List<int>.filled(bytes, 1));

bool _none(String _) => false;

DateTime _later() => DateTime.now().add(const Duration(days: 3));

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zen-vault-sweep-');
  });

  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Future<MediaVaultSweepResult> sweep(
    Set<String> used, {
    bool Function(String) inFlight = _none,
    DateTime Function() now = _later,
    int maxRemoved = kMediaVaultSweepMaxRemoved,
  }) => sweepMediaVault(
    folder: dir,
    referenced: () async => used,
    inFlight: inFlight,
    now: now,
    maxRemoved: maxRemoved,
  );

  test('an unused old file goes; a file in use stays', () async {
    final File used = _file(dir, _name(1));
    final File stray = _file(dir, _name(2), bytes: 7);
    final MediaVaultSweepResult r = await sweep(<String>{_name(1)});
    expect(r.outcome, MediaVaultSweepOutcome.swept);
    expect((r.removed, r.bytes), (1, 7));
    expect(used.existsSync(), isTrue);
    expect(stray.existsSync(), isFalse);
  });

  test('a file in use is never removed, whatever its age', () async {
    final List<File> files = <File>[
      for (int i = 0; i < 30; i++) _file(dir, _name(i)),
    ];
    await sweep(<String>{for (int i = 0; i < 30; i++) _name(i)});
    expect(files.every((File f) => f.existsSync()), isTrue);
  });

  test('a young file stays', () async {
    final File stray = _file(dir, _name(3));
    final MediaVaultSweepResult r = await sweep(<String>{}, now: DateTime.now);
    expect(r.outcome, MediaVaultSweepOutcome.nothing);
    expect(stray.existsSync(), isTrue);
  });

  test('a file being written or received now stays, its .tmp too', () async {
    final File stray = _file(dir, _name(4));
    final File partial = _file(dir, '${_name(5)}.tmp');
    final Set<String> busy = <String>{_name(4), _name(5)};
    await sweep(<String>{}, inFlight: busy.contains);
    expect(stray.existsSync(), isTrue);
    expect(partial.existsSync(), isTrue);
  });

  test('a .tmp left by a write that never finished goes', () async {
    final File partial = _file(dir, '${_name(6)}.tmp');
    // Even under the name of a file in use: a .tmp is never the file.
    await sweep(<String>{_name(6)});
    expect(partial.existsSync(), isFalse);
  });

  test('when what is in use cannot be read nothing goes', () async {
    final File stray = _file(dir, _name(7));
    final MediaVaultSweepResult r = await sweepMediaVault(
      folder: dir,
      referenced: () async => throw StateError('locked'),
      inFlight: _none,
      now: _later,
    );
    expect(r.outcome, MediaVaultSweepOutcome.unreadable);
    expect(stray.existsSync(), isTrue);
  });

  test('too many unused files to believe: nothing goes', () async {
    final List<File> files = <File>[
      for (int i = 0; i < 30; i++) _file(dir, _name(i)),
    ];
    final MediaVaultSweepResult r = await sweep(<String>{_name(0)});
    expect(r.outcome, MediaVaultSweepOutcome.implausible);
    expect(files.every((File f) => f.existsSync()), isTrue);
  });

  test('one sweep removes a bounded number', () async {
    for (int i = 0; i < 10; i++) {
      _file(dir, _name(i));
    }
    final MediaVaultSweepResult r = await sweep(<String>{
      for (int i = 0; i < 6; i++) _name(i),
    }, maxRemoved: 3);
    expect(r.removed, 3);
    expect(r.unused, 4);
  });

  test('other files and a missing folder are left alone', () async {
    final File other = _file(dir, 'notes.txt');
    final File upper = _file(dir, 'ABC.zmedia');
    await sweep(<String>{});
    expect(other.existsSync(), isTrue);
    expect(upper.existsSync(), isTrue);

    final Directory gone = Directory('${dir.path}${Platform.pathSeparator}x');
    final MediaVaultSweepResult r = await sweepMediaVault(
      folder: gone,
      referenced: () async => <String>{},
      inFlight: _none,
      now: _later,
    );
    expect(r.outcome, MediaVaultSweepOutcome.nothing);
    expect(gone.existsSync(), isFalse, reason: 'never made by the sweep');
  });
}
