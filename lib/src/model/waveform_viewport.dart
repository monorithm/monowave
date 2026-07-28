import 'dart:typed_data';

import 'waveform_peaks.dart';

/// The slice of a pyramid a painter should draw, already resolved to a level.
///
/// Everything here is in painter coordinates, so a `CustomPainter` is a loop
/// over [pairCount] with no arithmetic of its own:
///
/// ```dart
/// for (var i = 0; i < window.pairCount; i++) {
///   final x = window.xOfFirstPair + i * window.pixelsPerPair;
///   // window.minAt(i) .. window.maxAt(i)
/// }
/// ```
class PeakWindow {
  const PeakWindow({
    required this.peaks,
    required this.level,
    required this.firstPair,
    required this.pairCount,
    required this.xOfFirstPair,
    required this.pixelsPerPair,
  });

  /// The level's interleaved `[min, max, ...]` data. Read-only.
  final Int16List peaks;

  /// Which mipmap level this came from. Useful for debug overlays.
  final int level;

  /// Index of the first pair to draw, within [peaks].
  final int firstPair;

  /// How many pairs to draw.
  final int pairCount;

  /// Where the first pair starts, in viewport pixels.
  ///
  /// Usually slightly negative: the window is snapped outward to whole pairs so
  /// panning stays smooth instead of stepping.
  final double xOfFirstPair;

  /// Width of one pair on screen, in pixels.
  final double pixelsPerPair;

  /// Whether there is anything to draw.
  bool get isEmpty => pairCount <= 0;

  /// Minimum sample value of pair [i], where `i` is 0-based within the window.
  int minAt(int i) => peaks[(firstPair + i) * 2];

  /// Maximum sample value of pair [i], where `i` is 0-based within the window.
  int maxAt(int i) => peaks[(firstPair + i) * 2 + 1];
}

/// Which part of a waveform is on screen, and at what zoom.
///
/// Pure math and immutable: every gesture produces a new viewport rather than
/// mutating one, so a host can drive it from any state management it likes.
/// [startSample] is a `double` so panning is subpixel-smooth rather than
/// stepping a sample at a time.
class WaveformViewport {
  const WaveformViewport({
    required this.startSample,
    required this.samplesPerPixel,
    required this.widthPx,
  });

  /// Sample at the left edge. May be fractional, and may sit outside the audio.
  final double startSample;

  /// Zoom, as source samples per logical pixel. Smaller is more zoomed in.
  final double samplesPerPixel;

  /// Width of the drawing surface, in logical pixels.
  final double widthPx;

  /// A viewport showing the whole of [peaks] across [widthPx].
  factory WaveformViewport.fitted(WaveformPeaks peaks, double widthPx) {
    final span = peaks.lengthInSamples <= 0 ? 1 : peaks.lengthInSamples;
    return WaveformViewport(
      startSample: 0,
      samplesPerPixel: span / (widthPx <= 0 ? 1 : widthPx),
      widthPx: widthPx,
    );
  }

  /// Samples visible across the full width.
  double get sampleSpan => samplesPerPixel * widthPx;

  /// Sample at the right edge.
  double get endSample => startSample + sampleSpan;

  /// Where [sample] falls horizontally, in logical pixels.
  double xForSample(num sample) => (sample - startSample) / samplesPerPixel;

  /// Which sample sits under [x]. The inverse of [xForSample].
  double sampleAtX(double x) => startSample + x * samplesPerPixel;

  /// Picks a mipmap level and returns the slice to draw.
  ///
  /// The window is snapped outward to whole pairs, so the first pair usually
  /// begins slightly left of x=0. That is deliberate: clipping to the pair
  /// boundary instead would make a pan visibly step.
  PeakWindow resolve(WaveformPeaks peaks) {
    final level = peaks.levelFor(samplesPerPixel);
    final levelSpp = peaks.samplesPerPixel(level);
    final available = peaks.pairCount(level);

    final first = (startSample / levelSpp).floor().clamp(0, available);
    final last = (endSample / levelSpp).ceil().clamp(0, available);

    return PeakWindow(
      peaks: peaks.view(level),
      level: level,
      firstPair: first,
      pairCount: last - first,
      xOfFirstPair: xForSample(first * levelSpp),
      pixelsPerPair: levelSpp / samplesPerPixel,
    );
  }

  /// Zooms by [factor] about [focusX], keeping the sample under that point put.
  ///
  /// [factor] above 1 zooms in. Anchoring on the focus point is what makes a
  /// pinch feel attached to the audio rather than to the widget.
  WaveformViewport zoomedAt(double focusX, double factor) {
    if (factor <= 0) {
      throw ArgumentError.value(factor, 'factor', 'must be positive');
    }

    final anchor = sampleAtX(focusX);
    final zoomed = samplesPerPixel / factor;
    return WaveformViewport(
      startSample: anchor - focusX * zoomed,
      samplesPerPixel: zoomed,
      widthPx: widthPx,
    );
  }

  /// Scrolls by [dx] logical pixels. Positive [dx] moves content left.
  WaveformViewport pannedBy(double dx) => WaveformViewport(
    startSample: startSample + dx * samplesPerPixel,
    samplesPerPixel: samplesPerPixel,
    widthPx: widthPx,
  );

  /// Returns a copy with [widthPx] replaced, keeping the left edge and zoom.
  WaveformViewport resized(double width) => WaveformViewport(
    startSample: startSample,
    samplesPerPixel: samplesPerPixel,
    widthPx: width,
  );

  /// Constrains zoom and scroll so the audio cannot be lost off-screen.
  ///
  /// Zooming out past the whole file is clamped to fit; zooming in past
  /// [WaveformPeaks.finestSamplesPerPixel] is clamped too, because there is no
  /// finer data in memory to draw and the result would just be stretched.
  WaveformViewport clampedTo(WaveformPeaks peaks) {
    final total = peaks.lengthInSamples.toDouble();
    final width = widthPx <= 0 ? 1.0 : widthPx;

    final fitted = total / width;
    final finest = peaks.finestSamplesPerPixel.toDouble();
    // A file shorter than one screen at the finest level cannot satisfy both
    // bounds; fitting the whole file wins, so nothing is ever cut off.
    final floor = finest < fitted ? finest : fitted;
    final spp = samplesPerPixel.clamp(floor, fitted).toDouble();

    final maxStart = total - spp * width;
    final start = maxStart <= 0 ? 0.0 : startSample.clamp(0.0, maxStart);

    return WaveformViewport(
      startSample: start,
      samplesPerPixel: spp,
      widthPx: widthPx,
    );
  }

  @override
  String toString() =>
      'WaveformViewport(start: ${startSample.toStringAsFixed(1)}, '
      'spp: ${samplesPerPixel.toStringAsFixed(2)}, width: $widthPx)';
}
