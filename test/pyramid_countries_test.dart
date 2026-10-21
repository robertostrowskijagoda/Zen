import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_items.dart';
import 'package:zen/src/features/pyramid/presentation/country_picker.dart';
import 'package:zen/src/features/pyramid/pyramid_countries.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

import 'support/pyramid_world.dart';

/// "Kraj" for everybody: the countries followed (by default the profile's
/// nationalities, else the phone's region; any others picked), their
/// sections passed on by member friends on request, with limits.
void main() {
  bool national(Map<String, dynamic> m) => m['type'] == PyramidTypes.national;

  test('outside the pyramid: the phone\'s region by default, any countries '
      'picked; member friends pass on what is asked, not too often', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final SimPhone o = w.add('O');
    w.regions['O'] = 'de';
    await w.pyr(o).load();
    w.net.befriend(w.net['B1'], o);
    final PyramidService reader = w['O'];
    // No nationality in the profile: the region.
    expect(reader.followedCountries, isEmpty);
    expect(reader.feedCountries, <String>['DE']);
    expect(feedFiltersFor(reader.feed), contains(FeedFilter.national));

    // The hello says which sections; B1 (a member) passes them on.
    await reader.greet();
    await w.net.run();
    final PyramidRecord? de = await w['B1'].natPost('Hallo');
    await w.net.run();
    expect(
      reader.nationalSection('DE').map((PyrNationalPost p) => p.id),
      <String>[de!.id],
    );
    expect(reader.feed.national.map((PyrFeedPost p) => p.id), <String>[de.id]);

    // Another country instead: the German section goes.
    await reader.followCountries(<String>['ua', 'UA', 'xx1']);
    await w.net.run();
    expect(reader.followedCountries, <String>['UA']);
    expect(reader.feedCountries, <String>['UA']);
    expect(reader.nationalSection('DE'), isEmpty);

    // Back to Germany: caught up again — but not more often than every
    // few minutes per friend.
    final int sent = w.net['B1'].outbox.where(national).length;
    await reader.followCountries(<String>['DE', 'UA']);
    await w.net.run();
    expect(w.net['B1'].outbox.where(national), hasLength(sent));
    await w.net.advance(const Duration(milliseconds: kPyrCatchUpEveryMs));
    await reader.greet();
    await w.net.run();
    expect(
      reader.nationalSection('DE').map((PyrNationalPost p) => p.id),
      <String>[de.id],
    );

    // At most a few countries.
    await reader.followCountries(kPyrCountryCodes.take(20));
    expect(reader.followedCountries, hasLength(kPyrFollowMax));
    // None: the default again (no profile nationality: the region).
    await reader.followCountries(const <String>[]);
    expect(reader.feedCountries, <String>['DE']);
    // Kept over a restart.
    await reader.followCountries(<String>['FR']);
    await reader.load();
    expect(reader.followedCountries, <String>['FR']);
  });

  test('the profile\'s nationalities come before the region', () async {
    final PyramidWorld w = PyramidWorld();
    final SimPhone p = w.add('P');
    w
      ..regions['P'] = 'FR'
      ..profileNationalities['P'] = <String>['pl', 'UA'];
    await w.pyr(p).load();
    expect(w['P'].feedCountries, <String>['PL', 'UA']);
  });

  test(
    'a member keeps their own section and may follow others (read only)',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidRecord? de = await w['B1'].natPost('Hallo');
      final PyramidRecord? pl = await w['A1'].natPost('Cześć');
      await w.net.run();
      await w.sync();
      final PyramidService a = w['A'];
      expect(a.feedCountries, <String>['PL']);
      expect(a.feed.national.map((PyrFeedPost x) => x.id), <String>[pl!.id]);
      await a.followCountries(<String>['DE']);
      expect(a.feedCountries, <String>['PL', 'DE']);
      final Map<String, PyrFeedPost> shown = <String, PyrFeedPost>{
        for (final PyrFeedPost x in a.feed.national) x.id: x,
      };
      expect(shown.keys, unorderedEquals(<String>[pl.id, de!.id]));
      expect(shown[pl.id]!.canComment, isTrue);
      expect(shown[de.id]!.canComment, isFalse, reason: 'another nationality');
    },
  );

  testWidgets('the picker: search by name in the app\'s language, pick '
      'several, done', (WidgetTester tester) async {
    List<String>? picked;
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async => picked = await pickCountries(
                context,
                selected: const <String>['PL'],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('country-PL')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('country-search')), 'niem');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('country-DE')), findsOneWidget);
    expect(find.byKey(const Key('country-FR')), findsNothing);
    expect(find.text(countryLabel('DE')), findsOneWidget);
    await tester.tap(find.byKey(const Key('country-DE')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('country-done')));
    await tester.pumpAndSettle();
    expect(picked, <String>['PL', 'DE']);
  });
}
