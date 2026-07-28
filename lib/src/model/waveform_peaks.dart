import 'dart:typed_data';

/// A mipmap pyramid of min/max peaks.
///
/// Level 0 is the finest resolution monowave holds; each level above it covers
/// twice as many samples per pair. Zooming picks a level rather than re-reading
/// the file, which is what keeps a pan over a three-hour recording free.
///
/// Peaks are stored interleaved as `[min0, max0, min1, max1, ...]`. M1 backs
/// that with a Dart [Int16List]; M2 backs the same API with a view over memory
/// the C core owns, so nothing here changes when the decoder lands.
///
/// **Reduction is always min/max, never an average.** Averaging collapses
/// transients and renders speech as a flat sausage. [rms] is available as a
/// second series to overlay, not as a replacement.
class WaveformPeaks {
  // The two private fields are positional: Dart does not allow a named
  // parameter to be a private initializing formal.
  WaveformPeaks._(
    this._baseSamplesPerPixel,
    this._levels, {
    required this.sampleRate,
    required this.channels,
    required this.lengthInSamples,
    List<Int16List>? rms,
    void Function()? onDispose,
  }) : _rms = rms, // ignore: prefer_initializing_formals
       _onDispose = onDispose; // ignore: prefer_initializing_formals

  /// Wraps levels that were built elsewhere — by the C core, over memory it
  /// still owns.
  ///
  /// [onDispose] releases that memory. It also keeps whatever owns the
  /// allocation reachable for as long as this object is, which is what stops a
  /// finalizer from freeing peaks a painter is still reading.
  ///
  /// Nothing in this file imports `dart:ffi`: the native-ness lives entirely in
  /// the closure, so the model still compiles for web.
  factory WaveformPeaks.fromLevels(
    List<Int16List> levels, {
    required int sampleRate,
    required int channels,
    required int lengthInSamples,
    required int baseSamplesPerPixel,
    List<Int16List>? rms,
    void Function()? onDispose,
  }) {
    if (levels.isEmpty) {
      throw ArgumentError.value(levels, 'levels', 'must not be empty');
    }
    return WaveformPeaks._(
      baseSamplesPerPixel,
      levels,
      sampleRate: sampleRate,
      channels: channels,
      lengthInSamples: lengthInSamples,
      rms: rms,
      onDispose: onDispose,
    );
  }

  /// Sample rate of the source audio, in hertz.
  final int sampleRate;

  /// Channels the source had. Peaks themselves are always mono-mixed for now.
  final int channels;

  /// Length of the source audio in samples, per channel.
  final int lengthInSamples;

  final int _baseSamplesPerPixel;
  final List<Int16List> _levels;
  final List<Int16List>? _rms;
  final void Function()? _onDispose;
  bool _disposed = false;

  /// Whether [dispose] has been called. Reading peaks afterwards throws.
  bool get isDisposed => _disposed;

  /// Number of mipmap levels. Level 0 is finest.
  int get levels => _levels.length;

  /// The finest resolution held, in samples per min/max pair.
  ///
  /// Zooming past this is the one operation that cannot be served from memory.
  int get finestSamplesPerPixel => _baseSamplesPerPixel;

  /// Samples covered by one min/max pair at [level].
  int samplesPerPixel(int level) => _baseSamplesPerPixel << level;

  /// Number of min/max pairs at [level].
  int pairCount(int level) => _levels[level].length ~/ 2;

  /// The interleaved `[min, max, ...]` data at [level].
  ///
  /// Zero-copy and not defensively copied — treat it as read-only. Writing to
  /// it corrupts every level built above it. When these peaks came from the C
  /// core, this is a view straight into native memory, which is why a
  /// three-hour recording never reaches the Dart heap.
  Int16List view(int level) {
    if (_disposed) {
      throw StateError('These peaks were disposed; the memory is gone.');
    }
    return _levels[level];
  }

  /// One RMS value per pair at [level], or null if none was computed.
  ///
  /// Peaks say how far the audio went; RMS says how much of it there was.
  /// Drawing both — a peak hull with an RMS core inside it — is what makes a
  /// waveform read as a shape rather than as its outliers.
  ///
  /// Null for pyramids built in Dart from raw samples, which have no reason to
  /// compute it; the C core always provides it.
  Int16List? rms(int level) {
    if (_disposed) {
      throw StateError('These peaks were disposed; the memory is gone.');
    }
    final series = _rms;
    return series == null || level >= series.length ? null : series[level];
  }

