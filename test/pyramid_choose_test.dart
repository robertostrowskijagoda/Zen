import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

import 'support/pyramid_world.dart';

void main() {
  test('someone in two pyramids sees the one joined last', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidService a1 = w['A1'];
    final String first = a1.current!;
    // Later A1 starts a pyramid of their own: that is where they want to be.
    await w.net.advance(const Duration(hours: 1));
    final String second = await a1.createPyramid(
      name: 'Druga',
      myName: 'A1',
      nat: 'PL',
      birthYear: 1990,
      gender: 'k',
    );
    expect(second, isNot(first));
    expect(a1.current, second);
    // The others stay where they are.
    expect(w['S'].current, first);
  });
}
