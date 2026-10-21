import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/pyramid/pyramid_timeline.dart';

/// Playback speeds: steps per second.
const List<double> kPyrTimelineSpeeds = <double>[0.5, 1, 2, 4];

/// Their labels (no words: the same in every language).
const List<String> kPyrTimelineSpeedLabels = <String>['½×', '1×', '2×', '4×'];

/// The pyramid's history, animated: a slider from the founding to now,
/// play and pause, the speed, and the tree — the whole of it when small,
/// otherwise the top and the part around this person and the people
/// picked — with people moving between places as they join, move up,
/// swap with their heads, leave or come back. The steps are the public
/// history every member keeps; with reduced motion they change without
/// animation.
class PyramidTimelineView extends StatefulWidget {
  const PyramidTimelineView({required this.s, required this.me, super.key});

  final PyramidState s;
  final String me;

  @override
  State<PyramidTimelineView> createState() => _PyramidTimelineViewState();
}

class _PyramidTimelineViewState extends State<PyramidTimelineView> {
  PyrTimeline _timeline = PyrTimeline.empty;
  bool _ready = false;

  /// Steps shown (0: before the founding, the timeline's length: now).
  int _count = 0;
  int _speed = 1;
  Timer? _timer;
  final Set<String> _picked = <String>{};

  @override
  void initState() {
    super.initState();
    _load(atEnd: true);
  }

  @override
  void didUpdateWidget(PyramidTimelineView old) {
    super.didUpdateWidget(old);
    // The pyramid changes in place too ([PyramidState.revision]).
    if (!identical(old.s, widget.s) || widget.s.revision != _revision) {
      _load(atEnd: _count >= _timeline.length);
    }
  }

  /// The [PyramidState.revision] the timeline was worked out from.
  int _revision = -1;

  /// Works the timeline out (off the UI thread for a long history).
  void _load({required bool atEnd}) {
    _revision = widget.s.revision;
    void take(PyrTimeline t) {
      _timeline = t;
      _ready = true;
      _count = atEnd ? t.length : min(_count, t.length);
    }

    if (widget.s.moves.length <= kPyrTimelineIsolateMoves) {
      take(PyrTimeline.ofState(widget.s));
      return;
    }
    unawaited(
      PyrTimeline.ofStateAsync(widget.s).then((PyrTimeline t) {
        if (mounted) {
          setState(() => take(t));
        }
      }),
    );
  }

  Duration get _interval =>
      Duration(milliseconds: (1000 / kPyrTimelineSpeeds[_speed]).round());

