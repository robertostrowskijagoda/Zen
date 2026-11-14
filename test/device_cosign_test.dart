// Co-signatures of device certificates and cut-offs signed by a device
// (docs/SECURITY_MODEL.md, "Cutting a device off"), with real signatures,
// as a friend's phone keeps them: who holds the account key and password
// (a thief of one device) can neither add a device that counts at once,
// nor cut the owner's devices off with the account key alone, nor bring a
// cut-off device back with an old cut-off.
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/device_trust.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';

const int _h = 3600 * 1000;
final int _day = kNewDeviceWait.inMilliseconds;

/// An account with its first device [a] (the mark of co-signing on its
/// certificate), and a phone's directory with its own clock.
final class _World {
  _World._(this.setup, this.markA);

  final LedgerAccountSetup setup;
  final DeviceCertificate markA;
  int now = 0;

  static Future<_World> create() async {
    final LedgerAccountSetup setup = await LedgerAccountSetup.create(issued: 1);
    return _World._(setup, await setup.certificate.coSignedBy(setup.deviceKey));
  }

  String get account => setup.accountKey.id;
  LedgerKeyPair get a => setup.deviceKey;

  AccountDirectory directory() => AccountDirectory()..now = () => now;

  /// A device certified by the account key at [issued] (as a thief can).
  Future<(LedgerKeyPair, DeviceCertificate)> device(int issued) =>
      setup.addDevice(issued: issued);

  Future<DeviceRevocation> cut(
    String device, {
    LedgerKeyPair? by,
    DeviceCertificate? byCert,
    List<String> keep = const <String>[],
    int issued = 0,
  }) => DeviceRevocation.issue(
    account: setup.accountKey,
    device: device,
    cutoffs: const <String, int>{},
    issued: issued,
    by: by,
    byCertificate: byCert,
    keep: keep,
  );
}

