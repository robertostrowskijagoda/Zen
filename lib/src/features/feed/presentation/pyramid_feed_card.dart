import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/presentation/seen_tracker.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/pyramid/presentation/country_picker.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/presentation/report_sheet.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// The plaque of a pyramid post: „PIRAMIDA · szczyt”, „PIRAMIDA · Twoja
/// linia · poziom 2”, „KRAJ PL · prowadzący”.
String pyrFeedBadge(PyrFeedPost post) {
  final int level = post.level + 1;
  return switch (post.kind) {
    PyrFeedKind.top when post.delegated => t(
      'PIRAMIDA · do całej piramidy, z upoważnienia szefa',
    ),
    PyrFeedKind.top => t('PIRAMIDA · szczyt'),
    PyrFeedKind.line => t('PIRAMIDA · Twoja linia · poziom {level}', {
      'level': level,
    }),
    PyrFeedKind.own => t('PIRAMIDA · Twój post · poziom {level}', {
      'level': level,
    }),
    PyrFeedKind.national when post.lead => t('KRAJ {nat} · prowadzący', {
      'nat': post.nat,
    }),
    PyrFeedKind.national when post.priority => t('KRAJ {nat} · priorytet', {
      'nat': post.nat,
    }),
    PyrFeedKind.national => t('KRAJ {nat} · poziom {level}', {
      'nat': post.nat,
      'level': level,
    }),
  };
}

/// A pyramid post on the Tablica: a coloured stripe and its plaque, the
/// author's pyramid pseudonym (never a profile name), the text, the
/// branch's comments and „Komentuj” (members of the author's branch only)
/// and „Zgłoś”. A post the person reported is a line they can tap to see it
/// anyway. It counts as read once it was really on the screen
/// ([SeenTracker]).
class PyramidFeedCard extends ConsumerWidget {
  const PyramidFeedCard({required this.pyr, required this.post, super.key});

