// Runs the real WASM binding in a real browser:
//
//   chromedriver --port=4444 &
//   flutter drive \
//     --driver=test_driver/integration_test.dart \
//     --target=integration_test/wasm_parity_test.dart \
//     -d web-server --browser-name=chrome --headless
//
// It lives here, and not under `test/` as a `flutter test --platform chrome`
// suite, because that runner cannot load the artifact at all. Its harness
// serves the compiled test bundle and nothing else, so
// `rootBundle.load('packages/monowave/assets/monowave.wasm')` never completes -
// it does not throw, it hangs, and the suite dies on the framework's twelve
// minute timeout having run no test. That is why this file spent its first few
// months on a `continue-on-error` job describing itself as unproven: it was not
// a flaky runner, and it was not local. `flutter drive` builds and serves the
// example itself, assets included, which is the one arrangement where the web
// binding can reach the WASM module.
//
// This is the test that catches a drift between `src/` and
// `assets/monowave.wasm`, a rename the extension types cannot see at compile
// time, or a `_copyOut` that reads a series out of the heap and then forgets to
// pass it on.
//
// EVERY CASE HERE MUST BE `testWidgets`, NOT `test`. `integrationDriver` decides
// the exit code from `IntegrationTestWidgetsFlutterBinding.results`, and only
// `testWidgets` records into it - a plain `test` leaves the map empty, an empty
// map reads as "all passed", and the driver prints `All tests passed.` and exits
// 0 no matter what failed. This file was written with `test` first and a
// deliberately broken assertion still went green, which is the same species of
// bug as the one the file exists to catch.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monowave/monowave.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(MonowavePlatform.instance.ensureInitialized);

  testWidgets('the WASM core reports the same ABI as the native core', (
    tester,
  ) async {
    expect(MonowavePlatform.instance.abiVersion(), 14);
  });

  testWidgets('the WASM core reduces identically to the native core', (
    tester,
  ) async {
    final peak = MonowavePlatform.instance.reduceMinMax(
      Int16List.fromList([0, 1200, -3400, 900, -50, 32767, -32768, 7]),
    );

    expect(peak, (min: -32768, max: 32767));
  });

  testWidgets('an empty window reduces to silence', (tester) async {
    expect(MonowavePlatform.instance.reduceMinMax(Int16List(0)), (
      min: 0,
      max: 0,
    ));
  });

  testWidgets('the WASM binding returns the RMS series, not just the peaks', (
    tester,
  ) async {
    // The one leg of the RMS parity that neither the compiler nor
    // `tool/verify_wasm.mjs` can reach. The node gate proves the artifact
    // computes RMS and exports it; the extension type makes a missing member a
    // compile error. Neither notices a `_copyOut` that reads the series and
    // then forgets to pass it on - which is half of how 0.3.0 shipped `rms`
    // returning null on web while it worked on all five native targets.
    final peaks = await MonowavePlatform.instance.decodeBytes(_sine());
    addTearDown(peaks.dispose);

    for (var level = 0; level < peaks.levels; level++) {
      expect(
        peaks.rms(level),
        isNotNull,
        reason: 'the C core always computes RMS, on every target',
      );
      expect(peaks.rms(level), hasLength(peaks.pairCount(level)));
    }

    // And it is the real series rather than zeros: the same assertion
    // `test/decode_test.dart` makes natively, so the two targets are held to
    // one property. A sine reduces to about its peak over root two.
    expect(peaks.rms(0)![10], closeTo(20000 / math.sqrt2, 600));
  });

  // The node check in tool/verify_wasm.mjs proves the WASM renderer is
  // byte-identical to the native one. What it cannot exercise is this: the real
  // Dart web binding, its `_Core` extension type, and its handling of a heap
  // that moves underneath it. These properties hold with no pinned constant to
  // regenerate.
  const document = WaveformDocument([
    WaveformRegion(sourceStart: 1000, sourceEnd: 9000, fadeIn: 400),
    WaveformRegion(sourceStart: 20000, sourceEnd: 24000, fadeOut: 600),
  ]);

  testWidgets('the WASM binding renders a document', (tester) async {
    final pcm = await MonowavePlatform.instance.renderPcmBytes(
      bytes: _sine(),
      document: document,
    );

    expect(pcm, hasLength(8000 + 4000));
    // Linear fades are what make these exact rather than merely small.
    expect(pcm.first, 0, reason: 'the first frame of a fade-in');
    expect(pcm.last, 0, reason: 'the last frame of a fade-out');
  });

  testWidgets('gain scales the rendered samples', (tester) async {
    // Self-contained: two renders of the same audio, one at half gain. No
    // pinned digest to regenerate, and it still exercises the whole path.
    const loud = WaveformDocument([
      WaveformRegion(sourceStart: 5000, sourceEnd: 6000),
    ]);
    const quiet = WaveformDocument([
      WaveformRegion(sourceStart: 5000, sourceEnd: 6000, gain: 0.5),
    ]);

    final platform = MonowavePlatform.instance;
    final atFull = await platform.renderPcmBytes(
      bytes: _sine(),
      document: loud,
    );
    final atHalf = await platform.renderPcmBytes(
      bytes: _sine(),
      document: quiet,
    );

    expect(atHalf, hasLength(atFull.length));
    for (var i = 0; i < atFull.length; i++) {
      // Truncation toward zero, so half of an odd value lands one below.
      expect((atFull[i] * 0.5).truncate() - atHalf[i], inInclusiveRange(0, 1));
    }
  });

  testWidgets('the WASM binding reports undecodable bytes', (tester) async {
    await expectLater(
      MonowavePlatform.instance.renderPcmBytes(
        bytes: Uint8List.fromList(List.filled(64, 0)),
        document: document,
      ),
      throwsA(isA<MonowaveDecodeException>()),
    );
  });

  // Web playback. The browser will not start an AudioContext without a user
  // gesture, and a driven test has none - so `play` is asserted the way the
  // native "no device" test is: it either works or it reports why, and what it
  // must not do is hang. Everything that does not need the speaker is asserted
  // outright.
  testWidgets('the web binding opens a playback session', (tester) async {
    const document = WaveformDocument([
      WaveformRegion(sourceStart: 0, sourceEnd: 22050),
    ]);

    final session = await MonowavePlatform.instance.openPlaybackBytes(
      bytes: _sine(),
      document: document,
    );
    addTearDown(session.dispose);

    expect(session.duration, const Duration(milliseconds: 500));
    expect(session.position, Duration.zero);
    expect(session.isPlaying, isFalse);
    expect(session.isFinished, isFalse);
    // No feeder on web, so no race for it to lose.
    expect(session.underruns, 0);
  });

  testWidgets('the web session seeks and swaps documents', (tester) async {
    const before = WaveformDocument([
      WaveformRegion(sourceStart: 0, sourceEnd: 44100),
    ]);
    const after = WaveformDocument([
      WaveformRegion(sourceStart: 0, sourceEnd: 22050, gain: 0.5),
    ]);

    final session = await MonowavePlatform.instance.openPlaybackBytes(
      bytes: _sine(),
      document: before,
    );
    addTearDown(session.dispose);

    await session.seek(const Duration(milliseconds: 750));
    expect(session.position, const Duration(milliseconds: 750));

    await session.seek(const Duration(hours: 1));
    expect(session.position, session.duration, reason: 'a seek past the end');

    await session.seek(const Duration(milliseconds: 100));
    await session.setDocument(after);

    expect(session.document, same(after));
    expect(session.duration, const Duration(milliseconds: 500));
    expect(
      session.position,
      const Duration(milliseconds: 100),
      reason: 'the playhead keeps its output position across a swap',
    );
  });

  testWidgets('the web session reports a blocked audio context', (
    tester,
  ) async {
    final session = await MonowavePlatform.instance.openPlaybackBytes(
      bytes: _sine(),
      document: const WaveformDocument([
        WaveformRegion(sourceStart: 0, sourceEnd: 4410),
      ]),
    );
    addTearDown(session.dispose);

    try {
      await session.play();
      expect(session.isPlaying, isTrue);
      await session.pause();
      expect(session.isPlaying, isFalse);
    } on PlaybackUnavailable catch (error) {
      // Autoplay policy. The message has to say what to do about it.
      expect(session.isPlaying, isFalse);
      expect(error.message, contains('user gesture'));
    }
  });

  testWidgets('the web session refuses an empty document', (tester) async {
    await expectLater(
      MonowavePlatform.instance.openPlaybackBytes(
        bytes: _sine(),
        document: const WaveformDocument([]),
      ),
      throwsA(isA<PlaybackUnavailable>()),
    );
  });
}

/// One second of a 440 Hz sine at 20000, in a canonical 44-byte WAV container.
///
/// Synthesized here rather than imported from `Fixtures`: that file reaches for
/// `dart:io` to write a source file, which does not compile for web.
Uint8List _sine({int sampleRate = 44100, double amplitude = 20000}) {
  final samples = Int16List.fromList([
    for (var i = 0; i < sampleRate; i++)
      (math.sin(2 * math.pi * 440 * i / sampleRate) * amplitude).round(),
  ]);

  final out = Uint8List(44 + samples.length * 2);
  final data = ByteData.sublistView(out);

  void ascii(int offset, String tag) {
    for (var i = 0; i < tag.length; i++) {
      out[offset + i] = tag.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little) // PCM header size
    ..setUint16(20, 1, Endian.little) // format: PCM
    ..setUint16(22, 1, Endian.little) // channels
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little) // byte rate
    ..setUint16(32, 2, Endian.little) // block align
    ..setUint16(34, 16, Endian.little); // bits per sample
  ascii(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }

  return out;
}
