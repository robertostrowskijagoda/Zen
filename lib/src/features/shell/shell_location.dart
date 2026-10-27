import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';

/// A page the app can open again by itself after it was closed: a
/// conversation, a group, the settings. Only a kind and an id (an address, a
/// group id) are kept, never anything that is shown on the page.
@immutable
final class ShellPlace {
  const ShellPlace(this.kind, [this.id = '']);

  /// A conversation with one person; [id] is their address.
  const ShellPlace.peerChat(String address) : this(peerChatKind, address);

  /// A group's conversation; [id] is the group id.
  const ShellPlace.groupChat(String groupId) : this(groupChatKind, groupId);

  /// The settings page.
  static const ShellPlace settings = ShellPlace(settingsKind);

  static const String peerChatKind = 'peer';
  static const String groupChatKind = 'group';
  static const String settingsKind = 'settings';

  final String kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is ShellPlace && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// Where a conversation was scrolled to: the message at the edge of the
/// screen and how far it sat from that edge. A raw pixel offset would not
/// survive new messages and lazily built lists.
@immutable
final class ChatAnchor {
  const ChatAnchor(this.messageId, this.offset);

  final String messageId;
  final double offset;

  @override
  bool operator ==(Object other) =>
      other is ChatAnchor &&
      other.messageId == messageId &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(messageId, offset);
}

/// What an open page remembers of itself.
@immutable
final class PlaceMemory {
  const PlaceMemory({this.scroll = 0, this.anchor});

  /// How far a plain page (the settings) was scrolled.
  final double scroll;

  /// Where a conversation was scrolled to; `null`: at the latest message.
  final ChatAnchor? anchor;
}

/// The last place of the app: the open tab and how far its list was
/// scrolled, and the page open above it (if any).
@immutable
final class ShellLocation {
  const ShellLocation({
    required this.tab,
    this.tabScroll = 0,
    this.place,
    this.memory = const PlaceMemory(),
  });

  /// The id of the tab on the rail.
  final String tab;
  final double tabScroll;

  /// The topmost page that can be opened again, over the tab.
  final ShellPlace? place;
  final PlaceMemory memory;

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, Object?>{
        'tab': tab,
        'tabScroll': tabScroll,
        if (place != null)
          'place': <String, Object?>{'kind': place!.kind, 'id': place!.id},
        if (place != null && memory.scroll > 0) 'placeScroll': memory.scroll,
        if (place != null && memory.anchor != null)
          'anchor': <String, Object?>{
            'id': memory.anchor!.messageId,
            'offset': memory.anchor!.offset,
          },
      }),
    ),
  );

  /// The record stored by [encode]; `null` when it is not one.
  static ShellLocation? decode(Uint8List raw) {
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map<String, Object?>) {
        return null;
      }
      final Object? tab = json['tab'];
      if (tab is! String || tab.isEmpty) {
        return null;
      }
      final Object? place = json['place'];
      ShellPlace? shellPlace;
      if (place is Map<String, Object?>) {
        final Object? kind = place['kind'];
        final Object? id = place['id'];
        if (kind is String && kind.isNotEmpty && id is String) {
          shellPlace = ShellPlace(kind, id);
        }
      }
      final Object? anchor = json['anchor'];
      ChatAnchor? chatAnchor;
      if (shellPlace != null && anchor is Map<String, Object?>) {
        final Object? id = anchor['id'];
        final Object? offset = anchor['offset'];
        if (id is String && id.isNotEmpty && offset is num) {
          chatAnchor = ChatAnchor(id, offset.toDouble());
        }
      }
      return ShellLocation(
        tab: tab,
        tabScroll: _offset(json['tabScroll']),
        place: shellPlace,
        memory: shellPlace == null
            ? const PlaceMemory()
            : PlaceMemory(
                scroll: _offset(json['placeScroll']),
                anchor: chatAnchor,
              ),
      );
    } on Object {
      return null;
    }
  }

  static double _offset(Object? value) =>
      value is num && value.isFinite && value > 0 ? value.toDouble() : 0;
}

/// Keeps the last place of the app (the open tab, the page above it, how far
/// they were scrolled) in the account's encrypted store, so that the app,
/// closed and opened again, comes back to the same place.
///
/// The record is written a moment after the last change and at once when
/// the app leaves the screen; it holds ids and offsets only.
final class ShellLocationController with WidgetsBindingObserver {
  ShellLocationController(
    this._disk, {
    this.saveDelay = const Duration(milliseconds: 400),
  });

  /// Where the record lives, next to the other settings of the screens.
  static const String key = 'ui/last_place';

  final LedgerDisk _disk;
  final Duration saveDelay;

  String _tab = '';
  final Map<String, double> _tabScrolls = <String, double>{};
  final List<_OpenPlace> _open = <_OpenPlace>[];

  /// What the next page of the restored place gets as its memory.
  ShellPlace? _restoring;
  PlaceMemory _restoringMemory = const PlaceMemory();

  Timer? _timer;
  Uint8List? _lastSaved;
  bool _restoredOnce = false;
  bool _disposed = false;

  /// Counts what the user, a notification or a link did to the place (a tab,
  /// a page, a scroll); a restore that finds it changed gives way.
  int _changes = 0;

  int get changeCount => _changes;

  /// The first tab the app opens on (not a change: the user did nothing).
  void startOn(String tab) {
    if (_tab.isEmpty) {
      _tab = tab;
    }
  }

