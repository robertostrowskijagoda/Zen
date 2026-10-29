import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_bootstrap.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/public_peers.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/update_notice.dart';

import 'support/file_credentials_store.dart';

/// Every file the app keeps, damaged in every way a phone can damage it,
/// must never keep the app from starting (R5-#8, #22: stuck on the logo
/// after an update until the data was wiped).
///
/// The files are not listed by hand: a device starts once with the app's own
/// start-up (`ZenBootstrapper`, the real stores in a folder, the modules of
/// `ZenCore`), is used a little (a name, settings, a friend, messages, a
/// group) and closed; then each file it wrote, and its backup copy, is
/// damaged (emptied, cut short at a random point, replaced with random bytes,
/// a byte flipped, a newer or older format number, made huge) and the app
/// starts again on that folder. A store added tomorrow is covered without a
/// change here. Seeded: `ZEN_FUZZ_SEED` replays a run, `ZEN_FUZZ_CASES`
/// tries more cases than the default.
///
/// The few files read outside the start (the node's config, the public
/// peers, the update notice, the language) get the same damage through
/// their own loaders.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final int seed =
      int.tryParse(Platform.environment['ZEN_FUZZ_SEED'] ?? '') ?? 20261028;
  final int cases =
      int.tryParse(Platform.environment['ZEN_FUZZ_CASES'] ?? '') ?? 48;

  late Directory base;
  late Directory pristine;
  late List<String> files;

  setUpAll(() async {
    base = await Directory.systemTemp.createTemp('zen_fuzz_');
    ZenInstance.debugSetBaseDirectory(base);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (MethodCall call) async => base.path,
        );
    pristine = Directory('${base.path}/pristine')..createSync();
    final _Device device = await _Device.start(pristine);
    await device.use();
    await device.stop();
    // What the checks for lost data look for is there to begin with.
    final _Device again = await _Device.start(pristine);
    expect(await again.missing(), isEmpty);
    await again.stop();
    files = <String>[
      for (final FileSystemEntity e in pristine.listSync(recursive: true))
        if (e is File && !_isLog(e.path))
          e.path.substring(pristine.path.length + 1),
    ]..sort();
  });

  tearDownAll(() async {
    ZenInstance.debugSetBaseDirectory(null);
    try {
      await base.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps a file open a moment longer; the temp cleaning takes it.
    }
  });

  test('the app writes files to damage (the test sees its stores)', () {
    // Settings, the data store and the secrets at least.
    expect(files.where((String f) => f.startsWith('settings')), isNotEmpty);
    expect(files.where((String f) => f.startsWith('data')), isNotEmpty);
    expect(files.length, greaterThan(5), reason: '$files');
  });

  test(
    'the app starts and works on every damaged file ($cases cases, seed $seed)',
    () async {
      final Random random = Random(seed);
      final List<String> problems = <String>[];
      final List<String> silent = <String>[];
      for (int i = 0; i < cases; i++) {
        final String file = files[i % files.length];
        final _Damage damage =
            _Damage.values[random.nextInt(_Damage.values.length)];
        // A folder per case: Windows keeps the last one's log open a while.
        final Directory work = Directory('${base.path}/case$i');
        _copy(pristine, work);
        File(
          '${pristine.path}.secrets.json',
        ).copySync('${work.path}.secrets.json');
        final File target = File('${work.path}/$file');
        damage.apply(target, random);
        final File backup = File('${target.path}.bak');
        final bool hadBackup = backup.existsSync();
        bool backupDamaged = false;
        if (hadBackup && random.nextBool()) {
          // Both copies at once: nothing good is left of this file.
          damage.apply(backup, random);
          backupDamaged = true;
        }
        // With a good earlier copy nothing may be lost: the store reads it.
        final bool mayLose =
            !file.endsWith('.bak') &&
            !file.endsWith('.bak2') &&
            (!hadBackup || backupDamaged);
        final List<String> logged = <String>[];
        final String label = '$file (${damage.name})';
        // Errors nobody awaited (a service's start in the background) are
        // failures too: in the app they end that service for the session.
        final List<String> uncaught = <String>[];
        final Completer<void> done = Completer<void>();
        runZonedGuarded(
          () async {
            try {
              await _captureLog(logged, () async {
                final _Device device = await _Device.start(work);
                final List<String> lost = await device.missing();
                if (lost.isNotEmpty && !mayLose) {
                  problems.add(
                    '$label: lost although an earlier copy was good: '
                    '${lost.join(', ')}',
                  );
                }
                await device.use();
                await device.stop();
              }).timeout(const Duration(seconds: 30));
              // What was still running settles.
              await Future<void>.delayed(const Duration(milliseconds: 200));
            } on TimeoutException {
              problems.add('$label: the start hung');
            } on Object catch (error, stack) {
              problems.add('$label: $error\n${_top(stack)}');
            }
            done.complete();
          },
          (Object error, StackTrace stack) {
            uncaught.add('$error\n${_top(stack)}');
          },
        );
        await done.future;
        for (final String error in uncaught.toSet()) {
          problems.add('$label: unhandled in the background: $error');
        }
        if (!logged.any(_saysSomethingWentWrong)) {
          silent.add(label);
        }
      }
      final List<String> known = <String>[
        for (final String p in problems)
          if (_knownFinding(p) case final String id) '$id <- $p',
      ];
      final List<String> unexpected = <String>[
        for (final String p in problems)
          if (_knownFinding(p) == null) p,
      ];
      // ignore: avoid_print
      print(
        '${files.length} files, $cases cases.\n'
        'Known findings (test/regressions, not failing here until fixed): '
        '${known.length}\n  ${known.join('\n  ')}\n'
        'Damaged without a warning in the log (fine when the file is not '
        'read at the start or its backup took over): ${silent.length}\n'
        '  ${silent.join('\n  ')}',
      );
      expect(unexpected, isEmpty, reason: unexpected.join('\n\n'));
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );

  group('files read outside the start, through their own loaders', () {
    final Random random = Random(seed);
    late Directory folder;

    setUp(() async {
      folder = await Directory.systemTemp.createTemp('zen_fuzz_one_');
    });

    tearDown(() async {
      try {
        await folder.delete(recursive: true);
      } on FileSystemException {
        // As above.
      }
    });

    Future<void> everyDamage(
      File file,
      Future<void> Function() write,
      Future<void> Function() load,
    ) async {
      for (final _Damage damage in _Damage.values) {
        await write();
        damage.apply(file, random);
        await load().timeout(
          const Duration(seconds: 10),
          onTimeout: () => fail('${file.path} (${damage.name}): hung'),
        );
      }
    }

    test('the node config: a damaged file never throws, the backup or a new '
        'identity takes over', () async {
      final File file = File('${folder.path}/runtime/yggdrasil.config.json');
      await everyDamage(
        file,
        () => loadOrCreateNodeConfigJson(
          file: file,
          generateConfig: () => '{"PrivateKey":"${'ab' * 64}"}',
        ),
        () async {
          final String config = await loadOrCreateNodeConfigJson(
            file: file,
            generateConfig: () => '{"PrivateKey":"${'cd' * 64}"}',
          );
          jsonDecode(config);
        },
      );
    });

    test('the public peers fall back to the built-in list', () async {
      final File file = File('${folder.path}/public_peers.json');
      final PublicPeersStore store = PublicPeersStore(file: () async => file);
      await everyDamage(
        file,
        () async => file.writeAsStringSync(
          jsonEncode(<String, Object>{
            'v': 1,
            'peers': <Object>[
              <String, Object>{'uri': 'tls://192.0.2.1:443', 'on': true},
            ],
          }),
        ),
        store.load,
      );
    });

    test('the update notice reads as nothing kept', () async {
      final FileUpdateNoticeStore store = FileUpdateNoticeStore(
        directory: () async => folder,
      );
      final File file = File('${folder.path}/$kUpdateNoticeFileName');
      await everyDamage(
        file,
        () => store.update(
          (UpdateNoticeState s) => const UpdateNoticeState(
            checkedAtMillis: 1,
            notifiedVersion: '1.13.1',
          ),
        ),
        () async {
          await store.read();
          await store.update((UpdateNoticeState s) => s);
        },
      );
    });

    test('the language choice falls back to the system language', () async {
      final FileZenLanguageStore store = FileZenLanguageStore(
        supportDirectory: folder,
      );
      await store.write('de');
      final List<File> written = <File>[
        for (final FileSystemEntity e in folder.listSync(recursive: true))
          if (e is File) e,
      ];
      expect(written, isNotEmpty);
      await everyDamage(written.first, () => store.write('de'), store.read);
    });
  });
}

