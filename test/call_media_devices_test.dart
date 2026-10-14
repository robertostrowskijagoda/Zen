import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/calls/call_media_devices.dart';
import 'package:zen/src/features/calls/call_media_session.dart';

void main() {
  test('keeps every microphone instead of collapsing unnamed ones', () {
    final List<CallMediaDevice> devices = catalogCallMediaDevices(
      raw: const <RawCallMediaDevice>[
        RawCallMediaDevice(id: 'mic-a', label: '', kind: 'audioinput'),
        RawCallMediaDevice(id: 'mic-b', label: '', kind: 'audioinput'),
        RawCallMediaDevice(
          id: 'mic-c',
          label: 'Headset Microphone',
          kind: 'audioinput',
        ),
        RawCallMediaDevice(
          id: 'cam-front',
          label: 'Front Camera',
          kind: 'videoinput',
        ),
        RawCallMediaDevice(id: 'cam-back', label: '', kind: 'video'),
      ],
    );

    expect(
      devices
          .where(
            (CallMediaDevice d) => d.kind == CallMediaDeviceKind.microphone,
          )
          .map((CallMediaDevice d) => d.label)
          .toList(),
      <String>['Mikrofon 1', 'Mikrofon 2', 'Headset Microphone'],
    );
    expect(
      devices
          .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.camera)
          .map((CallMediaDevice d) => d.label)
          .toList(),
      <String>['Front Camera', 'Kamera 2'],
    );
  });

  test('adds speaker and earpiece on phones when Android reports none', () {
    final List<CallMediaDevice> devices = catalogCallMediaDevices(
      raw: const <RawCallMediaDevice>[
        RawCallMediaDevice(id: 'mic-a', label: 'Mic', kind: 'audioinput'),
      ],
      includeMobileAudioOutputs: true,
    );

    expect(
      devices
          .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.speaker)
          .map((CallMediaDevice d) => d.id)
          .toList(),
      <String>['speakerphone', 'earpiece'],
    );
  });

  test('does not duplicate speakerphone when the OS already listed it', () {
    final List<CallMediaDevice> devices = catalogCallMediaDevices(
      raw: const <RawCallMediaDevice>[
        RawCallMediaDevice(
          id: 'speakerphone',
          label: 'Speaker',
          kind: 'audiooutput',
        ),
      ],
      includeMobileAudioOutputs: true,
    );

    expect(
      devices
          .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.speaker)
          .map((CallMediaDevice d) => d.id)
          .toList(),
      <String>['earpiece', 'speakerphone'],
    );
  });

  test('dedupes the same device id reported twice', () {
    final List<CallMediaDevice> devices = catalogCallMediaDevices(
      raw: const <RawCallMediaDevice>[
        RawCallMediaDevice(id: 'mic-a', label: 'Mic', kind: 'audioinput'),
        RawCallMediaDevice(id: 'mic-a', label: 'Mic copy', kind: 'audioinput'),
      ],
    );

    expect(
      devices.where(
        (CallMediaDevice d) => d.kind == CallMediaDeviceKind.microphone,
      ),
      hasLength(1),
    );
  });

  test('filters 4 mobile cameras down to exactly 2 (front and back)', () {
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
          label: 'camera 2, facing back',
          kind: 'videoinput',
        ),
        RawCallMediaDevice(
          id: '3',
          label: 'camera 3, facing back',
          kind: 'videoinput',
        ),
      ],
      filterMobileCameras: true,
    );

    final List<CallMediaDevice> cameras = devices
        .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.camera)
        .toList();

    expect(cameras, hasLength(2));
    expect(cameras[0].label, 'Kamera przednia');
    expect(cameras[0].id, '1');
    expect(cameras[1].label, 'Kamera tylna');
    expect(cameras[1].id, '0');
  });

  test('handles numeric 0 and 1 IDs without labels on mobile', () {
    final List<CallMediaDevice> devices = catalogCallMediaDevices(
      raw: const <RawCallMediaDevice>[
        RawCallMediaDevice(id: '0', label: '', kind: 'videoinput'),
        RawCallMediaDevice(id: '1', label: '', kind: 'videoinput'),
      ],
      filterMobileCameras: true,
    );

    final List<CallMediaDevice> cameras = devices
        .where((CallMediaDevice d) => d.kind == CallMediaDeviceKind.camera)
        .toList();

    expect(cameras, hasLength(2));
    expect(cameras[0].label, 'Kamera przednia');
    expect(cameras[0].id, '1');
    expect(cameras[1].label, 'Kamera tylna');
    expect(cameras[1].id, '0');
  });
}
