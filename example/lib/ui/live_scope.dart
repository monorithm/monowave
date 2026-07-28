import 'dart:math' as math;

import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';

/// Colors for [LiveScope].
class LiveScopeStyle {
  const LiveScopeStyle({
    required this.active,
    required this.idle,
    this.barFraction = 0.55,
    this.minBarHeight = 2.0,
    this.barSlot = 9.0,
    this.gamma = 0.9,
    this.hullOpacity = 0.28,
    this.maxGain = 48.0,
  });

  final Color active;
  final Color idle;
  final double barFraction;
  final double minBarHeight;

  /// Width of one bar and its gap, in logical pixels.
  ///
  /// The same reasoning as the editor's canvas: a bar per pixel is a texture,
  /// and roughly forty bars is a shape.
  final double barSlot;

  /// Exponent on the amplitude axis. Near-linear, because the meter normalizes.
  ///
  /// This was a decibel curve, added because a linear meter looks dead in a
  /// quiet room. Decibels fixed that and broke the opposite end - everything
  /// above roughly -10 dB flattened to the same height. Normalizing against the
  /// signal's own loudness solves the quiet room without crushing the loud one.
  final double gamma;

  /// How much of the peak hull shows behind the RMS core.
  final double hullOpacity;

  /// Ceiling on normalization, so digital silence does not amplify into noise.
  ///
  /// Generous, because the percentile reference is what actually adapts - this
  /// only stops a completely silent input from being multiplied into static.
  /// Set too low it becomes the binding constraint instead, and a quiet room
  /// draws as a row of dots.
  final double maxGain;
}

/// The live recording visualizer: a bar per captured hop, newest at the right.
///
/// Reads [CaptureScope] directly rather than taking a list, so nothing is
/// allocated per repaint. The scope is a ring over a preallocated buffer, and
/// at 86 frames a second a `List<double>` rebuilt each tick would put its
/// garbage in the same frame budget as the painting.
class LiveScope extends StatelessWidget {
  const LiveScope({
    super.key,
    required this.scope,
    required this.style,
    this.height = 96,
  });

  /// The running session's scope, or null when idle.
  final CaptureScope? scope;

  final LiveScopeStyle style;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: RepaintBoundary(
      child: CustomPaint(
        painter: _ScopePainter(scope: scope, style: style),
      ),
    ),
  );
}

class _ScopePainter extends CustomPainter {
  _ScopePainter({required this.scope, required this.style})
    : _revision = scope?.revision ?? -1;

  final CaptureScope? scope;
  final LiveScopeStyle style;

  /// The scope is a ring that mutates in place. Keying repaints on its length
  /// works right up until the ring fills, at which point the length stops
  /// changing and the meter silently freezes - which is exactly what happened.
  final int _revision;

  @override
  void paint(Canvas canvas, Size size) {
    final scope = this.scope;
    final centre = size.height / 2;

    if (scope == null || scope.isEmpty) {
      // A flat line rather than an empty box, so the widget reads as "ready"
      // rather than "broken".
      canvas.drawRect(
        Rect.fromLTWH(0, centre - 0.5, size.width, 1),
        Paint()..color = style.idle,
      );
      return;
    }

    final reach = centre * 0.88;
    final slots = math.max(1, (size.width / style.barSlot).floor());
    final perSlot = math.max(1, (scope.capacity / slots).ceil());
    final ink = math.max(1.0, style.barSlot * style.barFraction);
    final radius = Radius.circular(ink / 2);

    // Scaled against the signal's own loudness, on a slow-moving reference:
    // a rolling percentile over the whole window shifts gradually, where a
    // per-frame maximum would make the meter pump on every syllable.
    final loudness = <int>[
      for (var i = 0; i < scope.length; i++) scope.rmsAt(i),
    ]..sort();
    final reference =
        loudness[(scope.length * 0.95).floor().clamp(0, scope.length - 1)] /
        0.72;
    final gain = reference <= 0
        ? 1.0
        : math.min(style.maxGain, 32768 / reference);

    double curve(double amplitude) => amplitude <= 0
        ? 0
        : math.pow(amplitude.clamp(0.0, 1.0), style.gamma).toDouble();

    final core = Paint()..color = style.active;
    final hull = Paint()
      ..color = style.active.withValues(alpha: style.hullOpacity);

    // Newest at the right: the window is anchored to the right edge, so a
    // half-full scope grows leftward instead of stretching.
    final drawn = (scope.length / perSlot).ceil();
    for (var slot = 0; slot < drawn; slot++) {
      final from = scope.length - (drawn - slot) * perSlot;
      var peak = 0;
      var rms = 0.0;
      var counted = 0;

      for (var i = math.max(0, from); i < from + perSlot; i++) {
        if (i >= scope.length) break;
        final low = scope.minAt(i).abs();
        final high = scope.maxAt(i).abs();
        if (low > peak) peak = low;
        if (high > peak) peak = high;
        final value = scope.rmsAt(i);
        rms += value * value.toDouble();
        counted++;
      }
      if (counted == 0) continue;
      rms = math.sqrt(rms / counted);

      final x =
          size.width -
          (drawn - slot) * style.barSlot +
          (style.barSlot - ink) / 2;

      final hullHeight = math.max(
        curve(peak * gain / CaptureScope.fullScale) * reach * 2,
        style.minBarHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centre - hullHeight / 2, ink, hullHeight),
          radius,
        ),
        hull,
      );

      final coreHeight = math.max(
        curve(rms * gain / CaptureScope.fullScale) * reach * 2,
        style.minBarHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centre - coreHeight / 2, ink, coreHeight),
          radius,
        ),
        core,
      );
    }
  }

  @override
  bool shouldRepaint(_ScopePainter old) =>
      old._revision != _revision ||
      !identical(old.scope, scope) ||
      old.style.active != style.active;
}
