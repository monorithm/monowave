import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:monokit/monokit.dart';

/// A [MonoPlaybackController] that advances a clock instead of playing audio.
///
/// M1 has no decoder and no audio output, and the point of the gallery is the
/// waveform rather than the sound. This also makes the seam visible: monowave
/// never learns what is playing, it only maps time to samples, so a real
/// `just_audio` adapter would replace this file and nothing else.
class DemoPlayer implements MonoPlaybackController {
  DemoPlayer(this._duration);

  static const _tick = Duration(milliseconds: 16);

  final Duration _duration;
  final ValueNotifier<bool> _isPlaying = ValueNotifier<bool>(false);
  final ValueNotifier<Duration> _position = ValueNotifier<Duration>(
    Duration.zero,
  );
  Timer? _timer;

  @override
  ValueListenable<bool> get isPlaying => _isPlaying;

  @override
  ValueListenable<Duration> get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  Future<void> play() async {
    if (_isPlaying.value) return;
    if (_position.value >= _duration) _position.value = Duration.zero;

    _isPlaying.value = true;
    _timer = Timer.periodic(_tick, (_) {
      final next = _position.value + _tick;
      if (next >= _duration) {
        _position.value = _duration;
        pause();
      } else {
        _position.value = next;
      }
    });
  }

  @override
  Future<void> pause() async {
    _timer?.cancel();
    _timer = null;
    _isPlaying.value = false;
  }

  @override
  Future<void> seek(Duration position) async {
    _position.value = position.isNegative
        ? Duration.zero
        : (position > _duration ? _duration : position);
  }

  void dispose() {
    _timer?.cancel();
    _isPlaying.dispose();
    _position.dispose();
  }
}
