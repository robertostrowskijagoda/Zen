import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';

/// Writes this device's own entries.
///
/// [writer] is random per installation, never reused: a device restored from
/// an old backup starts a fresh log instead of writing a second version of
/// entries it already wrote (which everyone would see as a fork).
final class LedgerAuthor {
  LedgerAuthor({
    required this.deviceKey,
    required this.certificate,
    required this.store,
    String? writer,
  }) : writer = writer ?? randomId();

  final LedgerKeyPair deviceKey;
  final DeviceCertificate certificate;
  final LedgerStore store;
  final String writer;

  String get account => certificate.account;

  Future<void> _tail = Future<void>.value();

  /// Appends one entry to [space]. Calls are serialized, so concurrent
  /// appends still form one chain.
  Future<LogEntry> append(
    String space,
    String kind,
    Map<String, dynamic> body, {
    List<String> blobs = const <String>[],
  }) {
    final Future<LogEntry> result = _tail.then((_) async {
      final LogEntry entry = await LogEntry.create(
        deviceKey: deviceKey,
        certificate: certificate,
        space: space,
        writer: writer,
        seq: store.headOf(space, writer) + 1,
        prev: store.lastIdOf(space, writer),
        hlc: store.clock.now(),
        kind: kind,
        body: body,
        blobs: blobs,
      );
      final IngestResult result = await store.ingest(entry);
      if (result.status != IngestStatus.added) {
        throw StateError('Nie udało się zapisać wpisu: $result');
      }
      return entry;
    });
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// Appends a checkpoint ([kLedgerCheckpointKind]) to [space]: from it on
  /// the log may be held and handed on without what came before.
  Future<LogEntry> checkpoint(String space) =>
      append(space, kLedgerCheckpointKind, const <String, dynamic>{});

  /// Appends [drafts] to [space] as one run: every entry is signed first,
  /// then all join the log together ([LedgerStore.ingestRun]), so neither
  /// a save nor a peer ever finds only some of them here. Calls are
  /// serialized with [append].
  Future<List<LogEntry>> appendRun(String space, List<LedgerDraft> drafts) {
    final Future<List<LogEntry>> result = _tail.then(
      (_) => _writeRun(space, drafts),
    );
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// Like [appendRun], with the drafts made by [plan] in turn with every
  /// other write: nothing is appended between what it read and its run.
  /// Writes nothing (and returns `null`) when [plan] returns `null`.
  Future<List<LogEntry>?> appendPlanned(
    String space,
    List<LedgerDraft>? Function() plan,
  ) {
    final Future<List<LogEntry>?> result = _tail.then((_) async {
      final List<LedgerDraft>? drafts = plan();
      return drafts == null ? null : _writeRun(space, drafts);
    });
    _tail = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<LogEntry>> _writeRun(
    String space,
    List<LedgerDraft> drafts,
  ) async {
    int seq = store.headOf(space, writer);
    String prev = store.lastIdOf(space, writer);
    final List<LogEntry> run = <LogEntry>[];
    for (final LedgerDraft draft in drafts) {
      final LogEntry entry = await LogEntry.create(
        deviceKey: deviceKey,
        certificate: certificate,
        space: space,
        writer: writer,
        seq: ++seq,
        prev: prev,
        hlc: store.clock.now(),
        kind: draft.kind,
        body: draft.body,
        blobs: draft.blobs,
      );
      run.add(entry);
      prev = entry.id;
    }
    if (!await store.ingestRun(run)) {
      throw StateError('Nie udało się zapisać wpisów.');
    }
    return run;
  }

  /// Starts [space] over: a checkpoint saying that [drafts], written right
  /// after it in the same run ([appendRun]), carry everything of the log
  /// still valid ([rebaseCountOf]); every holder may then drop what came
  /// before it. Returns the checkpoint and the entries.
  Future<List<LogEntry>> rebase(String space, List<LedgerDraft> drafts) {
    if (drafts.length > kMaxRebaseEntries) {
      throw ArgumentError('too many entries after a checkpoint');
    }
    return appendRun(space, <LedgerDraft>[
      (
        kind: kLedgerCheckpointKind,
        body: <String, dynamic>{'n': drafts.length},
        blobs: const <String>[],
      ),
      ...drafts,
    ]);
  }
}

/// One entry to be written ([LedgerAuthor.appendRun]).
typedef LedgerDraft = ({
  String kind,
  Map<String, dynamic> body,
  List<String> blobs,
});

/// A brand-new account with its first device.
final class LedgerAccountSetup {
  LedgerAccountSetup._(this.accountKey, this.deviceKey, this.certificate);

  final LedgerKeyPair accountKey;
  final LedgerKeyPair deviceKey;
  final DeviceCertificate certificate;

  static Future<LedgerAccountSetup> create({
    String deviceName = 'Urządzenie',
    int issued = 0,
    LedgerKeyPair? deviceKey,
  }) async {
    final LedgerKeyPair account = await LedgerKeyPair.generate();
    final LedgerKeyPair device = deviceKey ?? await LedgerKeyPair.generate();
    final DeviceCertificate cert = await DeviceCertificate.issue(
      account: account,
      device: device,
      name: deviceName,
      issued: issued,
    );
    return LedgerAccountSetup._(account, device, cert);
  }

  /// Certifies one more device of this account.
  Future<(LedgerKeyPair, DeviceCertificate)> addDevice({
    String name = 'Urządzenie',
    int issued = 0,
  }) async {
    final LedgerKeyPair device = await LedgerKeyPair.generate();
    return (
      device,
      await DeviceCertificate.issue(
        account: accountKey,
        device: device,
        name: name,
        issued: issued,
      ),
    );
  }
}
