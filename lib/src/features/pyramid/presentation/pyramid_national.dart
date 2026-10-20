import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// The way in to the national sections for somebody outside the pyramid
/// (§22.2): one row per nationality of the profile, read-only.
class PyramidNationalEntry extends StatelessWidget {
  const PyramidNationalEntry({
    required this.pyr,
    required this.nationalities,
    super.key,
  });

  final PyramidService pyr;

  /// The nationalities of this person's profile (§9).
  final List<String> nationalities;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenSection(t('Sekcja krajowa — tylko do czytania')),
        if (nationalities.isEmpty)
          ZenInfo(
            key: const Key('pyr-national-no-nationality'),
            icon: Icons.flag_outlined,
            tone: tone,
            text: t(
              'Dodaj narodowość w swoim profilu, żeby czytać sekcję krajową.',
            ),
          )
        else
          for (final String nat in nationalities)
            ZenTile(
              key: Key('pyr-national-read-$nat'),
              icon: Icons.flag_outlined,
              tone: tone,
              title: t('Sekcja {nat}', <String, Object?>{
                'nat': nationalityLabel(nat),
              }),
              subtitle: t('Czytasz; komentują członkowie piramidy.'),
              badge: switch (pyr.nationalSection(nat).length) {
                0 => null,
                final int n => '$n',
              },
              onTap: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (BuildContext _) =>
                        PyramidNationalReader(pyr: pyr, nat: nat),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

/// The national section of [nat], read-only (§22.2): for somebody who is
/// not a member — its posts, without commenting.
class PyramidNationalReader extends StatelessWidget {
  const PyramidNationalReader({
    required this.pyr,
    required this.nat,
    super.key,
  });

  final PyramidService pyr;
  final String nat;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 1);
    return Scaffold(
      key: const Key('pyr-national-reader'),
      appBar: ZenSectionBar(
        title: t('Sekcja krajowa {nat}', <String, Object?>{
          'nat': nationalityLabel(nat),
        }),
      ),
      body: ListenableBuilder(
        listenable: pyr,
        builder: (BuildContext context, Widget? _) {
          final List<PyrNationalPost> posts = pyr.nationalSection(nat);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              ZenInfo(
                icon: Icons.visibility_outlined,
                tone: tone,
                text: t(
                  'Tylko do czytania: komentują członkowie piramidy tej '
                  'narodowości. Posty przekazują Ci znajomi z piramidy.',
                ),
              ),
              if (posts.isEmpty)
                ZenEmpty(
                  icon: Icons.flag_outlined,
                  tone: tone,
                  title: t('Jeszcze nic'),
                  text: t(
                    'Gdy ktoś napisze w sekcji {nat}, znajomi z piramidy Ci '
                    'to przekażą.',
                    <String, Object?>{'nat': nat},
                  ),
                )
              else ...<Widget>[
                ZenSection(t('Posty w sekcji'), top: 16),
                for (final PyrNationalPost p in posts)
                  _NationalPostCard(post: p, tone: tone),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// One post of the section, read-only.
class _NationalPostCard extends StatelessWidget {
  const _NationalPostCard({required this.post, required this.tone});

  final PyrNationalPost post;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color levelTone = post.level == 0 ? zen.warning : tone;
    final String name = post.name.isEmpty ? '?' : post.name;
    return ZenCard(
      key: Key('pyr-national-post-${post.id}'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              PyrAvatar(text: pyrInitial(name), tone: levelTone, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      <String>[
                        if (post.lead) t('prowadzi sekcję'),
                        if (post.branch > 0)
                          t('gałąź {count} os.', <String, Object?>{
                            'count': post.branch,
                          }),
                        nationalityLabel(post.nat),
                        pyrDate(post.at),
                      ].join(' · '),
                      style: TextStyle(
                        color: zen.textMuted,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ZenPill(
                text: post.depth > 0
                    ? t('Poziom {level}/{depth}', <String, Object?>{
                        'level': post.level + 1,
                        'depth': post.depth,
                      })
                    : t('Poziom {level}', <String, Object?>{
                        'level': post.level + 1,
                      }),
                tone: levelTone,
                icon: Icons.arrow_upward_rounded,
              ),
            ],
          ),
          if (post.pinned) ...<Widget>[
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Icon(Icons.push_pin_rounded, size: 15, color: zen.warning),
                const SizedBox(width: 4),
                Text(
                  t('Przypięte w sekcji'),
                  style: TextStyle(
                    color: zen.warning,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            post.text,
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 15,
              height: 1.45,
            ),
          ),
          if (post.comments > 0) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              tn(
                post.comments,
                one: '{n} komentarz członka piramidy',
                few: '{n} komentarze członków piramidy',
                many: '{n} komentarzy członków piramidy',
              ),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
          ],
        ],
      ),
    );
  }
}
