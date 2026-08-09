// The M7 exit criterion: what comes out of the ring is what M6 renders, and
// the ring never loses a frame on the way.
//
// There is no audio device here. `wf_playback_pull` is the audio-thread entry
// point, and it is public for exactly the reason `wf_capture_feed` is: it lets
// a test drive the real ring, the real feeder thread and the real render on
// every platform, with no sound card and no permission prompt.
//
// Note what this deliberately does not use: miniaudio's null backend. That
// backend paces itself against a simulated clock, so a 30-second document would
// cost 30 seconds of CI for no coverage the synthetic pull does not already
// give. The device path gets a smoke test at the bottom instead.

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:monowave/monowave.dart';
import 'package:monowave/src/native/monowave_bindings.dart' as bindings;
import 'package:test/test.dart';

import 'fixtures.dart' as fixtures;

const _sampleRate = 44100;
const _seconds = 30;
const _frames = _sampleRate * _seconds;

/// Frames the consumer asks for per pull. A plausible device buffer.
const _block = 512;

/// The cushion between the feeder and the consumer, in frames. About a second.
const _ring = 65536;

/// Drives a playback to the end the way a device would, and returns everything
/// it emitted.
///
/// The consumer waits for a whole block before taking one, which is what a
/// well-provisioned device does. That is also what makes the underrun
/// assertion meaningful rather than tautological: the loop never outruns the
/// feeder, so any underrun would be the ring losing frames on its own.
({Int16List pcm, int underruns, int consumed}) _drain(
  Pointer<bindings.WfPlayback> playback,
) {
  final channels = bindings.wfPlaybackChannels(playback);
  final total = bindings.wfPlaybackLengthFrames(playback).toInt();
  final out = Int16List(total * channels);
  final block = calloc<Int16>(_block * channels);

  var frames = 0;
  try {
    // Bounded so a stalled feeder fails the test rather than hanging CI.
    for (var guard = 0; guard < 1000000; guard++) {
      if (bindings.wfPlaybackFinished(playback) != 0) break;

      final ready = bindings.wfPlaybackAvailable(playback);
      final drained = bindings.wfPlaybackDrained(playback) != 0;
      if (ready < _block && !drained) {
        sleep(const Duration(milliseconds: 1));
        continue;
      }

      final got = bindings.wfPlaybackPull(playback, block, _block);
      if (got == 0) continue;

      final samples = got * channels;
      out.setRange(
        frames * channels,
        frames * channels + samples,
        block.asTypedList(samples),
      );
      frames += got;
    }
  } finally {
    calloc.free(block);
  }

  return (
    pcm: frames * channels == out.length
        ? out
        : Int16List.sublistView(out, 0, frames * channels),
    underruns: bindings.wfPlaybackUnderruns(playback).toInt(),
    consumed: bindings.wfPlaybackConsumed(playback).toInt(),
  );
}

Pointer<bindings.WfPlayback> _open(
  String sourcePath,
  WaveformDocument document, {
  int ringFrames = _ring,
}) {
  final path = sourcePath.toNativeUtf8();
  final regions = calloc<bindings.WfRegion>(document.regions.length);
  final error = calloc<Int32>();

  try {
    for (var i = 0; i < document.regions.length; i++) {
      final region = document.regions[i];
      regions[i]
        ..sourceStart = region.sourceStart.toDouble()
        ..sourceEnd = region.sourceEnd.toDouble()
        ..gain = region.gain
        ..fadeIn = region.fadeIn
        ..fadeOut = region.fadeOut;
    }

    final playback = bindings.wfPlaybackCreate(
      path.cast(),
      regions,
      document.regions.length,
      ringFrames,
      error,
    );
    if (playback == nullptr) {
      fail('wf_playback_create failed with code ${error.value}');
    }
    return playback;
  } finally {
    calloc
      ..free(path)
      ..free(regions)
      ..free(error);
  }
}

