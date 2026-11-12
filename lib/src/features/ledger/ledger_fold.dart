import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';

// A device folds its own logs in `acts` and `profile`: entries that no
// longer count go, and every holder that understands a fold drops them too
// ([kLedgerFoldKind]). Only entries whose readers take the newest one of
// their kind and key, and nothing older, are ever left out; everything
// else is carried word for word, under the id it was signed with, so what
// every screen reads from the log stays the same. Posts (`feed`) are never
// folded.

/// The spaces of this account a device folds.
const List<String> kFoldedSpaceKinds = <String>['acts', 'profile'];

/// Entry kinds whose readers take only the newest one per key
/// ([foldKeyOf]). The names are the features' own (`kLikeKind`,
/// `kReactionsKind`, `kReactionsPageKind`, `kProfileKind`,
/// `kProfilePartKinds`); a test keeps them the same.
const String kFoldLikeKind = 'like';
const String kFoldBundleKind = 'rx';
const String kFoldBundlePageKind = 'rxp';
const Set<String> kFoldProfileKinds = <String>{
  'profile',
  'profile_all',
  'profile_mid',
  'profile_close',
};

/// Kinds carried without their own signature ([LogEntry.isVouched]):
/// nobody hands them on as signed entries, and the signature is most of
/// their size.
const Set<String> kFoldVouchedKinds = <String>{
  kFoldLikeKind,
  kFoldBundleKind,
  kFoldBundlePageKind,
};

/// Bytes a log may hold besides what a fold would leave of it (at least as
/// many as that) before its device folds it again: what bounds an honest
/// log at every friend to about twice what still counts.
const int kFoldSlackBytes = 64 * 1024;

/// Most bytes of a carrier's body: the rest of an entry is its signature
/// and the fields every entry has.
const int kCarrierBodyBytes = kMaxEntryBytes - 8 * 1024;

/// About what a carrier or a fold adds besides what it carries.
const int _entryOverheadBytes = 5 * 1024;

/// How long a device keeps its own log from before a fold: friends still on
/// a build before 1.17.0 do not understand a fold, and can catch up from it
/// in this time.
const Duration kFoldOwnKeep = Duration(days: 30);

/// What makes [e] no longer count once a newer entry of the same key is in
/// the same log: its kind and key; `null` for an entry that always counts.
String? foldKeyOf(LogEntry e) {
  switch (e.kind) {
    case kFoldLikeKind:
    case kFoldBundleKind:
      final Object? post = e.body['post'];
      return post is String ? '${e.kind}|$post' : null;
    case kFoldBundlePageKind:
      final Object? post = e.body['post'];
      final Object? pg = e.body['pg'];
      return post is String && pg is int ? '${e.kind}|$post|$pg' : null;
  }
  return kFoldProfileKinds.contains(e.kind) ? e.kind : null;
}

/// The entries of one log that still count, by [view] (the log as its
/// readers see it, [LedgerStore.logView], in log order; entries up to
/// [base] are what folds carried, the rest is held): what the newest
/// complete fold carried and every entry after it, less those a newer
/// entry of the same key ([foldKeyOf]) replaces. Also how many bytes of
/// the log from that fold on (or of all of it) are held.
@visibleForTesting
({List<LogEntry> live, int held}) liveEntriesOf(
  List<LogEntry> view, {
  int base = 0,
}) {
  int from = -1;
  int count = 0;
  for (int i = view.length - 1; i >= 0 && from < 0; i--) {
    final int? c = foldCountOf(view[i]);
    if (c != null &&
        view[i].seq > base &&
        i + c < view.length &&
        view[i + c].seq == view[i].seq + c &&
        view
            .sublist(i + 1, i + c + 1)
            .every((LogEntry e) => e.kind == kLedgerCarryKind)) {
      from = i;
      count = c;
    }
  }
  final List<LogEntry> counted = <LogEntry>[];
  int held = 0;
  for (int i = max(from, 0); i < view.length; i++) {
    final LogEntry e = view[i];
    if (e.seq > base) {
      held += e.encodedLength;
    }
    if (from >= 0 && i <= from + count) {
      counted.addAll(carriedIn(e));
    } else if (!startsLog(e) && e.kind != kLedgerCarryKind) {
      counted.add(e);
    }
  }
  counted.sort((LogEntry a, LogEntry b) => a.seq.compareTo(b.seq));
  final Map<String, int> newest = <String, int>{};
  for (final LogEntry e in counted) {
    final String? key = foldKeyOf(e);
    if (key != null) {
      newest[key] = max(newest[key] ?? 0, e.seq);
    }
  }
  bool counts(LogEntry e) {
    final String? key = foldKeyOf(e);
    return key == null || newest[key] == e.seq;
  }

  return (live: counted.where(counts).toList(), held: held);
}

