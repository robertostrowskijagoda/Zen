import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:zen/src/features/runtime/yggdrasil_signal_transport.dart';

abstract interface class NodeSignalBridge implements NativeSignalBridge {
  String generateConfigJson();

  Map<String, dynamic> startNode(String configJson);

  Map<String, dynamic> stopNode(int handle);

  Map<String, dynamic> getNodeInfo(int handle);

  /// Adds a mesh peer (e.g. a bridge learnt from friends) at runtime.
  Map<String, dynamic> addPeer(int handle, String uri);
}

/// Absolute paths the Windows build looks for the bridge DLL at, in order.
///
/// Release and profile builds load it only from next to the executable
/// (windows/CMakeLists.txt installs it there): the working directory can be
/// anything the app was started from, possibly a folder someone else can
/// write to, and a DLL planted there would run inside the app. Debug builds
/// (`flutter run`, `flutter test`) also try the working directory, where the
/// freshly built bridge of the checkout lives. There is never a bare-name
/// lookup through the system DLL search path.
///
/// The checkout keeps one DLL per architecture (build_windows.ps1): x64 in
/// `bin\`, ARM64 (Windows on ARM, [arm64]) in `bin\windows-arm64\`; next to
/// the executable there is only the one the build installed.
@visibleForTesting
List<String> windowsBridgeLibraryCandidates({
  required String exeDirectory,
  required String currentDirectory,
  required bool debugMode,
  bool arm64 = false,
}) {
  const String checkout = r'native\yggdrasil_bridge\bin';
  return <String>[
    '$exeDirectory\\yggdrasil_bridge.dll',
    if (debugMode) ...<String>[
      if (arm64)
        '$currentDirectory\\$checkout\\windows-arm64\\yggdrasil_bridge.dll'
      else
        '$currentDirectory\\$checkout\\yggdrasil_bridge.dll',
      if (currentDirectory != exeDirectory)
        '$currentDirectory\\yggdrasil_bridge.dll',
    ],
  ];
}

/// What the Android loader says when the bridge cannot be opened.
///
/// The APK carries the bridge for arm64-v8a, armeabi-v7a and x86_64
/// (android/app/build.gradle.kts); other ABIs (32-bit x86 emulators, MIPS)
/// are not supported.
@visibleForTesting
String androidBridgeLoadError(Object cause) =>
    'Could not load libyggdrasil_bridge.so — the ABI of this device may not '
    'be supported (the app bundles arm64-v8a, armeabi-v7a and x86_64). '
    'Cause: $cause';

final class YggdrasilBridgeException implements Exception {
  const YggdrasilBridgeException(this.message);

  final String message;

  @override
  String toString() => 'YggdrasilBridgeException: $message';
}

typedef _NativeNoArgCall = Pointer<Utf8> Function();
typedef _NativeIntArgCall = Pointer<Utf8> Function(Int32);
typedef _NativeIntIntArgCall = Pointer<Utf8> Function(Int32, Int32);
typedef _NativeIntStringArgCall = Pointer<Utf8> Function(Int32, Pointer<Utf8>);
typedef _NativeStringArgCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeIntTwoStringArgCall =
    Pointer<Utf8> Function(Int32, Pointer<Utf8>, Pointer<Utf8>);
typedef _DartNoArgCall = Pointer<Utf8> Function();
typedef _DartIntArgCall = Pointer<Utf8> Function(int);
typedef _DartIntIntArgCall = Pointer<Utf8> Function(int, int);
typedef _DartIntStringArgCall = Pointer<Utf8> Function(int, Pointer<Utf8>);
typedef _DartStringArgCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartIntTwoStringArgCall =
    Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>);
typedef _NativeFreeString = Void Function(Pointer<Utf8>);

