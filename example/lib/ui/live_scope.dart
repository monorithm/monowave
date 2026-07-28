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
    this.floorDb = -50,
  });

  final Color active;
  final Color idle;
  final double barFraction;
  final double minBarHeight;

  /// Silence floor for the decibel curve, in dB.
  ///
  /// A live meter has to be drawn on a decibel scale or it reads as broken.
  /// Room tone sits near 1% of full scale, which is a two-pixel bar on a linear
  /// axis — the same trap `CompactBars` avoids for the fixed-bar case, and the
  /// reason a linear meter looks dead while the microphone is working fine.
  final double floorDb;
}

final _ln10 = math.log(10);

/// Maps a 0..1 amplitude onto a 0..1 height through a decibel curve.
double _curve(double amplitude, double floorDb) {
  if (amplitude <= 0) return 0;
  final db = 20 * math.log(amplitude) / _ln10;
  return ((db - floorDb) / -floorDb).clamp(0.0, 1.0);
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
  /// changing and the meter silently freezes — which is exactly what happened.
  final int _revision;

  @override
  void paint(Canvas canvas, Size size) {
    final scope = this.scope;
    final center = size.height / 2;

    if (scope == null || scope.isEmpty) {
      // A flat line rather than an empty box, so the widget reads as "ready"
      // rather than "broken".
      canvas.drawRect(
        Rect.fromLTWH(0, center - 0.5, size.width, 1),
        Paint()..color = style.idle,
      );
      return;
    }

    // Newest at the right: the window is anchored to the right edge, so a
    // half-full scope grows leftward instead of stretching.
    final slot = size.width / scope.capacity;
    final barWidth = (slot * style.barFraction).clamp(1.0, slot);
    final firstX = size.width - scope.length * slot;
    final paint = Paint()..color = style.active;

    for (var i = 0; i < scope.length; i++) {
      final amplitude = _curve(scope.amplitudeAt(i), style.floorDb);
      var barHeight = amplitude * size.height;
      if (barHeight < style.minBarHeight) barHeight = style.minBarHeight;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            firstX + i * slot + (slot - barWidth) / 2,
            center - barHeight / 2,
            barWidth,
            barHeight,
          ),
          Radius.circular(barWidth / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ScopePainter old) =>
      old._revision != _revision ||
      !identical(old.scope, scope) ||
      old.style.active != style.active;
}
