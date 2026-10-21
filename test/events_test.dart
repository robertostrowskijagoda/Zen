import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

String addr(String n) => PeerShareCodec.normalizeAddress('200::$n');

final class _Host implements EventHost {
  _Host(this.net, this.name, List<String> friends)
    : address = addr(name),
      friendList = friends.map(addr).toList() {
    net[address] = this;
    events = EventService(
      host: this,
      disk: MemoryLedgerDisk(),
      now: () => clock,
    );
  }

  final Map<String, _Host> net;
  final String name;
  final String address;
  final List<String> friendList;
  late final EventService events;
  int clock = 1000;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    await net[to]?.events.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  @override
  List<String> friends() => friendList;

  @override
  bool isFriend(String a) =>
      friendList.contains(PeerShareCodec.normalizeAddress(a));

  @override
  String ownAddress() => address;

  @override
  String ownName() => name;

  @override
  String nameOf(String a) => net[a]?.name ?? '?';

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);
}

/// An invitation as someone else's phone would send it.
Map<String, dynamic> invitation(
  String id,
  String org, {
  EventReach reach = EventReach.friendsOfFriends,
  int startsAt = 100000,
}) => MeetEvent(
  id: id,
  organizer: org,
  organizerName: 'Ktoś',
  title: 'Impreza',
  startsAt: startsAt,
  ticketKey: 'klucz',
  reach: reach,
  updatedAt: 1,
).toJson();

/// What [h]'s event service keeps on its disk.
Map<String, dynamic> _storedEvents(_Host h) =>
    jsonDecode(
          utf8.decode(
            (h.events.disk as MemoryLedgerDisk).files['meet/events']!,
          ),
        )
        as Map<String, dynamic>;

/// A real small JPEG whose header now claims [width] × [height]: decoding
/// it would allocate the whole picture.
Uint8List claimedJpeg(int width, int height) {
  final Uint8List jpg = Uint8List.fromList(
    img.encodeJpg(img.Image(width: 16, height: 16)),
  );
  for (int i = 0; i + 8 < jpg.length; i++) {
    // The frame header (SOF0): length, precision, height, width.
    if (jpg[i] == 0xFF && jpg[i + 1] == 0xC0) {
      jpg[i + 5] = height >> 8;
      jpg[i + 6] = height & 0xFF;
      jpg[i + 7] = width >> 8;
      jpg[i + 8] = width & 0xFF;
      return jpg;
    }
  }
  throw StateError('no frame header');
}

