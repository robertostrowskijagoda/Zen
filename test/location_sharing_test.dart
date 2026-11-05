import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/messages/chat_location.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/location_sharing.dart';
import 'package:zen/src/features/chat/presentation/shared_location_card.dart';
import 'package:zen/src/features/meet/location.dart';

// "Udostępnij położenie": once, or live for a while; newer positions go
// as edits of the same message only when the device moved, and the
// sharing ends at its time or when stopped.
void main() {
  const String ola = '200:1111:2222:3333:4444:5555:6666:7777';

  test('the wire form is checked; a live one never outlasts the longest '
      'sharing', () {
    const ChatLocation here = ChatLocation(
      lat: 52.2297,
      lon: 21.0122,
      accuracy: 12,
      atMillis: 1000,
      untilMillis: 1000 + 3600000,
    );
    expect(ChatLocation.fromJson(here.toJson()), here);
    expect(
      ChatLocation.fromJson(<String, Object?>{
        'la': 91,
        'lo': 0,
        'at': 1,
        'un': 1,
      }),
      isNull,
    );
    expect(
      ChatLocation.fromJson(<String, Object?>{
        'la': 1,
        'lo': 1,
        'at': 1000,
        'un': 1000 + 100 * 3600000,
      })!.untilMillis,
      1000 + kMaxLocationShare.inMilliseconds,
    );
    // Stored with its message.
    final ChatMessage m = ChatMessage(
      id: 'm',
      sender: 'self',
      text: 'x',
      sentAtMillis: 1,
      direction: ChatMessageDirection.outgoing,
      location: here,
    );
    expect(
      chatMessageWithExtras(
        m.copyWith(location: null),
        chatMessageExtrasToJson(m),
      ).location,
      here,
    );
  });

  test('live sharing: newer positions when moved, nothing while standing, '
      'the end at its time; after a restart it goes on', () async {
    int now = 1000000;
    GeoFix fix = const GeoFix(52.2297, 21.0122, 10);
    final List<String> sent = <String>[];
    final List<ChatLocation> updates = <ChatLocation>[];
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    LocationSharingService service() => LocationSharingService(
      disk: disk,
      now: () => now,
      readFix: ({required bool ask}) async => fix,
      send: (String key, String text, ChatLocation location) async {
        sent.add(text);
        return 'msg-1';
      },
      update: (String key, String id, String text, ChatLocation l) async {
        updates.add(l);
        return true;
      },
    );
    final LocationSharingService sharing = service();
    await sharing.share(ola, length: const Duration(minutes: 15));
    expect(sent.single, contains('openstreetmap.org'));
    expect(sharing.isSharing('msg-1'), isTrue);

    // A minute later, still standing: nothing new.
    now += 60000;
    await sharing.tick();
    expect(updates, isEmpty);

    // Moved about 110 m.
    fix = const GeoFix(52.2307, 21.0122, 10);
    await sharing.tick();
    expect(updates.single.lat, 52.2307);

    // Ten minutes standing still: sent once more anyway.
    now += 10 * 60000;
    final LocationSharingService again = service();
    await again.tick();
    expect(updates, hasLength(2));

    // Its time is up.
    now += 5 * 60000;
    await again.tick();
    expect(again.isSharing('msg-1'), isFalse);
    again.dispose();
    sharing.dispose();
  });

  test('stopped early: the last position stays, marked as ended', () async {
    final List<ChatLocation> updates = <ChatLocation>[];
    final LocationSharingService sharing = LocationSharingService(
      disk: MemoryLedgerDisk(),
      now: () => 5000,
      readFix: ({required bool ask}) async => const GeoFix(1, 2, 3),
      send: (String key, String text, ChatLocation location) async => 'm',
      update: (String key, String id, String text, ChatLocation l) async {
        updates.add(l);
        return true;
      },
    );
    await sharing.share(ola, length: const Duration(hours: 1));
    await sharing.stop('m');
    expect(updates.single.isLiveAt(5000), isFalse);
    expect(sharing.isSharing('m'), isFalse);
    sharing.dispose();
  });

  test('"Jestem na miejscu": where the device is now, marked as arrived, '
      'and the sharing ends', () async {
    final List<(String, ChatLocation)> updates = <(String, ChatLocation)>[];
    int now = 5000;
    GeoFix? fix = const GeoFix(1, 2, 3);
    final LocationSharingService sharing = LocationSharingService(
      disk: MemoryLedgerDisk(),
      now: () => now,
      readFix: ({required bool ask}) async => fix,
      send: (String key, String text, ChatLocation location) async =>
          'm${updates.length}',
      update: (String key, String id, String text, ChatLocation l) async {
        updates.add((text, l));
        return true;
      },
    );
    await sharing.share(ola, length: const Duration(hours: 1));
    now = 65000;
    fix = const GeoFix(1.01, 2, 4);
    await sharing.arrive('m0');
    final (String text, ChatLocation here) = updates.single;
    expect(here.arrived, isTrue);
    expect(here.lat, 1.01);
    expect(here.atMillis, 65000);
    expect(here.isLiveAt(65000), isFalse);
    expect(text, startsWith('📍 Jestem na miejscu: '));
    expect(sharing.isSharing('m0'), isFalse);
    expect(ChatLocation.fromJson(here.toJson()), here);
    expect(here.toJson()['ar'], isTrue);
    // Arriving at nothing shared sends nothing.
    await sharing.arrive('m0');
    expect(updates, hasLength(1));

    // No position now: the last one, marked as arrived.
    await sharing.share(ola, length: const Duration(hours: 1));
    fix = null;
    await sharing.arrive('m1');
    expect(updates.last.$2.arrived, isTrue);
    expect(updates.last.$2.lat, 1.01);
    sharing.dispose();
  });

  test('no position: a message for the person, nothing sent', () async {
    final List<String> sent = <String>[];
    final LocationSharingService sharing = LocationSharingService(
      disk: MemoryLedgerDisk(),
      readFix: ({required bool ask}) async => null,
      send: (String key, String text, ChatLocation location) async {
        sent.add(text);
        return 'm';
      },
      update: (String key, String id, String text, ChatLocation l) async =>
          true,
    );
    await expectLater(sharing.share(ola), throwsStateError);
    expect(sent, isEmpty);
    sharing.dispose();
  });

  test('distance', () {
    expect(metresBetween(52, 21, 52, 21), 0);
    expect(metresBetween(52, 21, 52.001, 21), closeTo(111, 1));
  });

  testWidgets('the card: live until its time, the map, and ending the own '
      'sharing', (WidgetTester tester) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final List<ChatLocation> updates = <ChatLocation>[];
    final LocationSharingService sharing = LocationSharingService(
      disk: MemoryLedgerDisk(),
      readFix: ({required bool ask}) async => const GeoFix(52, 21, 9),
      send: (String key, String text, ChatLocation location) async => 'm',
      update: (String key, String id, String text, ChatLocation l) async {
        updates.add(l);
        return true;
      },
    );
    await tester.runAsync(
      () => sharing.share(ola, length: const Duration(hours: 1)),
    );
    final ChatMessage m = ChatMessage(
      id: 'm',
      sender: 'self',
      text: 'x',
      sentAtMillis: now,
      direction: ChatMessageDirection.outgoing,
      location: ChatLocation(
        lat: 52,
        lon: 21,
        accuracy: 9,
        atMillis: now,
        untilMillis: now + 3600000,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [locationSharingProvider.overrideWithValue(sharing)],
        child: MaterialApp(
          theme: ZenTheme.light(),
          home: Scaffold(body: SharedLocationCard(message: m)),
        ),
      ),
    );
    expect(find.byKey(const Key('shared-location-map')), findsOneWidget);
    await tester.tap(find.byKey(const Key('shared-location-stop')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(updates, hasLength(1));
    expect(find.byKey(const Key('shared-location-stop')), findsNothing);
    sharing.dispose();
  });
  test('how often a position is read, by the length; which shares are '
      "a conversation's; which systems share", () async {
    expect(
      locationUpdateEvery(const Duration(minutes: 15)),
      const Duration(minutes: 1),
    );
    expect(
      locationUpdateEvery(const Duration(minutes: 16)),
      const Duration(minutes: 2),
    );
    expect(
      locationUpdateEvery(const Duration(hours: 1)),
      const Duration(minutes: 2),
    );
    expect(
      locationUpdateEvery(const Duration(minutes: 61)),
      const Duration(minutes: 5),
    );

    int id = 0;
    final LocationSharingService sharing = LocationSharingService(
      disk: MemoryLedgerDisk(),
      now: () => 5000,
      readFix: ({required bool ask}) async => const GeoFix(1, 2, 3),
      send: (String key, String text, ChatLocation location) async =>
          'm${id++}',
      update: (String key, String id, String text, ChatLocation l) async =>
          true,
    );
    await sharing.share(ola, length: const Duration(hours: 1));
    await sharing.share('group:g', length: const Duration(hours: 1));
    expect(sharing.active(ola).map((LocationShare s) => s.messageId), <String>[
      'm0',
    ]);
    expect(sharing.active('group:x'), isEmpty);
    expect(sharing.active(), hasLength(2));
    sharing.dispose();

    for (final (TargetPlatform platform, bool shares)
        in <(TargetPlatform, bool)>[
          (TargetPlatform.android, true),
          (TargetPlatform.windows, true),
          (TargetPlatform.linux, false),
          (TargetPlatform.fuchsia, false),
        ]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(locationSharingAvailable, shares, reason: '$platform');
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