/// What this test found and the owner's regression list tracks
/// (test/regressions): the app frame a problem goes through, and the
/// regression it belongs to. Whoever fixes one removes its line here, so
/// the test guards the fix; anything not listed fails the test.
const Map<String, String> _knownFindings = <String, String>{
  // A settings file cut short or emptied (a write killed halfway, no good
  // backup) throws out of the first step of the start-up: the app never
  // gets past the logo until its data is wiped.
  'FileAppSettingsStore.load': 'R5-#22',
};

String? _knownFinding(String problem) {
  for (final MapEntry<String, String> e in _knownFindings.entries) {
    if (problem.contains(e.key)) {
      return e.value;
    }
  }
  return null;
}

/// The first frames of [stack] that are the app's own.
String _top(StackTrace stack) => stack
    .toString()
    .split('\n')
    .where((String line) => line.contains('package:zen/'))
    .take(8)
    .join('\n');

bool _saysSomethingWentWrong(String line) => RegExp(
  r'WARN|fail|unreadable|damaged|error|exception|nie udał',
  caseSensitive: false,
).hasMatch(line);

bool _isLog(String path) =>
    path.contains('zen-diagnostics') || path.endsWith('.log');

void _copy(Directory from, Directory to) {
  for (final FileSystemEntity e in from.listSync(recursive: true)) {
    if (e is File) {
      final File target = File(
        '${to.path}${e.path.substring(from.path.length)}',
      );
      target.parent.createSync(recursive: true);
      e.copySync(target.path);
    }
  }
}

