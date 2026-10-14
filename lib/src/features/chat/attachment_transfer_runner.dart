import 'dart:math' as math;

enum AttachmentTransferDispatchResult {
  completed,
  cancelled,
  incomplete,
  sendFailed,
}

final class AttachmentTransferDispatchState {
  AttachmentTransferDispatchState({
    required this.chunkCount,
    required Iterable<int> ackedChunkIndexes,
  }) : ackedChunkIndexes = Set<int>.unmodifiable(ackedChunkIndexes.toSet());

  final int chunkCount;
  final Set<int> ackedChunkIndexes;

  bool get isComplete =>
      chunkCount > 0 && ackedChunkIndexes.length >= chunkCount;

  bool hasAckedAll(Iterable<int> chunkIndexes) {
    return chunkIndexes.every(ackedChunkIndexes.contains);
  }

  List<int> pendingChunkIndexes() {
    if (chunkCount <= 0) {
      return const <int>[];
    }
    return List<int>.generate(
      chunkCount,
      (int index) => index,
    ).where((int index) => !ackedChunkIndexes.contains(index)).toList();
  }
}

typedef LoadAttachmentTransferDispatchState =
    Future<AttachmentTransferDispatchState?> Function();
typedef SendAttachmentTransferChunk = Future<bool> Function(int chunkIndex);

final class AttachmentTransferRunner {
  const AttachmentTransferRunner({
    this.pipelineWindow = 8,
    this.ackRoundTimeout = const Duration(milliseconds: 1500),
    this.ackPollInterval = const Duration(milliseconds: 40),
    this.maxRounds = 5,
  });

  final int pipelineWindow;
  final Duration ackRoundTimeout;
  final Duration ackPollInterval;
  final int maxRounds;

  Future<AttachmentTransferDispatchResult> run({
    required LoadAttachmentTransferDispatchState loadState,
    required SendAttachmentTransferChunk sendChunk,
  }) async {
    AttachmentTransferDispatchState? state = await loadState();
    if (state == null) {
      return AttachmentTransferDispatchResult.cancelled;
    }
    if (state.chunkCount <= 0) {
      return AttachmentTransferDispatchResult.incomplete;
    }
    if (state.isComplete) {
      return AttachmentTransferDispatchResult.completed;
    }

    List<int> pendingChunkIndexes = state.pendingChunkIndexes();
    for (int round = 0; round < maxRounds; round += 1) {
      if (pendingChunkIndexes.isEmpty) {
        return AttachmentTransferDispatchResult.completed;
      }
      for (
        int start = 0;
        start < pendingChunkIndexes.length;
        start += pipelineWindow
      ) {
        final int end = math.min(
          start + pipelineWindow,
          pendingChunkIndexes.length,
        );
        final List<int> batch = pendingChunkIndexes.sublist(start, end);
        final List<bool> results = await Future.wait(batch.map(sendChunk));
        if (results.any((bool sent) => !sent)) {
          return AttachmentTransferDispatchResult.sendFailed;
        }
      }
      state = await _waitForAckProgress(
        loadState: loadState,
        awaitedChunkIndexes: pendingChunkIndexes,
      );
      if (state == null) {
        return AttachmentTransferDispatchResult.cancelled;
      }
      if (state.isComplete) {
        return AttachmentTransferDispatchResult.completed;
      }
      pendingChunkIndexes = state.pendingChunkIndexes();
    }
    return AttachmentTransferDispatchResult.incomplete;
  }

  Future<AttachmentTransferDispatchState?> _waitForAckProgress({
    required LoadAttachmentTransferDispatchState loadState,
    required List<int> awaitedChunkIndexes,
  }) async {
    final DateTime deadline = DateTime.now().add(ackRoundTimeout);
    AttachmentTransferDispatchState? state = await loadState();
    if (state == null ||
        state.isComplete ||
        state.hasAckedAll(awaitedChunkIndexes)) {
      return state;
    }

    while (DateTime.now().isBefore(deadline)) {
      final Duration remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        break;
      }
      await Future<void>.delayed(
        remaining < ackPollInterval ? remaining : ackPollInterval,
      );
      state = await loadState();
      if (state == null ||
          state.isComplete ||
          state.hasAckedAll(awaitedChunkIndexes)) {
        return state;
      }
    }
    return loadState();
  }
}
