import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Global switch for perpetual decorative animations (pulsing dots, ringing
/// waves, marching dots). Infinite tickers would keep `pumpAndSettle` from
/// ever settling in widget tests, so the animations default to off under
/// `flutter test` and every widget below renders a static fallback then.
abstract final class ZenMotion {
  static bool enabled = _detectDefault();

  /// Whether motion may play here: [enabled], and the system does not ask
  /// for reduced motion (`MediaQuery.disableAnimations`).
  static bool allowedIn(BuildContext context) =>
      enabled && !(MediaQuery.maybeDisableAnimationsOf(context) ?? false);

  static bool _detectDefault() {
    if (kIsWeb) {
      return true;
    }
    return !Platform.environment.containsKey('FLUTTER_TEST');
  }
}

// ---------------------------------------------------------------------------
// Shared motion maths
//
// Every perpetual animation below draws its own speed, phase and waveform
// parameters from [_entropy] when its state is created. Two status dots on the
// same screen therefore never breathe in lockstep, and no animation repeats on
// a period the eye can lock onto.
// ---------------------------------------------------------------------------

final math.Random _entropy = math.Random();

double _rand(double min, double max) =>
    min + _entropy.nextDouble() * (max - min);

/// Deterministic 0..1 hash. Lets a waveform pick a different shape for every
/// cycle it enters without keeping any state.
double _hash01(int n) {
  int x = (n * 0x27D4EB2D) & 0x7FFFFFFF;
  x ^= x >> 15;
  x = (x * 0x85EBCA6B) & 0x7FFFFFFF;
  x ^= x >> 13;
  return (x & 0xFFFF) / 65535.0;
}

/// Smooth, quasi-random time warp. The derivative stays positive — time never
/// runs backwards — but wanders between roughly 0.7x and 1.3x, which is what
/// turns a metronome into something that reads as alive. [s1] and [s2] are
/// per-widget seeds, so no two instances wander the same way.
double _warp(double t, double s1, double s2) {
  return t + 0.55 * math.sin(t * 0.23 + s1) + 0.27 * math.sin(t * 0.61 + s2);
}

/// Free-running seconds clock shared by the perpetual animations: one ticker
/// whose value is elapsed seconds, wrapping every hour so it never grows large
/// enough to cost precision. Waveforms are then plain functions of time, which
/// is what makes randomised speeds cheap.
AnimationController _startMotionClock(TickerProvider vsync) {
  return AnimationController(
    vsync: vsync,
    duration: const Duration(hours: 1),
    lowerBound: 0,
    upperBound: 3600,
  )..repeat();
}

/// A row of dots that light up in a wave — the animated companion for
/// "Łączenie…" style status labels. Each dot runs at its own speed and drifts
/// in and out of phase with its neighbours. Falls back to static dots when
/// [ZenMotion.enabled] is false.
class ZenAnimatedDots extends StatefulWidget {
  const ZenAnimatedDots({
    super.key,
    this.color,
    this.size = 4,
    this.dotCount = 3,
    this.spacing = 3,
  });

  final Color? color;
  final double size;
  final int dotCount;
  final double spacing;

  @override
  State<ZenAnimatedDots> createState() => _ZenAnimatedDotsState();
}

/// Per-dot waveform parameters — drawn once, then held for the widget's life.
@immutable
class _DotWave {
  const _DotWave({
    required this.speed,
    required this.phase,
    required this.wobble,
    required this.seedA,
    required this.seedB,
    required this.floor,
  });

  factory _DotWave.random(int index, int count) {
    return _DotWave(
      // A base march (index / count) keeps the wave reading left-to-right;
      // the jitter on top is what stops it looking like a loading spinner.
      speed: _rand(0.72, 1.34),
      phase: index / (count + 1) + _rand(-0.09, 0.09),
      wobble: _rand(0, math.pi * 2),
      seedA: _rand(0, math.pi * 2),
      seedB: _rand(0, math.pi * 2),
      floor: _rand(0.14, 0.28),
    );
  }

  final double speed;
  final double phase;
  final double wobble;
  final double seedA;
  final double seedB;
  final double floor;

  /// 0..1 intensity at [seconds].
  double intensity(double seconds) {
    final double x = _warp(seconds * speed + phase, seedA, seedB);
    final double primary = 0.5 + 0.5 * math.sin(x * math.pi * 2);
    // A second, much slower sine beats against the first: the crest drifts
    // instead of landing on the same value every pass.
    final double drift = 0.5 + 0.5 * math.sin(x * math.pi * 0.86 + wobble);
    final double mixed = (primary * 0.78 + drift * 0.22).clamp(0.0, 1.0);
    return Curves.easeInOutCubic.transform(mixed);
  }
}

class _ZenAnimatedDotsState extends State<ZenAnimatedDots>
    with SingleTickerProviderStateMixin {
  AnimationController? _clock;
  late List<_DotWave> _waves;

  @override
  void initState() {
    super.initState();
    _waves = _buildWaves();
    if (ZenMotion.enabled) {
      _clock = _startMotionClock(this);
    }
  }

  @override
  void didUpdateWidget(ZenAnimatedDots oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dotCount != widget.dotCount) {
      _waves = _buildWaves();
    }
  }

  List<_DotWave> _buildWaves() {
    return List<_DotWave>.generate(
      widget.dotCount,
      (int index) => _DotWave.random(index, widget.dotCount),
      growable: false,
    );
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color resolved =
        widget.color ??
        DefaultTextStyle.of(context).style.color ??
        Colors.white;
    final AnimationController? clock = _clock;
    if (clock == null) {
      return _buildDots(resolved, (int _) => 1);
    }
    return AnimatedBuilder(
      animation: clock,
      builder: (BuildContext context, Widget? child) {
        return _buildDots(
          resolved,
          (int index) => _waves[index].intensity(clock.value),
        );
      },
    );
  }

  Widget _buildDots(Color color, double Function(int index) intensity) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int index = 0; index < widget.dotCount; index += 1)
          Padding(
            padding: EdgeInsets.only(left: index == 0 ? 0 : widget.spacing),
            child: _buildDot(color, intensity(index).clamp(0.0, 1.0), index),
          ),
      ],
    );
  }

  Widget _buildDot(Color color, double intensity, int index) {
    final double floor = _clock == null ? 1 : _waves[index].floor;
    final double opacity = floor + (1 - floor) * intensity;
    // The dots swell as they brighten — a flat opacity fade reads as a
    // progress spinner, the scale is what makes it read as a signal.
    final double scale = _clock == null ? 1 : 0.76 + 0.44 * intensity;
    return Transform.scale(
      scale: scale,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: SizedBox.square(dimension: widget.size),
        ),
      ),
    );
  }
}

