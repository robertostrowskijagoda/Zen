import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How handing the app to the system share sheet went.
enum ApkShareStatus {
  /// The share sheet is open with the installer.
  opened,

  /// There was no installer file to send (or it could not be read).
  noFile,

  /// Not possible here (not Android, or an older native side).
  unsupported,

  /// Anything else went wrong.
  failed,
}

@immutable
final class ApkShareResult {
  const ApkShareResult(this.status, {this.baseOnly = false, this.fileName});

  final ApkShareStatus status;

  /// The app was installed from several files (split APKs) and only the
  /// main one went out: on the other phone it may not install by itself.
  final bool baseOnly;

  /// Name of the file as the receiver gets it (e.g. `Zen-1.9.0.apk`).
  final String? fileName;

  bool get opened => status == ApkShareStatus.opened;
}

/// "Podaj dalej" through the system share sheet (Android, `zen/share_app`):
/// Quick Share, Bluetooth and the like send the installer from phone to
/// phone, no internet needed.
final class ShareAppChannel {
  const ShareAppChannel({
    MethodChannel channel = const MethodChannel('zen/share_app'),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// Opens the share sheet with the installer at [path] (e.g. a newer signed
  /// release), sent as [fileName]; without [path], the APK this app was
  /// installed from, named `Zen-<version>.apk`.
  Future<ApkShareResult> shareApk({String? path, String? fileName}) async {
    try {
      final Map<Object?, Object?>? reply = await _channel
          .invokeMethod<Map<Object?, Object?>>('shareApk', <String, Object>{
            'path': ?path,
            'name': ?fileName,
          });
      return parseApkShareReply(reply);
    } on MissingPluginException {
      return const ApkShareResult(ApkShareStatus.unsupported);
    } on PlatformException {
      return const ApkShareResult(ApkShareStatus.failed);
    }
  }
}

/// The native answer (`{ok, baseOnly, name}` or `{error}`) as a result.
@visibleForTesting
ApkShareResult parseApkShareReply(Map<Object?, Object?>? reply) {
  if (reply == null) {
    return const ApkShareResult(ApkShareStatus.failed);
  }
  if (reply['ok'] == true) {
    final Object? name = reply['name'];
    return ApkShareResult(
      ApkShareStatus.opened,
      baseOnly: reply['baseOnly'] == true,
      fileName: name is String ? name : null,
    );
  }
  return ApkShareResult(
    reply['error'] == 'no_file' ? ApkShareStatus.noFile : ApkShareStatus.failed,
  );
}
