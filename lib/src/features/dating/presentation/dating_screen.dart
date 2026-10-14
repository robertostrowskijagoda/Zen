import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/dating/presentation/dating_deck.dart';
import 'package:zen/src/features/dating/presentation/dating_profile_editor.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/presentation/safe_photo.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/presentation/report_sheet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The tone of dating screens.
Color datingTone(ZenColors zen) => zenTone(zen, 4);

/// A dating photo (base64 JPEG) or a placeholder.
Widget datingPhoto(String? photo, {double size = 72}) {
  final BorderRadius radius = BorderRadius.circular(size * 0.3);
  if (photo != null) {
    // Someone else's photo: made again here before it is shown (§19).
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox.square(
        dimension: size,
        child: SafePhoto(
          data: photo,
          clean: true,
          icon: Icons.favorite_rounded,
        ),
      ),
    );
  }
  return Builder(
    builder: (BuildContext context) {
      final Color tone = datingTone(ZenColors.of(context));
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            colors: <Color>[
              tone.withValues(alpha: 0.32),
              tone.withValues(alpha: 0.10),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: tone.withValues(alpha: 0.30)),
        ),
        child: Icon(Icons.favorite_rounded, color: tone, size: size * 0.45),
      );
    },
  );
}

/// A photo filling its box (cards, the profile), or a soft placeholder.
Widget datingCover(String? photo, ZenColors zen, Color tone) {
  if (photo != null) {
    return SafePhoto(data: photo, clean: true, icon: Icons.favorite_rounded);
  }
  return DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        colors: <Color>[
          Color.alphaBlend(tone.withValues(alpha: 0.55), zen.surface),
          Color.alphaBlend(
            zen.accentSecondary.withValues(alpha: 0.25),
            zen.surface,
          ),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Icon(
        Icons.favorite_rounded,
        size: 72,
        color: ZenColors.foregroundFor(tone).withValues(alpha: 0.75),
      ),
    ),
  );
}

/// The photos of a profile (up to four, §19.1) to swipe through, with dots
/// when there is more than one.
class DatingPhotoPager extends StatefulWidget {
  const DatingPhotoPager({required this.photos, super.key});

  final List<String> photos;

  @override
  State<DatingPhotoPager> createState() => _DatingPhotoPagerState();
}

