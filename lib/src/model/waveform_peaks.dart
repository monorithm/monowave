import 'dart:typed_data';

/// A mipmap pyramid of min/max peaks.
///
/// Level 0 is the finest resolution that monowave holds. Each level above it
/// covers two times as many samples for each pair. A zoom picks a level and
/// does not read the file again. This is what keeps a pan over a three-hour
/// recording free.
///
/// monowave stores peaks interleaved as `[min0, max0, min1, max1, ...]`. M1
/// backs that data with a Dart [Int16List]. M2 backs the same API with a view
/// over memory that the C core owns. As a result, nothing here changes when the
/// decoder lands.
///
/// **Reduction is always min/max, never an average.** An average collapses
/// transients and shows speech as a flat sausage. [rms] is available as a
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

  /// Wraps levels that the C core built elsewhere, over memory that it still
  /// owns.
  ///
  /// [onDispose] releases that memory. It also keeps the owner of the
  /// allocation reachable for as long as this object is reachable. As a result,
  /// a finalizer cannot release peaks that a painter still reads.
  ///
  /// Nothing in this file imports `dart:ffi`. The dependency on native code
  /// stays entirely in the closure, so the model still compiles for web.
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

  /// The number of channels that the source had. The peaks themselves are
  /// always mono-mixed for now.
  final int channels;

  /// Length of the source audio in samples, per channel.
  final int lengthInSamples;

  final int _baseSamplesPerPixel;
  final List<Int16List> _levels;
  final List<Int16List>? _rms;
  final void Function()? _onDispose;
  bool _disposed = false;

  /// True after a call to [dispose]. A read of peaks after that call throws.
  bool get isDisposed => _disposed;

  /// Number of mipmap levels. Level 0 is finest.
  int get levels => _levels.length;

  /// The finest resolution that the pyramid holds, in samples per min/max pair.
  ///
  /// A zoom past this resolution is the one operation that memory cannot serve.
  int get finestSamplesPerPixel => _baseSamplesPerPixel;

  /// Samples covered by one min/max pair at [level].
  int samplesPerPixel(int level) => _baseSamplesPerPixel << level;

  /// Number of min/max pairs at [level].
  int pairCount(int level) => _levels[level].length ~/ 2;

  /// The interleaved `[min, max, ...]` data at [level].
  ///
  /// This data is zero-copy, and monowave does not copy it defensively. Treat
  /// it as read-only. A write to it corrupts every level built above it. If
  /// these peaks came from the C core, this data is a view straight into native
  /// memory. This is why a three-hour recording never reaches the Dart heap.
  Int16List view(int level) {
    if (_disposed) {
      throw StateError('These peaks were disposed; the memory is gone.');
    }
    return _levels[level];
  }

  /// One RMS value per pair at [level]. Null if monowave computed none.
  ///
  /// Peaks tell you how far the audio went. RMS tells you how much of it there
  /// was. A waveform that shows both (a peak hull with an RMS core inside it)
  /// reads as a shape and not as its outliers.
  ///
  /// This value is null for a pyramid that Dart built from raw samples, because
  /// such a pyramid has no reason to compute it. The C core always supplies it.
  Int16List? rms(int level) {
    if (_disposed) {
      throw StateError('These peaks were disposed; the memory is gone.');
    }
    final series = _rms;
    return series == null || level >= series.length ? null : series[level];
  }

  /// Releases the memory behind these peaks.
  ///
  /// This method does nothing for peaks that Dart built. It is necessary for
  /// peaks that the C core allocated. It is idempotent. Any view that this
  /// object gave out before the call dangles after it, so remove those views
  /// first.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _onDispose?.call();
  }

  /// The coarsest level with a resolution that is still at least as fine as
  /// [targetSamplesPerPixel].
  ///
  /// If you draw from a level finer than the target, you waste work. If you
  /// draw from a coarser level, you visibly lose detail. This method picks the
  /// cheapest level that loses no detail.
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
  /// [baseSamplesPerPixel] is the finest resolution that the pyramid keeps. A
  /// value of 128 at 44.1 kHz is approximately 345 pairs each second. This is
  /// more than a 4K display can show for a one-minute voice note.
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

  /// Builds a pyramid from peaks that the C core computed, or that BBC
  /// `audiowaveform` computed on the server.
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
