import 'package:flutter/foundation.dart';

/// The chips over the Tablica: „Wszystko · Znajomi · 2. stopień ·
/// 3. stopień · Przyjaciele · Piramida · Kraj”. „Znajomi”, „2. stopień”
/// and „3. stopień” also say how far the reader looks ([depth]): kept on
/// the device, it holds under „Wszystko” too.
enum FeedFilter {
  /// Friends' posts (and from further away as far as the reader looks)
  /// and the pyramid's important ones, by time.
  all,

  /// Friends' and followed people's posts (and friends' reshares) only.
  friends,

  /// Also posts of friends of friends, passed on by friends' notices.
  second,

  /// Also posts three steps away, passed on the same way.
  third,

  /// Posts of the friends marked "Przyjaciel" only.
  close,

  /// The pyramid's posts in its order (§22.1) and the open referenda.
  pyramid,

  /// The national section (only here, never under [all]).
  national;

  /// How far a reader who picked this looks, in steps of friendship from
  /// the authors; `null` for a chip that leaves it as it was.
  int? get depth => switch (this) {
    FeedFilter.friends => 1,
    FeedFilter.second => 2,
    FeedFilter.third => 3,
    _ => null,
  };

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