  /// Releases the memory behind these peaks.
  ///
  /// A no-op for peaks built in Dart, and required for peaks the C core
  /// allocated. Idempotent. Any view handed out beforehand dangles afterwards,
  /// so drop those first.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _onDispose?.call();
  }

  /// The coarsest level whose resolution is still at least as fine as
  /// [targetSamplesPerPixel].
  ///
  /// Drawing from a level finer than the target wastes work; drawing from a
  /// coarser one visibly loses detail. This picks the cheapest level that does
  /// not lose any.
  int levelFor(double targetSamplesPerPixel) {
    var level = 0;
    while (level + 1 < levels &&
        samplesPerPixel(level + 1) <= targetSamplesPerPixel) {
      level++;
    }
    return level;
  }

  /// Builds a pyramid from mono 16-bit [samples].
  ///
  /// [baseSamplesPerPixel] is the finest resolution retained. 128 at 44.1 kHz
  /// is roughly 345 pairs per second, which is more than a 4K display can show
  /// for a one-minute voice note.
  factory WaveformPeaks.fromSamples(
    Int16List samples, {
    required int sampleRate,
    int channels = 1,
    int baseSamplesPerPixel = 128,
    int? maxLevels,
  }) {
    if (baseSamplesPerPixel < 1) {
      throw ArgumentError.value(
        baseSamplesPerPixel,
        'baseSamplesPerPixel',
        'must be at least 1',
      );
    }

    final base = _reduce(samples, baseSamplesPerPixel);
    final levels = <Int16List>[base];

    // Each level above is built from the one below by taking the min of the
    // mins and the max of the maxes. Because that is exact rather than
    // resampled, a coarse level always bounds the fine level under it.
    while (levels.last.length > 2 &&
        (maxLevels == null || levels.length < maxLevels)) {
      levels.add(_halve(levels.last));
    }

    return WaveformPeaks._(
      baseSamplesPerPixel,
      levels,
      sampleRate: sampleRate,
      channels: channels,
      lengthInSamples: samples.length,
    );
  }

  /// Builds a pyramid from peaks that were computed elsewhere — by the C core,
  /// or server-side by BBC `audiowaveform`.
  ///
  /// [base] is interleaved `[min, max, ...]` at [baseSamplesPerPixel].
  factory WaveformPeaks.fromInterleaved(
    Int16List base, {
    required int sampleRate,
    required int baseSamplesPerPixel,
    int channels = 1,
    int? lengthInSamples,
    int? maxLevels,
  }) {
    if (base.length.isOdd) {
      throw ArgumentError.value(
        base.length,
        'base',
        'interleaved peaks must have an even length (min/max pairs)',
      );
    }

    final levels = <Int16List>[base];
    while (levels.last.length > 2 &&
        (maxLevels == null || levels.length < maxLevels)) {
      levels.add(_halve(levels.last));
    }

    return WaveformPeaks._(
      baseSamplesPerPixel,
      levels,
      sampleRate: sampleRate,
      channels: channels,
      lengthInSamples:
          lengthInSamples ?? (base.length ~/ 2) * baseSamplesPerPixel,
    );
  }

  /// Reduces [samples] into interleaved min/max pairs of [samplesPerPixel].
  static Int16List _reduce(Int16List samples, int samplesPerPixel) {
    final pairs = (samples.length + samplesPerPixel - 1) ~/ samplesPerPixel;
    final out = Int16List(pairs * 2);

    for (var pair = 0; pair < pairs; pair++) {
      final start = pair * samplesPerPixel;
      final end = (start + samplesPerPixel).clamp(0, samples.length);

      var lo = samples[start];
      var hi = samples[start];
      for (var i = start + 1; i < end; i++) {
        final s = samples[i];
        if (s < lo) lo = s;
        if (s > hi) hi = s;
      }

      out[pair * 2] = lo;
      out[pair * 2 + 1] = hi;
    }

    return out;
  }

  /// Builds the next coarser level: min of mins, max of maxes.
  static Int16List _halve(Int16List fine) {
    final finePairs = fine.length ~/ 2;
    final coarsePairs = (finePairs + 1) ~/ 2;
    final out = Int16List(coarsePairs * 2);

    for (var pair = 0; pair < coarsePairs; pair++) {
      final a = pair * 2;
      final b = a + 1;

      var lo = fine[a * 2];
      var hi = fine[a * 2 + 1];
      if (b < finePairs) {
        if (fine[b * 2] < lo) lo = fine[b * 2];
        if (fine[b * 2 + 1] > hi) hi = fine[b * 2 + 1];
      }

      out[pair * 2] = lo;
      out[pair * 2 + 1] = hi;
    }

    return out;
  }
}