  final PyramidService pyr;
  final PyrFeedPost post;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final HiddenByMe hidden = ref.watch(hiddenByMeProvider);
    if (hidden.hides(id: post.id)) {
      return HiddenContentPlaceholder(
        key: Key('feed-hidden-${post.id}'),
        byMe: true,
        onShow: () => showHiddenAnyway(ref, id: post.id),
      );
    }
    final ZenColors zen = ZenColors.of(context);
    final bool national = post.kind == PyrFeedKind.national;
    final Color tone = national
        ? zen.tone(ZenTone.money)
        : post.kind == PyrFeedKind.top
        ? zen.warning
        : pyrTone(zen);
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final bool member = s != null && me != null && s.isMember(me);
    final bool leadsSection =
        national && member && s.nationalLead(post.nat) == me;
    final Set<String> bannedIds = s != null && member
        ? s.bannedEntries(pyr.now)
        : const <String>{};
    String nameOf(String key) => s?.members[key]?.name ?? '?';
    final ({int got, int read})? reach = post.kind == PyrFeedKind.own
        ? pyr.reachOf(post.id)
        : null;
    final String where = switch (post.kind) {
      PyrFeedKind.top => t('cała piramida'),
      PyrFeedKind.national => nationalityLabel(post.nat),
      _ when post.branch > 1 => t('do gałęzi {count} os.', <String, Object?>{
        'count': post.branch - 1,
      }),
      _ => t('do gałęzi'),
    };
    return SeenTracker(
      // A card further down the list reuses no other post's count.
      key: ValueKey<String>('feed-pyr-seen-${post.id}'),
      // One's own posts are not counted (the author does not count
      // themself), read ones not again.
      enabled: post.kind != PyrFeedKind.own && !pyr.wasRead(post.id),
      onSeen: () => pyr.markRead(<String>[post.id]),
      child: ZenCard(
        key: Key('feed-pyr-${post.id}'),
        padding: EdgeInsets.zero,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Container(
                width: 5,
                decoration: BoxDecoration(
                  color: tone,
                  borderRadius: BorderRadius.horizontal(
                    left: Radius.circular(ZenLook.of(context).radius(18)),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        pyrFeedBadge(post),
                        key: Key('feed-pyr-badge-${post.id}'),
                        style: zen.label(color: tone),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          PyrAvatar(
                            text: pyrInitial(post.name),
                            tone: tone,
                            size: 36,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  post.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: zen.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  <String>[
                                    where,
                                    pyrDate(post.at),
                                    if (!member) t('tylko do czytania'),
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
                        ],
                      ),
                      if (post.pinned) ...<Widget>[
                        const SizedBox(height: 6),
                        Row(
                          children: <Widget>[
                            Icon(
                              Icons.push_pin_rounded,
                              size: 15,
                              color: zen.warning,
                            ),
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
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          post.text,
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 15,
                            height: 1.45,
                          ),
                        ),
                      ),
                      if (reach != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8, right: 8),
                          child: Text(
                            t(
                              'Dotarło: {got} z {count} · przeczytało: {read}',
                              <String, Object?>{
                                'got': reach.got,
                                'count': post.branch > 0 ? post.branch - 1 : 0,
                                'read': reach.read,
                              },
                            ),
                            key: Key('pyr-reach-${post.id}'),
                            style: TextStyle(
                              color: zen.textMuted,
                              fontSize: 12,
                              height: 1.3,
                            ),
                          ),
                        ),
                      if (member && post.comments.isNotEmpty)
                        Container(
                          width: double.infinity,
                          margin: const EdgeInsets.fromLTRB(0, 10, 8, 0),
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          decoration: BoxDecoration(
                            color: zen.surfaceMuted,
                            borderRadius: context.zenRadius(
                              ZenLook.of(context).radius(14),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              for (final PyrComment c in post.comments)
                                if (!bannedIds.contains(c.id) &&
                                    !hidden.hides(id: c.id))
                                  InkWell(
                                    key: Key('pyr-comment-${c.id}'),
                                    // A comment is reported with its author.
                                    onLongPress: c.author == me
                                        ? null
                                        : () => unawaited(
                                            showReportSheet(
                                              context,
                                              pyr,
                                              target: c.author,
                                              evidence: t(
                                                'Komentarz — {name}\n{text}',
                                                <String, Object?>{
                                                  'name': nameOf(c.author),
                                                  'text': c.text,
                                                },
                                              ),
                                              contentId: c.id,
                                              entryId: c.id,
                                            ),
                                          ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 3,
                                      ),
                                      child: Text.rich(
                                        TextSpan(
                                          children: <InlineSpan>[
                                            TextSpan(
                                              text: '${nameOf(c.author)}  ',
                                              style: TextStyle(
                                                color: zen.textPrimary,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            TextSpan(text: c.text),
                                          ],
                                        ),
                                        style: TextStyle(
                                          color: zen.textSecondary,
                                          fontSize: 13.5,
                                          height: 1.35,
                                        ),
                                      ),
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      if (!member && post.commentCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            tn(
                              post.commentCount,
                              one: '{n} komentarz członka piramidy',
                              few: '{n} komentarze członków piramidy',
                              many: '{n} komentarzy członków piramidy',
                            ),
                            style: TextStyle(
                              color: zen.textMuted,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          if (member && post.canComment)
                            TextButton.icon(
                              key: Key('feed-pyr-comment-${post.id}'),
                              onPressed: () => unawaited(() async {
                                final String? text = await askText(
                                  context,
                                  title: t('Komentarz'),
                                  maxLines: 3,
                                );
                                if (text != null) {
                                  await pyr.comment(post.id, text);
                                }
                              }()),
                              icon: const Icon(
                                Icons.mode_comment_outlined,
                                size: 18,
                              ),
                              label: Text(
                                post.commentCount == 0
                                    ? t('Komentuj')
                                    : t('Komentuj ({count})', <String, Object?>{
                                        'count': post.commentCount,
                                      }),
                              ),
                            ),
                          if (leadsSection)
                            IconButton(
                              key: Key('pyr-pin-${post.id}'),
                              tooltip: post.pinned
                                  ? t('Odepnij')
                                  : t('Przypnij'),
                              icon: Icon(
                                post.pinned
                                    ? Icons.push_pin_rounded
                                    : Icons.push_pin_outlined,
                                color: post.pinned
                                    ? zen.warning
                                    : zen.textMuted,
                              ),
                              onPressed: () => unawaited(
                                pyr.pinNational(post.id, on: !post.pinned),
                              ),
                            ),
                          if (post.author != me)
                            IconButton(
                              key: Key('feed-pyr-report-${post.id}'),
                              tooltip: t('Zgłoś'),
                              icon: Icon(
                                Icons.flag_outlined,
                                color: zen.textMuted,
                              ),
                              onPressed: () => unawaited(
                                showReportSheet(
                                  context,
                                  pyr,
                                  target: post.author,
                                  evidence: post.text,
                                  contentId: post.id,
                                  // The post is a signed record every member
                                  // keeps: its id is the evidence and what a
                                  // ban names.
                                  entryId: post.id,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// „Referendum: … · Głosuj →”: the vote itself is in the Pyramid.
class PyramidReferendumCard extends StatelessWidget {
  const PyramidReferendumCard({required this.referendum, super.key});

  final PyrFeedReferendum referendum;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = pyrTone(zen);
    return ZenCard(
      key: Key('feed-ref-${referendum.id}'),
      tone: tone,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      onTap: () => unawaited(_open(context)),
      child: Row(
        children: <Widget>[
          ZenIconBadge(icon: Icons.how_to_vote_rounded, tone: tone, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  t('Referendum: {question}', <String, Object?>{
                    'question': referendum.question,
                  }),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                Text(
                  t('do {date} · doradcze', <String, Object?>{
                    'date': pyrDate(referendum.end),
                  }),
                  style: TextStyle(color: zen.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          TextButton(
            key: Key('feed-ref-vote-${referendum.id}'),
            onPressed: () => unawaited(_open(context)),
            child: Text(t('Głosuj →')),
          ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext _) => const PyramidScreen(openVotes: true),
    ),
  );
}

/// An alarm announcement in force: a red bar on top of the Tablica. A
/// notice for every member (a change of the emission limit announced) in
/// the colour of a warning.
class PyramidAlarmBar extends StatelessWidget {
  const PyramidAlarmBar({required this.alarm, super.key});

  final PyrFeedAlarm alarm;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = alarm.notice ? zen.warning : zen.danger;
    return Container(
      key: Key('feed-alarm-${alarm.id}'),
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: ZenLook.of(context).panel(zen, radius: 16, tone: tone),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.campaign_rounded, color: tone, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              alarm.notice
                  ? alarm.text
                  : t(
                      'Ogłoszenie alarmowe · do {date}\n{text}',
                      <String, Object?>{
                        'date': pyrDate(alarm.until),
                        'text': alarm.text,
                      },
                    ),
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Above the „Piramida” and „Kraj” lists: what the order is, and for a
/// member where to write (their branch; the section of their nationality,
/// with the lead's priority right). A reader outside learns that it only
/// reads.
class PyramidFeedHeader extends StatelessWidget {
  const PyramidFeedHeader({
    required this.pyr,
    required this.feed,
    required this.national,
    super.key,
  });

  final PyramidService pyr;
  final PyramidFeed feed;

  /// „Kraj” (else „Piramida”).
  final bool national;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = national ? zenTone(zen, 1) : pyrTone(zen);
    if (!feed.member) {
      final Widget info = ZenInfo(
        key: const Key('feed-pyr-readonly'),
        icon: Icons.visibility_outlined,
        tone: tone,
        text: national
            ? t(
                'Tylko do czytania: komentują członkowie piramidy tej '
                'narodowości. Posty przekazują Ci znajomi z piramidy.',
              )
            : t(
                'Tylko do czytania: posty szczytu do całej piramidy. '
                'Przekazują Ci je znajomi z piramidy.',
              ),
      );
      if (!national) {
        return info;
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          info,
          const SizedBox(height: 10),
          FollowedCountries(pyr: pyr),
        ],
      );
    }
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final String nat = feed.nat;
    final String? lead = s == null || nat.isEmpty ? null : s.nationalLead(nat);
    return ZenCard(
      key: Key(national ? 'feed-nat-header' : 'feed-pyr-header'),
      tone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            national
                ? (lead == null || s == null
                      ? t('Sekcja {nat} · bez osoby prowadzącej', {
                          'nat': nationalityLabel(nat),
                        })
                      : t('Sekcja {nat} · prowadzi: {name}', {
                          'nat': nationalityLabel(nat),
                          'name': s.members[lead]?.name ?? '?',
                        }))
                : t('Od szczytu, potem Twoja linia od najwyższego poziomu'),
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13,
              height: 1.35,
            ),
          ),
          if (national)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FollowedCountries(pyr: pyr),
            ),
          if (national)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                t('Jak w piramidzie: wyżej postawieni na górze.'),
                key: const Key('feed-nat-order'),
                style: TextStyle(
                  color: zen.textMuted,
                  fontSize: 12.5,
                  height: 1.35,
                ),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (national)
                FilledButton.icon(
                  key: const Key('feed-nat-post'),
                  onPressed: () => unawaited(() async {
                    final String? text = await askText(
                      context,
                      title: t('Post w sekcji {nat}', <String, Object?>{
                        'nat': nat,
                      }),
                      maxLines: 6,
                    );
                    if (text != null) {
                      await pyr.natPost(text);
                    }
                  }()),
                  icon: const Icon(Icons.edit_rounded),
                  label: Text(t('Napisz w sekcji')),
                )
              else ...<Widget>[
                PyramidBranchPostButton(pyr: pyr, branch: feed.branch),
                if (pyr.postingDelegation != null)
                  PyramidWholePostButton(pyr: pyr),
              ],
              if (national && s != null && me != null && lead == me)
                OutlinedButton.icon(
                  onPressed: () => unawaited(() async {
                    final String? name = await askText(
                      context,
                      title: t('Komu dać priorytet (pseudonim)?'),
                    );
                    final String? key = s.members.values
                        .where((PyrMember m) => m.name == name && m.nat == nat)
                        .map((PyrMember m) => m.key)
                        .firstOrNull;
                    if (key != null) {
                      await pyr.propose(
                        <String, dynamic>{
                          't': PyrT.natGrant,
                          'nat': nat,
                          'to': key,
                          'until': pyr.now + 30 * 24 * 3600 * 1000,
                        },
                        candidates: <String>[me],
                        need: 1,
                      );
                    }
                  }()),
                  icon: const Icon(Icons.star_outline_rounded),
                  label: Text(t('Nadaj priorytet (30 dni)')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