void main() {
  final platform = MonowavePlatform.instance;
  late Directory workspace;
  late String sourcePath;

  setUpAll(() async {
    await platform.ensureInitialized();

    workspace = Directory.systemTemp.createTempSync('monowave-playback');
    sourcePath = '${workspace.path}/source.wav';
    File(sourcePath).writeAsBytesSync(
      fixtures.wav(
        Int16List.fromList([
          for (var i = 0; i < _frames; i++)
            (math.sin(2 * math.pi * 440 * i / _sampleRate) * 20000).round(),
        ]),
      ),
    );
  });

  tearDownAll(() => workspace.deleteSync(recursive: true));

  test('thirty seconds through the ring is what M6 renders offline', () async {
    // The exit criterion. A document long enough that the feeder wraps the ring
    // many times, with an edit on it so the envelope is in the path too.
    const document = WaveformDocument([
      WaveformRegion(
        sourceStart: 0,
        sourceEnd: _frames ~/ 2,
        fadeIn: 2000,
        fadeOut: 3000,
      ),
      WaveformRegion(sourceStart: _frames ~/ 2, sourceEnd: _frames, gain: 0.4),
    ]);

    final expected = await platform.renderPcm(
      sourcePath: sourcePath,
      document: document,
    );

    final playback = _open(sourcePath, document);
    try {
      final played = _drain(playback);

      expect(
        played.pcm.length,
        expected.length,
        reason: 'the ring lost or invented frames',
      );
      expect(
        played.pcm,
        orderedEquals(expected),
        reason: 'what the device would hear is not what an export would write',
      );
      expect(played.consumed, _frames);
      expect(
        played.underruns,
        0,
        reason: 'a consumer that waits for a full block must never underrun',
      );
      expect(bindings.wfPlaybackFailed(playback), 0);
    } finally {
      bindings.wfPlaybackDestroy(playback);
    }
  });

  test('the ring wraps correctly at an awkward size', () async {
    // A small ring forces many wraps over a short document, which is where an
    // off-by-one in the mask shows up.
    const document = WaveformDocument([
      WaveformRegion(sourceStart: 1000, sourceEnd: 40000, gain: 0.6),
    ]);

    final expected = await platform.renderPcm(
      sourcePath: sourcePath,
      document: document,
    );

    final playback = _open(sourcePath, document, ringFrames: 2048);
    try {
      final played = _drain(playback);

      expect(played.pcm, orderedEquals(expected));
      expect(played.underruns, 0);
    } finally {
      bindings.wfPlaybackDestroy(playback);
    }
  });

  test('reports its shape from the render underneath it', () {
    const document = WaveformDocument([
      WaveformRegion(sourceStart: 0, sourceEnd: 5000),
      WaveformRegion(sourceStart: 8000, sourceEnd: 11000),
    ]);

    final playback = _open(sourcePath, document);
    try {
      expect(bindings.wfPlaybackSampleRate(playback), _sampleRate);
      expect(bindings.wfPlaybackChannels(playback), 1);
      expect(bindings.wfPlaybackLengthFrames(playback), 8000);
    } finally {
      bindings.wfPlaybackDestroy(playback);
    }
  });

  test('past the end it emits silence rather than counting underruns', () {
    // The distinction the counter exists to make: a ring that runs dry before
    // the render ends is a fault, and one that runs dry after it is the end.
    const document = WaveformDocument([
      WaveformRegion(sourceStart: 0, sourceEnd: 3000),
    ]);

    final playback = _open(sourcePath, document);
    final block = calloc<Int16>(_block);
    try {
      while (bindings.wfPlaybackFinished(playback) == 0) {
        if (bindings.wfPlaybackAvailable(playback) == 0 &&
            bindings.wfPlaybackDrained(playback) == 0) {
          sleep(const Duration(milliseconds: 1));
          continue;
        }
        bindings.wfPlaybackPull(playback, block, _block);
      }

      // Ten more pulls past the end. A device keeps asking after the audio
      // stops, and none of that is an underrun.
      for (var i = 0; i < 10; i++) {
        expect(bindings.wfPlaybackPull(playback, block, _block), 0);
      }
      expect(block.asTypedList(_block).every((s) => s == 0), isTrue);
      expect(bindings.wfPlaybackUnderruns(playback), 0);
      expect(bindings.wfPlaybackConsumed(playback), 3000);
    } finally {
      calloc.free(block);
      bindings.wfPlaybackDestroy(playback);
    }
  });

  test('an unreadable source fails to open rather than playing silence', () {
    final path = '${workspace.path}/nothing-here.wav'.toNativeUtf8();
    final regions = calloc<bindings.WfRegion>(1);
    final error = calloc<Int32>();

    try {
      regions[0]
        ..sourceStart = 0
        ..sourceEnd = 1000
        ..gain = 1.0
        ..fadeIn = 0
        ..fadeOut = 0;

      final playback = bindings.wfPlaybackCreate(
        path.cast(),
        regions,
        1,
        _ring,
        error,
      );

      expect(playback, nullptr);
      expect(error.value, 1, reason: 'WF_ERR_OPEN');
    } finally {
      calloc
        ..free(path)
        ..free(regions)
        ..free(error);
    }
  });

  test('starting without a device reports it rather than hanging', () {
    // CI has no speaker. Either it opens or it fails cleanly; what it must not
    // do is block. The same shape as the capture test.
    const document = WaveformDocument([
      WaveformRegion(sourceStart: 0, sourceEnd: 44100),
    ]);

    final playback = _open(sourcePath, document);
    try {
      final code = bindings.wfPlaybackStart(playback);
      expect(code, anyOf(0, 7), reason: 'WF_OK or WF_ERR_DEVICE');
      expect(bindings.wfPlaybackStop(playback), 0);
    } finally {
      bindings.wfPlaybackDestroy(playback);
    }
  });
}
