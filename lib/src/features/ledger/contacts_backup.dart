import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/logging/zen_log.dart';

// The backup of friends and groups in the account's `private` space, laid
// out so that it fits the ledger at any size the app allows and grows the
// logs friends keep as little as it can.
//
//  * Up to [kContactsWholeBytes] (some 240 friends) it is one `contacts`
//    entry, as every build since 1.14 reads it.
//  * Above that it is cut into parts ([splitContacts]): every friend,
//    group and record is an item, and the items run into parts whose ends
//    are picked by the items themselves (a part ends after an item whose
//    hash says so), so a change to one friend changes one part and the
//    others stay as they were. A set ([contactsSetOf]) names the parts it
//    is made of by their place in the same log, with a hash of the whole:
//    a reader takes a set only when every part is there and the whole
//    hashes right ([assembleContacts]), so it never mixes two backups and,
//    when the newest set is not all there, takes the one before.
//  * A new set writes only the parts that changed; the parts it keeps are
//    named from after the log's newest checkpoint only, so cutting the log
//    at a checkpoint never takes a part a later set needs.

/// Most bytes (JSON, before sealing) of a backup written as one entry:
/// sealed and signed it stays under the entry limit (`kMaxEntryBytes`).
const int kContactsWholeBytes = 40 * 1024;

/// Most bytes of one part (JSON, before sealing).
const int kContactsPartBytes = 32 * 1024;

/// A part does not end before it has this many bytes.
const int kContactsPartMinBytes = 8 * 1024;

/// After [kContactsPartMinBytes], about one item in this many ends a part.
const int kContactsPartSpread = 48;

/// Most parts of one set: with the parts' limit, room for far more than
/// the 5,000 friends, the removed friends' records and the 1,000 groups
/// a backup carries.
const int kMaxContactsParts = 256;

/// Most bytes of the removals carried over a checkpoint
/// ([contactRemovalsBody]).
const int kContactRemovalsBytes = 24 * 1024;

/// The format of a set and of its parts.
const int kContactsSetFormat = 1;

/// Key in a one-entry backup that holds only some of the friends and
/// groups ([cutContacts]): this build never takes such a backup for the
/// whole, while builds before 1.16.5 (which read only one-entry backups)
/// take in what it lists.
const String kContactsCutKey = 'cut';

/// The backup cannot be saved with friends at all (an item bigger than a
/// part, or more parts than [kMaxContactsParts]).
final class ContactsTooBigException implements Exception {
  const ContactsTooBigException(this.reason);

  final String reason;

  @override
  String toString() => 'ContactsTooBigException: $reason';
}

/// Bytes of [json] as written (UTF-8 of its JSON).
int contactsJsonBytes(Object? json) => utf8.encode(jsonEncode(json)).length;

/// Hash of [json] as written: what a set's `h` and a part's identity are.
String contactsHashOf(Object? json) => sha256Hex(utf8.encode(jsonEncode(json)));

/// A backup laid out in parts ([splitContacts]).
@immutable
final class ContactsSplit {
  const ContactsSplit({
    required this.layout,
    required this.scalars,
    required this.parts,
    required this.hash,
  });

  /// The backup's top-level keys in order, each with its shape: `l` a
  /// list, `m` a map (both cut into items), `s` anything else (kept in the
  /// set itself, [scalars]).
  final List<List<String>> layout;
  final Map<String, dynamic> scalars;

  /// The parts, `{v, i: [[key, item] or [key, name, value]…]}`, in order.
  final List<Map<String, dynamic>> parts;

  /// [contactsHashOf] the whole backup.
  final String hash;
}