class _DatingPhotoPagerState extends State<DatingPhotoPager> {
  final PageController _pages = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    final List<String> photos = widget.photos;
    if (photos.length <= 1) {
      return datingCover(photos.isEmpty ? null : photos.first, zen, tone);
    }
    final int current = _page.clamp(0, photos.length - 1);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PageView.builder(
          key: const Key('dating-photos'),
          controller: _pages,
          itemCount: photos.length,
          onPageChanged: (int i) => setState(() => _page = i),
          itemBuilder: (BuildContext context, int i) =>
              datingCover(photos[i], zen, tone),
        ),
        Positioned(
          top: 10,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (int i = 0; i < photos.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == current ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == current
                          ? const Color(0xFFFFFFFF)
                          : const Color(0x99FFFFFF),
                      borderRadius: BorderRadius.circular(4),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(color: Color(0x40000000), blurRadius: 4),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// "Znacie się przez: Bob → Kasia" (§19.3).
String datingWay(SeenProfile s) {
  if (s.introBy != null) {
    return 'Przedstawia: ${s.introBy}';
  }
  if (s.distance <= 1) {
    return 'To ktoś z Twoich znajomych';
  }
  return 'Znacie się przez: ${s.path.join(' → ')}';
}

/// "Randki przez znajomych" (§19).
class DatingScreen extends ConsumerStatefulWidget {
  const DatingScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const DatingScreen(),
    ),
  );

  @override
  ConsumerState<DatingScreen> createState() => _DatingScreenState();
}

class _DatingScreenState extends ConsumerState<DatingScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(datingServiceProvider).load());
  }

  @override
  Widget build(BuildContext context) {
    final DatingService dating = ref.watch(datingServiceProvider);
    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    return ListenableBuilder(
      listenable: dating,
      builder: (BuildContext context, Widget? _) {
        if (!dating.active) {
          return Scaffold(
            key: const Key('dating-screen'),
            appBar: const ZenSectionBar(title: 'Randki'),
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: <Widget>[
                ZenHero(
                  title: 'Randki przez znajomych',
                  icon: Icons.favorite_rounded,
                  tone: tone,
                  text:
                      'Tylko z ludźmi oddalonymi o 1–3 kroki znajomości — '
                      'zawsze jest ktoś wspólny, kogo można zapytać.',
                ),
                ZenInfo(
                  icon: Icons.visibility_off_rounded,
                  tone: tone,
                  title: 'Nikt nie wie, że randkujesz',
                  text:
                      'Twój telefon wysyła i przekazuje dalej takie same '
                      'paczki, czy randki są włączone, czy nie.',
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('dating-setup'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: tone,
                    foregroundColor: ZenColors.foregroundFor(tone),
                  ),
                  onPressed: () => unawaited(DatingProfileEditor.open(context)),
                  icon: const Icon(Icons.favorite_rounded),
                  label: Text(
                    dating.me.complete
                        ? 'Włącz randki'
                        : 'Załóż profil randkowy',
                  ),
                ),
                const SizedBox(height: 8),
                _FriendCorner(dating: dating),
              ],
            ),
          );
        }
        return DefaultTabController(
          length: 3,
          child: Scaffold(
            key: const Key('dating-screen'),
            appBar: ZenSectionBar(
              title: 'Randki',
              actions: <Widget>[
                IconButton(
                  tooltip: 'Mój profil randkowy',
                  icon: const Icon(Icons.account_circle_rounded),
                  onPressed: () => unawaited(DatingProfileEditor.open(context)),
                ),
              ],
              bottom: TabBar(
                indicatorColor: tone,
                labelColor: tone,
                unselectedLabelColor: zen.textSecondary,
                labelStyle: const TextStyle(fontWeight: FontWeight.w700),
                tabs: <Widget>[
                  Tab(text: 'Nowe (${dating.toDecide.length})'),
                  Tab(text: 'Pary (${dating.matches.length})'),
                  const Tab(text: 'Więcej'),
                ],
              ),
            ),
            body: TabBarView(
              children: <Widget>[
                _NewProfiles(dating: dating),
                _Matches(dating: dating),
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: <Widget>[
                    _SafeDateCard(dating: dating),
                    if (dating.liked.isNotEmpty) ...<Widget>[
                      const ZenSection('Czekasz na odpowiedź'),
                      for (final SeenProfile s in dating.liked)
                        _PersonRow(
                          photo: s.profile.photo,
                          title: '${s.profile.name}, ${s.profile.age}',
                          subtitle: 'Dowiesz się tylko, jeśli też powie „Tak”.',
                          trailing: Icon(
                            Icons.hourglass_top_rounded,
                            color: zen.textMuted,
                            size: 20,
                          ),
                          onTap: () => unawaited(
                            DatingProfileScreen.open(context, s.profile.key),
                          ),
                        ),
                    ],
                    _FriendCorner(dating: dating),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A person in a list: photo, name, a line under it.
class _PersonRow extends StatelessWidget {
  const _PersonRow({
    required this.photo,
    required this.title,
    required this.subtitle,
    this.subtitleColor,
    this.trailing,
    this.onTap,
  });

  final String? photo;
  final String title;
  final String subtitle;
  final Color? subtitleColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ZenCard(
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
      child: Row(
        children: <Widget>[
          datingPhoto(photo, size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: subtitleColor ?? zen.textSecondary,
                    fontSize: 13.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// A quoted line: an intro note or what a friend says.
class DatingQuote extends StatelessWidget {
  const DatingQuote({
    required this.text,
    super.key,
    required this.tone,
    this.by,
    this.signed = false,
  });

  final String text;
  final String? by;
  final Color tone;

  /// A friend's vouch, signed by them (checked on arrival).
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tone.withValues(alpha: 0.20)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.format_quote_rounded, color: tone, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '„$text”',
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 14,
                    height: 1.4,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                if (by != null && by!.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(text: '— ${by!}'),
                        if (signed)
                          TextSpan(
                            text: '  ✓ podpisane',
                            style: TextStyle(color: zen.success),
                          ),
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textMuted,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Nowe": the profiles to decide on, as a stack of cards (§19.5).
class _NewProfiles extends StatelessWidget {
  const _NewProfiles({required this.dating});

  final DatingService dating;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<SeenProfile> list = dating.toDecide;
    if (list.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: ZenEmpty(
            icon: Icons.favorite_border_rounded,
            tone: datingTone(zen),
            title: 'Na razie nikogo nowego',
            text:
                'Profile przychodzą od znajomych i ich znajomych — zwykle '
                'w ciągu tygodnia.',
          ),
        ),
      );
    }
    return DatingSwipeDeck(
      key: const Key('dating-deck'),
      profiles: list,
      onDecide: (SeenProfile s, bool yes) => dating.decide(s.profile.key, yes),
      onOpen: (SeenProfile s) =>
          unawaited(DatingProfileScreen.open(context, s.profile.key)),
      onMatchmake: (SeenProfile s) =>
          unawaited(introduceDatingProfile(context, dating, s)),
      onAsk: (SeenProfile s) => unawaited(askDatingOpinion(context, dating, s)),
    );
  }
}

/// "Zapytaj o opinię" (§19.3): a question to the friend the profile came
/// through (they learn that this person dates).
Future<void> askDatingOpinion(
  BuildContext context,
  DatingService dating,
  SeenProfile s,
) async {
  final TextEditingController c = TextEditingController(
    text: 'Co sądzisz o ${s.profile.name}?',
  );
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('Zapytaj o opinię'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const ZenInfo(
                icon: Icons.info_outline_rounded,
                text:
                    'Pytanie trafi do znajomego, od którego przyszedł profil. '
                    'Uwaga: dowie się wtedy, że randkujesz.',
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('dating-ask-text'),
                controller: c,
                maxLines: 3,
                maxLength: 500,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Pytanie'),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          key: const Key('dating-ask-send'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Zapytaj'),
        ),
      ],
    ),
  );
  final String question = c.text;
  disposeLater(c);
  if (ok != true) {
    return;
  }
  final bool sent = await dating.askOpinion(s.profile.key, question);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sent
              ? 'Pytanie poszło. Odpowiedź zobaczysz w zakładce „Więcej”.'
              : 'Nie da się teraz zapytać.',
        ),
      ),
    );
  }
}

/// "Swatuj" (§19.3): introduces [s] to another person this phone knows from
/// dating; both get the other's profile and the note.
Future<void> introduceDatingProfile(
  BuildContext context,
  DatingService dating,
  SeenProfile s,
) async {
  final List<SeenProfile> others = <SeenProfile>[
    ...dating.toDecide,
    ...dating.liked,
    ...dating.matches,
  ].where((SeenProfile o) => o.profile.key != s.profile.key).toList();
  if (others.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Nie znasz jeszcze nikogo innego w randkach.'),
      ),
    );
    return;
  }
  String? chosen;
  final TextEditingController note = TextEditingController();
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) {
        final ZenColors zen = ZenColors.of(context);
        final Color tone = datingTone(zen);
        return AlertDialog(
          title: Text('Przedstaw ${s.profile.name} komuś'),
          content: SizedBox(
            width: 400,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                for (final SeenProfile o in others)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: ListTile(
                      selected: chosen == o.profile.key,
                      selectedColor: tone,
                      selectedTileColor: tone.withValues(alpha: 0.10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      leading: datingPhoto(o.profile.photo, size: 40),
                      title: Text(
                        '${o.profile.name}, ${o.profile.age}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: chosen == o.profile.key
                          ? Icon(Icons.check_circle_rounded, color: tone)
                          : null,
                      onTap: () => set(() => chosen = o.profile.key),
                    ),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: note,
                  maxLength: 300,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Dlaczego?',
                    hintText: 'Myślę, że się polubicie',
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Anuluj'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Przedstaw'),
            ),
          ],
        );
      },
    ),
  );
  final String text = note.text;
  disposeLater(note);
  final String? pick = chosen;
  if (ok == true && pick != null) {
    final bool sent = await dating.introduce(s.profile.key, pick, text);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sent ? 'Wysłane do obojga.' : 'Nie da się teraz do nich dotrzeć.',
          ),
        ),
      );
    }
  }
}