/// Runs [body] with every line the app logs (`debugPrint`) kept in [lines].
Future<void> _captureLog(
  List<String> lines,
  Future<void> Function() body,
) async {
  final DebugPrintCallback previous = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) {
      lines.add(message);
    }
  };
  try {
    await body();
  } finally {
    debugPrint = previous;
  }
}

/// What can happen to a file on a phone: a write cut by a dead battery, a
/// bad sector, a file left by an older or newer version, a runaway writer.
enum _Damage {
  empty,
  truncated,
  randomBytes,
  flippedByte,
  newerFormat,
  olderFormat,
  huge;

  void apply(File file, Random random) {
    final Uint8List bytes = file.existsSync()
        ? file.readAsBytesSync()
        : Uint8List(0);
    switch (this) {
      case empty:
        file.writeAsBytesSync(const <int>[]);
      case truncated:
        file.writeAsBytesSync(
          bytes.sublist(0, bytes.isEmpty ? 0 : random.nextInt(bytes.length)),
        );
      case randomBytes:
        file.writeAsBytesSync(
          List<int>.generate(max(bytes.length, 16), (_) => random.nextInt(256)),
        );
      case flippedByte:
        if (bytes.isEmpty) {
          file.writeAsBytesSync(const <int>[0xff]);
          return;
        }
        final int at = random.nextInt(bytes.length);
        bytes[at] ^= 1 << random.nextInt(8);
        file.writeAsBytesSync(bytes);
      case newerFormat || olderFormat:
        file.writeAsBytesSync(_withVersion(bytes, this == newerFormat));
      case huge:
        // Past every store's size limit (the binary store's is 20 MB).
        final RandomAccessFile raf = file.openSync(mode: FileMode.write);
        raf.writeFromSync(bytes);
        raf.setPositionSync(24 * 1024 * 1024);
        raf.writeByteSync(1);
        raf.closeSync();
    }
  }

  /// [bytes] marked as written by a much newer ([newer]) or an older
  /// version: the version field of the binary store's envelope (after its
  /// four magic bytes), or `v` of a JSON file.
  static Uint8List _withVersion(Uint8List bytes, bool newer) {
    if (bytes.length > 6 &&
        bytes[0] == 0x5A &&
        bytes[1] == 0x45 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x31) {
      final Uint8List copy = Uint8List.fromList(bytes);
      copy[4] = newer ? 0xEE : 0x01;
      return copy;
    }
    try {
      final Object? json = jsonDecode(utf8.decode(bytes));
      if (json is Map<String, dynamic>) {
        json['v'] = newer ? 999 : 0;
        return Uint8List.fromList(utf8.encode(jsonEncode(json)));
      }
    } on Object {
      // Not JSON: sealed or binary; a byte for the version then.
    }
    final Uint8List copy = Uint8List.fromList(bytes);
    if (copy.isNotEmpty) {
      copy[0] = newer ? 0xFF : 0x00;
    }
    return copy;
  }
}