final class YggdrasilBridgeFfi implements NodeSignalBridge {
  YggdrasilBridgeFfi._(DynamicLibrary library, this._freeString)
    : _generateConfig = library
          .lookupFunction<_NativeNoArgCall, _DartNoArgCall>(
            'YggGenerateConfigJson',
          ),
      _startNode = library
          .lookupFunction<_NativeStringArgCall, _DartStringArgCall>(
            'YggStartNode',
          ),
      _stopNode = library.lookupFunction<_NativeIntArgCall, _DartIntArgCall>(
        'YggStopNode',
      ),
      _getNodeInfo = library.lookupFunction<_NativeIntArgCall, _DartIntArgCall>(
        'YggGetNodeInfo',
      ),
      _startSignaling = library
          .lookupFunction<_NativeIntArgCall, _DartIntArgCall>(
            'YggStartSignaling',
          ),
      _sendSignal = library
          .lookupFunction<_NativeIntTwoStringArgCall, _DartIntTwoStringArgCall>(
            'YggSendSignal',
          ),
      _waitSignal = library
          .lookupFunction<_NativeIntIntArgCall, _DartIntIntArgCall>(
            'YggWaitSignal',
          ),
      _pollSignal = library.lookupFunction<_NativeIntArgCall, _DartIntArgCall>(
        'YggPollSignal',
      ),
      _openRelay = library
          .lookupFunction<_NativeIntStringArgCall, _DartIntStringArgCall>(
            'YggOpenRelayJson',
          ),
      _closeRelay = library
          .lookupFunction<_NativeIntStringArgCall, _DartIntStringArgCall>(
            'YggCloseRelay',
          ),
      _addPeer = library
          .lookupFunction<_NativeIntStringArgCall, _DartIntStringArgCall>(
            'YggAddPeer',
          );