/// Status dot with a living pulse: a fast attack and slow release, at a speed
/// that wanders, and with an echo beat on roughly half the cycles — closer to
/// a heartbeat than to a blinking LED.
class ZenPulsingDot extends StatefulWidget {
  const ZenPulsingDot({
    super.key,
    required this.color,
    this.active = true,
    this.dimension = 12,
    this.dotSize = 6,
  });

  final Color color;
  final bool active;
  final double dimension;
  final double dotSize;

  @override
  State<ZenPulsingDot> createState() => _ZenPulsingDotState();
}

class _ZenPulsingDotState extends State<ZenPulsingDot>
    with TickerProviderStateMixin {
  AnimationController? _clock;

  // Waveform parameters — redrawn only when the widget is recreated, so the
  // pulse a user sees on one screen keeps its personality while it is visible.
  final double _period = _rand(1.05, 2.15);
  final double _seedA = _rand(0, math.pi * 2);
  final double _seedB = _rand(0, math.pi * 2);
  final double _offset = _rand(0, 4);
  final int _echoSeed = _entropy.nextInt(1 << 20);

  @override
  void initState() {
    super.initState();
    _syncClock();
  }

  @override
  void didUpdateWidget(ZenPulsingDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncClock();
  }

  void _syncClock() {
    final bool shouldAnimate = ZenMotion.enabled && widget.active;
    if (shouldAnimate && _clock == null) {
      _clock = _startMotionClock(this);
    } else if (!shouldAnimate && _clock != null) {
      _clock!.dispose();
      _clock = null;
    }
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  /// 0..1 beat intensity at [seconds].
  double _pulse(double seconds) {
    final double x = _warp((seconds + _offset) / _period, _seedA, _seedB);
    final int cycle = x.floor();
    final double f = (x - cycle).clamp(0.0, 1.0);
    // Bending the phase before the sine puts the crest at ~38% of the beat:
    // a quick rise, a long fall.
    double v = math.pow(math.sin(math.pow(f, 0.72) * math.pi), 1.7).toDouble();
    final double echo = _hash01(cycle * 31 + _echoSeed);
    if (echo > 0.42) {
      // Second, weaker beat riding on the tail of the first.
      final double d = f - (0.52 + 0.16 * echo);
      v = math.max(v, math.exp(-d * d * 210) * (0.28 + 0.4 * echo));
    }
    return v.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? clock = _clock;
    if (clock == null) {
      return _buildDot(1, 6, 1);
    }
    return AnimatedBuilder(
      animation: clock,
      builder: (BuildContext context, Widget? child) {
        final double v = _pulse(clock.value);
        return _buildDot(0.46 + 0.54 * v, 3 + 11 * v, 0.86 + 0.26 * v);
      },
    );
  }

  Widget _buildDot(double opacity, double blur, double scale) {
    return SizedBox.square(
      dimension: widget.dimension,
      child: Center(
        child: Transform.scale(
          scale: scale,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: widget.color.withValues(alpha: opacity.clamp(0.0, 1.0)),
              shape: BoxShape.circle,
              boxShadow: widget.active
                  ? <BoxShadow>[
                      BoxShadow(
                        color: widget.color.withValues(
                          alpha: (0.7 * opacity).clamp(0.0, 1.0),
                        ),
                        blurRadius: blur,
                      ),
                    ]
                  : null,
            ),
            child: SizedBox.square(dimension: widget.dotSize),
          ),
        ),
      ),
    );
  }
}

