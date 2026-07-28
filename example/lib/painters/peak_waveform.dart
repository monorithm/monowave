import 'package:monokit/monokit.dart';
import 'package:monowave/monowave.dart';

/// Colors and geometry for [PeakWaveform].
///
/// A struct rather than reading the theme inside the painter, so the painter
/// stays a pure function of its inputs and `shouldRepaint` can compare cheaply.
/// The page fills this from `MonokitTheme.of(context).colors`; nothing here is
/// hardcoded.
class WaveformStyle {
  const WaveformStyle({
    required this.played,
    required this.unplayed,
    required this.playhead,
    this.selectionFill,
    this.selectionEdge,
    this.barFraction = 0.68,
    this.minBarWidth = 1.0,
    this.minBarHeight = 1.5,
    this.playheadWidth = 2.0,
  });

  final Color played;
  final Color unplayed;
  final Color playhead;

  /// Wash over the selected range, and the colour of its two edges.
  final Color? selectionFill;
  final Color? selectionEdge;

  /// How much of each bar's slot is ink rather than gap.
  final double barFraction;
  final double minBarWidth;

  /// Silence still draws a hairline, so a gap reads as quiet rather than as
  /// missing data.
  final double minBarHeight;
  final double playheadWidth;

  bool sameGeometry(WaveformStyle other) =>
      barFraction == other.barFraction &&
      minBarWidth == other.minBarWidth &&
      minBarHeight == other.minBarHeight;
}

/// A zoomable min/max waveform with a playhead.
///
/// This is the reference implementation of the painter monowave deliberately
/// does not ship. It is what a host writes on top of [PeakWindow] and
/// [WaveformViewport], and it is written to be copied.
///
/// monokit's own `MonoWaveform` covers the fixed-bar voice-note case and should
/// be preferred there. This exists for what that cannot do: true min/max
/// asymmetry, and a viewport that zooms.
///
/// The body and the playhead are separate painters behind a [RepaintBoundary].
/// The body's `shouldRepaint` ignores progress entirely, so scrubbing repaints
/// a thin overlay rather than every bar.
class PeakWaveform extends StatelessWidget {
  const PeakWaveform({
    super.key,
    required this.peaks,
    required this.viewport,
    required this.progressSample,
    required this.style,
    this.selection,
    this.height = 96,
  });

  final WaveformPeaks peaks;
  final WaveformViewport viewport;

  /// Where the playhead sits, in source samples.
  final double progressSample;

  /// The selected range, in source samples. Null when nothing is selected.
  final WaveformSelection? selection;

  final WaveformStyle style;
  final double height;

  @override
  Widget build(BuildContext context) {
    final window = viewport.resolve(peaks);

    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          RepaintBoundary(
            child: CustomPaint(
              painter: _BodyPainter(window: window, style: style),
            ),
          ),
          CustomPaint(
            painter: _PlayheadPainter(
              window: window,
              style: style,
              playheadX: viewport.xForSample(progressSample),
            ),
          ),
          // Above the playhead: a selection is what the next action applies to,
          // so it should read as the foremost thing on screen.
          if (selection != null && !selection!.isEmpty)
            CustomPaint(
              painter: _SelectionPainter(
                style: style,
                startX: viewport.xForSample(selection!.start),
                endX: viewport.xForSample(selection!.end),
              ),
            ),
        ],
      ),
    );
  }
}

/// Draws every visible bar in the unplayed color. Repaints only when the data
/// or the viewport changes — never when the playhead moves.
class _BodyPainter extends CustomPainter {
  const _BodyPainter({required this.window, required this.style});

  final PeakWindow window;
  final WaveformStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBars(canvas, size, window, style, Paint()..color = style.unplayed);
  }

  @override
  bool shouldRepaint(_BodyPainter old) =>
      !identical(old.window.peaks, window.peaks) ||
      old.window.firstPair != window.firstPair ||
      old.window.pairCount != window.pairCount ||
      old.window.xOfFirstPair != window.xOfFirstPair ||
      old.window.pixelsPerPair != window.pixelsPerPair ||
      old.style.unplayed != style.unplayed ||
      !old.style.sameGeometry(style);
}

