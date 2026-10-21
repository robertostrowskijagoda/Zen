import 'package:flutter/foundation.dart';

/// The chips over the Tablica: „Wszystko · Znajomi · Piramida · Kraj”.
enum FeedFilter {
  /// Friends' posts and the pyramid's important ones, by time.
  all,

  /// Friends' and followed people's posts only.
  friends,

  /// The pyramid's posts in its order (§22.1) and the open referenda.
  pyramid,

  /// The national section (only here, never under [all]).
  national;

  /// [name] read back; [all] for anything else.
  static FeedFilter parse(String? name) => FeedFilter.values.firstWhere(
    (FeedFilter f) => f.name == name,
    orElse: () => FeedFilter.all,
  );
}

/// A filter another part of the app asked the Tablica for: the screen takes
/// it (and sets it back to null) when it is built or already shown.
final ValueNotifier<FeedFilter?> feedFilterRequest = ValueNotifier<FeedFilter?>(
  null,
);

/// Bumped with every [openFeed]: the shell switches to the Tablica.
final ValueNotifier<int> feedOpenRequest = ValueNotifier<int>(0);

/// Shows the Tablica with [filter] on (the Pyramid's „Otwórz na Tablicy”,
/// a tap on the pyramid's notification).
void openFeed(FeedFilter filter) {
  feedFilterRequest.value = filter;
  feedOpenRequest.value++;
}
