import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/chat/attachment_transfer_runner.dart';

void main() {
  test('attachment transfer runner completes when acks arrive', () async {
    final Set<int> acked = <int>{};
    final AttachmentTransferRunner runner = const AttachmentTransferRunner(
      pipelineWindow: 2,
      ackRoundTimeout: Duration(milliseconds: 120),
      ackPollInterval: Duration(milliseconds: 10),
      maxRounds: 2,
    );

    final AttachmentTransferDispatchResult result = await runner.run(
      loadState: () async => AttachmentTransferDispatchState(
        chunkCount: 3,
        ackedChunkIndexes: acked,
      ),
      sendChunk: (int chunkIndex) async {
        acked.add(chunkIndex);
        return true;
      },
    );

    expect(result, AttachmentTransferDispatchResult.completed);
    expect(acked, <int>{0, 1, 2});
  });

  test('attachment transfer runner reports send failures', () async {
    final AttachmentTransferRunner runner = const AttachmentTransferRunner(
      pipelineWindow: 2,
      ackRoundTimeout: Duration(milliseconds: 40),
      ackPollInterval: Duration(milliseconds: 10),
      maxRounds: 1,
    );

    final AttachmentTransferDispatchResult result = await runner.run(
      loadState: () async => AttachmentTransferDispatchState(
        chunkCount: 2,
        ackedChunkIndexes: const <int>[],
      ),
      sendChunk: (int chunkIndex) async => chunkIndex == 0,
    );

    expect(result, AttachmentTransferDispatchResult.sendFailed);
  });
}