/// Redraws the played portion clipped to the playhead, then the playhead.
///
/// Drawing the same bars twice is cheaper than it looks and much cheaper than
/// the alternative: the clip means the second pass touches only the pixels left
/// of the playhead, and the body underneath never repaints at all.
class _PlayheadPainter extends CustomPainter {
  const _PlayheadPainter({
    required this.window,
    required this.style,
    required this.playheadX,
  });

  final PeakWindow window;
  final WaveformStyle style;
  final double playheadX;

  @override
  void paint(Canvas canvas, Size size) {
    if (playheadX > 0) {
      canvas
        ..save()
        ..clipRect(
          Rect.fromLTWH(0, 0, playheadX.clamp(0, size.width), size.height),
        );
      _paintBars(canvas, size, window, style, Paint()..color = style.played);
      canvas.restore();
    }

    if (playheadX >= 0 && playheadX <= size.width) {
      canvas.drawRect(
        Rect.fromLTWH(
          playheadX - style.playheadWidth / 2,
          0,
          style.playheadWidth,
          size.height,
        ),
        Paint()..color = style.playhead,
      );
    }
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) =>
      old.playheadX != playheadX ||
      !identical(old.window.peaks, window.peaks) ||
      old.window.firstPair != window.firstPair ||
      old.style.played != style.played ||
      old.style.playhead != style.playhead;
}

/// Shared geometry, so the two passes cannot drift out of alignment.
void _paintBars(
  Canvas canvas,
  Size size,
  PeakWindow window,
  WaveformStyle style,
  Paint paint,
) {
  if (window.isEmpty || size.height <= 0) return;

  const fullScale = 32768.0;
  final center = size.height / 2;

  // Not a clamp: zoomed far enough out, a slot is narrower than the minimum bar
  // width, and clamp(min, max) with min > max throws. Bars overlapping slightly
  // is the right answer there — a gap would read as silence that is not there.
  final ink = window.pixelsPerPair * style.barFraction;
  final barWidth = ink < style.minBarWidth ? style.minBarWidth : ink;

  for (var i = 0; i < window.pairCount; i++) {
    final slotX = window.xOfFirstPair + i * window.pixelsPerPair;
    if (slotX + window.pixelsPerPair < 0) continue;
    if (slotX > size.width) break;

    // Canvas y grows downward, and min is negative, so the subtraction puts the
    // minimum below the centre line and the maximum above it.
    final top = center - (window.maxAt(i) / fullScale) * center;
    final bottom = center - (window.minAt(i) / fullScale) * center;

    var barHeight = bottom - top;
    var barTop = top;
    if (barHeight < style.minBarHeight) {
      barTop = center - style.minBarHeight / 2;
      barHeight = style.minBarHeight;
    }

    canvas.drawRect(
      Rect.fromLTWH(
        slotX + (window.pixelsPerPair - barWidth) / 2,
        barTop,
        barWidth,
        barHeight,
      ),
      paint,
    );
  }
}

/// Washes the selected range and marks its two edges.
class _SelectionPainter extends CustomPainter {
  const _SelectionPainter({
    required this.style,
    required this.startX,
    required this.endX,
  });

  final WaveformStyle style;
  final double startX;
  final double endX;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = style.selectionFill;
    final edge = style.selectionEdge;
    if (fill == null || edge == null) return;

    // Clamped rather than skipped: a selection wider than the viewport should
    // still wash everything visible.
    final left = startX.clamp(0.0, size.width);
    final right = endX.clamp(0.0, size.width);
    if (right > left) {
      canvas.drawRect(
        Rect.fromLTRB(left, 0, right, size.height),
        Paint()..color = fill,
      );
    }

    // Edges are drawn at their true position even when off-screen is clamped
    // away, so a handle never appears pinned to the edge of the viewport.
    final edgePaint = Paint()..color = edge;
    for (final x in <double>[startX, endX]) {
      if (x < -1 || x > size.width + 1) continue;
      canvas.drawRect(Rect.fromLTWH(x - 1, 0, 2, size.height), edgePaint);
    }
  }

  @override
  bool shouldRepaint(_SelectionPainter old) =>
      old.startX != startX ||
      old.endX != endX ||
      old.style.selectionFill != style.selectionFill;
}
