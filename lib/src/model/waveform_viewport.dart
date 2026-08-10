import 'dart:typed_data';

import 'waveform_peaks.dart';

/// The slice of a pyramid for a painter to draw, already resolved to a level.
///
/// Everything here is in painter coordinates. As a result, a `CustomPainter` is
/// a loop over [pairCount] with no arithmetic of its own:
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
    this.rms,
  });

  /// The interleaved `[min, max, ...]` data of the level. Read-only.
  final Int16List peaks;

  /// The mipmap level that this data came from. Useful for debug overlays.
  final int level;

  /// Index of the first pair to draw, within [peaks].
  final int firstPair;

  /// How many pairs to draw.
  final int pairCount;

  /// Where the first pair starts, in viewport pixels.
  ///
  /// Usually slightly negative. The viewport snaps the window outward to whole
  /// pairs, so a pan stays smooth and does not step.
  final double xOfFirstPair;

  /// Width of one pair on screen, in pixels.
  final double pixelsPerPair;

  /// One RMS value per pair, aligned with [peaks]. Null if the pyramid has
  /// none.
  final Int16List? rms;

  /// Whether there is anything to draw.
  bool get isEmpty => pairCount <= 0;

  /// Minimum sample value of pair [i], where `i` is 0-based within the window.
  int minAt(int i) => peaks[(firstPair + i) * 2];

  /// Maximum sample value of pair [i], where `i` is 0-based within the window.
  int maxAt(int i) => peaks[(firstPair + i) * 2 + 1];

  /// RMS of pair [i], or null if this pyramid carries none.
  int? rmsAt(int i) => rms?[firstPair + i];
}

/// Which part of a waveform is on screen, and at what zoom.
///
/// This class is pure math and immutable. Every gesture produces a new viewport
/// and changes none. As a result, a host can drive it from any state management
/// that the host likes. [startSample] is a `double`, so a pan is
/// subpixel-smooth and does not step one sample at a time.
class WaveformViewport {
  const WaveformViewport({
    required this.startSample,
    required this.samplesPerPixel,
    required this.widthPx,
  });

  /// Sample at the left edge. It can be fractional, and it can sit outside the
  /// audio.
  final double startSample;

  /// Zoom, as source samples per logical pixel. A smaller value is a closer
  /// zoom.
  final double samplesPerPixel;

  /// Width of the drawing surface, in logical pixels.
  final double widthPx;

  /// A viewport that shows the whole of [peaks] across [widthPx].
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

  /// The horizontal position of [sample], in logical pixels.
  double xForSample(num sample) => (sample - startSample) / samplesPerPixel;

  /// The sample under [x]. The inverse of [xForSample].
  double sampleAtX(double x) => startSample + x * samplesPerPixel;

  /// Picks a mipmap level and returns the slice to draw.
  ///
  /// This method snaps the window outward to whole pairs, so the first pair
  /// usually starts slightly left of x=0. That is deliberate. A clip to the
  /// pair boundary instead makes a pan visibly step.
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
      rms: peaks.rms(level),
    );
  }

  /// Zooms by [factor] about [focusX]. The sample under that point does not
  /// move.
  ///
  /// A [factor] more than 1 zooms in. The anchor on the focus point is what
  /// makes a pinch feel attached to the audio and not to the widget.
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

  /// Returns a copy with a new [widthPx]. The copy keeps the left edge and the
  /// zoom.
  WaveformViewport resized(double width) => WaveformViewport(
    startSample: startSample,
    samplesPerPixel: samplesPerPixel,
    widthPx: width,
  );

  /// Constrains the zoom and the scroll, so the viewport always shows audio.
  ///
  /// This method clamps a zoom out past the whole file to a fit. It also clamps
  /// a zoom in past [WaveformPeaks.finestSamplesPerPixel], because memory holds
  /// no finer data to draw and the result is only a stretched picture.
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