/// Cuts [snapshot] into parts (see the top of this file). Throws
/// [ContactsTooBigException] when it cannot be saved this way.
ContactsSplit splitContacts(Map<String, dynamic> snapshot) {
  final List<List<String>> layout = <List<String>>[];
  final Map<String, dynamic> scalars = <String, dynamic>{};
  final List<List<Object?>> items = <List<Object?>>[];
  int index = 0;
  for (final MapEntry<String, dynamic> e in snapshot.entries) {
    final Object? value = e.value;
    if (value is List) {
      layout.add(<String>[e.key, 'l']);
      for (final Object? item in value) {
        items.add(<Object?>[index, item]);
      }
    } else if (value is Map) {
      layout.add(<String>[e.key, 'm']);
      for (final MapEntry<dynamic, dynamic> m in value.entries) {
        if (m.key is! String) {
          throw const ContactsTooBigException('a key that is not text');
        }
        items.add(<Object?>[index, m.key, m.value]);
      }
    } else {
      layout.add(<String>[e.key, 's']);
      scalars[e.key] = value;
    }
    index++;
  }
  final List<Map<String, dynamic>> parts = <Map<String, dynamic>>[];
  List<List<Object?>> current = <List<Object?>>[];
  int bytes = 0;
  void close() {
    if (current.isEmpty) {
      return;
    }
    parts.add(<String, dynamic>{'v': kContactsSetFormat, 'i': current});
    current = <List<Object?>>[];
    bytes = 0;
  }

  for (final List<Object?> item in items) {
    final String json = jsonEncode(item);
    final int size = utf8.encode(json).length + 1;
    if (size > kContactsPartBytes - 64) {
      throw const ContactsTooBigException('one item is bigger than a part');
    }
    if (current.isNotEmpty && bytes + size > kContactsPartBytes - 64) {
      close();
    }
    current.add(item);
    bytes += size;
    if (bytes >= kContactsPartMinBytes &&
        int.parse(sha256Hex(utf8.encode(json)).substring(0, 6), radix: 16) %
                kContactsPartSpread ==
            0) {
      close();
    }
  }
  close();
  if (parts.length > kMaxContactsParts) {
    throw const ContactsTooBigException('more parts than a set may have');
  }
  return ContactsSplit(
    layout: layout,
    scalars: scalars,
    parts: parts,
    hash: contactsHashOf(snapshot),
  );
}

/// Most bytes one friend or group of a backup may take for [splitContacts]
/// to fit it in a part (with room for its place in the part).
const int kContactsItemBytes = kContactsPartBytes - 64 - 16;

/// [item] (one group of a backup) with [stamps] (address → millis) under
/// [key]: the newest of them that keep the item within [budget] bytes, so
/// a record that grows (who left a group: up to 256 entries) never makes
/// the item too big for a part and the whole backup unsavable. [item] as
/// it is when none fit or there are none.
Map<String, dynamic> contactsItemWithStamps(
  Map<String, dynamic> item,
  String key,
  Map<String, int> stamps, {
  int budget = kContactsItemBytes,
}) {
  if (stamps.isEmpty) {
    return item;
  }
  final List<MapEntry<String, int>> newest = stamps.entries.toList()
    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
      final int byTime = b.value.compareTo(a.value);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
  // `,"key":{}` and, for each entry, `"address":millis,`.
  int bytes = contactsJsonBytes(item) + contactsJsonBytes(key) + 4;
  final Map<String, int> kept = <String, int>{};
  for (final MapEntry<String, int> e in newest) {
    bytes += contactsJsonBytes(e.key) + '${e.value}'.length + 2;
    if (bytes > budget) {
      break;
    }
    kept[e.key] = e.value;
  }
  return kept.isEmpty ? item : <String, dynamic>{...item, key: kept};
}

/// The set of [split] whose parts are entries [seqs] of the same log, in
/// order.
Map<String, dynamic> contactsSetOf(ContactsSplit split, List<int> seqs) =>
    <String, dynamic>{
      'v': kContactsSetFormat,
      'k': split.layout,
      's': split.scalars,
      'p': seqs,
      'h': split.hash,
    };

/// The places (sequence numbers in the set's own log) of the parts [set]
/// names; `null` when it is not a set this build reads.
List<int>? contactsSetParts(Map<String, dynamic> set) {
  final Object? p = set['p'];
  if (set['v'] != kContactsSetFormat ||
      p is! List ||
      p.isEmpty ||
      p.length > kMaxContactsParts ||
      !p.every((Object? seq) => seq is int && seq > 0)) {
    return null;
  }
  return p.cast<int>();
}

/// The backup [set] stands for, put together from its parts ([partAt]
/// gives the opened part at a place in the set's log, or `null` when it is
/// not here or cannot be read); `null` unless every part is there and the
/// whole is exactly what the set's hash says.
Map<String, dynamic>? assembleContacts(
  Map<String, dynamic> set,
  Map<String, dynamic>? Function(int seq) partAt,
) {
  final List<int>? seqs = contactsSetParts(set);
  final Object? k = set['k'];
  final Object? s = set['s'];
  final Object? h = set['h'];
  if (seqs == null || k is! List || s is! Map || h is! String) {
    return null;
  }
  final Map<String, dynamic> out = <String, dynamic>{};
  final List<String> names = <String>[];
  final List<String> shapes = <String>[];
  for (final Object? key in k) {
    if (key is! List ||
        key.length != 2 ||
        key[0] is! String ||
        !const <String>{'l', 'm', 's'}.contains(key[1])) {
      return null;
    }
    final String name = key[0] as String;
    final String shape = key[1] as String;
    names.add(name);
    shapes.add(shape);
    out[name] = switch (shape) {
      'l' => <Object?>[],
      'm' => <String, dynamic>{},
      _ => s[name],
    };
  }
  for (final int seq in seqs) {
    final Map<String, dynamic>? part = partAt(seq);
    final Object? items = part?['i'];
    if (part == null || part['v'] != kContactsSetFormat || items is! List) {
      return null;
    }
    for (final Object? item in items) {
      if (item is! List || item.isEmpty || item[0] is! int) {
        return null;
      }
      final int at = item[0] as int;
      if (at < 0 || at >= names.length) {
        return null;
      }
      final Object? into = out[names[at]];
      if (shapes[at] == 'l' && item.length == 2 && into is List) {
        into.add(item[1]);
      } else if (shapes[at] == 'm' &&
          item.length == 3 &&
          item[1] is String &&
          into is Map) {
        into[item[1] as String] = item[2];
      } else {
        return null;
      }
    }
  }
  return contactsHashOf(out) == h ? out : null;
}