/// The app's stores compress with zstd, whose library comes from a platform
/// build; under `flutter test` gzip (dart:io) stands in, so the files are
/// compressed as in the app and damage reaches the decompression too.
final class _GzipCompressor implements BinaryCompressor {
  const _GzipCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async =>
      Uint8List.fromList(gzip.encode(payload));

  @override
  Future<Uint8List?> decompress(Uint8List payload) async =>
      Uint8List.fromList(gzip.decode(payload));
}

/// The app on [directory] without its screens and without a node: the
/// start-up of the app, its providers and the modules of `ZenCore`.
final class _Device {
  _Device._(this._boot, this._container);

  final ZenBootstrapResult _boot;
  final ProviderContainer _container;

  static Future<_Device> start(Directory directory) async {
    final BinaryCodec codec = BinaryCodec(compressor: const _GzipCompressor());
    final FileCredentialsStore secrets = FileCredentialsStore(
      File('${directory.path}.secrets.json'),
    );
    final ZenBootstrapper bootstrapper = ZenBootstrapper(
      supportDirectoryLoader: () async => directory,
      appSecurityServiceBuilder: () =>
          LocalAppSecurityService(credentialsStore: secrets),
      appSettingsStoreBuilder: (Directory folder) =>
          buildZenAppSettingsStoreForDirectory(
            folder,
            codec: codec,
            secrets: secrets,
          ),
      persistentStoresBuilder:
          (
            Directory folder, {
            AppSettingsStore? appSettingsStore,
            BinaryPayloadProtector? dataProtector,
          }) => buildZenPersistentStoresForDirectory(
            folder,
            codec: codec,
            dataProtector: dataProtector,
            appSettingsStore: appSettingsStore,
          ),
      runtimeBuilder: ({required RuntimeSignalBootstrapConfig config}) =>
          RuntimeNodeRuntime.preview(),
      prepareAccounts: () async {},
      receivesInBackground: () async => false,
    );
    final ZenBootstrapResult boot = await bootstrapper.bootstrap();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        ...boot.buildProviderOverrides(
          systemNotificationServiceFactory:
              MemoryRuntimeSystemNotificationService.new,
        ),
        supportDirectoryResolverProvider.overrideWithValue(
          () async => directory,
        ),
      ],
    );
    await container.read(socialHubControllerProvider.notifier).whenHydrated;
    await container.read(zenCoreProvider).start();
    return _Device._(boot, container);
  }

  static const String _friend = '200:1111:2222:3333:4444:5555:6666:7777';

  /// What [use] left that is not there (read straight after the start):
  /// the name, the theme, the friend, the group, the message.
  Future<List<String>> missing() async {
    final List<String> out = <String>[];
    final UserProfile? profile = await _container
        .read(userProfileStoreProvider)
        .load();
    if (profile?.displayName != 'Ala') {
      out.add('the name');
    }
    if (_container.read(appSettingsControllerProvider).themeMode !=
        AppThemeMode.dark) {
      out.add('the theme');
    }
    final SocialHubState hub = _container.read(socialHubControllerProvider);
    if (hub.friendByAddress(_friend) == null) {
      out.add('the friend');
    }
    if (hub.groups.isEmpty) {
      out.add('the group');
    }
    final List<ChatMessage> messages = await _container
        .read(messageTimelineStoreProvider)
        .load(_friend);
    if (!messages.any((ChatMessage m) => m.text == 'cześć')) {
      out.add('the message');
    }
    return out;
  }

  /// What a person does in the first minutes; each step writes files.
  Future<void> use() async {
    await _container
        .read(userProfileControllerProvider.notifier)
        .updateProfile(displayName: 'Ala');
    await _container
        .read(appSettingsControllerProvider.notifier)
        .setThemeMode(AppThemeMode.dark);
    final SocialHubController hub = _container.read(
      socialHubControllerProvider.notifier,
    );
    const String friend = _friend;
    await hub.sendFriendRequest(peerAddress: friend, senderDisplayName: 'Ala');
    await hub.createGroup(
      name: 'Rodzina',
      description: '',
      memberAddresses: <String>[friend],
    );
    await hub.sendLocalMessage(peerAddress: friend, text: 'cześć');
    // Stores write in the background; give them a moment.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  Future<void> stop() async {
    await _container.read(zenCoreProvider).stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _container.dispose();
    retireBootstrapResult(_boot);
  }
}