/// How [e] goes into a carrier: its signed part alone for the kinds
/// carried vouched for ([kFoldVouchedKinds]), else as it was signed.
Map<String, dynamic> _carriedJson(LogEntry e) =>
    e.isVouched || kFoldVouchedKinds.contains(e.kind) ? e.unsigned : e.toJson();

/// About how many bytes [e] takes in a carrier, without encoding it.
int _carriedSize(LogEntry e) =>
    e.isVouched || kFoldVouchedKinds.contains(e.kind)
    ? e.encodedLength - e.signature.length - 32
    : e.encodedLength;

/// The fold of one of this device's logs ([view]): a fold and its carriers,
/// to write in one run ([LedgerAuthor.appendRun]); `null` when it is not
/// worth it yet (the log holds no more than [slack] bytes, or as many as
/// the fold would leave, beyond what the fold would leave) or cannot be
/// done (an entry too big to carry, too many carriers).
List<LedgerDraft>? planFold(
  List<LogEntry> view, {
  int base = 0,
  int slack = kFoldSlackBytes,
}) {
  if (view.isEmpty) {
    return null;
  }
  final ({List<LogEntry> live, int held}) state = liveEntriesOf(
    view,
    base: base,
  );
  int estimate = _entryOverheadBytes;
  for (final LogEntry e in state.live) {
    estimate += _carriedSize(e);
  }
  estimate += _entryOverheadBytes * (estimate ~/ kCarrierBodyBytes + 1);
  if (state.held - estimate <= max(estimate, slack)) {
    return null;
  }
  final List<List<Map<String, dynamic>>> carriers =
      <List<Map<String, dynamic>>>[];
  List<Map<String, dynamic>> current = <Map<String, dynamic>>[];
  int bytes = 0;
  for (final LogEntry e in state.live) {
    final Map<String, dynamic> json = _carriedJson(e);
    final int size = canonicalJsonBytes(json).length + 1;
    if (size > kCarrierBodyBytes - 64) {
      return null;
    }
    if (bytes + size > kCarrierBodyBytes - 64) {
      carriers.add(current);
      current = <Map<String, dynamic>>[];
      bytes = 0;
    }
    current.add(json);
    bytes += size;
  }
  if (current.isNotEmpty) {
    carriers.add(current);
  }
  if (carriers.length > kMaxRebaseEntries) {
    return null;
  }
  return <LedgerDraft>[
    (
      kind: kLedgerFoldKind,
      body: <String, dynamic>{'c': carriers.length},
      blobs: const <String>[],
    ),
    for (final List<Map<String, dynamic>> items in carriers)
      (
        kind: kLedgerCarryKind,
        body: <String, dynamic>{'v': 1, 'e': items},
        blobs: const <String>[],
      ),
  ];
}

/// Friends whose logs reached the bound this phone keeps of them
/// ([AccountSpacePolicy.maxBytes]): the health report says so while any
/// does. Only the number of friends, no names.
final class LedgerRoomNotice extends ChangeNotifier {
  LedgerRoomNotice();

  /// The one the ledger reports to.
  static final LedgerRoomNotice instance = LedgerRoomNotice();

  Set<String> _accounts = const <String>{};

  /// How many friends' logs take nothing new for want of room.
  int get full => _accounts.length;

  /// The spaces that refuse new entries now ([LedgerStore.fullSpaces]).
  void update(Set<String> spaces) {
    final Set<String> accounts = <String>{
      for (final String s in spaces) s.substring(s.indexOf('/') + 1),
    };
    if (setEquals(accounts, _accounts)) {
      return;
    }
    _accounts = accounts;
    notifyListeners();
  }
}