void main() {
  test('invitations reach friends of friends with the chain, tickets work '
      'at the door', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2']);
    final _Host kuba = _Host(net, 'b2', <String>['a1', 'c3']);
    final _Host ola = _Host(net, 'c3', <String>['b2', 'd4']);
    final _Host dalej = _Host(net, 'd4', <String>['c3']);

    final MeetEvent e = await ania.events.create(
      title: 'Urodziny',
      startsAt: 100000,
      reach: EventReach.friendsOfFriends,
      capacity: 10,
    );
    expect(kuba.events.event(e.id), isNotNull);
    expect(ola.events.event(e.id), isNotNull, reason: 'Kuba passed it on');
    expect(ola.shown.last.body, contains('b2'));
    expect(dalej.events.event(e.id), isNull, reason: 'only one step further');

    await kuba.events.rsvp(e.id, GuestStatus.going);
    await ola.events.rsvp(e.id, GuestStatus.going);
    final MeetEvent mine = ania.events.event(e.id)!;
    expect(mine.guest(ola.address)!.broughtBy, kuba.address);
    expect(mine.chainOf(ola.address), <String>[ola.address, kuba.address]);
    expect(mine.goingCount, 2);
    // Everyone has the current list.
    expect(ola.events.event(e.id)!.goingCount, 2);

    // Ola's ticket opens the door once (the live code from her phone: her
    // ticket is pinned to it).
    final EventTicket ticket = ola.events.ticket(e.id)!;
    final String code = (await ola.events.ticketQr(e.id))!;
    expect((await ania.events.checkIn(e.id, code)).$1, CheckIn.ok);
    expect((await ania.events.checkIn(e.id, code)).$1, CheckIn.replayed);
    for (final _Host h in <_Host>[ania, kuba, ola, dalej]) {
      h.clock += EventTicket.liveWindow;
    }
    expect(
      (await ania.events.checkIn(e.id, (await ola.events.ticketQr(e.id))!)).$1,
      CheckIn.already,
    );
    // A forged one does not.
    final EventTicket forged = EventTicket(
      eventId: e.id,
      guest: dalej.address,
      name: 'd4',
      signature: ticket.signature,
      pin: ticket.pin,
    );
    expect(
      (await ania.events.checkIn(e.id, forged.toQr())).$1,
      CheckIn.invalid,
    );
    expect((await ania.events.checkIn(e.id, 'cokolwiek')).$1, CheckIn.invalid);

    // Someone outside the reach cannot just answer.
    await dalej.send(ania.address, <String, dynamic>{
      'type': EventTypes.rsvp,
      'id': e.id,
      's': 'going',
      'chain': <Map<String, String>>[
        <String, String>{'a': kuba.address, 'n': 'b2'},
        <String, String>{'a': ola.address, 'n': 'c3'},
      ],
    });
    expect(ania.events.event(e.id)!.guest(dalej.address), isNull);
  });

  test(
    'only the organizer changes an event; "selected" invites stay put',
    () async {
      final Map<String, _Host> net = <String, _Host>{};
      final _Host ania = _Host(net, 'a1', <String>['b2', 'c3']);
      final _Host kuba = _Host(net, 'b2', <String>['a1', 'c3']);
      final _Host ola = _Host(net, 'c3', <String>['a1', 'b2']);

      final MeetEvent e = await ania.events.create(
        title: 'Kolacja',
        startsAt: 100000,
        invite: <String>[kuba.address],
        capacity: 2,
      );
      expect(ola.events.event(e.id), isNull);
      await ola.events.rsvp(e.id, GuestStatus.going);
      expect(ania.events.event(e.id)!.guest(ola.address), isNull);

      // Kuba cannot rewrite it for others.
      final Map<String, dynamic> fake = kuba.events.event(e.id)!.toJson()
        ..['title'] = 'Zmienione'
        ..['upd'] = 999999;
      await kuba.send(ola.address, <String, dynamic>{
        'type': EventTypes.event,
        'e': fake,
      });
      expect(
        ola.events.event(e.id),
        isNull,
        reason: 'Kuba is not the organizer',
      );

      await kuba.events.rsvp(e.id, GuestStatus.going);
      expect(ania.events.event(e.id)!.isFull, isTrue);

      await ania.events.cancel(e.id);
      expect(kuba.events.event(e.id)!.cancelled, isTrue);
      expect(kuba.shown.last.title, startsWith('Odwołane'));
    },
  );

  test('+1: asked, or without asking when the organizer allowed it', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2']);
    final _Host kuba = _Host(net, 'b2', <String>['a1', 'c3', 'd4']);
    final _Host ola = _Host(net, 'c3', <String>['b2']);
    final _Host ewa = _Host(net, 'd4', <String>['b2']);

    final MeetEvent e = await ania.events.create(
      title: 'Grill',
      startsAt: 100000,
      invite: <String>[kuba.address],
    );
    await kuba.events.rsvp(e.id, GuestStatus.going);
    await kuba.events.askPlusOne(e.id, ola.address);
    expect(
      ania.events.event(e.id)!.guest(ola.address)!.status,
      GuestStatus.requested,
    );
    expect(
      ola.events.event(e.id),
      isNull,
      reason: 'not before the organizer agrees',
    );
    expect(ania.shown.last.title, contains('chce przyprowadzić'));

    await ania.events.decidePlusOne(e.id, ola.address, true);
    expect(ola.events.event(e.id), isNotNull);

    await ania.events.allowPlusOnes(e.id, kuba.address, 2);
    await kuba.events.askPlusOne(e.id, ewa.address);
    expect(
      ania.events.event(e.id)!.guest(ewa.address)!.status,
      GuestStatus.invited,
    );
    expect(ewa.events.event(e.id), isNotNull);
  });

  test('photos are made small and clean; anything else is refused', () {
    final img.Image picture = img.Image(width: 3000, height: 1500);
    final Uint8List jpeg = compressEventPhoto(
      Uint8List.fromList(img.encodePng(picture)),
    )!;
    final img.Image back = img.decodeJpg(jpeg)!;
    expect(back.width, kEventPhotoSide);
    expect(back.height, kEventPhotoSide ~/ 2);
    expect(jpeg.length, lessThan(kMaxSharedPhotoBytes));
    expect(
      compressEventPhoto(Uint8List.fromList(utf8.encode('nie obraz'))),
      isNull,
    );
    expect(compressEventPhoto(Uint8List(0)), isNull);
    final img.Image flat = img.decodeJpg(
      compressFlatPhoto(Uint8List.fromList(img.encodePng(picture)))!,
    )!;
    expect(flat.width, kFlatPhotoSide);
  });

  test('shared album: guests who went add photos once it started, the '
      'organizer passes them on; gratitude cards reach the host', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2', 'c3', 'd4']);
    final _Host kuba = _Host(net, 'b2', <String>['a1']);
    final _Host ola = _Host(net, 'c3', <String>['a1']);
    final _Host ewa = _Host(net, 'd4', <String>['a1']);
    final MeetEvent e = await ania.events.create(
      title: 'Grill',
      startsAt: 3600000,
      invite: <String>[kuba.address, ola.address, ewa.address],
    );
    await kuba.events.rsvp(e.id, GuestStatus.going);
    await ola.events.rsvp(e.id, GuestStatus.going);
    await ewa.events.rsvp(e.id, GuestStatus.declined);
    final Uint8List jpeg = compressEventPhoto(
      Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 48))),
    )!;

    // Not before it starts.
    expect(kuba.events.canAddPhotos(kuba.events.event(e.id)!), isFalse);
    expect(await kuba.events.addPhoto(e.id, jpeg), isNull);
    expect(await ola.events.sendThanks(e.id, 'Dzięki'), isFalse);
    for (final _Host h in <_Host>[ania, kuba, ola, ewa]) {
      h.clock = 3700000;
    }

    final EventPhoto photo = (await kuba.events.addPhoto(e.id, jpeg))!;
    expect(ania.events.photos(e.id).single.byName, 'b2');
    expect(ola.events.photos(e.id).single.id, photo.id);
    expect(ola.shown.last.title, 'Nowe zdjęcie: Grill');
    expect(ewa.events.photos(e.id), isEmpty, reason: 'she did not go');
    expect(ewa.events.canAddPhotos(ewa.events.event(e.id)!), isFalse);

    // Only your own photo, only when you went, only real pictures.
    await kuba.send(ania.address, <String, dynamic>{
      'type': EventTypes.photo,
      'id': e.id,
      'p': EventPhoto(
        id: 'udaje',
        by: ola.address,
        byName: 'c3',
        at: 1,
        data: base64Encode(jpeg),
      ).toJson(),
    });
    await ewa.send(ania.address, <String, dynamic>{
      'type': EventTypes.photo,
      'id': e.id,
      'p': EventPhoto(
        id: 'ewa1',
        by: ewa.address,
        byName: 'd4',
        at: 1,
        data: base64Encode(jpeg),
      ).toJson(),
    });
    await kuba.send(ania.address, <String, dynamic>{
      'type': EventTypes.photo,
      'id': e.id,
      'p': EventPhoto(
        id: 'smiec',
        by: kuba.address,
        byName: 'b2',
        at: 1,
        data: base64Encode(utf8.encode('to nie jest zdjęcie')),
      ).toJson(),
    });
    // A picture claiming to be 20000 × 20000 px is refused unopened.
    await kuba.send(ania.address, <String, dynamic>{
      'type': EventTypes.photo,
      'id': e.id,
      'p': EventPhoto(
        id: 'bomba',
        by: kuba.address,
        byName: 'b2',
        at: 1,
        data: base64Encode(claimedJpeg(20000, 20000)),
      ).toJson(),
    });
    expect(ania.events.photos(e.id), hasLength(1));

    // The organizer's own photos go to everyone who went.
    await ania.events.addPhoto(e.id, jpeg);
    expect(kuba.events.photos(e.id), hasLength(2));
    expect(ola.events.photos(e.id), hasLength(2));
    expect(ewa.events.photos(e.id), isEmpty);

    // The album survives a restart.
    final EventService again = EventService(
      host: ola,
      disk: ola.events.disk,
      now: () => ola.clock,
    );
    await again.load();
    expect(again.photos(e.id).map((EventPhoto p) => p.id), contains(photo.id));
    expect(again.photos(e.id), hasLength(2));

    // Gratitude cards: from those who went, to the host.
    expect(ewa.events.canThank(ewa.events.event(e.id)!), isFalse);
    expect(await ewa.events.sendThanks(e.id, 'Dzięki'), isFalse);
    expect(ania.events.canThank(ania.events.event(e.id)!), isFalse);
    expect(await ola.events.sendThanks(e.id, '  Super grill!  '), isTrue);
    expect(ania.events.thanksFor(e.id).single.text, 'Super grill!');
    expect(ania.events.thanksFor(e.id).single.byName, 'c3');
    expect(ania.shown.last.title, 'Karta wdzięczności: Grill');
    expect(ola.events.myThanks(e.id)!.text, 'Super grill!');
    expect(ola.events.thanksFor(e.id), isEmpty);
    // Sending again replaces the card.
    await ola.events.sendThanks(e.id, 'Jeszcze raz dzięki');
    expect(ania.events.thanksFor(e.id).single.text, 'Jeszcze raz dzięki');
    await kuba.events.sendThanks(e.id, 'Dziękuję!');
    expect(ania.events.thanksFor(e.id), hasLength(2));
    expect(await kuba.events.sendThanks(e.id, 'x' * 201), isFalse);

    final EventService host = EventService(
      host: ania,
      disk: ania.events.disk,
      now: () => ania.clock,
    );
    await host.load();
    expect(host.thanksFor(e.id), hasLength(2));
  });

  test(
    'tickets are pinned to the phone: a live code opens the door, a '
    'screenshot or a copy does not; "Będę" without a key does not count',
    () async {
      final Map<String, _Host> net = <String, _Host>{};
      final _Host ania = _Host(net, 'a1', <String>['b2', 'c3']);
      final _Host kuba = _Host(net, 'b2', <String>['a1']);
      final _Host ola = _Host(net, 'c3', <String>['a1']);
      void tick(int millis) {
        for (final _Host h in <_Host>[ania, kuba, ola]) {
          h.clock += millis;
        }
      }

      final MeetEvent e = await ania.events.create(
        title: 'Parapetówka',
        startsAt: 10000000,
        invite: <String>[kuba.address, ola.address],
      );
      await kuba.events.rsvp(e.id, GuestStatus.going);
      // "Będę" with no key of the phone: nothing changes.
      await ola.send(ania.address, <String, dynamic>{
        'type': EventTypes.rsvp,
        'id': e.id,
        's': 'going',
        'n': 'c3',
      });
      expect(
        ania.events.event(e.id)!.guest(ola.address)!.status,
        GuestStatus.invited,
      );
      expect(ola.events.ticket(e.id), isNull);

      final EventTicket kubaTicket = kuba.events.ticket(e.id)!;
      expect(kuba.events.ticketPinned(e.id), isTrue);

      // A copy of Kuba's bare ticket does not open the door any more.
      expect(
        (await ania.events.checkIn(e.id, kubaTicket.toQr())).$1,
        CheckIn.expired,
      );
      // Nor does a screenshot of his live code a while later.
      final String shot = (await kuba.events.ticketQr(e.id))!;
      tick(EventTicket.liveSlack + EventTicket.liveWindow);
      expect((await ania.events.checkIn(e.id, shot)).$1, CheckIn.expired);
      // Nor a code signed by another phone.
      final EventTicket fresh = EventTicket.fromQr(
        (await kuba.events.ticketQr(e.id))!,
      )!;
      final LedgerKeyPair other = await LedgerKeyPair.generate();
      final String faked = kubaTicket.toLiveQr(
        fresh.liveAt!,
        b64(
          await other.signClassical(
            EventTicket.liveBytes(e.id, kubaTicket.guest, fresh.liveAt!),
          ),
        ),
      );
      expect((await ania.events.checkIn(e.id, faked)).$1, CheckIn.invalid);

      // The live code from his own phone does, once.
      final String live = (await kuba.events.ticketQr(e.id))!;
      final (CheckIn result, EventGuest? who) = await ania.events.checkIn(
        e.id,
        live,
      );
      expect(result, CheckIn.ok);
      expect(who!.address, kuba.address);
      expect((await ania.events.checkIn(e.id, live)).$1, CheckIn.replayed);

      // Ola's "Będę" from the app pins her ticket too; saying it again
      // brings no second "X będzie" for the organizer.
      await ola.events.rsvp(e.id, GuestStatus.going);
      expect(ola.events.ticketPinned(e.id), isTrue);
      final int shown = ania.shown.length;
      await ola.events.rsvp(e.id, GuestStatus.going);
      expect(ania.shown, hasLength(shown));
      expect(
        (await ania.events.checkIn(
          e.id,
          (await ola.events.ticketQr(e.id))!,
        )).$1,
        CheckIn.ok,
      );

      // Both sides remember the keys after a restart.
      final EventService organizer = EventService(
        host: ania,
        disk: ania.events.disk,
        now: () => ania.clock,
      );
      await organizer.load();
      final EventService guest = EventService(
        host: kuba,
        disk: kuba.events.disk,
        now: () => kuba.clock,
      );
      await guest.load();
      expect(guest.ticketPinned(e.id), isTrue);
      tick(EventTicket.liveWindow);
      expect(
        (await organizer.checkIn(e.id, (await guest.ticketQr(e.id))!)).$1,
        CheckIn.already,
      );
      expect(
        (await organizer.checkIn(e.id, kubaTicket.toQr())).$1,
        CheckIn.expired,
      );
    },
  );

  test(
    'an album is wiped with its event, even when it was never loaded',
    () async {
      final Map<String, _Host> net = <String, _Host>{};
      final _Host ania = _Host(net, 'a1', <String>[]);
      final MeetEvent old = await ania.events.create(
        title: 'Dawno temu',
        startsAt: 5000,
      );
      // Written by another copy of the service (the one in the background)
      // after this one had loaded.
      final MemoryLedgerDisk disk = ania.events.disk as MemoryLedgerDisk;
      disk.files[EventService.albumKey(old.id)] = Uint8List.fromList(
        utf8.encode('[]'),
      );
      expect(ania.events.photos(old.id), isEmpty);

      ania.clock += 31 * 24 * 3600 * 1000;
      await ania.events.create(title: 'Nowe', startsAt: ania.clock + 1000);
      expect(ania.events.event(old.id), isNull);
      expect(disk.files.containsKey(EventService.albumKey(old.id)), isFalse);
    },
  );

  test('a picture from another phone is refused from its header when it '
      'claims to be huge; real ones still go through', () {
    expect(photoSizeAllowed(claimedJpeg(64, 64)), isTrue);
    expect(photoSizeAllowed(claimedJpeg(4000, 4000)), isTrue);
    expect(photoSizeAllowed(claimedJpeg(kMaxRemotePhotoSide + 1, 10)), isFalse);
    expect(
      photoSizeAllowed(claimedJpeg(4096, 4000)),
      isFalse,
      reason: 'over 16 MP',
    );
    expect(
      photoSizeAllowed(Uint8List.fromList(utf8.encode('nie obraz'))),
      isFalse,
    );
    // Decoding this one would take more than a gigabyte.
    final Uint8List bomb = claimedJpeg(20000, 20000);
    expect(compressRemoteEventPhoto(bomb), isNull);
    expect(compressRemoteFlatPhoto(bomb), isNull);
    expect(compressEventPhoto(bomb), isNull);
    expect(compressRemoteEventPhoto(claimedJpeg(6000, 10)), isNull);

    // Phones of this app send JPEGs: those still go through; other formats
    // from another phone do not.
    final img.Image picture = img.Image(width: 64, height: 48);
    final Uint8List jpeg = Uint8List.fromList(img.encodeJpg(picture));
    expect(compressRemoteEventPhoto(jpeg), isNotNull);
    expect(compressRemoteFlatPhoto(jpeg), isNotNull);
    expect(
      compressRemoteEventPhoto(Uint8List.fromList(img.encodePng(picture))),
      isNull,
    );
    expect(
      compressEventPhoto(Uint8List.fromList(img.encodePng(picture))),
      isNotNull,
    );
    expect(
      compressRemoteEventPhoto(
        Uint8List(kMaxRemotePhotoInputBytes + 1)..setAll(0, jpeg),
      ),
      isNull,
      reason: 'too many bytes',
    );
  });

  test(
    'invitations: a stranger is never taken on their word, an invitation '
    'goes no further than its reach, and a flood stops at the guard',
    () async {
      final Map<String, _Host> net = <String, _Host>{};
      final _Host v = _Host(net, 'a1', <String>['b2', 'c3']);
      final _Host k = _Host(net, 'b2', <String>['a1']);
      final _Host w = _Host(net, 'c3', <String>['a1', 'd4']);
      final _Host y = _Host(net, 'd4', <String>['c3']);
      final _Host stranger = _Host(net, 'e5', <String>[]);

      // A stranger naming one of v's friends as the one who vouches, asking
      // for 5 more steps: nothing happens anywhere.
      await stranger.send(v.address, <String, dynamic>{
        'type': EventTypes.event,
        'e': invitation('robak', stranger.address, reach: EventReach.twoSteps),
        'by': k.address,
        'hops': 5,
      });
      expect(v.events.event('robak'), isNull);
      expect(w.events.event('robak'), isNull);
      expect(v.shown, isEmpty);

      // A friend's event goes only as far as its own reach says.
      await k.send(v.address, <String, dynamic>{
        'type': EventTypes.event,
        'e': invitation('impreza', k.address),
        'hops': 5,
      });
      expect(v.events.event('impreza'), isNotNull);
      expect(w.events.event('impreza'), isNotNull, reason: 'one step further');
      expect(y.events.event('impreza'), isNull, reason: 'not two');

      // Passed on by a friend: the steps are counted along the chain.
      await k.send(v.address, <String, dynamic>{
        'type': EventTypes.event,
        'e': invitation('dalej', stranger.address, reach: EventReach.twoSteps),
        'hops': 5,
        'chain': <Map<String, String>>[
          <String, String>{'a': k.address, 'n': 'b2'},
        ],
      });
      expect(w.events.event('dalej'), isNotNull);
      expect(y.events.event('dalej'), isNull);

      // Nothing far ahead (it would never be cleaned up), no odd ids.
      await k.send(v.address, <String, dynamic>{
        'type': EventTypes.event,
        'e': invitation(
          'za-rok',
          k.address,
          startsAt: v.clock + EventService.maxAhead + 1,
        ),
      });
      await k.send(v.address, <String, dynamic>{
        'type': EventTypes.event,
        'e': invitation('a/b', k.address),
      });
      expect(v.events.event('za-rok'), isNull);
      expect(v.events.event('a/b'), isNull);

      // A flood from one friend stops at the guard; a day later more come.
      for (int i = 0; i < 40; i++) {
        await k.send(v.address, <String, dynamic>{
          'type': EventTypes.event,
          'e': invitation('fala$i', k.address, reach: EventReach.selected),
        });
      }
      expect(
        v.events.events,
        hasLength(EventService.maxNewEventsPerFriendPerDay),
      );
      v.clock += 24 * 3600 * 1000 + 1;
      await k.send(v.address, <String, dynamic>{
        'type': EventTypes.event,
        'e': invitation('nowa', k.address, reach: EventReach.selected),
      });
      expect(v.events.event('nowa'), isNotNull);
    },
  );

  test('how an invitation came is forgotten together with the event', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2']);
    final _Host kuba = _Host(net, 'b2', <String>['a1', 'c3']);
    final _Host ola = _Host(net, 'c3', <String>['b2']);
    final MeetEvent e = await ania.events.create(
      title: 'Urodziny',
      startsAt: 100000,
      reach: EventReach.friendsOfFriends,
    );
    expect((_storedEvents(ola)['via'] as Map).containsKey(e.id), isTrue);
    expect((_storedEvents(ola)['tok'] as Map).containsKey(e.id), isTrue);
    expect(_storedEvents(kuba)['fwd'] as List, contains(e.id));

    for (final _Host h in <_Host>[ania, kuba, ola]) {
      h.clock = 100000 + 31 * 24 * 3600 * 1000;
    }
    await kuba.events.create(title: 'Nowe', startsAt: kuba.clock + 1000);
    await ola.events.create(title: 'Nowe', startsAt: ola.clock + 1000);
    expect(ola.events.event(e.id), isNull);
    expect((_storedEvents(ola)['via'] as Map).containsKey(e.id), isFalse);
    expect(_storedEvents(ola)['tok'], isNull);
    expect(_storedEvents(kuba)['fwd'] as List, isNot(contains(e.id)));
  });

  test('someone the organizer does not know may answer only with the token '
      'the friend who passed the invitation on gave them', () async {
    final Map<String, _Host> net = <String, _Host>{};
    final _Host ania = _Host(net, 'a1', <String>['b2']);
    final _Host kuba = _Host(net, 'b2', <String>['a1', 'c3']);
    final _Host ola = _Host(net, 'c3', <String>['b2', 'd4']);
    final _Host dalej = _Host(net, 'd4', <String>['c3']);
    final _Host obcy = _Host(net, 'f6', <String>[]);
    final MeetEvent e = await ania.events.create(
      title: 'Urodziny',
      startsAt: 100000,
      reach: EventReach.twoSteps,
      capacity: 10,
    );
    expect(dalej.events.event(e.id), isNotNull, reason: 'two steps away');
    Map<String, dynamic> answer(List<String> chain, {Object? tok}) =>
        <String, dynamic>{
          'type': EventTypes.rsvp,
          'id': e.id,
          's': 'going',
          'n': 'obcy',
          'chain': <Map<String, String>>[
            for (final String a in chain) <String, String>{'a': a, 'n': '?'},
          ],
          'tok': ?tok,
        };
    final String olaToken = (_storedEvents(ola)['tok'] as Map)[e.id] as String;
    final String dalejToken =
        (_storedEvents(dalej)['tok'] as Map)[e.id] as String;

    // A stranger claiming to be "a friend of Kuba": without a token, with a
    // made-up one, with Ola's (good for her address only), with Dalej's
    // along his chain — nothing counts.
    await obcy.send(ania.address, answer(<String>[kuba.address]));
    await obcy.send(
      ania.address,
      answer(<String>[kuba.address], tok: b64(List<int>.filled(32, 1))),
    );
    await obcy.send(
      ania.address,
      answer(<String>[kuba.address], tok: olaToken),
    );
    await obcy.send(
      ania.address,
      answer(<String>[kuba.address, ola.address], tok: dalejToken),
    );
    expect(ania.events.event(e.id)!.guest(obcy.address), isNull);
    expect(ania.events.event(e.id)!.goingCount, 0);

    // Ola answering without a token: she is not the organizer's friend, so
    // it does not count; from the app it does.
    await ola.send(ania.address, <String, dynamic>{
      'type': EventTypes.rsvp,
      'id': e.id,
      's': 'going',
      'n': 'c3',
      'chain': <Map<String, String>>[
        <String, String>{'a': kuba.address, 'n': 'b2'},
      ],
    });
    expect(ania.events.event(e.id)!.guest(ola.address), isNull);
    await ola.events.rsvp(e.id, GuestStatus.going);
    expect(
      ania.events.event(e.id)!.guest(ola.address)!.broughtBy,
      kuba.address,
    );

    // Two steps away, with who brought whom.
    await dalej.events.rsvp(e.id, GuestStatus.going);
    final MeetEvent mine = ania.events.event(e.id)!;
    expect(mine.guest(dalej.address)!.status, GuestStatus.going);
    expect(mine.chainOf(dalej.address), <String>[
      dalej.address,
      ola.address,
      kuba.address,
    ]);

    // The organizer's own friends still answer without any token; a long
    // name is cut.
    final _Host gosia = _Host(net, 'a7', <String>['a1']);
    ania.friendList.add(gosia.address);
    await gosia.send(ania.address, <String, dynamic>{
      'type': EventTypes.rsvp,
      'id': e.id,
      's': 'maybe',
      'n': 'G' * 1000,
    });
    expect(ania.events.event(e.id)!.guest(gosia.address)!.name, hasLength(60));
  });

  test(
    'someone who does not know the organizer gets the invitation through '
    'the friend who vouches for them, and only for their own friends',
    () async {
      final Map<String, _Host> net = <String, _Host>{};
      final _Host ania = _Host(net, 'a1', <String>['b2']);
      final _Host kuba = _Host(net, 'b2', <String>['a1', 'c3']);
      final _Host ola = _Host(net, 'c3', <String>['b2']);
      final _Host ewa = _Host(net, 'd4', <String>[]);
      final MeetEvent e = await ania.events.create(
        title: 'Grill',
        startsAt: 100000,
        invite: <String>[kuba.address],
      );
      await ania.events.allowPlusOnes(e.id, kuba.address, 1);
      await kuba.events.askPlusOne(e.id, ola.address);
      expect(ola.events.event(e.id), isNotNull);
      expect(ola.shown.last.body, contains('b2'), reason: 'through Kuba');
      expect(kuba.events.event(e.id)!.guest(ola.address), isNotNull);
      // Later copies come straight from the organizer.
      await ola.events.rsvp(e.id, GuestStatus.going);
      expect(ola.events.ticket(e.id), isNotNull);

      // Kuba passes on only what the organizer itself asks, for his own
      // friends listed as brought by him.
      final _Host zosia = _Host(net, 'e5', <String>['b2']);
      kuba.friendList.add(zosia.address);
      final _Host ania2 = _Host(net, 'a9', <String>['b2']);
      kuba.friendList.add(ania2.address);
      final Map<String, dynamic> json = ania.events.event(e.id)!.toJson()
        ..['org'] = ania.address;
      (json['guests'] as List<Map<String, dynamic>>).addAll(
        <Map<String, dynamic>>[
          <String, dynamic>{'a': ewa.address, 'n': 'd4', 'by': kuba.address},
          <String, dynamic>{'a': zosia.address, 'n': 'e5', 'by': kuba.address},
        ],
      );
      Map<String, dynamic> pass(String to) => <String, dynamic>{
        'type': EventTypes.pass,
        'e': json,
        'to': to,
      };
      await ania.send(kuba.address, pass(ewa.address));
      expect(ewa.events.event(e.id), isNull, reason: 'not his friend');
      await ania2.send(kuba.address, pass(zosia.address));
      expect(
        zosia.events.event(e.id),
        isNull,
        reason: 'only the organizer asks',
      );
      await ania.send(kuba.address, pass(zosia.address));
      expect(zosia.events.event(e.id), isNotNull);
    },
  );
}
