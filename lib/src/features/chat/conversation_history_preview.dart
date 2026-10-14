import 'package:flutter/foundation.dart';

@immutable
final class ConversationHistoryPreview {
  const ConversationHistoryPreview({
    required this.messageCount,
    required this.attachmentBytes,
  });

  final int messageCount;
  final int attachmentBytes;

  bool get hasEntries => messageCount > 0;
}