class _Matches extends StatelessWidget {
  const _Matches({required this.dating});

  final DatingService dating;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    final List<SeenProfile> list = dating.matches;
    if (list.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: ZenEmpty(
            icon: Icons.favorite_rounded,
            tone: tone,
            title: 'Jeszcze bez par',
            text:
                'Para powstaje, gdy oboje powiecie „Tak”. „Nie” nikt nigdy '
                'nie zobaczy.',
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        for (final SeenProfile s in list)
          Builder(
            builder: (BuildContext context) {
              final List<DatingLine> chat = dating.chat(s.profile.key);
              return _PersonRow(
                photo: s.profile.photo,
                title: '${s.profile.name}, ${s.profile.age}',
                subtitle: chat.isEmpty
                    ? 'Napisz pierwszy(-a)!'
                    : chat.last.text,
                subtitleColor: chat.isEmpty ? tone : null,
                trailing: ZenIconBadge(
                  icon: Icons.chat_bubble_rounded,
                  tone: tone,
                  size: 38,
                ),
                onTap: () =>
                    unawaited(DatingChatScreen.open(context, s.profile.key)),
              );
            },
          ),
      ],
    );
  }
}

/// A profile in full: path, vouches, asking a friend, introducing, blocking.
class DatingProfileScreen extends ConsumerWidget {
  const DatingProfileScreen({required this.profileKey, super.key});

