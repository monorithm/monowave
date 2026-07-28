import 'dart:typed_data';

/// One hop of audio, already reduced by the audio thread.
typedef CaptureFrame = ({int min, int max, int rms});

/// A fixed-capacity rolling window of the most recent frames.
///
/// What a live visualizer draws. It is a ring over a preallocated [Int16List]
/// and it allocates nothing per frame - at 86 frames a second, a growable list
/// would be 86 allocations a second forever, and the garbage would land in the
/// same frame budget as the painting.
///
/// Index 0 is the oldest frame still retained; [length] is the newest.
class CaptureScope {
  CaptureScope({this.capacity = 256})
    : assert(capacity > 0),
      _data = Int16List(capacity * _stride);

  static const _stride = 3;

  /// How many frames are retained before the oldest is overwritten.
  final int capacity;

  final Int16List _data;
  int _length = 0;
  int _start = 0;
  int _revision = 0;

  /// Increments on every frame added.
  ///
  /// A painter must compare this rather than [length]: the scope is a ring that
  /// mutates in place, so once it is full the length never changes again and a
  /// `shouldRepaint` keyed on length silently stops repainting.
  int get revision => _revision;

  /// Frames currently retained, at most [capacity].
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
  /// The usual input to a bar visualizer: it does not care which direction the
  /// waveform went, only how far.
  double amplitudeAt(int index) {
    final low = minAt(index).abs();
    final high = maxAt(index).abs();
    return (low > high ? low : high) / fullScale;
  }

  /// Every retained amplitude, oldest first.
  ///
  /// Allocates, so call it once per painted frame rather than per bar.
  Float32List amplitudes() {
    final out = Float32List(_length);
    for (var i = 0; i < _length; i++) {
      out[i] = amplitudeAt(i);
    }
    return out;
  }
}
