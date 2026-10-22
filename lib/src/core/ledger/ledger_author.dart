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
}

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
