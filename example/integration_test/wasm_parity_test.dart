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
    expect(MonowavePlatform.instance.abiVersion(), 10);
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