  final void Function(Pointer<Utf8>) _freeString;
  final Pointer<Utf8> Function() _generateConfig;
  final Pointer<Utf8> Function(Pointer<Utf8>) _startNode;
  final Pointer<Utf8> Function(int) _stopNode;
  final Pointer<Utf8> Function(int) _getNodeInfo;
  final Pointer<Utf8> Function(int) _startSignaling;
  final Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>) _sendSignal;
  final Pointer<Utf8> Function(int, int) _waitSignal;
  final Pointer<Utf8> Function(int) _pollSignal;
  final Pointer<Utf8> Function(int, Pointer<Utf8>) _openRelay;
  final Pointer<Utf8> Function(int, Pointer<Utf8>) _closeRelay;
  final Pointer<Utf8> Function(int, Pointer<Utf8>) _addPeer;

  static YggdrasilBridgeFfi load() {
    final DynamicLibrary library = _openLibrary();
    final void Function(Pointer<Utf8>) freeString = library
        .lookupFunction<_NativeFreeString, void Function(Pointer<Utf8>)>(
          'YggFreeString',
        );
    return YggdrasilBridgeFfi._(library, freeString);
  }

  static DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      try {
        return DynamicLibrary.open('libyggdrasil_bridge.so');
      } catch (error) {
        // A readable cause instead of a raw FFI lookup error.
        throw YggdrasilBridgeException(androidBridgeLoadError(error));
      }
    }
    if (Platform.isWindows) {
      final List<String> candidates = windowsBridgeLibraryCandidates(
        exeDirectory: File(Platform.resolvedExecutable).parent.absolute.path,
        currentDirectory: Directory.current.absolute.path,
        debugMode: kDebugMode,
        arm64: Abi.current() == Abi.windowsArm64,
      );
      for (final String candidate in candidates) {
        if (File(candidate).existsSync()) {
          return DynamicLibrary.open(candidate);
        }
      }
      throw YggdrasilBridgeException(
        'Could not locate yggdrasil_bridge.dll. Checked: ${candidates.join(', ')}',
      );
    }
    if (Platform.isLinux) {
      // The bundle's lib/ folder (linux/CMakeLists.txt installs it there).
      // An absolute path, as on Windows: nothing is looked up through
      // LD_LIBRARY_PATH or the working directory.
      final String directory = File(
        Platform.resolvedExecutable,
      ).parent.absolute.path;
      final String library = '$directory/lib/libyggdrasil_bridge.so';
      if (!File(library).existsSync()) {
        throw YggdrasilBridgeException(
          'Could not locate libyggdrasil_bridge.so at $library.',
        );
      }
      return DynamicLibrary.open(library);
    }
    if (Platform.isIOS || Platform.isMacOS) {
      // iOS and macOS: the bridge is a static library linked into the app
      // itself (GoBridge.xcconfig in ios/Flutter and macos/Runner/Configs),
      // so its functions live in the process. A build without it fails here
      // with a readable cause.
      final DynamicLibrary process = DynamicLibrary.process();
      if (!process.providesSymbol('YggStartNode')) {
        throw const YggdrasilBridgeException(
          'The Go bridge is not linked into this build (build it with '
          'native/yggdrasil_bridge/build_ios.sh or build_macos.sh).',
        );
      }
      return process;
    }
    throw const YggdrasilBridgeException(
      'Signal bridge is not supported on this platform.',
    );
  }

  @override
  String generateConfigJson() =>
      _extractString(_readEnvelope(_generateConfig()));

  @override
  Map<String, dynamic> startNode(String configJson) {
    final Pointer<Utf8> nativeConfig = configJson.toNativeUtf8();
    try {
      return _extractMap(_readEnvelope(_startNode(nativeConfig)));
    } finally {
      malloc.free(nativeConfig);
    }
  }

  @override
  Map<String, dynamic> stopNode(int handle) =>
      _extractMap(_readEnvelope(_stopNode(handle)));

  @override
  Map<String, dynamic> getNodeInfo(int handle) =>
      _extractMap(_readEnvelope(_getNodeInfo(handle)));

  @override
  Map<String, dynamic> startSignaling(int handle) =>
      _extractMap(_readEnvelope(_startSignaling(handle)));

  @override
  Map<String, dynamic> sendSignal(
    int handle,
    String remoteAddress,
    String payload,
  ) {
    final Pointer<Utf8> nativeRemoteAddress = remoteAddress.toNativeUtf8();
    final Pointer<Utf8> nativePayload = payload.toNativeUtf8();
    try {
      return _extractMap(
        _readEnvelope(_sendSignal(handle, nativeRemoteAddress, nativePayload)),
      );
    } finally {
      malloc.free(nativeRemoteAddress);
      malloc.free(nativePayload);
    }
  }

  @override
  Map<String, dynamic> waitSignal(int handle, int timeoutMs) =>
      _extractMap(_readEnvelope(_waitSignal(handle, timeoutMs)));

  @override
  Map<String, dynamic> pollSignal(int handle) =>
      _extractMap(_readEnvelope(_pollSignal(handle)));

  @override
  Map<String, dynamic> openRelay(int handle, String payloadJson) {
    final Pointer<Utf8> nativePayload = payloadJson.toNativeUtf8();
    try {
      return _extractMap(_readEnvelope(_openRelay(handle, nativePayload)));
    } finally {
      malloc.free(nativePayload);
    }
  }

  @override
  Map<String, dynamic> closeRelay(int handle, String callId) {
    final Pointer<Utf8> nativeCallId = callId.toNativeUtf8();
    try {
      return _extractMap(_readEnvelope(_closeRelay(handle, nativeCallId)));
    } finally {
      malloc.free(nativeCallId);
    }
  }

  @override
  Map<String, dynamic> addPeer(int handle, String uri) {
    final Pointer<Utf8> nativeUri = uri.toNativeUtf8();
    try {
      return _extractMap(_readEnvelope(_addPeer(handle, nativeUri)));
    } finally {
      malloc.free(nativeUri);
    }
  }

  Map<String, dynamic> _readEnvelope(Pointer<Utf8> pointer) {
    final String response = _readString(pointer);
    if (response.isEmpty) {
      throw const YggdrasilBridgeException(
        'Native bridge returned an empty response.',
      );
    }
    final Object? decoded = jsonDecode(response);
    if (decoded is! Map<String, dynamic>) {
      throw const YggdrasilBridgeException(
        'Native bridge returned an invalid response.',
      );
    }
    if (decoded['ok'] != true) {
      throw YggdrasilBridgeException(
        decoded['error'] as String? ?? 'Unknown native bridge error.',
      );
    }
    return decoded;
  }

  String _readString(Pointer<Utf8> pointer) {
    try {
      return pointer.toDartString();
    } finally {
      _freeString(pointer);
    }
  }

  String _extractString(Map<String, dynamic> envelope) {
    final Object? data = envelope['data'];
    if (data is! String) {
      throw const YggdrasilBridgeException(
        'Expected string payload from native bridge.',
      );
    }
    return data;
  }

  Map<String, dynamic> _extractMap(Map<String, dynamic> envelope) {
    final Object? data = envelope['data'];
    if (data is! Map<String, dynamic>) {
      throw const YggdrasilBridgeException(
        'Expected object payload from native bridge.',
      );
    }
    return data;
  }
}
