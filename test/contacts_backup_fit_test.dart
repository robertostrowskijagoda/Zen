import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/ledger/contacts_backup.dart';

String _addr(int i) =>
    '200:${(0x1000 + i).toRadixString(16)}:5e1f:9a3b:7c2d:4e6f:8a1b:'
    '${(0x2000 + i).toRadixString(16)}';

/// One big group never makes the backup of friends and groups unsavable:
/// a group's item carries the names of its members only, within a budget,
/// and an item still too big for a part loses what can come back later
/// (or is left out) instead of failing the whole backup.
void main() {
  /// A community group at the member limit with ordinary names (about 30
  /// characters), plus 60 people who wrote there and left since.
  Map<String, dynamic> bigGroup({required Map<String, String> names}) =>
      contactsItemWithStamps(
        <String, dynamic>{
          'id': 'grupa-osiedle',
          'name': 'Osiedle Słoneczne — wszyscy',
          'avatar': 'leaf',
          'by': _addr(10000),
          'at': 1,
          'm': <String>[for (int i = 0; i < 256; i++) _addr(10000 + i)],
          'mn': names,
        },
        'left',
        <String, int>{for (int i = 256; i < 316; i++) _addr(10000 + i): i},
      );

  final Map<String, String> everyone = <String, String>{
    for (int i = 0; i < 316; i++)
      _addr(10000 + i): 'Małgorzata Wiśniewska-Kołodziej $i',
  };
  final List<Map<String, dynamic>> friends = <Map<String, dynamic>>[
    for (int i = 0; i < 500; i++)
      <String, dynamic>{'a': _addr(i), 'n': 'Znajomy numer $i'},
  ];

  test('a full group with every name ever seen is trimmed, not a reason to '
      'save nothing', () {
    final Map<String, dynamic> group = bigGroup(names: everyone);
    expect(contactsJsonBytes(group), greaterThan(kContactsItemBytes));
    final Map<String, dynamic> snapshot = <String, dynamic>{
      'v': 1,
      'friends': friends,
      'groups': <Map<String, dynamic>>[group],
    };
    final ({Map<String, dynamic> snapshot, int trimmed}) fit = fitContacts(
      snapshot,
    );
    expect(fit.trimmed, 1);
    final ContactsSplit split = splitContacts(fit.snapshot);
    final Map<String, dynamic> set = contactsSetOf(split, <int>[
      for (int i = 1; i <= split.parts.length; i++) i,
    ]);
    final Map<String, dynamic>? back = assembleContacts(
      set,
      (int seq) => split.parts[seq - 1],
    );
    expect(back, isNotNull);
    expect(back!['friends'], hasLength(500));
    final Map<String, dynamic> kept =
        (back['groups'] as List<Object?>).single! as Map<String, dynamic>;
    expect(kept['id'], 'grupa-osiedle');
    expect(kept['m'], hasLength(256));
  });

  test('the names a group\'s item carries are its members\', within a '
      'budget, and then it fits a part with its record of who left', () {
    final List<String> members = <String>[
      for (int i = 0; i < 256; i++) _addr(10000 + i),
    ];
    final Map<String, String> names = contactsMemberNames(everyone, members);
    expect(names, isNotEmpty);
    expect(names.keys.every(members.contains), isTrue);
    expect(
      contactsJsonBytes(names),
      lessThanOrEqualTo(kContactsItemBytes ~/ 2),
    );
    final Map<String, dynamic> group = bigGroup(names: names);
    expect(contactsJsonBytes(group), lessThanOrEqualTo(kContactsItemBytes));
    expect(group['left'], isNotEmpty);
    expect(
      fitContacts(<String, dynamic>{
        'groups': <Map<String, dynamic>>[group],
      }).trimmed,
      0,
    );
    // A small group keeps every member's name, and no one else's.
    final Map<String, String> few = contactsMemberNames(
      <String, String>{_addr(1): 'Ala', _addr(2): 'Ola', _addr(3): 'Ela'},
      <String>[_addr(1), _addr(2)],
    );
    expect(few, <String, String>{_addr(1): 'Ala', _addr(2): 'Ola'});
  });

  test('a backup that fits is saved exactly as it is', () {
    final Map<String, dynamic> snapshot = <String, dynamic>{
      'v': 1,
      'friends': friends,
      'groups': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'g',
          'name': 'Mała',
          'm': <String>[_addr(1)],
          'mn': <String, String>{_addr(1): 'Ala'},
        },
      ],
    };
    final ({Map<String, dynamic> snapshot, int trimmed}) fit = fitContacts(
      snapshot,
    );
    expect(fit.trimmed, 0);
    expect(identical(fit.snapshot, snapshot), isTrue);
  });
}
