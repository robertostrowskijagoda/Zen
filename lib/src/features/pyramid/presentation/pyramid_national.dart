import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// What somebody outside the pyramid reads of it — the top's posts to the
/// whole pyramid and the sections of their profile's nationalities, passed
/// on by friends who are members — is on the Tablica only (read-only,
/// members comment). Here: how many there are, and the way there.
class PyramidNationalEntry extends StatelessWidget {
  const PyramidNationalEntry({
    required this.pyr,
    required this.nationalities,
    super.key,
  });

  final PyramidService pyr;

  /// The nationalities of this person's profile.
  final List<String> nationalities;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 1);
    final PyramidFeed feed = pyr.feed;
    final int top = feed.pyramid.length;
    final int national = feed.national.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenSection(t('Piramida — tylko do czytania')),
        if (top + national > 0)
          ZenTile(
            key: const Key('pyr-read-open-feed'),
            icon: Icons.newspaper_rounded,
            tone: tone,
            title: t('Posty piramidy · Otwórz na Tablicy →'),
            subtitle: <String>[
              if (top > 0)
                tn(
                  top,
                  one: '{n} post szczytu',
                  few: '{n} posty szczytu',
                  many: '{n} postów szczytu',
                ),
              if (national > 0)
                tn(
                  national,
                  one: '{n} z sekcji krajowej',
                  few: '{n} z sekcji krajowej',
                  many: '{n} z sekcji krajowej',
                ),
            ].join(' · '),
            onTap: () => pyrOpenFeed(
              context,
              top > 0 ? FeedFilter.pyramid : FeedFilter.national,
            ),
          )
        else
          ZenInfo(
            key: const Key('pyr-read-nothing'),
            icon: Icons.visibility_outlined,
            tone: tone,
            text: t(
              'Gdy szczyt piramidy albo ktoś z sekcji Twojej narodowości coś '
              'napisze, znajomi z piramidy Ci to przekażą. Przeczytasz to na '
              'Tablicy.',
            ),
          ),
        if (nationalities.isEmpty)
          ZenInfo(
            key: const Key('pyr-national-no-nationality'),
            icon: Icons.flag_outlined,
            tone: tone,
            text: t(
              'Dodaj narodowość w swoim profilu, żeby czytać sekcję krajową.',
            ),
          ),
      ],
    );
  }
}
