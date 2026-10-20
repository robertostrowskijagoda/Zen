import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/presentation/dating_screen.dart';

/// Profiles to decide on as a stack of cards (§19.5): swipe right = „Tak”,
/// left = „Nie”, or the buttons under the stack. Deciding goes through
/// [onDecide] (the same „Tak” / „Nie” as before, §19.2).
class DatingSwipeDeck extends StatefulWidget {
  const DatingSwipeDeck({
    required this.profiles,
    required this.onDecide,
    this.onOpen,
    this.onMatchmake,
    this.onAsk,
    super.key,
  });

  /// The profiles, the one on top first.
  final List<SeenProfile> profiles;
  final Future<void> Function(SeenProfile seen, bool yes) onDecide;

  /// The whole profile.
  final void Function(SeenProfile seen)? onOpen;

  /// "Swatuj": introduce this person to someone else (§19.3).
  final void Function(SeenProfile seen)? onMatchmake;

  /// "Zapytaj o opinię" the friend the profile came through (§19.3); off
  /// for profiles that came with no friend (an introduction).
  final void Function(SeenProfile seen)? onAsk;

  @override
  State<DatingSwipeDeck> createState() => _DatingSwipeDeckState();
}

class _DatingSwipeDeckState extends State<DatingSwipeDeck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _motion = AnimationController(vsync: this);
  Animation<double>? _tween;

  /// How far the top card is pulled sideways.
  double _dx = 0;
  double _width = 360;

  /// The top card is flying away.
  bool _leaving = false;

  /// Which way the card was pulled before it went back (so the bounce past
  /// the middle shows no stamp).
  double _backSign = 0;

  /// Decided here, until the list from the service drops them.
  final Set<String> _gone = <String>{};

  /// The order of the cards: a profile that comes meanwhile goes under the
  /// stack, never in place of the card in hand.
  final List<String> _order = <String>[];

  void _syncOrder() {
    final Set<String> keys = <String>{
      for (final SeenProfile s in widget.profiles) s.profile.key,
    };
    _order.removeWhere((String k) => !keys.contains(k));
    _gone.removeWhere((String k) => !keys.contains(k));
    final Set<String> known = _order.toSet();
    for (final SeenProfile s in widget.profiles) {
      if (known.add(s.profile.key)) {
        _order.add(s.profile.key);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _syncOrder();
    _motion.addListener(() {
      final Animation<double>? t = _tween;
      if (t != null) {
        setState(() => _dx = t.value);
      }
    });
  }

  @override
  void didUpdateWidget(covariant DatingSwipeDeck oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncOrder();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  Future<void> _animate(double to, Duration duration, Curve curve) {
    _motion.duration = duration;
    _tween = Tween<double>(
      begin: _dx,
      end: to,
    ).animate(CurvedAnimation(parent: _motion, curve: curve));
    return _motion.forward(from: 0);
  }

  Future<void> _decide(SeenProfile s, bool yes) async {
    if (_leaving) {
      return;
    }
    _leaving = true;
    _backSign = 0;
    await _animate(
      (yes ? 1 : -1) * _width * 1.4,
      const Duration(milliseconds: 240),
      Curves.easeIn,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _gone.add(s.profile.key);
      _dx = 0;
      _tween = null;
      _leaving = false;
    });
    await widget.onDecide(s, yes);
  }

  void _onDrag(DragUpdateDetails d) {
    if (_leaving) {
      return;
    }
    _motion.stop();
    _tween = null;
    _backSign = 0;
    setState(() => _dx += d.primaryDelta ?? d.delta.dx);
  }

  void _onDragEnd(DragEndDetails d, SeenProfile top) {
    if (_leaving) {
      return;
    }
    final double v = d.primaryVelocity ?? 0;
    final bool fling = v.abs() > 900;
    if (fling || _dx.abs() > _width * 0.28) {
      unawaited(_decide(top, fling ? v > 0 : _dx > 0));
    } else {
      // Back to the middle, with a little bounce.
      _backSign = _dx.sign;
      unawaited(
        _animate(0, const Duration(milliseconds: 380), Curves.easeOutBack),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    final Map<String, SeenProfile> byKey = <String, SeenProfile>{
      for (final SeenProfile s in widget.profiles) s.profile.key: s,
    };
    final List<SeenProfile> list = <SeenProfile>[
      for (final String k in _order)
        if (!_gone.contains(k) && byKey[k] != null) byKey[k]!,
    ];
    if (list.isEmpty) {
      return const SizedBox.shrink();
    }
    final SeenProfile top = list.first;
    return Column(
      children: <Widget>[
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    _width = c.maxWidth;
                    // The next card comes forward as the top one leaves.
                    final double pull = (_dx.abs() / (_width * 0.5)).clamp(
                      0.0,
                      1.0,
                    );
                    final double stamp = _backSign != 0 && _dx.sign != _backSign
                        ? 0
                        : _dx / (_width * 0.25);
                    return Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        for (int i = math.min(list.length, 3) - 1; i >= 1; i--)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: Transform.translate(
                                offset: Offset(0, 12.0 * i - 12 * pull),
                                child: Transform.scale(
                                  scale: 1 - 0.05 * i + 0.05 * pull,
                                  alignment: Alignment.bottomCenter,
                                  child: DatingSwipeCard(
                                    key: ValueKey<String>(list[i].profile.key),
                                    seen: list[i],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        Positioned.fill(
                          child: Semantics(
                            label: t(
                              '{name}. Przesuń w prawo — Tak, w lewo — Nie.',
                              {'name': top.profile.name},
                            ),
                            child: GestureDetector(
                              key: Key('dating-card-${top.profile.name}'),
                              onHorizontalDragUpdate: _onDrag,
                              onHorizontalDragEnd: (DragEndDetails d) =>
                                  _onDragEnd(d, top),
                              child: Transform.translate(
                                offset: Offset(_dx, _dx.abs() * 0.05),
                                child: Transform.rotate(
                                  angle: _dx / _width * 0.3,
                                  alignment: Alignment.bottomCenter,
                                  child: DatingSwipeCard(
                                    key: ValueKey<String>(top.profile.key),
                                    seen: top,
                                    stamp: stamp,
                                    onOpen: widget.onOpen == null
                                        ? null
                                        : () => widget.onOpen!(top),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: _RoundAction(
                    buttonKey: const Key('dating-deck-no'),
                    icon: Icons.close_rounded,
                    label: t('Nie'),
                    color: zen.danger,
                    size: 60,
                    onTap: () => unawaited(_decide(top, false)),
                  ),
                ),
                Expanded(
                  child: _RoundAction(
                    buttonKey: const Key('dating-deck-match'),
                    icon: Icons.people_alt_rounded,
                    label: t('Swatuj'),
                    color: zen.accent,
                    size: 46,
                    onTap: widget.onMatchmake == null
                        ? null
                        : () => widget.onMatchmake!(top),
                  ),
                ),
                Expanded(
                  child: _RoundAction(
                    buttonKey: const Key('dating-deck-ask'),
                    icon: Icons.forum_rounded,
                    label: t('Zapytaj o opinię'),
                    color: zen.accentSecondary,
                    size: 46,
                    onTap: widget.onAsk == null || top.friend == null
                        ? null
                        : () => widget.onAsk!(top),
                  ),
                ),
                Expanded(
                  child: _RoundAction(
                    buttonKey: const Key('dating-deck-yes'),
                    icon: Icons.favorite_rounded,
                    label: t('Tak'),
                    color: tone,
                    size: 60,
                    filled: true,
                    onTap: () => unawaited(_decide(top, true)),
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

/// A round button with its name under it.
class _RoundAction extends StatelessWidget {
  const _RoundAction({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.color,
    required this.size,
    required this.onTap,
    this.filled = false,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final Color color;
  final double size;
  final VoidCallback? onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool on = onTap != null;
    final Color c = on ? color : zen.textMuted.withValues(alpha: 0.5);
    return Semantics(
      button: true,
      enabled: on,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Material(
            key: buttonKey,
            color: filled && on ? c : zen.surface,
            shape: CircleBorder(side: BorderSide(color: c, width: 2)),
            elevation: on ? 2 : 0,
            shadowColor: c.withValues(alpha: 0.4),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox.square(
                dimension: size,
                child: Icon(
                  icon,
                  size: size * 0.45,
                  color: filled && on ? ZenColors.foregroundFor(c) : c,
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: on ? zen.textSecondary : zen.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// One profile as a card: first its description as a "photo" of its own
/// (§19.5), then the photos; a tap on the right half shows the next one,
/// on the left half the one before.
class DatingSwipeCard extends StatefulWidget {
  const DatingSwipeCard({
    required this.seen,
    this.stamp = 0,
    this.onOpen,
    super.key,
  });

  final SeenProfile seen;

  /// How far a swipe went: above 0 towards „Tak”, below towards „Nie” (±1
  /// shows the stamp in full).
  final double stamp;

  /// Opens the whole profile (`null`: no button).
  final VoidCallback? onOpen;

  @override
  State<DatingSwipeCard> createState() => _DatingSwipeCardState();
}

class _DatingSwipeCardState extends State<DatingSwipeCard> {
  int _page = 0;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = datingTone(zen);
    final DatingProfile p = widget.seen.profile;
    final int pages = 1 + p.photos.length;
    final int page = _page.clamp(0, pages - 1);
    final bool onText = page == 0;
    final double stamp = widget.stamp.clamp(-1.0, 1.0);
    return Material(
      color: zen.surface,
      clipBehavior: Clip.antiAlias,
      elevation: 3,
      shadowColor: const Color(0x33000000),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: BorderSide(color: zen.outlineSoft),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints c) => Stack(
          fit: StackFit.expand,
          children: <Widget>[
            GestureDetector(
              key: const Key('dating-card-pages'),
              behavior: HitTestBehavior.opaque,
              onTapUp: pages < 2
                  ? null
                  : (TapUpDetails d) => setState(() {
                      final bool next = d.localPosition.dx > c.maxWidth / 2;
                      // From the last photo, the right half goes back to
                      // the description.
                      _page = next ? (page + 1) % pages : math.max(page - 1, 0);
                    }),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                layoutBuilder: (Widget? current, List<Widget> previous) =>
                    Stack(
                      fit: StackFit.expand,
                      children: <Widget>[...previous, ?current],
                    ),
                child: KeyedSubtree(
                  key: ValueKey<int>(page),
                  child: onText
                      ? _DescriptionPage(seen: widget.seen, tone: tone)
                      : _PhotoPage(
                          seen: widget.seen,
                          photo: p.photos[page - 1],
                          tone: tone,
                        ),
                ),
              ),
            ),
            if (pages > 1)
              Positioned(
                top: 10,
                left: 14,
                right: 14,
                child: IgnorePointer(
                  child: Row(
                    children: <Widget>[
                      for (int i = 0; i < pages; i++)
                        Expanded(
                          child: Container(
                            height: 4,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: BoxDecoration(
                              color: onText
                                  ? tone.withValues(
                                      alpha: i == page ? 0.9 : 0.25,
                                    )
                                  : Color(i == page ? 0xFFFFFFFF : 0x73FFFFFF),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (stamp > 0.05)
              Positioned(
                top: 36,
                left: 20,
                child: _Stamp(
                  text: t('TAK'),
                  color: zen.success,
                  angle: -0.25,
                  strength: stamp,
                ),
              ),
            if (stamp < -0.05)
              Positioned(
                top: 36,
                right: 20,
                child: _Stamp(
                  text: t('NIE'),
                  color: zen.danger,
                  angle: 0.25,
                  strength: -stamp,
                ),
              ),
            if (widget.onOpen != null)
              Positioned(
                right: 10,
                bottom: 10,
                child: IconButton(
                  key: const Key('dating-card-open'),
                  tooltip: t('Cały profil'),
                  style: IconButton.styleFrom(
                    backgroundColor: onText
                        ? tone.withValues(alpha: 0.16)
                        : const Color(0x59000000),
                    foregroundColor: onText ? tone : const Color(0xFFFFFFFF),
                  ),
                  icon: const Icon(Icons.info_outline_rounded),
                  onPressed: widget.onOpen,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "TAK" / "NIE" stamped on the card while it is swiped.
class _Stamp extends StatelessWidget {
  const _Stamp({
    required this.text,
    required this.color,
    required this.angle,
    required this.strength,
  });

  final String text;
  final Color color;
  final double angle;

  /// 0..1: how visible.
  final double strength;

  @override
  Widget build(BuildContext context) {
    final double s = strength.clamp(0.0, 1.0);
    return IgnorePointer(
      child: Opacity(
        opacity: s,
        child: Transform.rotate(
          angle: angle,
          child: Transform.scale(
            scale: 0.85 + 0.15 * s,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                border: Border.all(color: color, width: 4),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                text,
                style: TextStyle(
                  color: color,
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 3,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The description as the first "photo": name, the way you know each
/// other, what they write, and what friends say.
class _DescriptionPage extends StatelessWidget {
  const _DescriptionPage({required this.seen, required this.tone});

  final SeenProfile seen;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final DatingProfile p = seen.profile;
    final String? note = seen.introNote;
    final bool empty =
        p.about.isEmpty &&
        p.lookingFor.isEmpty &&
        p.vouches.isEmpty &&
        (note == null || note.isEmpty);
    return DecoratedBox(
      key: const Key('dating-card-text'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Color.alphaBlend(tone.withValues(alpha: 0.24), zen.surface),
            Color.alphaBlend(
              zen.accentSecondary.withValues(alpha: 0.10),
              zen.surface,
            ),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned(
            right: -24,
            bottom: -36,
            child: Icon(
              Icons.format_quote_rounded,
              size: 190,
              color: tone.withValues(alpha: 0.10),
            ),
          ),
          SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 32, 22, 64),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  p.name,
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 30,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.people_alt_rounded, size: 17, color: tone),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        datingWay(seen),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (note != null && note.isNotEmpty) ...<Widget>[
                  DatingQuote(text: note, tone: tone),
                  const SizedBox(height: 14),
                ],
                if (p.about.isNotEmpty) ...<Widget>[
                  Text(t('O MNIE'), style: zen.label(color: tone)),
                  const SizedBox(height: 4),
                  Text(
                    p.about,
                    maxLines: 10,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 16,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (p.lookingFor.isNotEmpty) ...<Widget>[
                  Text(t('SZUKAM'), style: zen.label(color: tone)),
                  const SizedBox(height: 4),
                  Text(
                    p.lookingFor,
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                for (final DatingVouch v in p.vouches.take(2)) ...<Widget>[
                  DatingQuote(text: v.text, by: v.by, signed: true, tone: tone),
                  const SizedBox(height: 10),
                ],
                if (empty)
                  Text(
                    t('Ta osoba nie napisała jeszcze nic o sobie.'),
                    style: TextStyle(color: zen.textMuted, fontSize: 14),
                  ),
                if (p.photos.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Icon(
                        Icons.touch_app_rounded,
                        size: 16,
                        color: zen.textMuted,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          t('Stuknij z prawej strony, by zobaczyć zdjęcia'),
                          style: TextStyle(
                            color: zen.textMuted,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    ],
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

/// A photo with the name over a dark shade at the bottom.
class _PhotoPage extends StatelessWidget {
  const _PhotoPage({
    required this.seen,
    required this.photo,
    required this.tone,
  });

  final SeenProfile seen;
  final String photo;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final DatingProfile p = seen.profile;
    const Color onPhoto = Color(0xFFFFFFFF);
    const Color onPhotoSoft = Color(0xE6FFFFFF);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        datingCover(photo, zen, tone),
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Color(0x33000000),
                  Color(0x00000000),
                  Color(0x00000000),
                  Color(0xB3000000),
                ],
                stops: <double>[0, 0.18, 0.55, 1],
              ),
            ),
          ),
        ),
        Positioned(
          left: 18,
          right: 64,
          bottom: 18,
          child: IgnorePointer(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: zen.display(
                    color: onPhoto,
                    size: 28,
                    weight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    const Icon(
                      Icons.people_alt_rounded,
                      size: 15,
                      color: onPhotoSoft,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        datingWay(seen),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: onPhotoSoft,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
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
    );
  }
}