  void _play() {
    if (_count >= _timeline.length) {
      _count = 0;
    }
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _tick());
    setState(() {});
  }

  void _tick() {
    if (!mounted) {
      return;
    }
    if (_count >= _timeline.length) {
      _stop();
      return;
    }
    setState(() => _count++);
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    if (mounted) {
      setState(() {});
    }
  }

  void _setSpeed(int i) {
    setState(() => _speed = i);
    if (_timer != null) {
      _play();
    }
  }

  void _toggle(String key) => setState(() {
    if (!_picked.remove(key)) {
      _picked.add(key);
    }
  });

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    if (!_ready) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final PyrTimeline tl = _timeline;
    if (tl.length == 0) {
      return ZenInfo(
        icon: Icons.timeline_rounded,
        text: t('Nikt jeszcze nie zmienił miejsca.'),
      );
    }
    final bool playing = _timer != null;
    final bool still = MediaQuery.of(context).disableAnimations;
    final Duration motion = still
        ? Duration.zero
        : Duration(
            milliseconds: min(600, (700 / kPyrTimelineSpeeds[_speed]).round()),
          );
    final Map<String, String> positions = tl.positionsAfter(_count);
    final PyrTimelineStep? step = _count == 0 ? null : tl.steps[_count - 1];
    final String name = widget.s.members[widget.me]?.name ?? '';
    return Column(
      key: const Key('pyr-timeline'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            IconButton.filledTonal(
              key: const Key('pyr-timeline-play'),
              tooltip: playing ? t('Pauza') : t('Odtwórz'),
              onPressed: playing ? _stop : _play,
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
            Expanded(
              child: Slider(
                key: const Key('pyr-timeline-slider'),
                value: _count.toDouble(),
                max: tl.length.toDouble(),
                divisions: tl.length <= 2000 ? tl.length : null,
                onChanged: (double v) {
                  _timer?.cancel();
                  _timer = null;
                  setState(() => _count = v.round());
                },
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Icon(Icons.speed_rounded, size: 18, color: zen.textMuted),
            for (int i = 0; i < kPyrTimelineSpeeds.length; i++)
              ChoiceChip(
                key: Key('pyr-timeline-speed-$i'),
                label: Text(kPyrTimelineSpeedLabels[i]),
                selected: _speed == i,
                onSelected: (_) => _setSpeed(i),
              ),
            Text(
              t('{step} z {count}', <String, Object?>{
                'step': _count,
                'count': tl.length,
              }),
              style: TextStyle(color: zen.textMuted, fontSize: 12.5),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          step == null
              ? t('Początek: piramida jest jeszcze pusta.')
              : '${pyrDate(step.at)} · ${step.text}',
          key: const Key('pyr-timeline-event'),
          style: TextStyle(
            color: zen.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 8),
        PyramidTimelineTree(
          positions: positions,
          names: tl.names,
          me: widget.me,
          picked: _picked,
          motion: motion,
          onTap: _toggle,
        ),
        if (_picked.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String k in _picked)
                InputChip(
                  key: Key('pyr-timeline-picked-$k'),
                  label: Text(tl.names[k] ?? '?'),
                  onDeleted: () => _toggle(k),
                ),
            ],
          ),
        Text(
          name.isEmpty
              ? t('Dotknij osoby, aby ją wyróżnić.')
              : t(
                  'Ty: {name}. Dotknij osoby, aby ją wyróżnić.',
                  <String, Object?>{'name': name},
                ),
          style: TextStyle(color: zen.textMuted, fontSize: 12.5),
        ),
        const SizedBox(height: 6),
        // The steps up to the one shown, the newest first: a tap goes there.
        for (int i = _count - 1; i >= max(0, _count - 5); i--)
          InkWell(
            key: Key('pyr-timeline-step-$i'),
            onTap: () {
              _timer?.cancel();
              _timer = null;
              setState(() => _count = i + 1);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    i == _count - 1
                        ? Icons.radio_button_checked_rounded
                        : Icons.circle_outlined,
                    size: 14,
                    color: i == _count - 1 ? pyrTone(zen) : zen.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${pyrDate(tl.steps[i].at)} · ${tl.steps[i].text}',
                      style: TextStyle(
                        color: i == _count - 1
                            ? zen.textPrimary
                            : zen.textSecondary,
                        fontSize: 13,
                        height: 1.3,
                      ),
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

/// The tree at one moment: places as rows by level, lines from each head
/// to the two below, and the people, who move between places with
/// [motion] (zero: they jump). [me] and [picked] stand out.
class PyramidTimelineTree extends StatelessWidget {
  const PyramidTimelineTree({
    required this.positions,
    required this.names,
    required this.me,
    required this.picked,
    required this.motion,
    required this.onTap,
    super.key,
  });

  /// Key → path.
  final Map<String, String> positions;
  final Map<String, String> names;
  final String me;
  final Set<String> picked;
  final Duration motion;
  final void Function(String key) onTap;

  static const double _row = 64;
  static const double _node = 34;
  static const double _label = 64;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Set<String> visible = pyrVisiblePaths(positions, <String>{
      me,
      ...picked,
    });
    final Map<int, List<String>> rows = <int, List<String>>{};
    for (final String p in visible) {
      (rows[p.length] ??= <String>[]).add(p);
    }
    for (final List<String> r in rows.values) {
      r.sort();
    }
    final int depth = visible.isEmpty
        ? 0
        : visible.map((String p) => p.length).reduce(max);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double w = c.maxWidth.isFinite ? c.maxWidth : 320;
        Offset spot(String p) {
          final List<String> row = rows[p.length]!;
          return Offset(
            w * (row.indexOf(p) + 1) / (row.length + 1),
            _node / 2 + 8 + p.length * _row,
          );
        }

        final Map<String, Offset> at = <String, Offset>{
          for (final String p in visible) p: spot(p),
        };
        final List<(Offset, Offset)> edges = <(Offset, Offset)>[
          for (final String p in visible)
            if (p.isNotEmpty && at.containsKey(PyrPath.parent(p)))
              (at[PyrPath.parent(p)]!, at[p]!),
        ];
        return SizedBox(
          height: (depth + 1) * _row + 16,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: CustomPaint(painter: _EdgePainter(edges, zen.outline)),
              ),
              for (final MapEntry<String, String> e in positions.entries)
                if (at[e.value] case final Offset o)
                  AnimatedPositioned(
                    key: ValueKey<String>('pyr-tl-${e.key}'),
                    duration: motion,
                    curve: Curves.easeInOut,
                    left: o.dx - _label / 2,
                    top: o.dy - _node / 2,
                    width: _label,
                    child: _Person(
                      name: names[e.key] ?? '?',
                      tone: e.key == me
                          ? zen.accent
                          : picked.contains(e.key)
                          ? zen.warning
                          : pyrTone(zen),
                      filled: e.key == me || picked.contains(e.key),
                      onTap: () => onTap(e.key),
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _Person extends StatelessWidget {
  const _Person({
    required this.name,
    required this.tone,
    required this.filled,
    required this.onTap,
  });

  final String name;
  final Color tone;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          PyrAvatar(
            text: pyrInitial(name),
            tone: tone,
            size: PyramidTimelineTree._node,
            filled: filled,
          ),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: filled ? tone : zen.textSecondary,
              fontSize: 11,
              fontWeight: filled ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.edges, this.color);

  final List<(Offset, Offset)> edges;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint line = Paint()
      ..color = color
      ..strokeWidth = 1.5;
    for (final (Offset a, Offset b) in edges) {
      canvas.drawLine(a, b, line);
    }
  }

  @override
  bool shouldRepaint(_EdgePainter old) {
    if (old.color != color || old.edges.length != edges.length) {
      return true;
    }
    for (int i = 0; i < edges.length; i++) {
      if (old.edges[i] != edges[i]) {
        return true;
      }
    }
    return false;
  }
}