/// Burst shapes a neon tube can fail in. Each one has its own step timing, so
/// a lamp does not always glitch the same way twice.
enum _FlickerProfile {
  /// Many tiny, very fast dips — a failing ballast buzzing.
  buzz,

  /// One long, deep sag with a slow recovery — a voltage drop.
  sag,

  /// Irregular medium-depth stutter.
  stutter,

  /// A few failed ignitions before the tube settles — a cold start.
  coldStart,
}

/// Authentic flickering neon lamp simulation. Between bursts the glow keeps a
/// slow, barely visible hum instead of sitting perfectly still, and every
/// burst draws its own profile *and* its own speed, so no two look alike.
/// Renders a stable glowing child when [ZenMotion.enabled] is false.
class ZenNeonFlicker extends StatefulWidget {
  const ZenNeonFlicker({
    super.key,
    required this.child,
    required this.color,
    this.glowRadius = 14,
    this.glowAlpha = 0.5,
    this.minQuietSeconds = 3,
    this.maxQuietSeconds = 9,
  });

  final Widget child;
  final Color color;
  final double glowRadius;
  final double glowAlpha;
  final int minQuietSeconds;
  final int maxQuietSeconds;

  @override
  State<ZenNeonFlicker> createState() => _ZenNeonFlickerState();
}

