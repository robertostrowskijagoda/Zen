import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/calls/call_audio_route.dart';

void main() {
  test('a connected headset is chosen over the earpiece, whatever the order '
      'Android lists the outputs in', () {
    expect(
      callHeadsetOutput(<String>['earpiece', 'speaker', 'bluetooth']),
      'bluetooth',
    );
    expect(
      callHeadsetOutput(<String>['earpiece', 'wired-headset', 'bluetooth']),
      'bluetooth',
    );
    expect(
      callHeadsetOutput(<String>['wired-headset', 'earpiece']),
      'wired-headset',
    );
    expect(callHeadsetOutput(<String>['earpiece', 'speaker']), isNull);
  });
}
