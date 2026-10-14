import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:zen/src/features/runtime/yggdrasil_signal_transport.dart';

abstract interface class NodeSignalBridge implements NativeSignalBridge {
  String generateConfigJson();

  Map<String, dynamic> startNode(String configJson);

  Map<String, dynamic> stopNode(int handle);

  Map<String, dynamic> getNodeInfo(int handle);

  /// Adds a mesh peer (e.g. a bridge learnt from friends) at runtime.
  Map<String, dynamic> addPeer(int handle, String uri);
}

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
        // The APK only ships arm64-v8a native libs — surface a readable cause
        // instead of a raw FFI lookup error.
        throw YggdrasilBridgeException(
          'Could not load libyggdrasil_bridge.so — the device ABI may not be '
          'supported (the app bundles arm64-v8a only). Cause: $error',
        );
      }
    }
    if (Platform.isWindows) {
      // Absolute candidates only; no bare-name lookup and no paths escaping
      // the executable/project directory, so a writable CWD or a sibling
      // directory cannot smuggle a malicious DLL into the search.
      final String exeDirectory = File(
        Platform.resolvedExecutable,
      ).parent.absolute.path;
      final String currentDirectory = Directory.current.absolute.path;
      final List<String> candidates = <String>[
        '$exeDirectory\\yggdrasil_bridge.dll',
        '$currentDirectory\\native\\yggdrasil_bridge\\bin\\yggdrasil_bridge.dll',
        if (currentDirectory != exeDirectory)
          '$currentDirectory\\yggdrasil_bridge.dll',
      ];
      for (final String candidate in candidates) {
        if (File(candidate).existsSync()) {
          return DynamicLibrary.open(candidate);
        }
      }
      throw YggdrasilBridgeException(
        'Could not locate yggdrasil_bridge.dll. Checked: ${candidates.join(', ')}',
      );
    }
    if (Platform.isIOS) {
      // iOS: the bridge is a static library linked into the app itself
      // (ios/Flutter/GoBridge.xcconfig), so its functions live in the
      // process. A build without it fails here with a readable cause.
      final DynamicLibrary process = DynamicLibrary.process();
      if (!process.providesSymbol('YggStartNode')) {
        throw const YggdrasilBridgeException(
          'The Go bridge is not linked into this iOS build '
          '(build it with native/yggdrasil_bridge/build_ios.sh).',
        );
      }
      return process;
    }
    throw const YggdrasilBridgeException(
      'Signal bridge is currently supported on Windows, Android and iOS only.',
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