class _ZenNeonFlickerState extends State<ZenNeonFlicker>
    with TickerProviderStateMixin {
  Timer? _quietTimer;
  Timer? _stepTimer;
  AnimationController? _clock;
  double _burstOpacity = 1.0;

  // Idle-hum parameters: a mains-frequency-ish shimmer plus a slow breath.
  final double _humSeedA = _rand(0, math.pi * 2);
  final double _humSeedB = _rand(0, math.pi * 2);
  final double _humSpeed = _rand(0.22, 0.48);
  final double _humDepth = _rand(0.04, 0.11);

  @override
  void initState() {
    super.initState();
    if (ZenMotion.enabled) {
      _clock = _startMotionClock(this);
      _scheduleNextFlicker();
    }
  }

  @override
  void didUpdateWidget(ZenNeonFlicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (ZenMotion.enabled) {
      _clock ??= _startMotionClock(this);
      if (_quietTimer == null && _stepTimer == null) {
        _scheduleNextFlicker();
      }
    } else {
      _cancelTimers();
      _clock?.dispose();
      _clock = null;
      _burstOpacity = 1.0;
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    _clock?.dispose();
    super.dispose();
  }

  void _cancelTimers() {
    _quietTimer?.cancel();
    _quietTimer = null;
    _stepTimer?.cancel();
    _stepTimer = null;
  }

  void _scheduleNextFlicker() {
    if (!mounted || !ZenMotion.enabled) return;
    _cancelTimers();
    final int span = (widget.maxQuietSeconds - widget.minQuietSeconds).clamp(
      1,
      60,
    );
    // Skewing the draw makes short gaps common and long gaps rare, which is
    // how real intermittent faults are distributed.
    final double skew = math.pow(_entropy.nextDouble(), 1.5).toDouble();
    final int delayMs = (widget.minQuietSeconds * 1000 + skew * span * 1000)
        .toInt();
    _quietTimer = Timer(Duration(milliseconds: delayMs), _triggerFlickerBurst);
  }

  void _triggerFlickerBurst() {
    if (!mounted || !ZenMotion.enabled) return;
    final _FlickerProfile profile =
        _FlickerProfile.values[_entropy.nextInt(_FlickerProfile.values.length)];
    // The speed multiplier is the point of the whole rework: the same profile
    // plays frantically one time and lazily the next.
    final double speed = _rand(0.55, 1.9);
    final int totalSteps = switch (profile) {
      _FlickerProfile.buzz => 9 + _entropy.nextInt(9),
      _FlickerProfile.sag => 2 + _entropy.nextInt(2),
      _FlickerProfile.stutter => 4 + _entropy.nextInt(6),
      _FlickerProfile.coldStart => 5 + _entropy.nextInt(4),
    };
    int stepIndex = 0;

    void nextStep() {
      if (!mounted || !ZenMotion.enabled) return;
      if (stepIndex >= totalSteps) {
        setState(() => _burstOpacity = 1.0);
        _scheduleNextFlicker();
        return;
      }

      final bool isDip = stepIndex.isEven;
      final double progress = stepIndex / totalSteps;
      final double target = switch (profile) {
        _FlickerProfile.buzz =>
          isDip
              ? 0.55 + _entropy.nextDouble() * 0.3
              : 0.94 + _entropy.nextDouble() * 0.06,
        _FlickerProfile.sag =>
          isDip
              ? 0.05 + _entropy.nextDouble() * 0.14
              : 0.9 + _entropy.nextDouble() * 0.1,
        _FlickerProfile.stutter =>
          isDip
              ? 0.16 + _entropy.nextDouble() * 0.42
              : 0.9 + _entropy.nextDouble() * 0.1,
        // A cold start climbs: each failed ignition gets a little brighter.
        _FlickerProfile.coldStart =>
          isDip
              ? 0.08 + _entropy.nextDouble() * 0.12
              : (0.35 + 0.6 * progress) + _entropy.nextDouble() * 0.08,
      };

      final int baseMs = switch (profile) {
        _FlickerProfile.buzz =>
          isDip ? 14 + _entropy.nextInt(22) : 16 + _entropy.nextInt(26),
        _FlickerProfile.sag =>
          isDip ? 90 + _entropy.nextInt(220) : 130 + _entropy.nextInt(180),
        _FlickerProfile.stutter =>
          isDip ? 22 + _entropy.nextInt(50) : 30 + _entropy.nextInt(80),
        _FlickerProfile.coldStart =>
          isDip ? 40 + _entropy.nextInt(110) : 55 + _entropy.nextInt(130),
      };

      setState(() => _burstOpacity = target.clamp(0.04, 1.0));
      stepIndex++;
      _stepTimer = Timer(
        Duration(milliseconds: math.max(10, (baseMs / speed).round())),
        nextStep,
      );
    }

    nextStep();
  }

  /// Slow idle shimmer, so a lamp that is not currently glitching still is not
  /// perfectly, obviously static.
  double _hum(double seconds) {
    final double x = _warp(seconds * _humSpeed, _humSeedA, _humSeedB);
    final double wave = 0.5 + 0.5 * math.sin(x * math.pi * 2);
    return 1 - _humDepth * (1 - wave);
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? clock = _clock;
    if (!ZenMotion.enabled || clock == null) {
      return _buildGlow(1);
    }
    return AnimatedBuilder(
      animation: clock,
      builder: (BuildContext context, Widget? child) {
        return _buildGlow(_burstOpacity * _hum(clock.value));
      },
    );
  }

  Widget _buildGlow(double opacity) {
    final double clamped = opacity.clamp(0.05, 1.0);
    return Opacity(
      opacity: clamped,
      child: DecoratedBox(
        decoration: BoxDecoration(
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: widget.color.withValues(
                alpha: (widget.glowAlpha * clamped).clamp(0.0, 1.0),
              ),
              blurRadius: widget.glowRadius * clamped,
              spreadRadius: -1,
            ),
          ],
        ),
        child: widget.child,
      ),
    );
  }
}