/// What of [snapshot] fits [budget] bytes as one entry builds before
/// 1.16.5 read: everything but its lists and maps, then one item from each
/// in turn while they fit, marked [kContactsCutKey].
Map<String, dynamic> cutContacts(
  Map<String, dynamic> snapshot, {
  int budget = kContactsWholeBytes,
}) {
  final List<String> keys = snapshot.keys.toList();
  final Map<String, List<Object?>> lists = <String, List<Object?>>{};
  final Map<String, Map<String, dynamic>> maps =
      <String, Map<String, dynamic>>{};
  final Map<String, Iterator<Object?>> next = <String, Iterator<Object?>>{};
  for (final String key in keys) {
    final Object? value = snapshot[key];
    if (value is List) {
      lists[key] = <Object?>[];
      next[key] = value.iterator;
    } else if (value is Map) {
      maps[key] = <String, dynamic>{};
      next[key] = value.entries.iterator;
    }
  }
  Map<String, dynamic> build() => <String, dynamic>{
    for (final String key in keys)
      key: lists[key] ?? maps[key] ?? snapshot[key],
    kContactsCutKey: true,
  };
  int bytes = contactsJsonBytes(build());
  final Set<String> open = next.keys.toSet();
  while (open.isNotEmpty) {
    for (final String key in open.toList()) {
      final Iterator<Object?> it = next[key]!;
      if (!it.moveNext()) {
        open.remove(key);
        continue;
      }
      final Object? item = it.current;
      final int size = item is MapEntry
          ? contactsJsonBytes(<Object?>[item.key, item.value])
          : contactsJsonBytes(item) + 1;
      if (bytes + size > budget) {
        open.remove(key);
        continue;
      }
      bytes += size;
      if (item is MapEntry) {
        maps[key]![item.key as String] = item.value;
      } else {
        lists[key]!.add(item);
      }
    }
  }
  return build();
}

/// The body of the removals carried over a checkpoint: [removedAt]
/// (`address` or `group:id` → when, millis), the newest first, as many as
/// fit [kContactRemovalsBytes]; `null` when there are none.
Map<String, dynamic>? contactRemovalsBody(Map<String, int> removedAt) {
  if (removedAt.isEmpty) {
    return null;
  }
  final List<MapEntry<String, int>> newest = removedAt.entries.toList()
    ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
      final int byTime = b.value.compareTo(a.value);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
  final Map<String, int> kept = <String, int>{};
  int bytes = 32;
  for (final MapEntry<String, int> e in newest) {
    bytes += utf8.encode(e.key).length + 24;
    if (bytes > kContactRemovalsBytes) {
      break;
    }
    kept[e.key] = e.value;
  }
  return <String, dynamic>{'v': kContactsSetFormat, 'x': kept};
}

/// The removals a carried body ([contactRemovalsBody]) holds.
Map<String, int> contactRemovalsOf(Map<String, dynamic>? body) {
  final Object? x = body?['x'];
  final Map<String, int> out = <String, int>{};
  if (body?['v'] != kContactsSetFormat || x is! Map) {
    return out;
  }
  for (final MapEntry<dynamic, dynamic> e in x.entries) {
    if (e.key is String && e.value is int && (e.value as int) > 0) {
      out[e.key as String] = e.value as int;
    }
  }
  return out;
}

/// Whether the newest backup of friends and groups could not be saved
/// with friends: the health report says so until one is saved again.
final class ContactsBackupNotice extends ChangeNotifier {
  ContactsBackupNotice();

  /// The one the ledger reports to.
  static final ContactsBackupNotice instance = ContactsBackupNotice();

  bool _failing = false;

  bool get failing => _failing;

  /// Saving failed for [reason] (no names, no addresses).
  void fail(String reason) {
    logZenWarning('The friends and groups backup was not saved: $reason');
    if (_failing) {
      return;
    }
    _failing = true;
    notifyListeners();
  }

  /// A backup was saved (or there was nothing new to save).
  void saved() {
    if (!_failing) {
      return;
    }
    _failing = false;
    notifyListeners();
  }
}
