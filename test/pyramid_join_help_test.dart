import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_join_help.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

PyrMember _member(
  String key,
  String addr, {
  Set<String> old = const <String>{},
}) => PyrMember(
  key: key,
  name: 'pseudonim-$key',
  nat: 'PL',
  birthYear: 1990,
  dataCommit: 'c',
  joinedAt: 1,
  pq: 'pq',
  addr: addr,
)..addrs.addAll(old);

void main() {
  test('friends who are members are named, by their device address', () {
    final List<PyrMember> members = <PyrMember>[
      _member('k1', '200::a1'),
      _member('k2', '200::b9', old: <String>{'200::b2'}),
      _member('k3', '200::c3'),
    ];
    expect(
      friendsInPyramid(members, <String, String>{
        '200:0:0:0:0:0:0:a1': 'Ola',
        '200::b2': 'Piotr',
        '200::d4': 'Ewa',
      }),
      <String>['Ola', 'Piotr'],
    );
  });

  test('a member who left does not count', () {
    final PyrMember gone = _member('k1', '200::a1')..active = false;
    expect(
      friendsInPyramid(<PyrMember>[gone], <String, String>{'200::a1': 'Ola'}),
      isEmpty,
    );
  });
}