  final String profileKey;

  static Future<void> open(BuildContext context, String key) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              DatingProfileScreen(profileKey: key),
        ),
      );

  /// "Podziękuj swatowi" (§19.3): a payment in the pyramid's currency to
  /// the friend who introduced the pair.
  Future<void> _thank(
    BuildContext context,
    WidgetRef ref,
    DatingService dating,
    SeenProfile s,
  ) async {
    final PyramidService pyramid = ref.read(pyramidServiceProvider);
    final String? mine = pyramid.myKey;
    final int balance = mine == null ? 0 : pyramid.state?.balanceOf(mine) ?? 0;
    final TextEditingController amount = TextEditingController(text: '10');
    // Amounts are kept in hundredths (see parseMoney / formatMoney).
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Podziękuj: ${s.introBy ?? 'swat'}'),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const ZenInfo(
                  icon: Icons.volunteer_activism_rounded,
                  text:
                      'Przelew w walucie piramidy. W tytule będzie tylko '
                      '„Podziękowanie” — nikt nie dowie się, za co.',
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('dating-thank-amount'),
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Kwota',
                    prefixIcon: const Icon(Icons.toll_rounded),
                    helperText: 'Masz: ${formatMoney(balance)}',
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Wyślij'),
          ),
        ],
      ),
    );
    final int value = parseMoney(amount.text) ?? 0;
    disposeLater(amount);
    if (ok != true) {
      return;
    }
    // Money leaves: asked again who this is (§14.1).
    if (value > 0 &&
        value <= balance &&
        (!context.mounted || !await confirmPayment(context))) {
      return;
    }
    final bool sent =
        value > 0 &&
        value <= balance &&
        await dating.thankMatchmaker(s.profile.key, value);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sent
                ? 'Wysłane. Dziękujecie swatowi 💐'
                : value > balance
                ? 'Za mało środków.'
                : 'Nie udało się wysłać (może czeka jeszcze poprzedni przelew).',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DatingService dating = ref.watch(datingServiceProvider);
    return ListenableBuilder(
      listenable: dating,
      builder: (BuildContext context, Widget? _) {
        final SeenProfile? s = dating.profile(profileKey);
        if (s == null) {
          return Scaffold(appBar: AppBar());
        }
        final DatingProfile p = s.profile;
        final ZenColors zen = ZenColors.of(context);
        final Color tone = datingTone(zen);
        final bool? decided = dating.decision(p.key);
        final bool match = dating.isMatch(p.key);
        final String? note = s.introNote;
        return Scaffold(
          appBar: AppBar(
            title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: <Widget>[
              PopupMenuButton<String>(
                onSelected: (String v) => unawaited(() async {
                  if (v == 'report') {
                    await showReportSheet(
                      context,
                      ref.read(pyramidServiceProvider),
                      datingKey: p.key,
                      evidence: '${p.name}, ${p.age}: ${p.about}',
                    );
                    return;
                  }
                  if (v == 'block') {
                    await dating.block(p.key);
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  }
                }()),
                itemBuilder: (BuildContext context) =>
                    const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'block',
                        child: ListTile(
                          leading: Icon(Icons.block_rounded),
                          title: Text('Zablokuj'),
                        ),
                      ),
                      PopupMenuItem<String>(
                        value: 'report',
                        child: ListTile(
                          leading: Icon(Icons.flag_rounded),
                          title: Text('Zgłoś (np. osoba niepełnoletnia)'),
                        ),
                      ),
                    ],
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: DatingPhotoPager(photos: p.photos),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '${p.name}, ${p.age}',
                style: zen.display(
                  color: zen.textPrimary,
                  size: 28,
                  weight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  ZenPill(
                    text: p.gender.label,
                    tone: tone,
                    icon: Icons.person_rounded,
                  ),
                  if (match)
                    ZenPill(
                      text: 'Para',
                      tone: zen.success,
                      icon: Icons.favorite_rounded,
                      filled: true,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              ZenInfo(
                icon: Icons.people_alt_rounded,
                tone: tone,
                text: datingWay(s),
              ),
              if (note != null && note.isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                DatingQuote(text: note, tone: tone),
              ],
              if (p.about.isNotEmpty) ...<Widget>[
                const ZenSection('O mnie'),
                Text(
                  p.about,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
              ],
              if (p.lookingFor.isNotEmpty) ...<Widget>[
                const ZenSection('Czego szukam'),
                Text(
                  p.lookingFor,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
              ],
              if (p.vouches.isNotEmpty) ...<Widget>[
                const ZenSection('Znajomi o mnie'),
                for (final DatingVouch v in p.vouches)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: DatingQuote(
                      text: v.text,
                      by: v.by,
                      signed: true,
                      tone: tone,
                    ),
                  ),
              ],
              const SizedBox(height: 24),
              if (match)
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: tone,
                    foregroundColor: ZenColors.foregroundFor(tone),
                  ),
                  onPressed: () =>
                      unawaited(DatingChatScreen.open(context, p.key)),
                  icon: const Icon(Icons.chat_rounded),
                  label: const Text('Napisz'),
                )
              else
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                        ),
                        onPressed: decided == false
                            ? null
                            : () => unawaited(dating.decide(p.key, false)),
                        icon: const Icon(Icons.close_rounded),
                        label: Text(
                          decided == false ? 'Powiedziałeś(-aś) „Nie”' : 'Nie',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          backgroundColor: tone,
                          foregroundColor: ZenColors.foregroundFor(tone),
                        ),
                        onPressed: decided == true
                            ? null
                            : () => unawaited(dating.decide(p.key, true)),
                        icon: const Icon(Icons.favorite_rounded),
                        label: Text(
                          decided == true ? 'Powiedziałeś(-aś) „Tak”' : 'Tak',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ],
                ),
              if (match && dating.thanked(p.key)) ...<Widget>[
                const SizedBox(height: 10),
                Center(
                  child: ZenPill(
                    text: 'Podziękowano swatowi',
                    tone: zen.success,
                    icon: Icons.volunteer_activism_rounded,
                  ),
                ),
              ] else if (dating.canThank(p.key)) ...<Widget>[
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  key: const Key('dating-thank'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () => unawaited(_thank(context, ref, dating, s)),
                  icon: const Icon(Icons.volunteer_activism_rounded),
                  label: Text(
                    'Podziękuj swatowi (${s.introBy})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (s.friend != null)
                    OutlinedButton.icon(
                      onPressed: () =>
                          unawaited(askDatingOpinion(context, dating, s)),
                      icon: const Icon(Icons.forum_rounded),
                      label: const Text('Zapytaj o opinię'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        unawaited(introduceDatingProfile(context, dating, s)),
                    icon: const Icon(Icons.people_alt_rounded),
                    label: const Text('Swatuj'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Talking to a match; it goes back through friends, sealed.
class DatingChatScreen extends ConsumerStatefulWidget {
  const DatingChatScreen({required this.profileKey, super.key});

  final String profileKey;

  static Future<void> open(BuildContext context, String key) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => DatingChatScreen(profileKey: key),
        ),
      );

  @override
  ConsumerState<DatingChatScreen> createState() => _DatingChatScreenState();
}

class _DatingChatScreenState extends ConsumerState<DatingChatScreen> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send(DatingService dating) async {
    final String t = _text.text;
    if (t.trim().isEmpty) {
      return;
    }
    _text.clear();
    await dating.sendMessage(widget.profileKey, t);
  }

  @override
  Widget build(BuildContext context) {
    final DatingService dating = ref.watch(datingServiceProvider);
    return ListenableBuilder(
      listenable: dating,
      builder: (BuildContext context, Widget? _) {
        final SeenProfile? s = dating.profile(widget.profileKey);
        final List<DatingLine> lines = dating.chat(widget.profileKey);
        final ZenColors zen = ZenColors.of(context);
        final Color tone = datingTone(zen);
        final Color onTone = ZenColors.foregroundFor(tone);
        return Scaffold(
          key: const Key('dating-chat'),
          appBar: AppBar(
            title: Row(
              children: <Widget>[
                datingPhoto(s?.profile.photo, size: 34),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    s?.profile.name ?? 'Randki',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            actions: <Widget>[
              IconButton(
                tooltip: 'Profil',
                icon: const Icon(Icons.person_rounded),
                onPressed: () => unawaited(
                  DatingProfileScreen.open(context, widget.profileKey),
                ),
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  children: <Widget>[
                    ZenInfo(
                      icon: Icons.lock_rounded,
                      tone: tone,
                      text:
                          'Wiadomości idą przez znajomych, zaszyfrowane — nikt '
                          'po drodze ich nie przeczyta. Mogą dochodzić '
                          'z opóźnieniem. Gdy się poznacie, dodajcie się do '
                          'znajomych.',
                    ),
                    if (lines.isEmpty)
                      ZenEmpty(
                        icon: Icons.waving_hand_rounded,
                        tone: tone,
                        title: 'Zacznijcie rozmowę',
                        text: 'Napisz pierwszy(-a)!',
                      ),
                    const SizedBox(height: 8),
                    for (final DatingLine l in lines)
                      Align(
                        alignment: l.mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          margin: EdgeInsets.only(
                            top: 3,
                            bottom: 3,
                            left: l.mine ? 48 : 0,
                            right: l.mine ? 0 : 48,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          constraints: const BoxConstraints(maxWidth: 480),
                          decoration: BoxDecoration(
                            color: l.mine ? tone : zen.surfaceRaised,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(18),
                              topRight: const Radius.circular(18),
                              bottomLeft: Radius.circular(l.mine ? 18 : 6),
                              bottomRight: Radius.circular(l.mine ? 6 : 18),
                            ),
                            border: l.mine
                                ? null
                                : Border.all(color: zen.outlineSoft),
                          ),
                          child: Text(
                            l.text,
                            style: TextStyle(
                              color: l.mine ? onTone : zen.textPrimary,
                              fontSize: 15,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: zen.surface,
                  border: Border(top: BorderSide(color: zen.outlineSoft)),
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: TextField(
                            key: const Key('dating-chat-text'),
                            controller: _text,
                            minLines: 1,
                            maxLines: 4,
                            enableIMEPersonalizedLearning: false,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: const InputDecoration(
                              hintText: 'Napisz…',
                            ),
                            onSubmitted: (_) => unawaited(_send(dating)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          key: const Key('dating-chat-send'),
                          tooltip: 'Wyślij',
                          style: IconButton.styleFrom(
                            backgroundColor: tone,
                            foregroundColor: onTone,
                          ),
                          onPressed: () => unawaited(_send(dating)),
                          icon: const Icon(Icons.send_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// What friends ask of this person, with dating on or off: opinions,
/// a few words for their profile, and dates to watch over.
class _FriendCorner extends ConsumerWidget {
  const _FriendCorner({required this.dating});

  final DatingService dating;

  Future<void> _answer(BuildContext context, OpinionAsk a) async {
    final TextEditingController c = TextEditingController(text: a.answer ?? '');
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(a.question),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: c,
            autofocus: true,
            maxLines: 4,
            maxLength: 2000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Twoja opinia',
              hintText: 'Szczerze, w kilku zdaniach',
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(c.text),
            child: const Text('Odpowiedz'),
          ),
        ],
      ),
    );
    disposeLater(c);
    if (text != null && text.trim().isNotEmpty) {
      await dating.answerOpinion(a.id, text);
    }
  }

  Future<void> _vouch(BuildContext context, String id, String name) async {
    final TextEditingController c = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Kilka słów o: $name'),
        content: SizedBox(
          width: 400,
          child: TextField(
            controller: c,
            autofocus: true,
            maxLines: 3,
            maxLength: 300,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Co o niej / nim powiesz?',
              hintText: 'Super gość, gotuje genialnie…',
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(c.text),
            child: const Text('Wyślij'),
          ),
        ],
      ),
    );
    disposeLater(c);
    if (text != null && text.trim().isNotEmpty) {
      await dating.writeVouch(id, text);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final SocialHubState social = watchSocialPeople(ref);
    String name(String address) {
      final FriendProfile? f = social.friendByAddress(address);
      return f == null ? 'Znajomy' : social.nameFor(f);
    }

    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    final List<OpinionAsk> asks = dating.asksToMe;
    final List<OpinionAsk> mine = dating.myAsks;
    final List<SafeDate> watching = dating.safeDates
        .where((SafeDate d) => !d.mine)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (watching.isNotEmpty) const ZenSection('Czuwasz'),
        for (final SafeDate d in watching)
          Builder(
            builder: (BuildContext context) {
              final bool alarmed = d.alarmedAt != null;
              final Color t = alarmed ? zen.danger : zen.success;
              return ZenCard(
                tone: t,
                padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
                child: Row(
                  children: <Widget>[
                    ZenIconBadge(
                      icon: alarmed
                          ? Icons.warning_amber_rounded
                          : Icons.shield_moon_rounded,
                      tone: t,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '${name(d.friend)} jest na randce',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: zen.textPrimary,
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            <String>[
                              'Ma dać znać do ${_clock(d.until)}',
                              if (d.note.isNotEmpty) d.note,
                              if (d.locatedAt != null)
                                'Położenie z ${_clock(d.locatedAt!)}',
                            ].join(' · '),
                            style: TextStyle(
                              color: zen.textSecondary,
                              fontSize: 13.5,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (d.lat != null)
                      IconButton(
                        tooltip: 'Mapa',
                        color: t,
                        icon: const Icon(Icons.map_rounded),
                        onPressed: () => unawaited(openMap(d.lat!, d.lon!)),
                      ),
                  ],
                ),
              );
            },
          ),
        if (asks.isNotEmpty) ...<Widget>[
          const ZenSection('Znajomi pytają o opinię'),
          for (final OpinionAsk a in asks)
            _PersonRow(
              photo: a.photo,
              title: '${name(a.friend)}: ${a.question}',
              subtitle: a.answer == null
                  ? 'Dotknij, żeby odpowiedzieć'
                  : 'Twoja odpowiedź: ${a.answer}',
              subtitleColor: a.answer == null ? tone : null,
              trailing: Icon(
                Icons.reply_rounded,
                color: zen.textMuted,
                size: 20,
              ),
              onTap: () => unawaited(_answer(context, a)),
            ),
        ],
        if (dating.vouchRequests.isNotEmpty) ...<Widget>[
          const ZenSection('Proszą o kilka słów'),
          for (final MapEntry<String, String> r in dating.vouchRequests.entries)
            ZenTile(
              icon: Icons.edit_note_rounded,
              tone: tone,
              title: name(r.value),
              subtitle: 'Prosi o kilka słów do profilu. Dotknij, żeby napisać.',
              trailing: IconButton(
                tooltip: 'Odrzuć',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => unawaited(dating.dismissVouchRequest(r.key)),
              ),
              onTap: () => unawaited(_vouch(context, r.key, name(r.value))),
            ),
        ],
        if (mine.isNotEmpty) ...<Widget>[
          const ZenSection('Twoje pytania o opinię'),
          for (final OpinionAsk a in mine)
            _PersonRow(
              photo: a.photo,
              title: '${name(a.friend)} o ${a.name}',
              subtitle: a.answer ?? 'Czekasz na odpowiedź',
              subtitleColor: a.answer == null ? zen.textMuted : null,
            ),
        ],
      ],
    );
  }
}

String _clock(int millis) {
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(millis);
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// "Idę na randkę" (§19.4).
class _SafeDateCard extends ConsumerWidget {
  const _SafeDateCard({required this.dating});

  final DatingService dating;

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final MeetHostNames names = MeetHostNames(ref);
    final List<String> close = names.closeFriends();
    final List<String> friends = close.isNotEmpty ? close : names.friends();
    if (friends.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Najpierw dodaj znajomych.')),
      );
      return;
    }
    String friend = friends.first;
    int hours = 3;
    final TextEditingController note = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter set) {
          final ZenColors zen = ZenColors.of(context);
          return AlertDialog(
            title: const Text('Idę na randkę'),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Wybrany przyjaciel zobaczy, gdzie jesteś, do czasu, aż '
                      'potwierdzisz „Wszystko OK”. Jeśli nie potwierdzisz na czas, '
                      'dostanie przypomnienie, a 15 minut później alarm.',
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: friend,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Kto czuwa',
                        prefixIcon: Icon(Icons.shield_rounded),
                      ),
                      items: <DropdownMenuItem<String>>[
                        for (final String f in friends)
                          DropdownMenuItem<String>(
                            value: f,
                            child: Text(
                              names.nameOf(f),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (String? v) => set(() => friend = v ?? friend),
                    ),
                    const SizedBox(height: 16),
                    Text('DAM ZNAĆ ZA', style: zen.label(color: zen.textMuted)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final int h in <int>[1, 2, 3, 4, 6, 8, 12])
                          ChoiceChip(
                            label: Text('$h h'),
                            selected: hours == h,
                            onSelected: (_) => set(() => hours = h),
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: note,
                      maxLength: 200,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Gdzie i z kim (nie trzeba)',
                        hintText: 'Kawiarnia na Starym Mieście, Ola',
                        prefixIcon: Icon(Icons.place_rounded),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Anuluj'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Start'),
              ),
            ],
          );
        },
      ),
    );
    final String text = note.text;
    disposeLater(note);
    if (ok != true) {
      return;
    }
    final GeoFix? fix = await currentFix();
    await dating.startSafeDate(
      friend: friend,
      length: Duration(hours: hours),
      note: text,
      lat: fix?.lat,
      lon: fix?.lon,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    final SafeDate? d = dating.mySafeDate;
    if (d == null) {
      return ZenCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ZenIconBadge(icon: Icons.shield_rounded, tone: tone),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Bezpieczna randka',
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Przyjaciel będzie wiedział, gdzie jesteś, dopóki nie '
                        'dasz znać, że wszystko OK.',
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton.tonalIcon(
              key: const Key('dating-safe-start'),
              onPressed: () => unawaited(_start(context, ref)),
              icon: const Icon(Icons.shield_rounded),
              label: const Text('Idę na randkę'),
            ),
          ],
        ),
      );
    }
    return ZenCard(
      tone: zen.success,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ZenIconBadge(
                icon: Icons.verified_user_rounded,
                tone: zen.success,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '${MeetHostNames(ref).nameOf(d.friend)} czuwa',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Daj znać do ${_clock(d.until)}.',
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: const Key('dating-safe-ok'),
                style: FilledButton.styleFrom(
                  backgroundColor: zen.success,
                  foregroundColor: ZenColors.foregroundFor(zen.success),
                ),
                onPressed: () => unawaited(dating.safeOk()),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Wszystko OK'),
              ),
              OutlinedButton(
                onPressed: () =>
                    unawaited(dating.extendSafeDate(const Duration(hours: 1))),
                child: const Text('+1 h'),
              ),
              OutlinedButton.icon(
                onPressed: () => unawaited(() async {
                  final GeoFix? fix = await currentFix();
                  if (fix != null) {
                    await dating.updateSafeLocation(fix.lat, fix.lon);
                  }
                }()),
                icon: const Icon(Icons.my_location_rounded),
                label: const Text('Wyślij położenie'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Friends and their names, for the dating screens.
final class MeetHostNames {
  MeetHostNames(this.ref);

  final WidgetRef ref;

  List<String> friends() => ref.read(meetServiceProvider).host.friends();
  List<String> closeFriends() =>
      ref.read(meetServiceProvider).host.closeFriends();
  String nameOf(String a) => ref.read(meetServiceProvider).host.nameOf(a);
}
