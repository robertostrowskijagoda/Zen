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

  /// Frames a second of the perpetual animations (the display would draw
  /// 60-120): enough to read as alive, little enough for the battery.
  static const int framesPerSecond = 15;

  /// Whether the shared clock of the perpetual animations runs now (it
  /// stops when nothing animates, motion is off or the window is not
  /// active).
  @visibleForTesting
  static bool get clockRunning => _LowRateClock.instance.isRunning;

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

/// The shared clock of the perpetual animations: elapsed seconds (wrapping
/// every hour), moved by a timer at [ZenMotion.framesPerSecond] — not by a
/// ticker at the display's 60-120 frames a second — and only while some
/// animation listens and the window is shown and active. A window behind
/// others (inactive on a computer) or in the background draws nothing.
final class _LowRateClock extends ChangeNotifier with WidgetsBindingObserver {
  _LowRateClock._();

  static final _LowRateClock instance = _LowRateClock._();

  final Stopwatch _elapsed = Stopwatch();
  Timer? _timer;
  int _clients = 0;
  bool _observing = false;

  double get seconds => (_elapsed.elapsedMicroseconds / 1e6) % 3600;

  bool get isRunning => _timer != null;

  void attach(VoidCallback listener) {
    addListener(listener);
    _clients += 1;
    _sync();
  }

  void detach(VoidCallback listener) {
    removeListener(listener);
    _clients = math.max(0, _clients - 1);
    _sync();
  }

