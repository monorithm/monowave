import 'dart:math' as math;

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
    this.normalize = true,
    this.maxGain = 8.0,
    this.barSlot = 9.0,
    this.gamma = 0.9,
    this.hullOpacity = 0.22,
  });

  final Color played;
  final Color unplayed;

  /// How much of the peak hull shows through behind the RMS core.
  ///
  /// The hull is where the audio *reached*; the core is how much of it there
  /// was. Drawing the hull at full strength lets outliers dominate again, which
  /// is the thing the core exists to fix.
  final double hullOpacity;
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

  /// Scale the drawing so the loudest moment fills the height.
  ///
  /// On by default, and it is the difference between a legible waveform and a
  /// flat line. Normal speech peaks well below full scale - a quiet room tone
  /// sits around 1% of it, which draws as a two-pixel bar and reads as broken.
  /// `CompactBars` makes the same correction for the fixed-bar case.
  final bool normalize;

  /// Ceiling on that scaling, so digital silence does not amplify into noise.
  final double maxGain;

  /// Width of one bar and its gap, in logical pixels.
  ///
  /// One bar per pixel is what makes a waveform look like static: each bar is
  /// the extremes of its bucket, so a single sample sets its height and
  /// neighbours swing wildly. Aggregating into wider slots is what every
  /// consumer voice app does, and it costs nothing - merging min/max pairs is
  /// exactly the operation the mipmap already performs, so no peak is lost.
  ///
  /// Wider than feels necessary, deliberately. Two hundred bars across six
  /// seconds is a texture, not a shape; forty is a shape. Resolution past the
  /// point where the eye can follow the envelope is what makes a waveform read
  /// as a fence.
  final double barSlot;

  /// Exponent on the amplitude axis. 1.0 is linear; lower lifts quiet content.
  ///
  /// Kept close to linear on purpose. Normalization already lifts a quiet
  /// recording to fill the box, so a strong curve on top of it lifts everything
  /// a second time and the envelope disappears - every bar lands in the top
  /// third and the result reads as a fence rather than as audio.
  ///
  /// Decibels are wrong here for the same reason, only more so. dB is right for
  /// a *meter*, where the question is "how loud is it now"; across a waveform
  /// it crushes everything above roughly -10 dB to the same height.
  final double gamma;

  double get slotFraction => barFraction;

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

  /// How much to scale so the body of the audio fills the height.
  ///
  /// A high percentile rather than the maximum. Normalizing to the peak is
  /// defeated by a single transient - the click as a microphone opens sets the
  /// maximum, and everything after it is scaled down against a sample nobody
  /// cares about, which is how a normal recording ends up drawn as a thread.
  ///
  /// Taken from a coarse level so the cost is bounded by the level's size
  /// rather than the file's, and computed once per build rather than per bar.
  double get _gain {
    if (!style.normalize) return 1;

    // The coarsest level with enough pairs for a percentile to mean something.
    var level = peaks.levels - 1;
    while (level > 0 && peaks.pairCount(level) < 32) {
      level--;
    }

    final view = peaks.view(level);
    final pairs = peaks.pairCount(level);
    if (pairs == 0) return 1;

    final magnitudes = List<int>.generate(pairs, (i) {
      final low = view[i * 2].abs();
      final high = view[i * 2 + 1].abs();
      return low > high ? low : high;
    })..sort();

    // 98th, not 90th. A lower percentile fills the box more eagerly but clips
    // everything above it, and clipping that is invisible at 160px reads as a
    // barcode once the canvas is tall.
    final reference = magnitudes[(pairs * 0.98).floor().clamp(0, pairs - 1)];
    if (reference <= 0) return 1;

    final gain = 32768 / reference;
    return gain > style.maxGain ? style.maxGain : gain;
  }

  @override
  Widget build(BuildContext context) {
    final window = viewport.resolve(peaks);
    final gain = _gain;

    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          RepaintBoundary(
            child: CustomPaint(
              painter: _BodyPainter(window: window, style: style, gain: gain),
            ),
          ),
          CustomPaint(
            painter: _PlayheadPainter(
              window: window,
              style: style,
              gain: gain,
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
/// or the viewport changes - never when the playhead moves.
class _BodyPainter extends CustomPainter {
  const _BodyPainter({
    required this.window,
    required this.style,
    required this.gain,
  });

  final PeakWindow window;
  final WaveformStyle style;
  final double gain;

  @override
  void paint(Canvas canvas, Size size) {
    _paintBars(
      canvas,
      size,
      window,
      style,
      gain,
      Paint()..color = style.unplayed,
    );
  }

  @override
  bool shouldRepaint(_BodyPainter old) =>
      !identical(old.window.peaks, window.peaks) ||
      old.window.firstPair != window.firstPair ||
      old.window.pairCount != window.pairCount ||
      old.window.xOfFirstPair != window.xOfFirstPair ||
      old.window.pixelsPerPair != window.pixelsPerPair ||
      old.gain != gain ||
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
    required this.gain,
    required this.playheadX,
  });

  final PeakWindow window;
  final WaveformStyle style;
  final double gain;
  final double playheadX;

  @override
  void paint(Canvas canvas, Size size) {
    if (playheadX > 0) {
      canvas
        ..save()
        ..clipRect(
          Rect.fromLTWH(0, 0, playheadX.clamp(0, size.width), size.height),
        );
      _paintBars(
        canvas,
        size,
        window,
        style,
        gain,
        Paint()..color = style.played,
      );
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
///
/// Two standardisations happen here, both purely visual - the peaks themselves
/// are untouched, which is the whole point of the package handing over exact
/// data and letting the host decide how to draw it.
void _paintBars(
  Canvas canvas,
  Size size,
  PeakWindow window,
  WaveformStyle style,
  double gain,
  Paint paint,
) {
  if (window.isEmpty || size.height <= 0 || size.width <= 0) return;

  const fullScale = 32768.0;

  // Headroom, so the loudest peaks stop short of the frame. A waveform that
  // touches its edge reads as clipped whether it is or not.
  final centre = size.height / 2;
  final reach = centre * 0.88;

  /// Amplitude 0..1 onto height 0..1.
  double curve(double amplitude) {
    if (amplitude <= 0) return 0;
    return math.pow(amplitude.clamp(0.0, 1.0), style.gamma).toDouble();
  }

  // One bar per slot, not one per pair. Pairs falling inside a slot are merged
  // by min-of-mins and max-of-maxes - lossless, and the same reduction the
  // pyramid uses.
  // The hull is only drawn separately when there is a core to put inside it.
  final hull = window.rms == null
      ? null
      : (Paint()..color = paint.color.withValues(alpha: style.hullOpacity));

  final slots = math.max(1, (size.width / style.barSlot).floor());
  final ink = math.max(1.0, style.barSlot * style.barFraction);
  final radius = Radius.circular(ink / 2);

  for (var slot = 0; slot < slots; slot++) {
    final left = slot * style.barSlot;

    // Which pairs land in this slot, in window coordinates.
    final from = ((left - window.xOfFirstPair) / window.pixelsPerPair).floor();
    final to =
        ((left + style.barSlot - window.xOfFirstPair) / window.pixelsPerPair)
            .ceil();
    if (to <= 0 || from >= window.pairCount) continue;

    var low = 0;
    var high = 0;
    var loudness = 0.0;
    var counted = 0;
    var seen = false;
    for (var i = math.max(0, from); i < math.min(to, window.pairCount); i++) {
      final pairLow = window.minAt(i);
      final pairHigh = window.maxAt(i);
      if (!seen) {
        low = pairLow;
        high = pairHigh;
        seen = true;
      } else {
        if (pairLow < low) low = pairLow;
        if (pairHigh > high) high = pairHigh;
      }

      // Merging RMS is the root of the mean of the squares, not the mean.
      final pairRms = window.rmsAt(i);
      if (pairRms != null) {
        loudness += pairRms * pairRms.toDouble();
        counted++;
      }
    }
    if (!seen) continue;
    loudness = counted == 0 ? 0 : math.sqrt(loudness / counted);

    final x = left + (style.barSlot - ink) / 2;

    // The hull: how far the audio reached.
    final up = curve((high.abs() * gain) / fullScale) * reach;
    final down = curve((low.abs() * gain) / fullScale) * reach;

    var top = centre - up;
    var height = up + down;
    if (height < style.minBarHeight) {
      top = centre - style.minBarHeight / 2;
      height = style.minBarHeight;
    }

    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x, top, ink, height), radius),
      hull ?? paint,
    );

    // The core: how much of it there was. Symmetric about the centre, because
    // RMS has no sign.
    if (hull != null && loudness > 0) {
      final half = curve((loudness * gain) / fullScale) * reach;
      final coreHeight = math.max(half * 2, style.minBarHeight);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, centre - coreHeight / 2, ink, coreHeight),
          radius,
        ),
        paint,
      );
    }
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
