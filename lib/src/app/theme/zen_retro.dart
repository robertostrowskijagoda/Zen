import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The pieces of the retro look (an old desktop music player): LED
/// digits, an LCD spectrum analyzer and pinstriped title bars.

/// [text] in seven-segment LED digits ('0'–'9', '+', '-' and spaces), the
/// unlit segments faintly visible like on a real display.
class ZenLedNumber extends StatelessWidget {
  const ZenLedNumber(
    this.text, {
    required this.color,
    this.height = 14,
    this.glow = true,
    super.key,
  });

  final String text;
  final Color color;

  /// Height of one digit.
  final double height;

  /// A soft bloom around the lit segments.
  final bool glow;

  /// Width of [count] digits at [height].
  static double widthOf(int count, double height) =>
      count <= 0 ? 0 : count * height * 0.56 + (count - 1) * height * 0.2;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: text,
      child: CustomPaint(
        size: Size(widthOf(text.length, height) + height * 0.12, height),
        painter: _LedPainter(text: text, color: color, glow: glow),
      ),
    );
  }
}

class _LedPainter extends CustomPainter {
  const _LedPainter({
    required this.text,
    required this.color,
    required this.glow,
  });

  final String text;
  final Color color;
  final bool glow;

  // Segments a b c d e f g as bits 0..6.
  static const Map<String, int> _digits = <String, int>{
    '0': 0x3F,
    '1': 0x06,
    '2': 0x5B,
    '3': 0x4F,
    '4': 0x66,
    '5': 0x6D,
    '6': 0x7D,
    '7': 0x07,
    '8': 0x7F,
    '9': 0x6F,
    '-': 0x40,
    '+': 0x40,
    ' ': 0x00,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final double h = size.height;
    final double w = h * 0.56;
    final double s = h * 0.13;
    final double gap = h * 0.2;
    final Paint lit = Paint()..color = color;
    final Paint ghost = Paint()..color = color.withValues(alpha: 0.10);
    final Paint bloom = Paint()
      ..color = color.withValues(alpha: 0.55)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, h * 0.12);
    final Path on = Path();
    final Path off = Path();
    // The classic slight forward slant.
    canvas
      ..save()
      ..translate(h * 0.06, 0)
      ..skew(-0.08, 0);
    for (int i = 0; i < text.length; i++) {
      final String ch = text[i];
      final int mask = _digits[ch] ?? 0;
      final double x = i * (w + gap) + h * 0.06;
      final List<Path> segments = _segments(x, w, h, s);
      for (int k = 0; k < 7; k++) {
        ((mask & (1 << k)) != 0 ? on : off).addPath(segments[k], Offset.zero);
      }
      if (ch == '+') {
        // A short upright through the middle bar.
        on.addPath(
          _vertical(x + w / 2, h / 2 - w * 0.36, h / 2 + w * 0.36, s),
          Offset.zero,
        );
      }
    }
    canvas.drawPath(off, ghost);
    if (glow) {
      canvas.drawPath(on, bloom);
    }
    canvas
      ..drawPath(on, lit)
      ..restore();
  }

  static List<Path> _segments(double x, double w, double h, double s) {
    final double g = s * 0.28;
    final double half = s / 2;
    final double mid = h / 2;
    return <Path>[
      _horizontal(x + half + g, x + w - half - g, half, s), // a
      _vertical(x + w - half, half + g, mid - g, s), // b
      _vertical(x + w - half, mid + g, h - half - g, s), // c
      _horizontal(x + half + g, x + w - half - g, h - half, s), // d
      _vertical(x + half, mid + g, h - half - g, s), // e
      _vertical(x + half, half + g, mid - g, s), // f
      _horizontal(x + half + g, x + w - half - g, mid, s), // g
    ];
  }

  static Path _horizontal(double x1, double x2, double y, double s) {
    final double k = s / 2;
    return Path()
      ..moveTo(x1, y)
      ..lineTo(x1 + k, y - k)
      ..lineTo(x2 - k, y - k)
      ..lineTo(x2, y)
      ..lineTo(x2 - k, y + k)
      ..lineTo(x1 + k, y + k)
      ..close();
  }

  static Path _vertical(double x, double y1, double y2, double s) {
    final double k = s / 2;
    return Path()
      ..moveTo(x, y1)
      ..lineTo(x + k, y1 + k)
      ..lineTo(x + k, y2 - k)
      ..lineTo(x, y2)
      ..lineTo(x - k, y2 - k)
      ..lineTo(x - k, y1 + k)
      ..close();
  }

  @override
  bool shouldRepaint(_LedPainter oldDelegate) =>
      oldDelegate.text != text ||
      oldDelegate.color != color ||
      oldDelegate.glow != glow;
}