  bool get _shown {
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  void _sync() {
    if (_clients > 0 && !_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    } else if (_clients == 0 && _observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    final bool run = _clients > 0 && _shown;
    if (run && _timer == null) {
      _elapsed.start();
      _timer = Timer.periodic(
        const Duration(microseconds: 1000000 ~/ ZenMotion.framesPerSecond),
        (_) => notifyListeners(),
      );
    } else if (!run && _timer != null) {
      _timer?.cancel();
      _timer = null;
      _elapsed.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _sync();
}

/// A state that follows the shared low-rate clock while [wantsMotion].
mixin _LowRateMotion<T extends StatefulWidget> on State<T> {
  bool _onClock = false;

  /// Whether this widget animates now (checked on every change).
  bool get wantsMotion;

  double get clockSeconds => _LowRateClock.instance.seconds;

  bool get onClock => _onClock;

  /// Called on every tick while on the clock.
  void onClockTick() {
    if (mounted) {
      setState(() {});
    }
  }

  void syncClock() {
    final bool want = wantsMotion;
    if (want && !_onClock) {
      _onClock = true;
      _LowRateClock.instance.attach(onClockTick);
    } else if (!want && _onClock) {
      _onClock = false;
      _LowRateClock.instance.detach(onClockTick);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncClock();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncClock();
  }

  @override
  void dispose() {
    if (_onClock) {
      _onClock = false;
      _LowRateClock.instance.detach(onClockTick);
    }
    super.dispose();
  }
}

/// A row of dots that light up in a wave — the animated companion for
/// "Łączenie…" style status labels. Each dot runs at its own speed and drifts
/// in and out of phase with its neighbours. Static dots when motion is off
/// ([ZenMotion.allowedIn]); otherwise at a low frame rate.
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
    with _LowRateMotion<ZenAnimatedDots> {
  late List<_DotWave> _waves;

  @override
  bool get wantsMotion => ZenMotion.allowedIn(context);

  @override
  void initState() {
    super.initState();
    _waves = _buildWaves();
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
  Widget build(BuildContext context) {
    final Color resolved =
        widget.color ??
        DefaultTextStyle.of(context).style.color ??
        Colors.white;
    if (!onClock) {
      return _buildDots(resolved, (int _) => 1);
    }
    final double seconds = clockSeconds;
    return RepaintBoundary(
      child: _buildDots(
        resolved,
        (int index) => _waves[index].intensity(seconds),
      ),
    );
  }

  Widget _buildDots(Color color, double Function(int index) intensity) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int index = 0; index < widget.dotCount; index += 1)
          Padding(
            padding: EdgeInsetsDirectional.only(
              start: index == 0 ? 0 : widget.spacing,
            ),
            child: _buildDot(color, intensity(index).clamp(0.0, 1.0), index),
          ),
      ],
    );
  }

  Widget _buildDot(Color color, double intensity, int index) {
    final double floor = onClock ? _waves[index].floor : 1;
    final double opacity = floor + (1 - floor) * intensity;
    // The dots swell as they brighten — a flat opacity fade reads as a
    // progress spinner, the scale is what makes it read as a signal.
    final double scale = onClock ? 0.76 + 0.44 * intensity : 1;
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
///
/// [continuous]: it pulses for as long as it is shown (a call going on),
/// at a low frame rate. Otherwise it is still and pulses only briefly
/// ([kZenBriefPulse]): when it becomes [active], or from the start with
/// [pulseOnStart]. Still whenever motion is off ([ZenMotion.allowedIn]).
class ZenPulsingDot extends StatefulWidget {
  const ZenPulsingDot({
    super.key,
    required this.color,
    this.active = true,
    this.dimension = 12,
    this.dotSize = 6,
    this.continuous = true,
    this.pulseOnStart = false,
  });

  final Color color;
  final bool active;
  final double dimension;
  final double dotSize;
  final bool continuous;
  final bool pulseOnStart;

  @override
  State<ZenPulsingDot> createState() => _ZenPulsingDotState();
}

/// How long a dot that is not [ZenPulsingDot.continuous] pulses when its
/// state changes.
const Duration kZenBriefPulse = Duration(seconds: 3);

class _ZenPulsingDotState extends State<ZenPulsingDot>
    with _LowRateMotion<ZenPulsingDot> {
  // Waveform parameters — redrawn only when the widget is recreated, so the
  // pulse a user sees on one screen keeps its personality while it is visible.
  final double _period = _rand(1.05, 2.15);
  final double _seedA = _rand(0, math.pi * 2);
  final double _seedB = _rand(0, math.pi * 2);
  final double _offset = _rand(0, 4);
  final int _echoSeed = _entropy.nextInt(1 << 20);

  /// A brief pulse plays (until [_briefTimer] ends it).
  bool _brief = false;
  Timer? _briefTimer;

  @override
  bool get wantsMotion =>
      widget.active &&
      ZenMotion.allowedIn(context) &&
      (widget.continuous || _brief);

  @override
  void initState() {
    super.initState();
    if (widget.pulseOnStart) {
      _startBrief();
    }
  }

  @override
  void didUpdateWidget(ZenPulsingDot oldWidget) {
    if (!oldWidget.active && widget.active) {
      _startBrief();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void dispose() {
    _briefTimer?.cancel();
    super.dispose();
  }

  void _startBrief() {
    _brief = true;
    _briefTimer?.cancel();
    _briefTimer = Timer(kZenBriefPulse, () {
      _briefTimer = null;
      _brief = false;
      if (mounted) {
        // Back to still: off the clock, one last frame.
        syncClock();
        setState(() {});
      }
    });
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
    if (!onClock) {
      return _buildDot(1, 6, 1);
    }
    final double v = _pulse(clockSeconds);
    // The glow's blur changes every frame: kept to this small layer.
    return RepaintBoundary(
      child: _buildDot(0.46 + 0.54 * v, 3 + 11 * v, 0.86 + 0.26 * v),
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

/// A neon lamp: it flickers once — a short burst with its own profile and
/// speed — when it appears and whenever [trigger] changes (a new count),
/// and glows still in between, so a screen that shows it draws nothing.
/// Still when motion is off ([ZenMotion.allowedIn]).
class ZenNeonFlicker extends StatefulWidget {
  const ZenNeonFlicker({
    super.key,
    required this.child,
    required this.color,
    this.glowRadius = 14,
    this.glowAlpha = 0.5,
    this.trigger,
  });

  final Widget child;
  final Color color;
  final double glowRadius;
  final double glowAlpha;

  /// A change of this value flickers the lamp again.
  final Object? trigger;

  @override
  State<ZenNeonFlicker> createState() => _ZenNeonFlickerState();
}

class _ZenNeonFlickerState extends State<ZenNeonFlicker> {
  Timer? _stepTimer;
  double _burstOpacity = 1.0;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _triggerFlickerBurst();
    } else if (!ZenMotion.allowedIn(context)) {
      _settle();
    }
  }

  @override
  void didUpdateWidget(ZenNeonFlicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trigger != widget.trigger) {
      _triggerFlickerBurst();
    }
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    super.dispose();
  }

  void _settle() {
    _stepTimer?.cancel();
    _stepTimer = null;
    _burstOpacity = 1.0;
  }

  void _triggerFlickerBurst() {
    _stepTimer?.cancel();
    _stepTimer = null;
    if (!mounted || !ZenMotion.allowedIn(context)) {
      _burstOpacity = 1.0;
      return;
    }
    final _FlickerProfile profile =
        _FlickerProfile.values[_entropy.nextInt(_FlickerProfile.values.length)];
    // The same profile plays frantically one time and lazily the next.
    final double speed = _rand(0.55, 1.9);
    final int totalSteps = switch (profile) {
      _FlickerProfile.buzz => 9 + _entropy.nextInt(9),
      _FlickerProfile.sag => 2 + _entropy.nextInt(2),
      _FlickerProfile.stutter => 4 + _entropy.nextInt(6),
      _FlickerProfile.coldStart => 5 + _entropy.nextInt(4),
    };
    int stepIndex = 0;

    void nextStep() {
      if (!mounted) return;
      if (stepIndex >= totalSteps || !ZenMotion.allowedIn(context)) {
        _stepTimer = null;
        setState(() => _burstOpacity = 1.0);
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

      // Never faster than the low frame rate of the other animations.
      final int minStepMs = 1000 ~/ ZenMotion.framesPerSecond;
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
        Duration(milliseconds: math.max(minStepMs, (baseMs / speed).round())),
        nextStep,
      );
    }

    // After the current build: this can come from didChangeDependencies.
    _stepTimer = Timer(Duration.zero, nextStep);
  }

  @override
  Widget build(BuildContext context) {
    final Widget glow = _buildGlow(_burstOpacity);
    return _stepTimer == null ? glow : RepaintBoundary(child: glow);
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
/// Only the child when motion is off ([ZenMotion.allowedIn]); otherwise at
/// a low frame rate.
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
    with _LowRateMotion<ZenPulseRings> {
  late List<_RingJitter> _rings;

  final double _speed = _rand(0.78, 1.24);
  final double _seedA = _rand(0, math.pi * 2);
  final double _seedB = _rand(0, math.pi * 2);

  @override
  bool get wantsMotion => widget.ringCount > 0 && ZenMotion.allowedIn(context);

  @override
  void initState() {
    super.initState();
    _rings = _buildRings();
  }

  @override
  void didUpdateWidget(ZenPulseRings oldWidget) {
    if (oldWidget.ringCount != widget.ringCount) {
      _rings = _buildRings();
    }
    super.didUpdateWidget(oldWidget);
  }

  List<_RingJitter> _buildRings() {
    return List<_RingJitter>.generate(
      math.max(0, widget.ringCount),
      (int index) => _RingJitter.random(index, widget.ringCount),
      growable: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!onClock) {
      return SizedBox(
        width: widget.baseSize,
        height: widget.baseSize,
        child: Center(child: widget.child),
      );
    }
    final double periodSeconds =
        widget.period.inMilliseconds / 1000 * (1 / _speed);
    final double t = _warp(
      clockSeconds / math.max(0.2, periodSeconds),
      _seedA,
      _seedB,
    );
    return SizedBox(
      width: widget.baseSize,
      height: widget.baseSize,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: <Widget>[
          RepaintBoundary(
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: <Widget>[
                for (int index = 0; index < _rings.length; index += 1)
                  _buildRing((t + _rings[index].phase) % 1.0, _rings[index]),
              ],
            ),
          ),
          widget.child,
        ],
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
