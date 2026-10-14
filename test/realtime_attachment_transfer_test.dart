import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/chat/realtime_attachment_transfer.dart';

void main() {
  test('realtime attachment transfer keeps safe chunk size', () {
    expect(kRealtimeAttachmentChunkSizeBytes, lessThanOrEqualTo(64 * 1024));
  });

  test('realtime attachment transfer limits buffered bytes', () {
    expect(
      kRealtimeAttachmentBufferedAmountLimitBytes,
      lessThanOrEqualTo(2 * 1024 * 1024),
    );
  });

  test('realtime attachment progress skips tiny rapid updates', () {
    expect(
      shouldEmitRealtimeAttachmentProgressUpdate(
        previousProgress: 0.10,
        nextProgress: 0.105,
        elapsedSinceLastUpdate: const Duration(milliseconds: 40),
      ),
      isFalse,
    );
  });

  test('realtime attachment progress updates after enough delta or time', () {
    expect(
      shouldEmitRealtimeAttachmentProgressUpdate(
        previousProgress: 0.10,
        nextProgress: 0.12,
        elapsedSinceLastUpdate: const Duration(milliseconds: 40),
      ),
      isTrue,
    );
    expect(
      shouldEmitRealtimeAttachmentProgressUpdate(
        previousProgress: 0.20,
        nextProgress: 0.205,
        elapsedSinceLastUpdate: const Duration(milliseconds: 150),
      ),
      isTrue,
    );
  });
}
