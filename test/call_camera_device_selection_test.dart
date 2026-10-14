import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/calls/call_media_devices.dart';
import 'package:zen/src/features/calls/call_media_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Call media device selection & constraints', () {
    test('catalogCallMediaDevices catalogs cameras with distinct labels', () {
      final List<CallMediaDevice> devices = catalogCallMediaDevices(
        raw: const <RawCallMediaDevice>[
          RawCallMediaDevice(id: '0', label: 'Back Camera', kind: 'videoinput'),
          RawCallMediaDevice(
            id: '1',
            label: 'Front Camera',
            kind: 'videoinput',
          ),
          RawCallMediaDevice(
            id: 'default',
            label: 'Default Mic',
            kind: 'audioinput',
          ),
        ],
      );

      final List<CallMediaDevice> cameras = devices
          .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.camera)
          .toList();
      expect(cameras, hasLength(2));
      expect(cameras[0].id, '0');
      expect(cameras[0].label, 'Back Camera');
      expect(cameras[1].id, '1');
      expect(cameras[1].label, 'Front Camera');
    });

    test(
      'catalogCallMediaDevices assigns numbered fallbacks for empty camera labels',
      () {
        final List<CallMediaDevice> devices = catalogCallMediaDevices(
          raw: const <RawCallMediaDevice>[
            RawCallMediaDevice(id: '0', label: '', kind: 'videoinput'),
            RawCallMediaDevice(id: '1', label: '', kind: 'videoinput'),
          ],
        );

        final List<CallMediaDevice> cameras = devices
            .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.camera)
            .toList();
        expect(cameras, hasLength(2));
        expect(cameras[0].label, 'Kamera 1');
        expect(cameras[1].label, 'Kamera 2');
      },
    );

    test(
      'catalogCallMediaDevices filters 4 raw mobile cameras down to front and back',
      () {
        final List<CallMediaDevice> devices = catalogCallMediaDevices(
          raw: const <RawCallMediaDevice>[
            RawCallMediaDevice(
              id: '0',
              label: 'camera 0, facing back',
              kind: 'videoinput',
            ),
            RawCallMediaDevice(
              id: '1',
              label: 'camera 1, facing front',
              kind: 'videoinput',
            ),
            RawCallMediaDevice(
              id: '2',
              label: 'camera 2, facing back (wide)',
              kind: 'videoinput',
            ),
            RawCallMediaDevice(
              id: '3',
              label: 'camera 3, facing back (macro)',
              kind: 'videoinput',
            ),
          ],
          filterMobileCameras: true,
        );

        final List<CallMediaDevice> cameras = devices
            .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.camera)
            .toList();
        expect(cameras, hasLength(2));
        expect(cameras[0].id, '1');
        expect(cameras[0].label, 'Kamera przednia');
        expect(cameras[1].id, '0');
        expect(cameras[1].label, 'Kamera tylna');
      },
    );

    test(
      'buildVideoConstraints passes deviceId as plain String, not a Map (prevents Android ClassCastException)',
      () {
        final Map<String, dynamic> constraints =
            buildVideoConstraintsForTesting(deviceId: 'camera_front_1');
        expect(constraints['deviceId'], isA<String>());
        expect(constraints['deviceId'], 'camera_front_1');
        expect(constraints['deviceId'] is Map, isFalse);
      },
    );

    test('buildVideoConstraints handles null or empty deviceId safely', () {
      final Map<String, dynamic> nullConstraints =
          buildVideoConstraintsForTesting(deviceId: null);
      expect(nullConstraints.containsKey('deviceId'), isFalse);

      final Map<String, dynamic> emptyConstraints =
          buildVideoConstraintsForTesting(deviceId: '');
      expect(emptyConstraints.containsKey('deviceId'), isFalse);
    });

    test(
      'buildAudioConstraints passes deviceId as plain String and configures defaults',
      () {
        final Map<String, dynamic> constraints =
            buildAudioConstraintsForTesting(deviceId: 'mic_input_2');
        expect(constraints['deviceId'], isA<String>());
        expect(constraints['deviceId'], 'mic_input_2');
        expect(constraints['deviceId'] is Map, isFalse);
        expect(constraints['echoCancellation'], isTrue);
      },
    );
  });
}