void main() {
  test('the account key alone cuts off in an account that never co-signed, '
      'and is refused once it does', () async {
    final _World w = await _World.create();
    final (LedgerKeyPair _, DeviceCertificate certB) = await w.device(2);

    final AccountDirectory before = w.directory();
    await before.addCertificate(w.setup.certificate);
    await before.addCertificate(certB);
    expect(before.isStrict(w.account), isFalse);
    expect(await before.addRevocation(await w.cut(certB.device)), isTrue);
    expect(before.isRevoked(w.account, certB.device), isTrue);

    final AccountDirectory after = w.directory();
    await after.addCertificate(w.markA);
    await after.addCertificate(certB);
    expect(after.isStrict(w.account), isTrue);
    // The thief's cut-off of the owner's first device, account key only.
    expect(await after.addRevocation(await w.cut(w.a.id)), isFalse);
    expect(after.isRevoked(w.account, w.a.id), isFalse);
    expect(after.revocationCount, 0);
  });

  test('a device co-signed by one that counts counts at once; the thief\'s '
      'own waits a day after it was first seen, unless its co-signature is '
      'by a device not known or does not hold', () async {
    final _World w = await _World.create();
    final AccountDirectory dir = w.directory();
    await dir.addCertificate(w.markA);
    w.now = 2 * _h; // past the first contact

    final (LedgerKeyPair b, DeviceCertificate certB) = await w.device(2 * _h);
    final DeviceCertificate coB = await certB.coSignedBy(w.a);
    expect(await dir.addCertificate(coB), isTrue);
    expect(dir.isRevoked(w.account, b.id), isFalse);

    final (LedgerKeyPair t, DeviceCertificate certT) = await w.device(2 * _h);
    await dir.addCertificate(await certT.coSignedBy(t));
    expect(dir.isRevoked(w.account, t.id), isTrue);
    expect(dir.isCutOff(w.account, t.id), isFalse);
    expect(dir.pendingUntil(w.account, t.id), 2 * _h + _day);
    expect(dir.pendingDevicesOf(w.account).keys, <String>[t.id]);

    // Co-signed by a device of the account nobody here knows: waits until
    // that one's certificate comes, then counts by it.
    final (LedgerKeyPair c, DeviceCertificate certC) = await w.device(2 * _h);
    final (LedgerKeyPair d, DeviceCertificate certD) = await w.device(2 * _h);
    await dir.addCertificate(await certD.coSignedBy(c));
    expect(dir.isRevoked(w.account, d.id), isTrue);
    await dir.addCertificate(await certC.coSignedBy(w.a));
    expect(dir.isRevoked(w.account, c.id), isFalse);
    expect(dir.isRevoked(w.account, d.id), isFalse);

    // A co-signature that does not hold (made for another certificate).
    final (LedgerKeyPair e, DeviceCertificate certE) = await w.device(2 * _h);
    final CoSignature other = (await certT.coSignedBy(w.a)).co!;
    await dir.addCertificate(certE.withCo(other));
    expect(dir.pendingUntil(w.account, e.id), isNotNull);

    w.now = 2 * _h + _day;
    expect(dir.isRevoked(w.account, t.id), isFalse);
  });

  test('a certificate issued again for a known device does not replace it, '
      'and a device that counts takes no co-signature that would tie it to '
      'the stolen device', () async {
    final _World w = await _World.create();
    final AccountDirectory dir = w.directory();
    await dir.addCertificate(w.markA);
    final (LedgerKeyPair s, DeviceCertificate certS) = await w.device(2);
    await dir.addCertificate(await certS.coSignedBy(w.a));
    w.now = 30 * _h;

    // The account key signs a second certificate for the owner's device,
    // without its mark.
    final DeviceCertificate again = await DeviceCertificate.issue(
      account: w.setup.accountKey,
      device: w.a,
      name: 'Inne',
      issued: 99,
    );
    expect(await dir.addCertificate(again), isTrue);
    expect(dir.certificateOf(w.account, w.a.id)!.signature, w.markA.signature);

    // The stolen device co-signs the owner's first device.
    await dir.addCertificate(await w.setup.certificate.coSignedBy(s));
    expect(dir.certificateOf(w.account, w.a.id)!.co!.by, w.a.id);

    // Cut-off of the stolen device: the owner's device stays.
    expect(
      await dir.addRevocation(
        await w.cut(s.id, by: w.a, byCert: w.markA, issued: 30 * _h),
      ),
      isTrue,
    );
    expect(dir.isCutOff(w.account, s.id), isTrue);
    expect(dir.isRevoked(w.account, w.a.id), isFalse);
  });

  test('a cut-off is checked with the certificate it carries: a changed '
      'list of kept devices counts as the account key alone, and is '
      'refused; one by a device that waits is refused', () async {
    final _World w = await _World.create();
    final AccountDirectory dir = w.directory();
    await dir.addCertificate(w.markA);
    final (LedgerKeyPair s, DeviceCertificate certS) = await w.device(2);
    await dir.addCertificate(await certS.coSignedBy(w.a));
    w.now = 2 * _h;

    final DeviceRevocation real = await w.cut(
      s.id,
      by: w.a,
      byCert: w.markA,
      keep: <String>[w.a.id],
      issued: 2 * _h,
    );
    final DeviceRevocation? changed = DeviceRevocation.fromJson(
      <String, dynamic>{
        ...real.toJson(),
        'keep': <String>[w.a.id, s.id],
      },
    );
    expect(changed!.hasDevicePart, isTrue);
    expect(await changed.verifyDevicePart(), isFalse);
    expect(await dir.addRevocation(changed), isFalse);
    expect(dir.isRevoked(w.account, s.id), isFalse);

    // A damaged device part is dropped whole when read.
    final DeviceRevocation? damaged = DeviceRevocation.fromJson(
      <String, dynamic>{...real.toJson(), 'dsig': 'x'},
    );
    expect(damaged!.hasDevicePart, isFalse);

    // The thief's own device, waiting, cuts the owner's: refused.
    final (LedgerKeyPair t, DeviceCertificate certT) = await w.device(2 * _h);
    await dir.addCertificate(certT);
    expect(
      await dir.addRevocation(
        await w.cut(w.a.id, by: t, byCert: certT, issued: 3 * _h),
      ),
      isFalse,
    );

    expect(await dir.addRevocation(real), isTrue);
    expect(dir.isCutOff(w.account, s.id), isTrue);
  });

  test('a veto: the owner cuts off the thief\'s device while it waits; it '
      'never counts, and its cut-off of the owner a day later does '
      'nothing', () async {
    final _World w = await _World.create();
    final AccountDirectory dir = w.directory();
    await dir.addCertificate(w.markA);
    w.now = 5 * _h;
    final (LedgerKeyPair t, DeviceCertificate certT) = await w.device(5 * _h);
    final DeviceCertificate markT = await certT.coSignedBy(t);
    await dir.addCertificate(markT);
    w.now = 6 * _h;
    expect(
      await dir.addRevocation(
        await w.cut(t.id, by: w.a, byCert: w.markA, issued: 6 * _h),
      ),
      isTrue,
    );
    w.now = 5 * _h + _day + _h;
    expect(dir.isCutOff(w.account, t.id), isTrue);
    await dir.addRevocation(
      await w.cut(w.a.id, by: t, byCert: markT, issued: w.now),
    );
    expect(dir.isRevoked(w.account, w.a.id), isFalse);
    expect(dir.isCutOff(w.account, t.id), isTrue);
  });

  test('an old cut-off replayed to a new friend leaves later devices alone, '
      'and the cut-off device cuts nothing', () async {
    final _World w = await _World.create();
    final (LedgerKeyPair s, DeviceCertificate certS) = await w.device(2);
    final DeviceCertificate coS = await certS.coSignedBy(w.a);
    final DeviceRevocation old = await w.cut(
      s.id,
      by: w.a,
      byCert: w.markA,
      keep: <String>[w.a.id],
      issued: 10 * _h,
    );
    // Months later the person restores the account from paper.
    final (LedgerKeyPair p, DeviceCertificate certP) = await w.device(
      2000 * _h,
    );
    final DeviceCertificate markP = await certP.coSignedBy(p);

    w.now = 3000 * _h;
    final AccountDirectory cel = w.directory();
    for (final DeviceCertificate c in <DeviceCertificate>[
      w.markA,
      coS,
      markP,
    ]) {
      await cel.addCertificate(c);
    }
    expect(await cel.addRevocation(old), isTrue);
    expect(cel.isCutOff(w.account, s.id), isTrue);
    expect(cel.isRevoked(w.account, p.id), isFalse);
    // Taken again: nothing changes.
    expect(await cel.addRevocation(old), isTrue);
    expect(cel.revocationCount, 1);

    // The stolen device's key still works: it cuts the restored one off.
    final DeviceRevocation late = await w.cut(
      p.id,
      by: s,
      byCert: coS,
      keep: <String>[s.id],
      issued: 3000 * _h,
    );
    await cel.addRevocation(late);
    expect(cel.isRevoked(w.account, p.id), isFalse);
    expect(cel.isRevoked(w.account, w.a.id), isFalse);
  });

  test('when a device was first seen and when a cut-off came survive a '
      'restart', () async {
    final _World w = await _World.create();
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    Future<LedgerStore> open() async {
      final LedgerStore store = LedgerStore(
        clock: HlcClock(wallClock: () => w.now),
      );
      await LedgerArchive(
        disk: disk,
      ).open(store, BlobStore(backend: DiskBlobChunkBackend(disk)));
      return store;
    }

    final LedgerStore first = LedgerStore(
      clock: HlcClock(wallClock: () => w.now),
    );
    final LedgerArchive archive = LedgerArchive(disk: disk);
    await archive.open(first, BlobStore(backend: DiskBlobChunkBackend(disk)));
    await first.directory.addCertificate(w.markA);
    w.now = 5 * _h;
    final (LedgerKeyPair t, DeviceCertificate certT) = await w.device(5 * _h);
    await first.directory.addCertificate(certT);
    w.now = 6 * _h;
    await first.applyRevocation(
      await w.cut(t.id, by: w.a, byCert: w.markA, issued: 6 * _h),
    );
    await archive.flush();

    w.now = 40 * _h;
    final LedgerStore second = await open();
    expect(second.directory.seenOf(w.account)[t.id]!.at, 5 * _h);
    expect(second.directory.isStrict(w.account), isTrue);
    // Still a veto after the restart: the device stays out.
    expect(second.directory.isCutOff(w.account, t.id), isTrue);
    expect(
      second.directory.receivedAtOf(second.directory.revocations.single),
      6 * _h,
    );
  });

  test('certificates and cut-offs keep their device parts on the way, and '
      'what came before them reads them as before', () async {
    final _World w = await _World.create();
    final (LedgerKeyPair s, DeviceCertificate certS) = await w.device(2);
    final DeviceCertificate coS = await certS.coSignedBy(w.a);
    final DeviceCertificate back = DeviceCertificate.fromJson(coS.toJson())!;
    expect(back.co!.by, w.a.id);
    expect(await back.verify(), isTrue);
    expect(await back.verifyCo(w.markA), isTrue);
    // A damaged co-signature costs only itself.
    final DeviceCertificate? bare = DeviceCertificate.fromJson(
      <String, dynamic>{
        ...coS.toJson(),
        'co': <String, dynamic>{'by': 1},
      },
    );
    expect(bare!.co, isNull);
    expect(await bare.verify(), isTrue);

    final DeviceRevocation cut = await w.cut(
      s.id,
      by: w.a,
      byCert: w.markA,
      keep: <String>[w.a.id],
    );
    final DeviceRevocation again = DeviceRevocation.fromJson(cut.toJson())!;
    expect(again.by, w.a.id);
    expect(again.keep, <String>[]);
    expect(await again.verify(), isTrue);
    expect(await again.verifyDevicePart(), isTrue);
    // The account's part alone holds as it did (what versions before
    // device parts check).
    expect(await again.withoutDevicePart().verify(), isTrue);
  });

  test('devices a stolen device co-signed cannot crowd out the owner\'s '
      'cut-off of it', () async {
    final _World w = await _World.create();
    final AccountDirectory dir = w.directory();
    await dir.addCertificate(w.markA);
    final (LedgerKeyPair s, DeviceCertificate certS) = await w.device(2);
    final DeviceCertificate coS = await certS.coSignedBy(w.a);
    await dir.addCertificate(coS);
    // The thief makes devices co-signed by the stolen one, and each signs
    // as many cut-offs of made-up devices as it may.
    int n = 0;
    while (dir.revocationCount <
        AccountDirectory.maxSignedRevocationsPerAccount) {
      final (LedgerKeyPair t, DeviceCertificate certT) = await w.device(3);
      final DeviceCertificate coT = await certT.coSignedBy(s);
      await dir.addCertificate(coT);
      for (int i = 0; i < AccountDirectory.maxRevocationsPerSigner; i++) {
        expect(
          await dir.addRevocation(
            await w.cut(b64(randomBytes(32)), by: t, byCert: coT, issued: n++),
          ),
          isTrue,
        );
      }
    }
    expect(
      await dir.addRevocation(
        await w.cut(s.id, by: w.a, byCert: w.markA, issued: 10 * _h),
      ),
      isTrue,
    );
    expect(dir.isCutOff(w.account, s.id), isTrue);
  });
}
