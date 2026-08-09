// The M8 exit criteria: a seek lands where it says, the clock does not drift,
// and the fake answers the way the real session does.
//
// Driven through `pullSynthetic` rather than a speaker, for the reason M7 gives:
// the audio-thread entry point is public so the realtime path is testable on
// every platform, and a device paced against a real clock would cost CI a
// wall-clock minute to learn nothing extra.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:monowave/monowave.dart';
import 'package:monowave/src/playback/ffi_playback_session.dart';
import 'package:monowave/testing.dart';
import 'package:test/test.dart';

import 'fixtures.dart' as fixtures;

const _sampleRate = 44100;
const _frames = _sampleRate * 4;
const _block = 512;

/// The whole document, so a seek has somewhere to land.
const _document = WaveformDocument([
  WaveformRegion(sourceStart: 0, sourceEnd: _frames),
]);

/// Two regions, so a seek has to walk rather than divide.
const _edited = WaveformDocument([
  WaveformRegion(sourceStart: 0, sourceEnd: 20000),
  WaveformRegion(sourceStart: 100000, sourceEnd: 140000, gain: 0.5),
]);

/// Waits until the feeder has at least [frames] ready, or the render is done.
///
/// [frames] must be at least one. Waiting for zero is satisfied immediately,
/// which is not waiting at all - and a loop that pulls on that races the feeder
/// and passes only on a machine fast enough to have filled the ring already.
void _waitForRing(FfiPlaybackSession session, int frames) {
  assert(frames >= 1, 'waiting for zero frames is not waiting');
  for (var spin = 0; spin < 5000; spin++) {
    if (session.buffered >= frames || session.isFinished) return;
    sleep(const Duration(milliseconds: 1));
  }
  fail('the feeder never produced $frames frames');
}

/// Waits until the render is exhausted and the ring is empty.
void _waitForFinished(FfiPlaybackSession session) {
  for (var spin = 0; spin < 5000; spin++) {
    if (session.isFinished) return;
    sleep(const Duration(milliseconds: 1));
  }
  fail('the render never finished');
}