/// A spectrum-analyzer strip of LED bars (decoration in the retro header).
/// It plays only on activity: for a few seconds when a message comes in,
/// and the whole time a call is on; otherwise it shows a quiet, still
/// level. It ticks at a retro 15 frames per second, repaints only its own
/// layer, and stands still under reduced motion and in tests.
class ZenSpectrumStrip extends ConsumerStatefulWidget {
  const ZenSpectrumStrip({this.bars = 12, this.height = 22, super.key});

  final int bars;
  final double height;

  @override
  ConsumerState<ZenSpectrumStrip> createState() => _ZenSpectrumStripState();
}

int _unreadOf(SocialHubState s) =>
    s.acceptedFriends.fold<int>(0, (int sum, f) => sum + f.unreadCount) +
    s.groupList.fold<int>(0, (int sum, g) => sum + g.unreadCount);

bool _inCallOf(SocialHubState s) =>
    s.activeCall?.status == CallSessionStatus.active;

class _ZenSpectrumStripState extends ConsumerState<ZenSpectrumStrip>
    with SingleTickerProviderStateMixin {
  static const int _frameMs = 66;
  static const int _burstMs = 2800;
  static const int _fadeMs = 700;

  final _SpectrumFrame _frame = _SpectrumFrame();
  Ticker? _ticker;
  bool _allowed = false;
  bool _inCall = false;
  int _elapsedMs = 0;
  int _burstEndMs = 0;

  @override
  void initState() {
    super.initState();
    ref.listenManual<bool>(
      socialHubControllerProvider.select(_inCallOf),
      (bool? previous, bool next) => _setInCall(next),
      fireImmediately: true,
    );
    ref.listenManual<int>(socialHubControllerProvider.select(_unreadOf), (
      int? previous,
      int next,
    ) {
      if (previous != null && next > previous) {
        _burst(_burstMs);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _allowed = ZenMotion.allowedIn(context);
    if (!_allowed) {
      _stop();
    } else if (_inCall) {
      _burst(_burstMs);
    }
  }

  void _setInCall(bool value) {
    _inCall = value;
    if (value) {
      _burst(_burstMs);
    } else {
      // Let the bars fall back after the call.
      _burstEndMs = math.min(_burstEndMs, _elapsedMs + _fadeMs);
    }
  }

  void _burst(int ms) {
    if (!_allowed) {
      return;
    }
    final Ticker ticker = _ticker ??= createTicker(_tick);
    if (!ticker.isActive) {
      _elapsedMs = 0;
      ticker.start();
    }
    _burstEndMs = math.max(_burstEndMs, _elapsedMs + ms);
  }

  void _tick(Duration elapsed) {
    final int ms = elapsed.inMilliseconds;
    if (ms ~/ _frameMs == _elapsedMs ~/ _frameMs && ms != 0) {
      _elapsedMs = ms;
      return;
    }
    _elapsedMs = ms;
    if (_inCall) {
      _burstEndMs = ms + _fadeMs;
    }
    final int left = _burstEndMs - ms;
    if (left <= 0) {
      _stop();
      return;
    }
    final double energy = (left / _fadeMs).clamp(0.0, 1.0);
    _frame.update((ms ~/ _frameMs) * _frameMs / 1000, 0.2 + 0.8 * energy);
  }

  void _stop() {
    _ticker?.stop();
    _elapsedMs = 0;
    _burstEndMs = 0;
    _frame.update(0, 0.2);
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return RepaintBoundary(
      child: CustomPaint(
        size: Size(widget.bars * 4.0 - 1, widget.height),
        painter: _SpectrumPainter(
          frame: _frame,
          bars: widget.bars,
          low: zen.accent,
          high: zen.accentSecondary,
          peak: zen.accentTertiary,
        ),
      ),
    );
  }
}

class _SpectrumFrame extends ChangeNotifier {
  double seconds = 0;
  double energy = 0.2;

  void update(double seconds, double energy) {
    if (seconds == this.seconds && energy == this.energy) {
      return;
    }
    this.seconds = seconds;
    this.energy = energy;
    notifyListeners();
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({
    required this.frame,
    required this.bars,
    required this.low,
    required this.high,
    required this.peak,
  }) : super(repaint: frame);

  final _SpectrumFrame frame;
  final int bars;
  final Color low;
  final Color high;
  final Color peak;

  /// The level (0..1) of bar [i] at [s] seconds, louder on the bass side.
  static double level(int i, int bars, double s, double energy) {
    final double a = 0.5 + 0.5 * math.sin(s * (2.3 + i * 0.41) + i * 1.7);
    final double b = 0.5 + 0.5 * math.sin(s * (6.1 + (i % 5) * 0.9) + i * 0.6);
    final double c = 0.5 + 0.5 * math.sin(s * 11.3 + i * i * 0.37);
    final double tilt = 1 - i / (bars * 1.7);
    return ((a * 0.5 + b * 0.32 + c * 0.18) * tilt * energy).clamp(0.06, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const double barWidth = 3;
    const double block = 2;
    const double step = 3;
    final int blocks = (size.height / step).floor();
    if (blocks <= 0) {
      return;
    }
    final Paint ghost = Paint()..color = low.withValues(alpha: 0.08);
    final Paint paint = Paint();
    for (int i = 0; i < bars; i++) {
      final double x = i * (barWidth + 1);
      final int lit = (level(i, bars, frame.seconds, frame.energy) * blocks)
          .round()
          .clamp(1, blocks);
      for (int k = 0; k < blocks; k++) {
        final double y = size.height - (k + 1) * step + (step - block);
        final Rect r = Rect.fromLTWH(x, y, barWidth, block);
        if (k >= lit) {
          canvas.drawRect(r, ghost);
          continue;
        }
        final double f = k / blocks;
        paint.color = f > 0.8
            ? peak
            : f > 0.55
            ? high
            : low;
        canvas.drawRect(r, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.bars != bars ||
      oldDelegate.low != low ||
      oldDelegate.high != high ||
      oldDelegate.peak != peak;
}

/// A tiny title bar: [title] in pixel caps between pinstripes, like the
/// title of a player window.
class ZenTitleBar extends StatelessWidget {
  const ZenTitleBar(this.title, {this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Widget stripes = SizedBox(
      height: 9,
      child: CustomPaint(
        painter: _PinstripePainter(
          light: zen.outlineStrong,
          dark: zen.surfaceSunk,
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 2, 4, 2),
      decoration: ShapeDecoration(
        color: zen.surfaceRaised,
        shape: ZenBevelBorder.of(zen),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(width: 10, child: stripes),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: zen.mono(
                color: zen.accentSecondary,
                size: 11,
                letterSpacing: 1.2,
                height: 1.1,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(child: stripes),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 4),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _PinstripePainter extends CustomPainter {
  const _PinstripePainter({required this.light, required this.dark});

  final Color light;
  final Color dark;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint l = Paint()..color = light;
    final Paint d = Paint()..color = dark;
    for (double y = 0; y + 2 <= size.height; y += 3) {
      canvas
        ..drawRect(Rect.fromLTWH(0, y, size.width, 1), l)
        ..drawRect(Rect.fromLTWH(0, y + 1, size.width, 1), d);
    }
  }

  @override
  bool shouldRepaint(_PinstripePainter oldDelegate) =>
      oldDelegate.light != light || oldDelegate.dark != dark;
}
