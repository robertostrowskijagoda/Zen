import 'package:flutter/foundation.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';

/// One card of the Tablica: a friend's post, a pyramid post, an open
/// referendum or an alarm in force.
@immutable
sealed class FeedItem {
  const FeedItem();

  /// Unique on the Tablica: one content, one card.
  String get id;
}

/// A friend's (or a followed person's) post.
final class FeedFriendItem extends FeedItem {
  const FeedFriendItem(this.post);

  final FeedPost post;

  @override
  String get id => post.id;
}

/// A pyramid post, made from its record while the list is built (never
/// copied into a log).
final class FeedPyramidItem extends FeedItem {
  const FeedPyramidItem(this.post);

  final PyrFeedPost post;

  @override
  String get id => post.id;
}

/// „Referendum: … · Głosuj →”: one votes in the Pyramid.
final class FeedReferendumItem extends FeedItem {
  const FeedReferendumItem(this.referendum);

  final PyrFeedReferendum referendum;

  @override
  String get id => 'ref-${referendum.id}';
}

/// The red bar of an alarm on top, in every filter.
final class FeedAlarmItem extends FeedItem {
  const FeedAlarmItem(this.alarm);

  final PyrFeedAlarm alarm;

  @override
  String get id => 'alarm-${alarm.id}';
}

/// The chips the Tablica shows for [pyramid]: „Piramida” and „Kraj” only
/// when there is something of them (always for a member). Empty when there
/// is nothing to choose between (friends' posts only).
List<FeedFilter> feedFiltersFor(PyramidFeed pyramid) {
  final List<FeedFilter> out = <FeedFilter>[
    FeedFilter.all,
    FeedFilter.friends,
    if (pyramid.showsPyramid) FeedFilter.pyramid,
    if (pyramid.showsNational) FeedFilter.national,
  ];
  return out.length > 2 ? out : const <FeedFilter>[];
}

typedef _Timed = ({int at, FeedItem item});

/// What the Tablica shows under [filter]:
/// - every filter starts with the alarms in force;
/// - „Wszystko”: the open referenda, then one timeline, newest first, of
///   [wall] and the pyramid's important posts (the top, the line up) —
///   never the national section nor one's own pyramid posts;
/// - „Znajomi”: [wall] only;
/// - „Piramida”: the referenda, then the pyramid's posts as §22.1 orders
///   them (the top, then the line from the highest);
/// - „Kraj”: the national section only.
/// A content is there once, whatever the sources hold.
List<FeedItem> composeFeed(
  FeedFilter filter, {
  required List<FeedPost> wall,
  required PyramidFeed pyramid,
}) {
  final Set<String> seen = <String>{};
  final List<FeedItem> out = <FeedItem>[];
  void add(FeedItem item) {
    if (seen.add(item.id)) {
      out.add(item);
    }
  }

  for (final PyrFeedAlarm a in pyramid.alarms) {
    add(FeedAlarmItem(a));
  }
  if (filter == FeedFilter.all || filter == FeedFilter.pyramid) {
    for (final PyrFeedReferendum r in pyramid.referenda) {
      add(FeedReferendumItem(r));
    }
  }
  switch (filter) {
    case FeedFilter.all:
      final List<_Timed> timeline = <_Timed>[
        for (final FeedPost p in wall)
          (at: p.sortMillis, item: FeedFriendItem(p)),
        for (final PyrFeedPost p in pyramid.important)
          (at: p.at, item: FeedPyramidItem(p)),
      ]..sort((_Timed a, _Timed b) => b.at.compareTo(a.at));
      for (final _Timed x in timeline) {
        add(x.item);
      }
    case FeedFilter.friends:
      for (final FeedPost p in wall) {
        add(FeedFriendItem(p));
      }
    case FeedFilter.pyramid:
      for (final PyrFeedPost p in pyramid.pyramid) {
        add(FeedPyramidItem(p));
      }
    case FeedFilter.national:
      for (final PyrFeedPost p in pyramid.national) {
        add(FeedPyramidItem(p));
      }
  }
  return out;
}
