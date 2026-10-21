import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/meet/eat_together.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/nearby.dart';

void main() {
  const int now = 10 * 3600 * 1000;
  const int minute = 60 * 1000;
  const IntentStatus hungry = IntentStatus(
    kind: IntentKind.eat,
    setAt: now - 30 * minute,
    until: now + 60 * minute,
    note: 'pizza?',
  );

  test('"Chcę zjeść razem": a friend who wants to eat and was near within '
      'the hour', () {
    final List<EatTogether> got = eatTogetherNearby(
      hungry: <(String, IntentStatus)>[
        ('ola', hungry),
        ('kuba', hungry),
        ('zosia', hungry),
        ('ewa', hungry),
      ],
      // Ola in range now; a stranger (no friend) does not count.
      people: <NearbyPerson>[
        NearbyPerson(
          token: 'aa',
          device: 'mac1',
          rssi: -60,
          seenAt: now - minute,
          friend: 'ola',
        ),
        NearbyPerson(token: 'bb', device: 'mac2', rssi: -60, seenAt: now),
      ],
      encounters: const <Encounter>[
        // Kuba passed 40 minutes ago: still within the hour.
        Encounter(
          friend: 'kuba',
          start: now - 50 * minute,
          end: now - 40 * minute,
        ),
        // Zosia two hours ago: too long.
        Encounter(
          friend: 'zosia',
          start: now - 130 * minute,
          end: now - 120 * minute,
        ),
      ],
      now: now,
    );
    expect(got.map((EatTogether e) => e.friend), <String>['ola', 'kuba']);
    expect(got.first.status.note, 'pizza?');
  });

  test('only the "eat" status, still on, and not after "Nie teraz"', () {
    List<String> who({
      IntentStatus status = hungry,
      Set<String> dismissed = const <String>{},
    }) => eatTogetherNearby(
      hungry: <(String, IntentStatus)>[('ola', status)],
      people: const <NearbyPerson>[],
      encounters: const <Encounter>[
        Encounter(friend: 'ola', start: now - minute, end: now),
      ],
      now: now,
      dismissed: dismissed,
    ).map((EatTogether e) => e.friend).toList();

    expect(who(), <String>['ola']);
    expect(who(dismissed: <String>{'ola'}), isEmpty);
    expect(
      who(
        status: const IntentStatus(
          kind: IntentKind.eat,
          setAt: 0,
          until: now - minute,
        ),
      ),
      isEmpty,
    );
    expect(
      who(status: const IntentStatus(kind: IntentKind.walk, setAt: 0)),
      isEmpty,
    );
  });
}
