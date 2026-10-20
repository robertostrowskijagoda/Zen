import 'package:zen/src/domain/messages/chat_message.dart';

/// Id prefix of group messages that are posts on the group board (§13).
///
/// The board is a view over the ordinary group messages: a post is a group
/// message whose id starts with this prefix. The id travels in the existing
/// `group_message` signal (`msgId`) and is stored with the message, so
/// nothing changes on the wire or on disk; peers that predate the board just
/// show the post as a normal group message.
const String kGroupBoardIdPrefix = 'grp-board-';

/// Longest post on the board (the group message limit still applies).
const int kMaxBoardPostChars = 2000;

/// The id of a new board post.
String newBoardPostId({required int timestamp, required String groupId}) =>
    '$kGroupBoardIdPrefix$timestamp-$groupId';

/// Whether [message] is a post on the group board.
bool isBoardPost(ChatMessage message) =>
    !message.isSystem && message.id.startsWith(kGroupBoardIdPrefix);

/// The board posts among [messages], newest first.
List<ChatMessage> boardPostsOf(List<ChatMessage> messages) {
  final List<ChatMessage> posts = messages.where(isBoardPost).toList();
  posts.sort(
    (ChatMessage a, ChatMessage b) => b.sentAtMillis.compareTo(a.sentAtMillis),
  );
  return posts;
}