/// Expanding sonar-style rings behind [child] — used for the incoming-call
/// hero icon and the "connecting" state on the call surface. Ring spacing,
/// reach and speed are jittered per instance so the sonar reads as organic.
/// Renders only the child when [ZenMotion.enabled] is false.
class ZenPulseRings extends StatefulWidget {
  const ZenPulseRings({
    super.key,
    required this.child,
    required this.color,
    this.ringCount = 2,
    this.baseSize = 88,
    this.period = const Duration(milliseconds: 1400),
  });

  final Widget child;
  final Color color;
  final int ringCount;

  /// Diameter the rings start from — should match the child's footprint.
  final double baseSize;
  final Duration period;

  @override
  State<ZenPulseRings> createState() => _ZenPulseRingsState();
}

@immutable
class _RingJitter {
  const _RingJitter({
    required this.phase,
    required this.reach,
    required this.opacity,
  });

  factory _RingJitter.random(int index, int count) {
    return _RingJitter(
      phase: index / math.max(1, count) + _rand(-0.07, 0.07),
      reach: _rand(0.5, 0.78),
      opacity: _rand(0.45, 0.7),
    );
  }

  final double phase;
  final double reach;
  final double opacity;
}

class _ZenPulseRingsState extends State<ZenPulseRings>
    with TickerProviderStateMixin {
  AnimationController? _clock;
  late List<_RingJitter> _rings;

  final double _speed = _rand(0.78, 1.24);
  final double _seedA = _rand(0, math.pi * 2);
  final double _seedB = _rand(0, math.pi * 2);

  @override
  void initState() {
    super.initState();
    _rings = _buildRings();
    _syncController();
  }

  @override
  void didUpdateWidget(ZenPulseRings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ringCount != widget.ringCount) {
      _rings = _buildRings();
      _syncController();
    }
  }

  List<_RingJitter> _buildRings() {
    return List<_RingJitter>.generate(
      math.max(0, widget.ringCount),
      (int index) => _RingJitter.random(index, widget.ringCount),
      growable: false,
    );
  }

  void _syncController() {
    final bool shouldAnimate = ZenMotion.enabled && widget.ringCount > 0;
    if (shouldAnimate && _clock == null) {
      _clock = _startMotionClock(this);
    } else if (!shouldAnimate && _clock != null) {
      _clock!.dispose();
      _clock = null;
    }
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? clock = _clock;
    if (clock == null) {
      return SizedBox(
        width: widget.baseSize,
        height: widget.baseSize,
        child: Center(child: widget.child),
      );
    }
    final double periodSeconds =
        widget.period.inMilliseconds / 1000 * (1 / _speed);
    return SizedBox(
      width: widget.baseSize,
      height: widget.baseSize,
      child: AnimatedBuilder(
        animation: clock,
        builder: (BuildContext context, Widget? child) {
          final double t = _warp(
            clock.value / math.max(0.2, periodSeconds),
            _seedA,
            _seedB,
          );
          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: <Widget>[
              for (int index = 0; index < _rings.length; index += 1)
                _buildRing((t + _rings[index].phase) % 1.0, _rings[index]),
              widget.child,
            ],
          );
        },
      ),
    );
  }

  Widget _buildRing(double phase, _RingJitter jitter) {
    final double eased = Curves.easeOutCubic.transform(phase.clamp(0.0, 1.0));
    final double size = widget.baseSize * (1 + eased * jitter.reach);
    return IgnorePointer(
      child: Opacity(
        opacity: ((1 - eased) * jitter.opacity).clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: widget.color, width: 1.5),
          ),
          width: size,
          height: size,
        ),
      ),
    );
  }
}

