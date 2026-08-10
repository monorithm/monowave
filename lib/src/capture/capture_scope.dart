import 'dart:typed_data';

/// One hop of audio, which the audio thread already reduced.
typedef CaptureFrame = ({int min, int max, int rms});

/// A rolling window of the most recent frames, with a fixed capacity.
///
/// A live visualizer draws this window. The window is a ring over a
/// preallocated [Int16List], and it allocates nothing for each frame. At 86
/// frames each second, a growable list makes 86 allocations each second, and
/// it never stops.
/// That garbage lands in the same frame budget as the paint operation.
///
/// Index 0 is the oldest frame that the window keeps. [length] is the newest.
class CaptureScope {
  CaptureScope({this.capacity = 256})
    : assert(capacity > 0),
      _data = Int16List(capacity * _stride);

  static const _stride = 3;

  /// How many frames the window keeps before it overwrites the oldest frame.
  final int capacity;

  final Int16List _data;
  int _length = 0;
  int _start = 0;
  int _revision = 0;

  /// Increases by one for each frame that the scope adds.
  ///
  /// A painter must compare this value and not [length]. The scope is a ring
  /// that changes in place. After the scope is full, the length never changes
  /// again. A `shouldRepaint` that uses the length then stops the repaints,
  /// with no error.
  int get revision => _revision;

  /// Frames that the scope keeps now, at most [capacity].
  int get length => _length;

  bool get isEmpty => _length == 0;

  /// Full-scale reference, so a painter can map a value to a height.
  static const fullScale = 32768.0;

  void add(CaptureFrame frame) {
    final slot = ((_start + _length) % capacity) * _stride;
    _data[slot] = frame.min;
    _data[slot + 1] = frame.max;
    _data[slot + 2] = frame.rms;

    if (_length < capacity) {
      _length++;
    } else {
      _start = (_start + 1) % capacity;
    }
    _revision++;
  }

  void clear() {
    _length = 0;
    _start = 0;
    _revision++;
  }

  int _at(int index, int offset) {
    if (index < 0 || index >= _length) {
      throw RangeError.index(index, this, 'index', null, _length);
    }
    return _data[((_start + index) % capacity) * _stride + offset];
  }

  int minAt(int index) => _at(index, 0);
  int maxAt(int index) => _at(index, 1);
  int rmsAt(int index) => _at(index, 2);

  /// The larger excursion of frame [index], from 0 to 1.
  ///
  /// This value is the usual input to a bar visualizer. Such a visualizer does
  /// not need the direction of the waveform, only the distance.
  double amplitudeAt(int index) {
    final low = minAt(index).abs();
    final high = maxAt(index).abs();
    return (low > high ? low : high) / fullScale;
  }

  /// Every amplitude that the scope keeps, oldest first.
  ///
  /// This method allocates. Therefore, a caller must call it one time for each
  /// painted frame, and not one time for each bar.
  Float32List amplitudes() {
    final out = Float32List(_length);
    for (var i = 0; i < _length; i++) {
      out[i] = amplitudeAt(i);
    }
    return out;
  }
}
