import 'package:zen/src/features/feed/feed_items.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/search/search_text.dart';
import 'package:zen/src/features/social/mentions.dart';

/// What the search on the Tablica looks at in [item]: the text of a post
/// (names in place of mentions), who wrote it and the comments under it
/// that this device has. A referendum by its question; an alarm stays on
/// top whatever is searched.
String feedSearchText(FeedItem item) => switch (item) {
  FeedFriendItem(:final FeedPost post) => <String>[
    post.authorLabel,
    mentionsAsPlainText(post.text, post.mentions),
    for (final FeedComment c in post.comments)
      if (!c.hiddenByAuthor) ...<String>[
        c.authorLabel,
        mentionsAsPlainText(c.text, c.mentions),
      ],
  ].join('\n'),
  FeedPyramidItem(:final post) => <String>[
    post.name,
    post.text,
    for (final PyrComment c in post.comments) c.text,
  ].join('\n'),
  FeedReferendumItem(:final referendum) => referendum.question,
  FeedAlarmItem() => '',
};

/// The cards of [items] that [query] finds (all of them for an empty
/// query); alarms always stay.
List<FeedItem> searchFeed(List<FeedItem> items, SearchQuery query) {
  if (query.isEmpty) {
    return items;
  }
  return <FeedItem>[
    for (final FeedItem item in items)
      if (item is FeedAlarmItem || query.matches(feedSearchText(item))) item,
  ];
}