/// Smooth fade, slide and subtle scale entrance transition with deliberate, visible pacing.
class ZenFadeSlide extends StatelessWidget {
  const ZenFadeSlide({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 360),
    this.offset = const Offset(0, 12),
    this.curve = Curves.easeOutCubic,
    this.enableScale = true,
    this.delay = Duration.zero,
  });

  final Widget child;
  final Duration duration;
  final Offset offset;
  final Curve curve;
  final bool enableScale;

  /// Optional stagger delay — the child stays fully transparent until it
  /// elapses, then runs the entrance tween. Used for sequenced list
  /// entrances; keep delays short and only on initial insertion.
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    if (!ZenMotion.allowedIn(context)) {
      return child;
    }
    final Widget entrance = _buildEntrance();
    if (delay > Duration.zero) {
      return _ZenDelayedEntrance(
        delay: delay,
        placeholder: child,
        child: entrance,
      );
    }
    return entrance;
  }

  Widget _buildEntrance() {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: duration,
      curve: curve,
      builder: (BuildContext context, double value, Widget? child) {
        final double scale = enableScale ? (0.97 + 0.03 * value) : 1.0;
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(offset.dx * (1 - value), offset.dy * (1 - value)),
            child: Transform.scale(scale: scale, child: child),
          ),
        );
      },
      child: child,
    );
  }
}

/// Holds the entrance invisible until [delay] elapses — the stagger
/// companion of [ZenFadeSlide]. [placeholder] reserves the layout space so
/// the list does not jump when the real entrance starts.
class _ZenDelayedEntrance extends StatefulWidget {
  const _ZenDelayedEntrance({
    required this.delay,
    required this.placeholder,
    required this.child,
  });

  final Duration delay;
  final Widget placeholder;
  final Widget child;

  @override
  State<_ZenDelayedEntrance> createState() => _ZenDelayedEntranceState();
}

class _ZenDelayedEntranceState extends State<_ZenDelayedEntrance> {
  Timer? _timer;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) {
        setState(() => _started = true);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_started) {
      return widget.child;
    }
    return Opacity(opacity: 0, child: IgnorePointer(child: widget.placeholder));
  }
}

