import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_bootstrap.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The machines that run the tests have no zstd library: envelopes are
/// stored uncompressed, a form the app writes too (when compressing does
/// not help) and reads like any other.
final class PassThroughCompressor implements BinaryCompressor {
  const PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => null;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}

final BinaryCodec harnessCodec = BinaryCodec(
  compressor: const PassThroughCompressor(),
);

/// Secure storage as a map (the upgrade fixtures keep theirs in
/// `secure_storage.json`).
final class MapSecrets implements AppSecurityCredentialsStore {
  MapSecrets([Map<String, String>? values])
    : values = values ?? <String, String>{};

  final Map<String, String> values;

  /// Every call waits this long first ([hang]: never answers).
  Duration delay = Duration.zero;
  bool hang = false;

  Future<void> _wait() async {
    if (hang) {
      await Completer<void>().future;
    }
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
  }

  @override
  Future<String?> read(String key) async {
    await _wait();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await _wait();
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    await _wait();
    values.remove(key);
  }
}

/// What a start on [folder] got to.
final class HarnessStart {
  HarnessStart(this.result, this.secrets);

  final ZenBootstrapResult result;
  final MapSecrets secrets;
}

/// The app's real start sequence (ZenBootstrapper with the real file
/// stores, the real settings store with its protected copy and the real
/// app lock) on [folder], everything but the node (no Go bridge here) and
/// the system's secure storage ([secrets] instead).
Future<HarnessStart> startZenOn(
  Directory folder, {
  required MapSecrets secrets,
  ZenStartTimeouts timeouts = const ZenStartTimeouts(),
  Duration within = const Duration(seconds: 30),
}) async {
  ZenInstance.debugSetBaseDirectory(folder);
  final ZenBootstrapper bootstrapper = ZenBootstrapper(
    supportDirectoryLoader: () async => folder,
    appSecurityServiceBuilder: () => LocalAppSecurityService(
      credentialsStore: secrets,
      passwordIterations: 1,
    ),
    appSettingsStoreBuilder: (Directory dir) =>
        buildZenAppSettingsStoreForDirectory(
          dir,
          codec: harnessCodec,
          secrets: secrets,
        ),
    persistentStoresBuilder:
        (
          Directory dir, {
          AppSettingsStore? appSettingsStore,
          BinaryPayloadProtector? dataProtector,
        }) => buildZenPersistentStoresForDirectory(
          dir,
          codec: harnessCodec,
          dataProtector: dataProtector,
          appSettingsStore: appSettingsStore,
        ),
    runtimeBuilder: ({required RuntimeSignalBootstrapConfig config}) =>
        RuntimeNodeRuntime.preview(),
    timeouts: timeouts,
  );
  final ZenBootstrapResult result = await bootstrapper.bootstrap().timeout(
    within,
  );
  return HarnessStart(result, secrets);
}

/// The social hub of [result] as the app builds it, hydrated from the
/// stored snapshot (the first thing the app shows after unlocking).
Future<(ProviderContainer, SocialHubState)> hydrateHub(
  ZenBootstrapResult result, {
  Duration within = const Duration(seconds: 30),
}) async {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      ...result.buildProviderOverrides(
        systemNotificationServiceFactory:
            MemoryRuntimeSystemNotificationService.new,
      ),
    ],
  );
  final SocialHubController hub = container.read(
    socialHubControllerProvider.notifier,
  );
  await hub.whenHydrated.timeout(within);
  // The hydration's own follow-up (retention, the queue) ran too.
  await hub.hydrateFromStore().timeout(within).catchError((Object _) {});
  return (container, container.read(socialHubControllerProvider));
}

/// Deletes [folder]; on Windows a file the diagnostics log still holds
/// open may keep it for a moment, which leaves it to the system.
Future<void> deleteQuietly(Directory folder) async {
  try {
    await folder.delete(recursive: true);
  } on FileSystemException {
    // Left in the temporary folder.
  }
}

/// [source] copied into a new temporary folder.
Directory copyFixture(Directory source, String prefix) {
  final Directory target = Directory.systemTemp.createTempSync(prefix);
  for (final FileSystemEntity entity in source.listSync(recursive: true)) {
    final String relative = entity.path.substring(source.path.length + 1);
    final String path = '${target.path}${Platform.pathSeparator}$relative';
    if (entity is Directory) {
      Directory(path).createSync(recursive: true);
    } else if (entity is File) {
      File(path).parent.createSync(recursive: true);
      entity.copySync(path);
    }
  }
  return target;
}

Map<String, String> readSecrets(Directory fixture) {
  final Object? json = jsonDecode(
    File('${fixture.path}/secure_storage.json').readAsStringSync(),
  );
  return <String, String>{
    for (final MapEntry<String, dynamic> e
        in (json! as Map<String, dynamic>).entries)
      e.key: e.value as String,
  };
}
