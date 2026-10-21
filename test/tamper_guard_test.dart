import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/hybrid_signature_ffi.dart';
import 'package:zen/src/features/security/device_integrity.dart';

import 'support/pyramid_world.dart';

void main() {
  tearDown(TamperGuard.reset);

  test('findings inside the process count as tampering, root only warns', () {
    final DeviceIntegrity rooted = DeviceIntegrity.fromMap(<Object?, Object?>{
      'rooted': true,
      'reasons': <Object?>['su', 'emulator'],
      'emulator': true,
    });
    expect(rooted.hasWarning, isTrue);
    expect(rooted.tampered, isFalse);
    expect(rooted.emulator, isTrue);

    final DeviceIntegrity hooked = DeviceIntegrity.fromMap(<Object?, Object?>{
      'reasons': <Object?>['hooks'],
    });
    expect(hooked.tampered, isTrue);
    expect(hooked.hasWarning, isTrue);
    expect(hooked.describe().single, contains('Xposed'));
    expect(
      DeviceIntegrity.fromMap(const <Object?, Object?>{
        'tampered': true,
      }).tampered,
      isTrue,
    );

    // A debuggable copy is a modified one in a release build only.
    expect(
      DeviceIntegrity.fromMap(const <Object?, Object?>{
        'debuggable': true,
      }, release: false).tampered,
      isFalse,
    );
    final DeviceIntegrity debuggable = DeviceIntegrity.fromMap(
      const <Object?, Object?>{'debuggable': true},
      release: true,
    );
    expect(debuggable.tampered, isTrue);
    expect(debuggable.reasons, contains('app-debuggable'));

    final DeviceIntegrity resigned = DeviceIntegrity.clean.withTampering(
      const <String>['resigned'],
    );
    expect(resigned.tampered, isTrue);
    expect(resigned.describe().single, contains('certyfikatem'));
    expect(
      DeviceIntegrity.clean.withTampering(const <String>[]),
      same(DeviceIntegrity.clean),
    );
  });

  test('a debugger is read from TracerPid', () {
    expect(tracedFromStatus('Name:\tzen\nTracerPid:\t0\n'), isFalse);
    expect(tracedFromStatus('Name:\tzen\nTracerPid:\t4242\n'), isTrue);
    expect(tracedFromStatus('Name:\tzen\n'), isFalse);
  });

  test(
    'payments and the power key wait while someone is inside the process',
    () async {
      int checks = 0;
      DeviceIntegrity found = DeviceIntegrity.fromMap(<Object?, Object?>{
        'reasons': <Object?>['debugger'],
      });
      TamperGuard.debugCheck = () async {
        checks++;
        return found;
      };
      expect(await TamperGuard.allowsSensitive(), isFalse);
      expect(await TamperGuard.allowsSensitive(), isFalse);
      expect(checks, 1, reason: 'one check counts for a minute');
      expect(TamperGuard.last.reasons, <String>['debugger']);

      TamperGuard.reset();
      found = DeviceIntegrity.fromMap(<Object?, Object?>{
        'rooted': true,
        'reasons': <Object?>['su'],
      });
      TamperGuard.debugCheck = () async => found;
      expect(await TamperGuard.allowsSensitive(), isTrue, reason: 'a warning');

      // A check that fails blocks nothing.
      TamperGuard.reset();
      TamperGuard.debugCheck = () async => throw StateError('no channel');
      expect(await TamperGuard.allowsSensitive(), isTrue);
    },
  );

  test(
    'a pyramid payment is refused while the process is tampered with',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      // Founding the pyramid checked (and remembered) a clean process.
      TamperGuard.reset();
      int asked = 0;
      TamperGuard.debugCheck = () async {
        asked++;
        return DeviceIntegrity.fromMap(<Object?, Object?>{
          'reasons': <Object?>['frida-loaded'],
        });
      };
      expect(await w['A1'].pay(w['B1'].myKey!, 100), isNull);
      expect(asked, 1);
    },
  );

  test('the native copy of a bridge request is overwritten', () {
    final Pointer<Utf8> text = 'seed: secret'.toNativeUtf8();
    final int length = text.length;
    wipeNativeUtf8(text);
    expect(text.cast<Uint8>().asTypedList(length), everyElement(0));
    malloc.free(text);
    wipeNativeUtf8(nullptr);
  });
}