/// Tactile pressable wrapper with smooth spring compression on tap.
class ZenPressable extends StatefulWidget {
  const ZenPressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scalePressed = 0.975,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scalePressed;

  @override
  State<ZenPressable> createState() => _ZenPressableState();
}

class _ZenPressableState extends State<ZenPressable> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    if (!ZenMotion.enabled ||
        (widget.onTap == null && widget.onLongPress == null)) {
      return InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: widget.child,
      );
    }
    return GestureDetector(
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      behavior: HitTestBehavior.opaque,
      child: AnimatedScale(
        scale: _isPressed ? widget.scalePressed : 1.0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

/// How a single letter fails during a glitch burst.
enum _GlitchProfile {
  /// Two or three quick twitches.
  twitch,

  /// A long, chaotic run of unequal stutters.
  stutter,

  /// A deep sag that takes its time coming back.
  sag,
}

/// Renders text with organic, highly randomised dying-neon flicker. Letters
/// glitch independently — each one picks its own profile, its own step count
/// and its own playback speed — and once in a while the whole word browns out
/// together. Quiet gaps between bursts are drawn from a skewed distribution,
/// so short gaps are common and long ones rare.
class ZenNeonGlitchText extends StatefulWidget {
  const ZenNeonGlitchText({
    super.key,
    required this.text,
    this.style,
    this.glowColor,
    this.glowRadius = 8,
    this.minQuietSeconds = 8,
    this.maxQuietSeconds = 38,
  });

  final String text;
  final TextStyle? style;
  final Color? glowColor;
  final double glowRadius;
  final int minQuietSeconds;
  final int maxQuietSeconds;

  @override
  State<ZenNeonGlitchText> createState() => _ZenNeonGlitchTextState();
}

class _ZenNeonGlitchTextState extends State<ZenNeonGlitchText> {
  Timer? _quietTimer;
  final List<Timer> _letterTimers = <Timer>[];
  final Map<int, double> _letterOpacity = <int, double>{};
  int _runningLetters = 0;

  @override
  void initState() {
    super.initState();
    if (ZenMotion.enabled && widget.text.isNotEmpty) {
      _scheduleNextFlicker();
    }
  }

  @override
  void didUpdateWidget(ZenNeonGlitchText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (ZenMotion.enabled) {
      if (_quietTimer == null && _runningLetters == 0) {
        _scheduleNextFlicker();
      }
    } else {
      _cancelTimers();
    }
  }

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }

  void _cancelTimers() {
    _quietTimer?.cancel();
    _quietTimer = null;
    for (final Timer timer in _letterTimers) {
      timer.cancel();
    }
    _letterTimers.clear();
    _runningLetters = 0;
    _letterOpacity.clear();
  }

  void _scheduleNextFlicker() {
    if (!mounted || !ZenMotion.enabled || widget.text.isEmpty) return;
    _cancelTimers();
    final int span = (widget.maxQuietSeconds - widget.minQuietSeconds).clamp(
      2,
      90,
    );
    // Exponential-ish skew: most gaps sit near the minimum, the occasional one
    // stretches out — the pattern never becomes predictable.
    final double skew = math.pow(_entropy.nextDouble(), 1.7).toDouble();
    final int delayMs = (widget.minQuietSeconds * 1000 + skew * span * 1000)
        .toInt();
    _quietTimer = Timer(Duration(milliseconds: delayMs), _triggerGlitch);
  }

  void _triggerGlitch() {
    if (!mounted || !ZenMotion.enabled || widget.text.isEmpty) return;
    final List<int> validIndices = <int>[];
    for (int i = 0; i < widget.text.length; i++) {
      if (widget.text[i].trim().isNotEmpty) {
        validIndices.add(i);
      }
    }
    if (validIndices.isEmpty) {
      _scheduleNextFlicker();
      return;
    }

    _letterOpacity.clear();
    final double roll = _entropy.nextDouble();
    final List<int> chosen;
    if (roll < 0.06) {
      // Rare full-word brownout: every letter sags at once, then recovers.
      chosen = validIndices;
    } else {
      final int count = roll < 0.3 && validIndices.length > 2 ? 2 : 1;
      final List<int> pool = List<int>.of(validIndices)..shuffle(_entropy);
      chosen = pool.take(count).toList(growable: false);
    }

    _runningLetters = chosen.length;
    for (final int index in chosen) {
      _runLetter(index);
    }
  }

  /// Drives one letter through its own independent glitch timeline.
  void _runLetter(int index) {
    final _GlitchProfile profile =
        _GlitchProfile.values[_entropy.nextInt(_GlitchProfile.values.length)];
    // Per-letter speed: two letters glitching at once do so at different rates.
    final double speed = _rand(0.6, 1.75);
    final int steps = switch (profile) {
      _GlitchProfile.twitch => 2 + _entropy.nextInt(2),
      _GlitchProfile.stutter => 5 + _entropy.nextInt(7),
      _GlitchProfile.sag => 3 + _entropy.nextInt(3),
    };
    int step = 0;

    void nextStep() {
      if (!mounted || !ZenMotion.enabled) return;
      if (step >= steps) {
        setState(() => _letterOpacity.remove(index));
        _runningLetters -= 1;
        if (_runningLetters <= 0) {
          _runningLetters = 0;
          _scheduleNextFlicker();
        }
        return;
      }

      final bool isLow = step.isEven;
      final double target = switch (profile) {
        _GlitchProfile.twitch =>
          isLow
              ? 0.28 + _entropy.nextDouble() * 0.38
              : 0.93 + _entropy.nextDouble() * 0.07,
        _GlitchProfile.stutter =>
          isLow
              ? 0.12 + _entropy.nextDouble() * 0.42
              : 0.9 + _entropy.nextDouble() * 0.1,
        _GlitchProfile.sag =>
          isLow
              ? 0.04 + _entropy.nextDouble() * 0.12
              : 0.88 + _entropy.nextDouble() * 0.12,
      };

      final int baseMs = switch (profile) {
        _GlitchProfile.twitch =>
          isLow ? 28 + _entropy.nextInt(34) : 34 + _entropy.nextInt(46),
        _GlitchProfile.stutter =>
          isLow ? 18 + _entropy.nextInt(48) : 22 + _entropy.nextInt(52),
        _GlitchProfile.sag =>
          isLow ? 70 + _entropy.nextInt(140) : 60 + _entropy.nextInt(110),
      };

      setState(() => _letterOpacity[index] = target.clamp(0.04, 1.0));
      step++;
      _letterTimers.add(
        Timer(
          Duration(milliseconds: math.max(12, (baseMs / speed).round())),
          nextStep,
        ),
      );
    }

    nextStep();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle baseStyle =
        widget.style ?? DefaultTextStyle.of(context).style;
    if (!ZenMotion.enabled || _letterOpacity.isEmpty) {
      return Text(widget.text, style: baseStyle);
    }

    final Color glow = widget.glowColor ?? baseStyle.color ?? Colors.amber;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List<Widget>.generate(widget.text.length, (int i) {
        final double? opacity = _letterOpacity[i];
        if (opacity == null) {
          return Text(widget.text[i], style: baseStyle);
        }
        return Opacity(
          opacity: opacity.clamp(0.04, 1.0),
          child: Text(
            widget.text[i],
            style: baseStyle.copyWith(
              shadows: <Shadow>[
                Shadow(
                  color: glow.withValues(
                    alpha: (0.75 * opacity).clamp(0.0, 1.0),
                  ),
                  blurRadius: widget.glowRadius * opacity,
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}