  void selectTab(String tab) {
    if (tab == _tab) {
      return;
    }
    _tab = tab;
    _changed();
  }

  void tabScrolled(String tab, double offset) {
    _tabScrolls[tab] = offset < 0 ? 0 : offset;
    if (tab == _tab) {
      _changed();
    }
  }

  /// A page for [place] opened on [route]; it stays the place until the
  /// route is popped. Returns what the page remembered from before the app
  /// was closed (`null` for a page the user opened now).
  PlaceMemory? openPlace(Route<dynamic> route, ShellPlace place) {
    // Pages of an app that was locked and unlocked: their routes are gone
    // without having been popped.
    _open.removeWhere((_OpenPlace o) => !o.route.isActive);
    PlaceMemory? memory;
    if (_restoring == place) {
      memory = _restoringMemory;
      _restoring = null;
      _restoringMemory = const PlaceMemory();
    }
    _open.add(_OpenPlace(route, place, memory ?? const PlaceMemory()));
    unawaited(route.popped.then((_) => _closePlace(route)));
    _changed();
    return memory;
  }

  void placeScrolled(Route<dynamic> route, double offset) {
    final _OpenPlace? open = _find(route);
    if (open == null) {
      return;
    }
    open.memory = PlaceMemory(
      scroll: offset < 0 ? 0 : offset,
      anchor: open.memory.anchor,
    );
    _changed();
  }

  /// A conversation is at [anchor]; `null`: at its latest message.
  void chatAnchored(Route<dynamic> route, ChatAnchor? anchor) {
    final _OpenPlace? open = _find(route);
    if (open == null) {
      return;
    }
    open.memory = PlaceMemory(scroll: open.memory.scroll, anchor: anchor);
    _changed();
  }

  _OpenPlace? _find(Route<dynamic> route) {
    for (final _OpenPlace o in _open) {
      if (identical(o.route, route)) {
        return o;
      }
    }
    return null;
  }

  void _closePlace(Route<dynamic> route) {
    if (_disposed) {
      return;
    }
    _open.removeWhere((_OpenPlace o) => identical(o.route, route));
    _changed();
  }

  /// The place as it is now.
  ShellLocation get current {
    final _OpenPlace? top = _open.isEmpty ? null : _open.last;
    return ShellLocation(
      tab: _tab,
      tabScroll: _tabScrolls[_tab] ?? 0,
      place: top?.place,
      memory: top?.memory ?? const PlaceMemory(),
    );
  }

  /// The stored place of the tab [tab] (0 when nothing is known).
  double tabScroll(String tab) => _tabScrolls[tab] ?? 0;

  /// Where to go back to: the place stored when the app was closed, the
  /// first time; later (the app locked and unlocked while running) the place
  /// it was at. `null` when there is none.
  ///
  /// The pages that open it ask for their own memory ([openPlace]).
  Future<ShellLocation?> restorePoint() async {
    if (_restoredOnce) {
      final ShellLocation now = current;
      return now.tab.isEmpty ? null : _arm(now);
    }
    _restoredOnce = true;
    final int mark = _changes;
    try {
      final Uint8List? raw = await _disk.read(key);
      if (raw == null || raw.isEmpty || mark != _changes || _disposed) {
        return null;
      }
      _lastSaved = raw;
      final ShellLocation? stored = ShellLocation.decode(raw);
      return stored == null ? null : _arm(stored);
    } on Object {
      return null;
    }
  }

  /// The restore is over (the place was opened, or is gone): what it armed
  /// for the page is dropped, so that a page the user opens later starts
  /// fresh.
  void restoreDone() {
    _restoring = null;
    _restoringMemory = const PlaceMemory();
  }

  ShellLocation _arm(ShellLocation location) {
    // The tab's scroll is for the page built next; the page above it takes
    // its own when it opens.
    _tabScrolls[location.tab] = location.tabScroll;
    _restoring = location.place;
    _restoringMemory = location.memory;
    return location;
  }

  void _changed() {
    _changes += 1;
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(saveDelay, () => unawaited(flush()));
  }

  /// Writes the place now, when it differs from what was written last.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    final ShellLocation now = current;
    if (now.tab.isEmpty) {
      return;
    }
    final Uint8List bytes = now.encode();
    if (_lastSaved != null && listEquals(_lastSaved, bytes)) {
      return;
    }
    _lastSaved = bytes;
    try {
      await _disk.write(key, bytes);
    } on Object {
      // A place that could not be written is only not restored.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The app may be killed without another word once it is away.
    if (state != AppLifecycleState.resumed) {
      unawaited(flush());
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    if (_timer != null) {
      unawaited(flush());
    }
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

final class _OpenPlace {
  _OpenPlace(this.route, this.place, this.memory);

  final Route<dynamic> route;
  final ShellPlace place;
  PlaceMemory memory;
}

/// The last place of the open account (the ledger's store is its own).
final Provider<ShellLocationController> shellLocationProvider =
    Provider<ShellLocationController>((Ref ref) {
      final ShellLocationController controller = ShellLocationController(
        ref.read(ledgerDiskProvider),
      );
      WidgetsBinding.instance.addObserver(controller);
      ref.onDispose(() {
        WidgetsBinding.instance.removeObserver(controller);
        controller.dispose();
      });
      return controller;
    });