void main() {
  final platform = MonowavePlatform.instance;
  late Directory workspace;
  late String sourcePath;

  setUpAll(() async {
    await platform.ensureInitialized();

    workspace = Directory.systemTemp.createTempSync('monowave-transport');
    sourcePath = '${workspace.path}/source.wav';
    File(sourcePath).writeAsBytesSync(
      fixtures.wav(
        Int16List.fromList([
          // A sweep rather than a steady tone: every offset sounds different,
          // so a seek that lands in the wrong place cannot pass by luck.
          for (var i = 0; i < _frames; i++)
            (math.sin(2 * math.pi * (200 + i / 40) * i / _sampleRate) * 18000)
                .round(),
        ]),
      ),
    );
  });

  tearDownAll(() => workspace.deleteSync(recursive: true));

  Future<FfiPlaybackSession> open([
    WaveformDocument document = _document,
  ]) async {
    final session = await FfiPlaybackSession.open(
      sourcePath: sourcePath,
      document: document,
    );
    addTearDown(session.dispose);
    return session;
  }

  group('a seek lands where it says', () {
    // Sample-exact, because the source is WAV. MP3 would land on a frame
    // boundary of about 1152 samples and decode forward from there.
    for (final at in const [
      Duration(seconds: 1),
      Duration(milliseconds: 2500),
    ]) {
      test('at $at', () async {
        final rendered = await platform.renderPcm(
          sourcePath: sourcePath,
          document: _document,
        );
        final expectedFrame =
            at.inMicroseconds * _sampleRate ~/ Duration.microsecondsPerSecond;

        final session = await open();
        await session.seek(at);

        // Before the pull. Taking a block moves the playhead on by exactly
        // that block, which is the point of the clock test below.
        expect(session.position, at);

        _waitForRing(session, _block);
        final got = session.pullSynthetic(_block);

        expect(got, hasLength(_block));
        expect(
          got,
          orderedEquals(
            rendered.sublist(expectedFrame, expectedFrame + _block),
          ),
          reason: 'the samples after the seek are not the ones at $at',
        );
      });
    }

    test('across a region boundary, walking rather than dividing', () async {
      // The seek target sits inside the second region, which starts at a
      // completely different source offset. A mapping that divided by a single
      // region length would land in the wrong audio entirely.
      final rendered = await platform.renderPcm(
        sourcePath: sourcePath,
        document: _edited,
      );
      const target = 25000; // 5000 frames into the second region

      final session = await open(_edited);
      await session.seek(
        Duration(
          microseconds: target * Duration.microsecondsPerSecond ~/ _sampleRate,
        ),
      );
      _waitForRing(session, _block);

      expect(
        session.pullSynthetic(_block),
        orderedEquals(rendered.sublist(target, target + _block)),
      );
    });

    test('past the end finishes rather than running off', () async {
      final session = await open();

      await session.seek(const Duration(hours: 1));

      // The playhead lands on the end rather than an hour in.
      expect(session.position, session.duration);

      expect(session.pullSynthetic(_block), isEmpty);
      _waitForFinished(session);
      expect(session.isFinished, isTrue);
    });

    test('back to zero replays from the start', () async {
      final rendered = await platform.renderPcm(
        sourcePath: sourcePath,
        document: _document,
      );

      final session = await open();
      _waitForRing(session, _block);
      final first = session.pullSynthetic(_block);

      await session.seek(Duration.zero);
      expect(session.position, Duration.zero);

      _waitForRing(session, _block);
      expect(session.pullSynthetic(_block), orderedEquals(first));
      expect(rendered.sublist(0, _block), orderedEquals(first));
    });
  });

  group('the clock', () {
    test('tracks frames consumed and never runs backwards', () async {
      final session = await open();

      expect(session.position, Duration.zero);

      var last = Duration.zero;
      var pulled = 0;
      for (var i = 0; i < 60; i++) {
        _waitForRing(session, _block);
        pulled += session.pullSynthetic(_block).length;

        final now = session.position;
        expect(now, greaterThanOrEqualTo(last), reason: 'the clock went back');
        expect(
          now.inMicroseconds,
          closeTo(
            pulled * Duration.microsecondsPerSecond / _sampleRate,
            // One device buffer of slack, which is all any consumer of an
            // audio callback can claim.
            _block * Duration.microsecondsPerSecond / _sampleRate,
          ),
          reason: 'position drifted from the frames actually consumed',
        );
        last = now;
      }
    });

    test('is the device, not a wall clock', () async {
      // The distinction that matters. A timer-driven playhead advances while
      // nothing is being consumed; this one does not move until frames do.
      final session = await open();
      _waitForRing(session, _block);

      final before = session.position;
      sleep(const Duration(milliseconds: 50));

      expect(
        session.position,
        before,
        reason: 'the playhead moved without the device consuming anything',
      );
    });

    test('stops at the end of the document', () async {
      final session = await open(
        const WaveformDocument([
          WaveformRegion(sourceStart: 0, sourceEnd: 4000),
        ]),
      );

      while (!session.isFinished) {
        _waitForRing(session, 1);
        if (session.isFinished) break;
        if (session.pullSynthetic(_block).isEmpty) break;
      }

      expect(session.position, session.duration);
      expect(session.underruns, 0);
    });
  });

  group('the session', () {
    test('reports the duration the document describes', () async {
      final session = await open(_edited);

      expect(
        session.duration,
        Duration(
          microseconds: 60000 * Duration.microsecondsPerSecond ~/ _sampleRate,
        ),
      );
      expect(session.document, same(_edited));
    });

    test('refuses an empty document', () async {
      await expectLater(
        FfiPlaybackSession.open(
          sourcePath: sourcePath,
          document: const WaveformDocument([]),
        ),
        throwsA(isA<PlaybackUnavailable>()),
      );
    });

    test('reports an unreadable source', () async {
      await expectLater(
        FfiPlaybackSession.open(
          sourcePath: '${workspace.path}/nothing-here.wav',
          document: _document,
        ),
        throwsA(isA<PlaybackUnavailable>()),
      );
    });

    test('refuses use after dispose, but still answers its counters', () async {
      final session = await FfiPlaybackSession.open(
        sourcePath: sourcePath,
        document: _document,
      );
      _waitForRing(session, _block);
      session.pullSynthetic(_block);

      final position = session.position;
      await session.dispose();

      expect(session.position, position);
      expect(session.underruns, 0);
      expect(session.isFinished, isTrue);
      expect(() => session.pullSynthetic(_block), throwsStateError);
      await expectLater(session.seek(Duration.zero), throwsStateError);

      // Idempotent: a double destroy would corrupt the heap.
      await session.dispose();
    });

    test('play reports a missing device rather than hanging', () async {
      // CI has no speaker. Either it opens or it fails cleanly.
      final session = await open();

      try {
        await session.play();
        expect(session.isPlaying, isTrue);
        await session.pause();
        expect(session.isPlaying, isFalse);
      } on PlaybackUnavailable {
        expect(session.isPlaying, isFalse);
      }
    });
  });

  group('the fake', () {
    // The third exit criterion. A host that builds a scrubber against the fake
    // must not discover a different contract against a real device.
    test('matches the real session on the shared contract', () async {
      final real = await open(_edited);
      final fake = FakePlaybackSession(document: _edited);

      for (final session in <PlaybackSession>[real, fake]) {
        expect(session.duration, real.duration, reason: 'duration');
        expect(session.position, Duration.zero, reason: 'starts at zero');
        expect(session.isPlaying, isFalse);
        expect(session.isFinished, isFalse);
        expect(session.underruns, 0);
        expect(session.document, same(_edited));
      }
    });

    test('clamps a seek to the document, as the real one does', () async {
      final real = await open();
      final fake = FakePlaybackSession(document: _document);

      for (final session in <PlaybackSession>[real, fake]) {
        await session.seek(const Duration(hours: 1));
        expect(
          session.position,
          session.duration,
          reason: 'a seek past the end should land on the end',
        );

        await session.seek(const Duration(seconds: -5));
        expect(session.position, Duration.zero);
      }
    });

    test('keeps answering after dispose, like the real one', () async {
      final fake = FakePlaybackSession(document: _document);
      await fake.seek(const Duration(seconds: 1));
      await fake.dispose();

      expect(fake.position, const Duration(seconds: 1));
      expect(fake.underruns, 0);
      expect(fake.isPlaying, isFalse);
    });

    test('records what it was asked to do', () async {
      final fake = FakePlaybackSession(document: _document);

      await fake.play();
      fake.advance(const Duration(seconds: 1));
      await fake.seek(const Duration(seconds: 2));
      await fake.pause();

      expect(fake.playCount, 1);
      expect(fake.pauseCount, 1);
      expect(fake.seeks, [const Duration(seconds: 2)]);
      expect(fake.position, const Duration(seconds: 2));
    });

    test('the platform fake hands one out and records it', () async {
      final platformFake = FakeMonowavePlatform()..install();
      addTearDown(FakeMonowavePlatform.uninstall);

      final session = await MonowavePlatform.instance.openPlayback(
        sourcePath: 'take.wav',
        document: _document,
      );

      expect(platformFake.playbacks.single, same(session));
      expect(session.duration.inSeconds, 4);
    });
  });
}
