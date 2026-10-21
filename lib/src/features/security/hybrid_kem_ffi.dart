import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

typedef _JsonCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

/// [HybridKem] of the Go bridge (`pq_exports.go`): the calls are
/// synchronous and take well under a millisecond; they run only when a
/// session or a seal key is made, never per message.
final class BridgeHybridKem implements HybridKem {
  BridgeHybridKem.fromLibrary(DynamicLibrary library)
    : _publicKey = library.lookupFunction<_JsonCall, _JsonCall>(
        'YggPqPublicKeyJson',
      ),
      _encapsulate = library.lookupFunction<_JsonCall, _JsonCall>(
        'YggPqEncapsulateJson',
      ),
      _decapsulate = library.lookupFunction<_JsonCall, _JsonCall>(
        'YggPqDecapsulateJson',
      ),
      _free = library.lookupFunction<_NativeFree, _DartFree>('YggFreeString');

  /// The bridge this process loads anyway (yggdrasil_bridge_ffi.dart).
  static BridgeHybridKem load() =>
      BridgeHybridKem.fromLibrary(YggdrasilBridgeFfi.openLibrary());

  final _JsonCall _publicKey;
  final _JsonCall _encapsulate;
  final _JsonCall _decapsulate;
  final _DartFree _free;

  @override
  Future<Uint8List> publicKeyOf(Uint8List seed) async {
    final Map<String, dynamic> data = _call(_publicKey, <String, String>{
      'seed': base64.encode(seed),
    });
    return _bytes(data['publicKey'], kHybridPublicKeyBytes);
  }

  @override
  Future<HybridEncapsulation> encapsulate(
    Uint8List publicKey, {
    required List<int> info,
  }) async {
    final Map<String, dynamic> data = _call(_encapsulate, <String, String>{
      'publicKey': base64.encode(publicKey),
      'info': base64.encode(info),
    });
    return HybridEncapsulation(
      ciphertext: _bytes(data['ciphertext'], kHybridCiphertextBytes),
      secret: _bytes(data['secret'], kHybridSecretBytes),
    );
  }

  @override
  Future<Uint8List> decapsulate(
    Uint8List seed,
    Uint8List ciphertext, {
    required List<int> info,
  }) async {
    final Map<String, dynamic> data = _call(_decapsulate, <String, String>{
      'seed': base64.encode(seed),
      'ciphertext': base64.encode(ciphertext),
      'info': base64.encode(info),
    });
    return _bytes(data['secret'], kHybridSecretBytes);
  }

  Map<String, dynamic> _call(_JsonCall call, Map<String, String> request) {
    final Pointer<Utf8> native = jsonEncode(request).toNativeUtf8();
    try {
      final Object? decoded = jsonDecode(_read(call(native)));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('The bridge KEM gave no object.');
      }
      if (decoded['ok'] != true) {
        throw FormatException(
          decoded['error'] as String? ?? 'The bridge KEM failed.',
        );
      }
      final Object? data = decoded['data'];
      if (data is! Map<String, dynamic>) {
        throw const FormatException('The bridge KEM gave no data.');
      }
      return data;
    } finally {
      malloc.free(native);
    }
  }

  String _read(Pointer<Utf8> result) {
    try {
      return result.toDartString();
    } finally {
      _free(result);
    }
  }

  static Uint8List _bytes(Object? value, int length) {
    if (value is! String) {
      throw const FormatException('The bridge KEM gave no bytes.');
    }
    final Uint8List bytes = base64.decode(value);
    if (bytes.length != length) {
      throw FormatException('The bridge KEM gave ${bytes.length} bytes.');
    }
    return bytes;
  }
}
